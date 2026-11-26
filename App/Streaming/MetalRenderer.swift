import CoreVideo
import Metal
// Missing from recent iOS Simulator SDKs, so simulator builds go without upscaling
#if canImport(MetalFX)
import MetalFX
#endif
import QuartzCore
import UIKit
import simd

/// Must match RenderUniforms in Shaders.metal
private struct RenderUniforms {
	var ndcScale: SIMD2<Float>
	var uvOrigin: SIMD2<Float>
	var uvSize: SIMD2<Float>
	var lumaSize: SIMD2<Float>
	var matrix: Int32
	var transferMode: Int32
	var bicubic: Int32
	var fullRange: Int32
}

/// Draws decoded YCbCr frames into a CAMetalLayer as soon as they arrive (or on a
/// steady clock while network smoothing is holding frames back, see FramePacer).
///
/// SDR uses an 8-bit BT.709 layer. HDR uses a 10-bit BT.2100 PQ layer with EDR
/// enabled, so the PS5's PQ signal goes to the display untouched and iOS
/// handles the tone mapping for the panel.
final class MetalRenderer {
	#if canImport(MetalFX)
	static let supportsMetalFX = MTLCreateSystemDefaultDevice().map {
		MTLFXSpatialScalerDescriptor.supportsDevice($0)
	} ?? false
	#else
	static let supportsMetalFX = false
	#endif

	let device: MTLDevice
	private let queue: MTLCommandQueue
	private let pipelineSDR: MTLRenderPipelineState
	private let pipelineHDR: MTLRenderPipelineState
	private var textureCache: CVMetalTextureCache?

	/// MetalFX passes: the stream at its own size into an RGB texture (16-bit float for HDR's PQ
	/// signal), then the upscaled result onto the drawable, pixel for pixel or scaled down from 4K.
	private struct MetalFXPipelines {
		let nativeFloat: MTLRenderPipelineState
		let scaledSDR: MTLRenderPipelineState
		let scaledHDR: MTLRenderPipelineState
		let downsampleSDR: MTLRenderPipelineState
		let downsampleHDR: MTLRenderPipelineState
	}
	private let metalFX: MetalFXPipelines?

	private struct SpatialKey: Equatable {
		var input: SIMD2<Int>
		var output: SIMD2<Int>
		var hdr: Bool
	}
	/// Accessed under renderLock. Also remember unsuccessful configurations so we don't retry every frame.
	private var spatialKey: SpatialKey?
	#if canImport(MetalFX)
	private var spatialScaler: MTLFXSpatialScaler?
	#endif

	private let lock = NSLock()
	private weak var layer: CAMetalLayer?
	private var drawableSize: CGSize = .zero
	private var hdrOutput = false
	private var displayMode: DisplayMode = .fit
	private var upscaling: UpscalingMode = .sharp
	private var paused = false
	/// One real video frame retained for a native-pixel snapshot, without reading live drawables.
	private struct ScreenshotFrame {
		let luma: CVMetalTexture
		let chroma: CVMetalTexture
		let uniforms: RenderUniforms
		let size: CGSize
	}
	private var screenshotFrame: ScreenshotFrame?

	// Frame generation (experimental)
	/// Switched on in settings. It only runs while the game's own frame rate fits twice into the screen's.
	private var frameGeneration = false
	/// The stream's requested frame interval, and the screen's refresh rate
	private var frameInterval: CFTimeInterval = 1.0 / 60
	private var screenHz = 60
	/// Video thread only: frame generation is wanted and new frames are being measured
	private var measuring = false
	/// Video thread only: time between new game frames, smoothed. Can be longer than the
	/// stream's frame interval, e.g. a 60 fps game in a 120 fps stream.
	private var newFrameInterval: CFTimeInterval = 1.0 / 60
	/// Video thread only: when the game's frame rate was last checked, and how many checks in a
	/// row it's been on the other side of the line (so it doesn't flip on and off)
	private var lastRateCheck: CFTimeInterval = 0
	private var rateStreak = 0
	/// Video thread only
	private let frameGenerator: FrameGenerator?
	/// Video thread only: the generator used for the last frame (nil when off)
	private var activeGenerator: FrameGenerator?
	/// Video thread only: the last real frame, kept for the next in-between
	private var previous: (luma: CVMetalTexture, chroma: CVMetalTexture)?
	/// Drawables handed to Core Animation but not on screen yet
	private var inFlight = 0
	/// Video thread only: a coarse grid of the last new frame's luma, to spot
	/// repeats, and how many stream frames ago that frame came
	private var lastSignature: [UInt8] = []
	private var framesSinceNew = 1
	/// Video thread only: whether each of the last 16 stream frames looked like
	/// a repeat of the one before (bit 0 newest), and whether repeats are being
	/// dropped because the stream settled into a 30 fps pattern (see `noteRepeat`)
	private var repeatHistory: UInt16 = 0
	private var repeatHistoryCount = 0
	private var dropRepeats = false
	/// Video thread only: when the last new frame arrived, and whether the
	/// stream lost frames since (see `noteLostFrames`)
	private var lastNewFrameAt: CFTimeInterval = 0
	private var lostSinceNew = false
	/// Debug: the last few seconds of frames shown, for the capture button (nil when off)
	private var capture: FrameCapture?
	/// Network smoothing's buffer (nil when off). Guarded by `lock`.
	private var pacer: FramePacer?
	/// "Video thread only" state below is touched by whichever thread is drawing: the
	/// video thread, or the pacer's while it's holding frames back. This keeps them apart.
	private let renderLock = NSLock()
	/// Video thread: frames were lost before the next one to be decoded
	private var pendingLost = false
	/// Video thread only: new real frames so far, numbering pairs in a capture
	private var realFrames = 0

	/// Frames presented (stats)
	private(set) var presentedFrames = 0
	/// Frames made by frame generation, and skipped because we were behind (stats)
	private(set) var generatedFrames = 0
	private(set) var skippedFrames = 0
	/// Repeats of the last frame dropped while generating (a 30 fps game in a 60 fps stream) (stats)
	private(set) var repeatedFrames = 0
	/// In-between frames not made because frames before the real one were lost or late (stats)
	private(set) var gapFrames = 0
	/// GPU time to make one in-between frame, smoothed (stats)
	private(set) var generateMs: Double = 0
	/// Frame generation's quality level when it's stepped down (stats)
	private(set) var frameGenStatus: String?
	/// Frame generation is making frames: on, and the game is slow enough for the screen (stats)
	private(set) var frameGenRunning = false
	/// New game frames a second, measured while frame generation is on; 0 before the first check (stats)
	private(set) var gameFPS: Double = 0
	/// The screen's current refresh rate, from the display link (stats)
	var displayHz: Double = 0

	init?() {
		guard let device = MTLCreateSystemDefaultDevice(),
			let queue = device.makeCommandQueue(),
			let library = device.makeDefaultLibrary()
		else { return nil }
		self.device = device
		self.queue = queue
		frameGenerator = FrameGenerator(device: device, library: library)
		if frameGenerator == nil { log.error("Frame generation shaders failed to load") }

		func pipeline(_ format: MTLPixelFormat, fragment: String = "stream_fragment") -> MTLRenderPipelineState? {
			let desc = MTLRenderPipelineDescriptor()
			desc.vertexFunction = library.makeFunction(name: "stream_vertex")
			desc.fragmentFunction = library.makeFunction(name: fragment)
			desc.colorAttachments[0].pixelFormat = format
			return try? device.makeRenderPipelineState(descriptor: desc)
		}
		guard let sdr = pipeline(.bgra8Unorm), let hdr = pipeline(.bgr10a2Unorm) else { return nil }
		pipelineSDR = sdr
		pipelineHDR = hdr
		if Self.supportsMetalFX, let nativeFloat = pipeline(.rgba16Float),
			let scaledSDR = pipeline(.bgra8Unorm, fragment: "stream_scaled_fragment"),
			let scaledHDR = pipeline(.bgr10a2Unorm, fragment: "stream_scaled_fragment"),
			let downsampleSDR = pipeline(.bgra8Unorm, fragment: "stream_downsample_fragment"),
			let downsampleHDR = pipeline(.bgr10a2Unorm, fragment: "stream_downsample_fragment")
		{
			metalFX = MetalFXPipelines(
				nativeFloat: nativeFloat, scaledSDR: scaledSDR, scaledHDR: scaledHDR,
				downsampleSDR: downsampleSDR, downsampleHDR: downsampleHDR)
		} else {
			metalFX = nil
		}
		CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
	}

	// MARK: - Configuration (main thread)

	func attach(_ layer: CAMetalLayer) {
		layer.device = device
		layer.framebufferOnly = true
		layer.maximumDrawableCount = 3
		layer.isOpaque = true
		layer.backgroundColor = UIColor.black.cgColor
		lock.withLock { self.layer = layer }
		applyOutputMode(to: layer)
	}

	/// `frameGeneration` is the setting; it runs while the measured game frame rate fits twice into `screenHz`
	func configure(
		hdr: Bool, displayMode: DisplayMode, upscaling: UpscalingMode, frameGeneration: Bool, fps: Int, frameCapture: Bool,
		smoothing: Bool, screenHz: Int
	) {
		let pacer = lock.withLock { () -> FramePacer? in
			if smoothing, self.pacer == nil {
				self.pacer = FramePacer { [weak self] pixelBuffer, lost in
					self?.renderPaced(pixelBuffer, lost: lost)
				}
			} else if !smoothing, let old = self.pacer {
				old.stop()
				self.pacer = nil
			}
			return self.pacer
		}
		pacer?.configure(fps: fps, screenHz: screenHz)
		let changed = lock.withLock { () -> Bool in
			let changed = self.hdrOutput != hdr
			self.hdrOutput = hdr
			self.displayMode = displayMode
			self.upscaling = upscaling
			self.frameGeneration = frameGeneration
			self.frameInterval = 1.0 / Double(max(fps, 1))
			self.screenHz = max(screenHz, 1)
			if frameCapture, capture == nil {
				capture = FrameCapture(device: device)
			} else if !frameCapture {
				capture = nil
			}
			return changed
		}
		if changed, let layer = lock.withLock({ self.layer }) {
			applyOutputMode(to: layer)
		}
	}

	func setDisplayMode(_ mode: DisplayMode) {
		lock.withLock { displayMode = mode }
	}

	func setPaused(_ paused: Bool) {
		lock.withLock { self.paused = paused }
	}

	/// A new connection: discard frames from the previous stream.
	func resetSmoothing() {
		lock.withLock {
			screenshotFrame = nil
			return pacer
		}?.reset()
	}

	/// Network smoothing: frames held back now, frames dropped to keep the delay bounded
	/// and times the buffer ran dry (totals). nil when smoothing is off.
	var smoothingStats: (depth: Int, dropped: Int, underruns: Int)? {
		guard let pacer = lock.withLock({ pacer }) else { return nil }
		let s = pacer.stats
		return (pacer.currentDepth, s.dropped, s.underruns)
	}

	/// Saves the frame capture at the next decoded frame (see FrameCapture)
	func saveCapture(_ completion: @escaping (Result<(URL, Int), Error>) -> Void) {
		guard let capture = lock.withLock({ capture }) else {
			completion(.failure(FrameCapture.CaptureError.off))
			return
		}
		capture.requestSave(completion)
	}


	func setDrawableSize(_ size: CGSize) {
		lock.withLock {
			drawableSize = size
			layer?.drawableSize = size
		}
	}

	private func applyOutputMode(to layer: CAMetalLayer) {
		let hdr = lock.withLock { hdrOutput }
		if hdr {
			layer.pixelFormat = .bgr10a2Unorm
			layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
			layer.wantsExtendedDynamicRangeContent = true
			// PS5 doesn't send mastering metadata over Remote Play; typical HDR10 values
			layer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)
		} else {
			layer.pixelFormat = .bgra8Unorm
			layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
			layer.wantsExtendedDynamicRangeContent = false
			layer.edrMetadata = nil
		}
	}

	/// The last real frame, whole and at the stream's own resolution: no black bars,
	/// no zoom crop and no upscaling. HDR is tone mapped to sRGB. For Screenshot.
	func renderScreenshot() async throws -> CGImage {
		guard let frame = lock.withLock({ screenshotFrame }),
			let luma = CVMetalTextureGetTexture(frame.luma), let chroma = CVMetalTextureGetTexture(frame.chroma)
		else { throw StreamScreenshot.ScreenshotError.noFrame }
		// The CoreVideo wrappers keep the decoded surfaces alive until the GPU has read them
		defer { withExtendedLifetime(frame) {} }
		let width = luma.width, height = luma.height
		guard width > 0, height > 0 else { throw StreamScreenshot.ScreenshotError.noFrame }
		let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
			width: width, height: height, mipmapped: false)
		descriptor.usage = .renderTarget
		descriptor.storageMode = .shared
		guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else {
			throw StreamScreenshot.ScreenshotError.renderFailed
		}
		var uniforms = frame.uniforms
		uniforms.ndcScale = .one
		uniforms.uvOrigin = .zero
		uniforms.uvSize = .one
		uniforms.bicubic = 0
		guard draw(luma: luma, chroma: chroma, uniforms: &uniforms, to: texture, in: buffer) else {
			throw StreamScreenshot.ScreenshotError.renderFailed
		}
		try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
			buffer.addCompletedHandler { finished in
				if finished.status == .completed { completion.resume() }
				else { completion.resume(throwing: finished.error ?? StreamScreenshot.ScreenshotError.renderFailed) }
			}
			buffer.commit()
		}

		let rowBytes = width * 4
		var pixels = Data(count: height * rowBytes)
		pixels.withUnsafeMutableBytes { bytes in
			texture.getBytes(bytes.baseAddress!, bytesPerRow: rowBytes,
				from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
		}
		let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
		let profile = uniforms.transferMode == 3 ? CGColorSpace.sRGB : CGColorSpace.itur_709
		guard let colourSpace = CGColorSpace(name: profile),
			let provider = CGDataProvider(data: pixels as CFData),
			let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
				bytesPerRow: rowBytes, space: colourSpace, bitmapInfo: bitmapInfo, provider: provider,
				decode: nil, shouldInterpolate: false, intent: .defaultIntent)
		else { throw StreamScreenshot.ScreenshotError.renderFailed }
		return image
	}

	// MARK: - Rendering (decoder thread)

	/// The stream lost frames before the next one to be decoded. Video thread
	/// (decoding is synchronous, so this comes before that frame's `display`).
	func noteLostFrames() {
		pendingLost = true
	}

	/// A decoded frame. Video thread.
	func display(_ pixelBuffer: CVPixelBuffer) {
		let lost = pendingLost
		pendingLost = false
		if let pacer = lock.withLock({ pacer }), pacer.submit(pixelBuffer, lost: lost) {
			return
		}
		renderLock.withLock {
			if lost { lostSinceNew = true }
			render(pixelBuffer)
		}
	}

	/// A frame the smoothing buffer held back, now due. Pacer thread.
	private func renderPaced(_ pixelBuffer: CVPixelBuffer, lost: Bool) {
		renderLock.withLock {
			if lost { lostSinceNew = true }
			render(pixelBuffer)
		}
	}

	/// Call with `renderLock` held
	private func render(_ pixelBuffer: CVPixelBuffer) {
		lock.lock()
		let layer = self.layer
		let target = drawableSize
		let hdr = hdrOutput
		let mode = displayMode
		let upscaling = self.upscaling
		let paused = self.paused
		let frameGeneration = self.frameGeneration
		let interval = frameInterval
		let screenHz = self.screenHz
		let inFlight = self.inFlight
		let generateMs = self.generateMs
		let capture = self.capture
		lock.unlock()

		// Measuring new frames runs whenever frame generation is switched on, generating or not
		let wanted = frameGeneration && !paused
		if wanted != measuring {
			measuring = wanted
			lastSignature = []
			framesSinceNew = 1
			repeatHistory = 0
			repeatHistoryCount = 0
			dropRepeats = false
			lastNewFrameAt = 0
			lostSinceNew = false
			newFrameInterval = interval
			lastRateCheck = 0
			rateStreak = 0
			// Start as the requested frame rate allows; the measurement corrects it
			frameGenRunning = wanted && interval * Double(screenHz) >= 2 * 0.95
			gameFPS = 0
		}
		let generator = pickGenerator(wanted && frameGenRunning)
		if generator !== activeGenerator {
			previous = nil
			activeGenerator?.reset()
			activeGenerator = generator
			lock.withLock { self.generateMs = 0 }
		}
		if let capture {
			let name =
				generator.map {
					"custom (motion map \($0.flowFormat == .rg16Float ? "rg16Float" : "rg32Float"), level \($0.level))"
				} ?? "off"
			capture.frameStart(generator: name, streamFps: Int((1 / interval).rounded()))
		}
		guard !paused, let layer, target.width > 0, target.height > 0, let cache = textureCache else { return }

		let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
		let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
			|| pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
		let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
			|| pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

		// A 30 fps game in a 60 fps stream sends every frame twice. Generating
		// between a frame and its repeat is wasted (and leaves the output
		// uneven), so while generating, repeats are dropped and the in-between
		// goes halfway between the two different frames, spread over the time
		// the game frame lasts. Up to two repeats in a row (20 fps); after that
		// the frame counts as new, so a still scene keeps updating. Only once the
		// stream shows a steady new/repeat pattern: in a 60 fps game a frame with
		// little motion can look like a repeat, and dropping it is a visible hitch.
		var gap = interval
		// Frames lost, or a hitch (the console or network stalled): the last
		// real frame and this one can be several game frames apart, too far
		// for the motion search, so blending them makes things vanish or
		// smear. Show only the real frame then.
		var discontinuity = false
		if wanted {
			let signature = Self.lumaSignature(pixelBuffer, tenBit: tenBit)
			let looksRepeated = Self.isRepeat(signature, of: lastSignature)
			noteRepeat(looksRepeated)
			if dropRepeats, looksRepeated, framesSinceNew < 3 {
				framesSinceNew += 1
				if generator != nil {
					repeatedFrames += 1
					capture?.note(.repeated, pair: realFrames)
					return
				}
				// Not generating: still shown, but it isn't a new game frame
			} else {
				lastSignature = signature
				framesSinceNew = 1
				let now = CACurrentMediaTime()
				let since = now - lastNewFrameAt
				discontinuity = lostSinceNew || (lastNewFrameAt > 0 && since > newFrameInterval * 2.5)
				if lastNewFrameAt > 0, !lostSinceNew {
					// Capped, so a hitch nudges it rather than throwing it, but a real drop still gets there
					newFrameInterval = newFrameInterval * 0.9 + min(since, newFrameInterval * 2) * 0.1
				}
				lastNewFrameAt = now
				lostSinceNew = false
				gap = newFrameInterval
				checkGameRate(now: now, screenHz: screenHz)
			}
		}
		realFrames += 1

		guard let luma = makeTexture(pixelBuffer, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
			let chroma = makeTexture(pixelBuffer, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache),
			let lumaTex = CVMetalTextureGetTexture(luma),
			let chromaTex = CVMetalTextureGetTexture(chroma)
		else { return }

		// Colour metadata from the stream
		let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
		let matrixKey = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
		let framePQ = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
		let bt2020 = matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) || framePQ

		let transferMode: Int32 =
			switch (framePQ, hdr) {
			case (true, true), (false, false): 0
			case (false, true): 1
			case (true, false): 2
			}

		// Fit / zoom geometry
		let videoW = Float(lumaTex.width)
		let videoH = Float(lumaTex.height)
		let tw = Float(target.width)
		let th = Float(target.height)
		let fitScale = min(tw / videoW, th / videoH)
		let zoomScale = max(tw / videoW, th / videoH)
		let scale = mode == .fit ? fitScale : zoomScale
		let dw = videoW * scale
		let dh = videoH * scale
		var ndcScale = SIMD2<Float>(min(dw / tw, 1), min(dh / th, 1))
		var uvSize = SIMD2<Float>(min(tw / dw, 1), min(th / dh, 1))
		if mode == .fit { uvSize = .one } else { ndcScale = .one }
		let uvOrigin = (SIMD2<Float>.one - uvSize) * 0.5

		var uniforms = RenderUniforms(
			ndcScale: ndcScale, uvOrigin: uvOrigin, uvSize: uvSize,
			lumaSize: SIMD2(videoW, videoH),
			matrix: bt2020 ? 1 : 0, transferMode: transferMode,
			bicubic: (upscaling != .bilinear && scale > 1.01) ? 1 : 0, fullRange: fullRange ? 1 : 0)

		// Native: scale just the picture, not the black bars, and crop after upscaling in zoom mode.
		// 4K: upscale to fit 3840x2160, then scale that down onto the screen.
		let to4K = upscaling == .metalFX4K
		let scaledSize: SIMD2<Int>
		if to4K {
			let f = min(3840 / videoW, 2160 / videoH)
			scaledSize = SIMD2(Int((videoW * f).rounded()), Int((videoH * f).rounded()))
		} else {
			scaledSize = SIMD2(Int(dw.rounded()), Int(dh.rounded()))
		}
		let useMetalFX = upscaling.usesMetalFX && metalFX != nil
			&& scaledSize.x > lumaTex.width && scaledSize.y > lumaTex.height
		if !useMetalFX {
			spatialKey = nil
			#if canImport(MetalFX)
			spatialScaler = nil
			#endif
		}

		func drawFrame(luma: MTLTexture, chroma: MTLTexture, to texture: MTLTexture, in buffer: MTLCommandBuffer) {
			if useMetalFX, drawMetalFX(luma: luma, chroma: chroma, uniforms: uniforms, size: scaledSize,
				downsample: to4K, to: texture, in: buffer) { return }
			draw(luma: luma, chroma: chroma, uniforms: &uniforms, to: texture, in: buffer)
		}

		guard var commandBuffer = queue.makeCommandBuffer() else { return }

		// Frame generation: show the in-between frame now and the real one half a
		// frame later. Costs half a frame of delay, since the in-between needs
		// the newer frame.
		var generated = false
		/// The in-between frame shown, for the capture (copied in the next command buffer)
		var capturedGenerated: (seq: Int, luma: MTLTexture, chroma: MTLTexture)?
		if let generator {
			let paired = generator.push(
				luma: lumaTex, chroma: chromaTex, bt2020: bt2020, fullRange: fullRange, into: commandBuffer)
			if paired, let previous, let prevLuma = CVMetalTextureGetTexture(previous.luma),
				let prevChroma = CVMetalTextureGetTexture(previous.chroma)
			{
				// Generators step their quality down when they can't keep up
				// (e.g. the phone throttling) and back up when there's room
				if generator.adapt(generateMs: generateMs, interval: gap) {
					lock.withLock { self.generateMs = 0 }
				}
				// Two or more still waiting for the screen: we're behind, so show
				// only the real frame rather than queue up more delay
				if discontinuity {
					gapFrames += 1
					capture?.note(.gap, pair: realFrames)
				} else if inFlight >= 2 {
					skippedFrames += 1
					capture?.note(.skipped, pair: realFrames)
				} else if let drawable = layer.nextDrawable(), let outLuma = generator.outLuma,
					let outChroma = generator.outChroma
				{
					generator.interpolate(
						previous: (prevLuma, prevChroma), current: (lumaTex, chromaTex), into: commandBuffer)
					// Time frame generation on its own: the draw (MetalFX 4K especially) would
					// inflate it and make the generator step its quality down for no reason
					commandBuffer.addCompletedHandler { [weak self] buffer in
						_ = (previous, luma, chroma)
						let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
						guard let self, ms > 0 else { return }
						self.lock.withLock { self.generateMs = self.generateMs == 0 ? ms : self.generateMs * 0.9 + ms * 0.1 }
					}
					commandBuffer.commit()
					guard let drawBuffer = queue.makeCommandBuffer() else { return }
					commandBuffer = drawBuffer
					drawFrame(luma: outLuma, chroma: outChroma, to: drawable.texture, in: commandBuffer)
					let seq = capture?.reserve(.generated, pair: realFrames)
					if let seq { capturedGenerated = (seq, outLuma, outChroma) }
					track(drawable, in: commandBuffer, captureSeq: seq, capture: capture)
					commandBuffer.present(drawable)
					commandBuffer.commit()
					generatedFrames += 1
					generated = true
					guard let next = queue.makeCommandBuffer() else { return }
					commandBuffer = next
				}
			}
			self.previous = (luma, chroma)
		}

		// Keep the CVMetalTextures alive until the GPU is done with them
		commandBuffer.addCompletedHandler { _ in
			_ = luma
			_ = chroma
		}
		// Capture copies go in this command buffer, after the in-between was
		// drawn and before the next one overwrites the generator's output
		var realSeq: Int?
		if let capture {
			if let g = capturedGenerated {
				capture.copy(
					seq: g.seq, luma: g.luma, chroma: g.chroma, bt2020: bt2020, fullRange: fullRange, into: commandBuffer)
			}
			realSeq = capture.reserve(.real, pair: realFrames)
			if let realSeq {
				capture.copy(
					seq: realSeq, luma: lumaTex, chroma: chromaTex, bt2020: bt2020, fullRange: fullRange, into: commandBuffer)
			}
		}

		guard let drawable = layer.nextDrawable() else {
			commandBuffer.commit()
			return
		}
		drawFrame(luma: lumaTex, chroma: chromaTex, to: drawable.texture, in: commandBuffer)
		track(drawable, in: commandBuffer, captureSeq: realSeq, capture: capture)
		#if targetEnvironment(simulator)
		// The simulator has no paced presentation, so the real frame just follows the generated one
		commandBuffer.present(drawable)
		#else
		if generated {
			// Slightly under half, so a late frame doesn't push every following one later
			commandBuffer.present(drawable, afterMinimumDuration: gap * 0.45)
		} else {
			commandBuffer.present(drawable)
		}
		#endif
		commandBuffer.commit()
		// Export HDR frames through the PNG-specific sRGB tone and gamut mapping path.
		uniforms.transferMode = framePQ ? 3 : 0
		lock.withLock {
			screenshotFrame = ScreenshotFrame(luma: luma, chroma: chroma, uniforms: uniforms,
				size: CGSize(width: drawable.texture.width, height: drawable.texture.height))
		}
		presentedFrames += 1
	}

	/// Once a second: frame generation runs when the game's frame rate fits twice into the
	/// screen's, and stops after two checks clearly above. The gap between keeps a game
	/// hovering around 60 from flipping it on and off. Video thread only.
	private func checkGameRate(now: CFTimeInterval, screenHz: Int) {
		guard lastRateCheck > 0 else {
			lastRateCheck = now
			return
		}
		guard now - lastRateCheck >= 1 else { return }
		lastRateCheck = now
		let fps = 1 / newFrameInterval
		gameFPS = fps
		let limit = Double(screenHz) / 2
		let flip = frameGenRunning ? fps > limit * 1.12 : fps <= limit * 1.05
		rateStreak = flip ? rateStreak + 1 : 0
		guard rateStreak >= 2 else { return }
		rateStreak = 0
		frameGenRunning.toggle()
		log.notice("Frame gen: game at \(Int(fps.rounded()), privacy: .public) fps on a \(screenHz, privacy: .public) Hz screen, \(self.frameGenRunning ? "generating" : "paused", privacy: .public)")
	}

	/// Tracks whether recent stream frames looked like repeats, and turns repeat
	/// dropping on when they alternate new/repeat (a 30 fps game in a 60 fps
	/// stream) and off when they stop. A 60 fps game never alternates: its odd
	/// look-alike frame is isolated, and a still scene is a run of look-alikes.
	/// Video thread only.
	private func noteRepeat(_ repeated: Bool) {
		repeatHistory = repeatHistory << 1 | (repeated ? 1 : 0)
		repeatHistoryCount = min(repeatHistoryCount + 1, 16)
		guard repeatHistoryCount == 16 else { return }
		// Changes between neighbouring frames, out of 15; 30 fps gives about 15
		let changes = ((repeatHistory ^ (repeatHistory >> 1)) & 0x7FFF).nonzeroBitCount
		if !dropRepeats, changes >= 12 {
			dropRepeats = true
			log.notice("Frame gen: stream repeats frames (30 fps game), dropping repeats")
		} else if dropRepeats, changes < 8 {
			dropRepeats = false
			log.notice("Frame gen: stream stopped repeating frames, showing every frame")
		}
	}

	/// Luma on a 96x54 grid (8-bit), read straight from the decoded frame
	private static func lumaSignature(_ pb: CVPixelBuffer, tenBit: Bool) -> [UInt8] {
		guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return [] }
		defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
		let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
		let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
		let cols = 96, rows = 54
		var out = [UInt8](repeating: 0, count: cols * rows)
		for r in 0..<rows {
			let row = base.advanced(by: ((r * 2 + 1) * h / (rows * 2)) * stride)
			for c in 0..<cols {
				let x = (c * 2 + 1) * w / (cols * 2)
				// 10-bit samples sit in the top bits of 16
				out[r * cols + c] =
					tenBit ? UInt8(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 8) : row.load(fromByteOffset: x, as: UInt8.self)
			}
		}
		return out
	}

	/// Same picture give or take compression noise: hardly any sample moved
	/// much. A small thing moving (a character idling) still changes a few
	/// samples by a lot, so that counts as new.
	private static func isRepeat(_ a: [UInt8], of b: [UInt8]) -> Bool {
		guard !a.isEmpty, a.count == b.count else { return false }
		var big = 0, total = 0
		for i in 0..<a.count {
			let d = abs(Int(a[i]) - Int(b[i]))
			total += d
			if d > 12 { big += 1 }
		}
		return big <= 2 && Double(total) / Double(a.count) < 1.5
	}

	/// The generator to use, or nil when frame generation is off. Video thread only.
	private func pickGenerator(_ on: Bool) -> FrameGenerator? {
		let picked = on ? frameGenerator : nil
		let status = picked.flatMap { $0.status.isEmpty ? nil : "quality \($0.status)" }
		if status != frameGenStatus { lock.withLock { frameGenStatus = status } }
		return picked
	}

	#if !canImport(MetalFX)
	private func drawMetalFX(
		luma: MTLTexture, chroma: MTLTexture, uniforms: RenderUniforms, size: SIMD2<Int>, downsample: Bool,
		to texture: MTLTexture, in commandBuffer: MTLCommandBuffer
	) -> Bool { false }
	#else
	private func drawMetalFX(
		luma: MTLTexture, chroma: MTLTexture, uniforms: RenderUniforms, size: SIMD2<Int>, downsample: Bool,
		to texture: MTLTexture, in commandBuffer: MTLCommandBuffer
	) -> Bool {
		guard let metalFX else { return false }
		// Follow the drawable, which can lag an HDR switch by a frame
		let hdrTarget = texture.pixelFormat == .bgr10a2Unorm
		let key = SpatialKey(input: SIMD2(luma.width, luma.height), output: size, hdr: hdrTarget)
		if spatialKey != key {
			spatialKey = key
			spatialScaler = makeSpatialScaler(key)
		}
		guard let scaler = spatialScaler, let input = scaler.colorTexture, let output = scaler.outputTexture else {
			return false
		}

		var native = uniforms
		native.ndcScale = .one
		native.uvOrigin = .zero
		native.uvSize = .one
		native.bicubic = 0
		guard draw(luma: luma, chroma: chroma, uniforms: &native, to: input, in: commandBuffer) else { return false }
		scaler.encode(commandBuffer: commandBuffer)

		guard let encoder = makeDrawEncoder(to: texture, in: commandBuffer) else { return false }
		if downsample {
			// 4K: scale down with the usual Fit/Zoom geometry
			var geometry = uniforms
			encoder.setRenderPipelineState(hdrTarget ? metalFX.downsampleHDR : metalFX.downsampleSDR)
			encoder.setVertexBytes(&geometry, length: MemoryLayout<RenderUniforms>.stride, index: 0)
		} else {
			// Centre the output on whole pixels so compositing doesn't filter it a second time.
			// Positive offsets leave black bars; negative offsets crop to the drawable.
			let x = (texture.width - output.width) / 2
			let y = (texture.height - output.height) / 2
			var origin = SIMD2(Int32(x), Int32(y))
			encoder.setRenderPipelineState(hdrTarget ? metalFX.scaledHDR : metalFX.scaledSDR)
			encoder.setScissorRect(MTLScissorRect(x: max(x, 0), y: max(y, 0),
				width: min(texture.width, output.width), height: min(texture.height, output.height)))
			encoder.setVertexBytes(&native, length: MemoryLayout<RenderUniforms>.stride, index: 0)
			encoder.setFragmentBytes(&origin, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
		}
		encoder.setFragmentTexture(output, index: 0)
		encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		encoder.endEncoding()
		return true
	}

	private func makeSpatialScaler(_ key: SpatialKey) -> MTLFXSpatialScaler? {
		// PQ is a perceptual curve in 0...1, like SDR gamma, so both use perceptual mode
		let format: MTLPixelFormat = key.hdr ? .rgba16Float : .bgra8Unorm
		let desc = MTLFXSpatialScalerDescriptor()
		desc.inputWidth = key.input.x
		desc.inputHeight = key.input.y
		desc.outputWidth = key.output.x
		desc.outputHeight = key.output.y
		desc.colorTextureFormat = format
		desc.outputTextureFormat = format
		desc.colorProcessingMode = .perceptual
		guard let scaler = desc.makeSpatialScaler(device: device) else { return nil }

		func makeTexture(width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
			let desc = MTLTextureDescriptor.texture2DDescriptor(
				pixelFormat: format, width: width, height: height, mipmapped: false)
			desc.storageMode = .private
			// Every pass and frame uses the same queue, with tracked textures for its dependencies.
			desc.hazardTrackingMode = .tracked
			desc.usage = usage
			return device.makeTexture(descriptor: desc)
		}
		guard let input = makeTexture(width: key.input.x, height: key.input.y,
				usage: scaler.colorTextureUsage.union(.renderTarget)),
			let output = makeTexture(width: key.output.x, height: key.output.y,
				usage: scaler.outputTextureUsage.union(.shaderRead))
		else { return nil }
		scaler.colorTexture = input
		scaler.outputTexture = output
		scaler.inputContentWidth = key.input.x
		scaler.inputContentHeight = key.input.y
		return scaler
	}
	#endif

	private func makeDrawEncoder(to texture: MTLTexture, in commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store
		return commandBuffer.makeRenderCommandEncoder(descriptor: pass)
	}

	@discardableResult
	private func draw(
		luma: MTLTexture, chroma: MTLTexture, uniforms: inout RenderUniforms, to texture: MTLTexture,
		in commandBuffer: MTLCommandBuffer
	) -> Bool {
		// The layer's pixel format can lag a settings change by a frame
		let pipeline: MTLRenderPipelineState
		switch texture.pixelFormat {
		case .bgr10a2Unorm: pipeline = pipelineHDR
		case .rgba16Float:
			guard let nativeFloat = metalFX?.nativeFloat else { return false }
			pipeline = nativeFloat
		default: pipeline = pipelineSDR
		}
		guard let encoder = makeDrawEncoder(to: texture, in: commandBuffer) else { return false }
		encoder.setRenderPipelineState(pipeline)
		encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
		encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
		encoder.setFragmentTexture(luma, index: 0)
		encoder.setFragmentTexture(chroma, index: 1)
		encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		encoder.endEncoding()
		return true
	}

	/// Counts the drawable as in flight until it reaches the screen (or is dropped).
	/// Call before committing `commandBuffer`.
	private func track(
		_ drawable: CAMetalDrawable, in commandBuffer: MTLCommandBuffer, captureSeq: Int? = nil,
		capture: FrameCapture? = nil
	) {
		lock.withLock { inFlight += 1 }
		#if targetEnvironment(simulator)
		// No presented handlers on the simulator: treat the GPU finishing as the frame being shown
		_ = drawable
		commandBuffer.addCompletedHandler { [weak self] _ in
			if let captureSeq, let capture { capture.presented(seq: captureSeq, at: CACurrentMediaTime()) }
			guard let self else { return }
			self.lock.withLock { self.inFlight -= 1 }
		}
		#else
		_ = commandBuffer
		drawable.addPresentedHandler { [weak self] shown in
			if let captureSeq, let capture { capture.presented(seq: captureSeq, at: shown.presentedTime) }
			guard let self else { return }
			self.lock.withLock { self.inFlight -= 1 }
		}
		#endif
	}

	private func makeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
		let w = CVPixelBufferGetWidthOfPlane(pb, plane)
		let h = CVPixelBufferGetHeightOfPlane(pb, plane)
		var texture: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &texture)
		return status == kCVReturnSuccess ? texture : nil
	}
}

/// Hosts a CAMetalLayer at the screen's native pixel density and routes screen touches.
final class StreamMetalView: UIView {
	private let metalLayer = CAMetalLayer()

	let renderer: MetalRenderer

	/// Top-right hot corner (settings)
	var onCornerTap: (() -> Void)?
	/// Top-left hot corner (Xbox button)
	var onLeftCornerTap: (() -> Void)?
	var onVirtualPad: ((VirtualPadState) -> Void)?
	var onReset: (() -> Void)?
	private var acceptsInput = false
	private let controls = VirtualControlsOverlay(frame: .zero)
	private var controlsArea = CGRect.null
	private var systemButtonY: CGFloat?
	var videoAspectForLetterbox: CGFloat? {
		didSet { if videoAspectForLetterbox != oldValue { setNeedsLayout() } }
	}
	var onFrameGenerationTap: (() -> Void)?
	private var frameGenerationTouches: Set<ObjectIdentifier> = []
	/// Touches on the picture work as a mouse: pointing straight at things with a controller,
	/// and as a trackpad in the top half with virtual controls up.
	var onMouse: ((TouchMouse.Event) -> Void)? {
		didSet { mouse.onEvent = onMouse }
	}
	private let mouse = TouchMouse()
	private var touchMouse = false
	/// Three fingers tapped together: toggles the iPhone keyboard, like Moonlight
	var onThreeFingerTap: (() -> Void)?
	/// When and where each finger on the view landed, so a third finger joining thumbs
	/// that are already on the sticks or buttons isn't mistaken for a three-finger tap
	private var touchStarts: [ObjectIdentifier: (time: CFTimeInterval, point: CGPoint)] = [:]
	/// A three-finger tap in progress: until every finger lifts, touches skip the controls
	/// and the mouse. Not valid once a finger wanders, a fourth lands or it's held too long.
	private var threeFinger: (began: CFTimeInterval, valid: Bool)?
	/// How close together the three fingers must land, and the longest tap
	private static let threeFingerLanding: CFTimeInterval = 0.15
	private static let threeFingerTapTime: CFTimeInterval = 0.4
	private static let threeFingerSlop: CGFloat = 20
	/// The picture's width over height, and whether it's zoomed to fill the view
	var videoAspect: CGFloat = 16.0 / 9.0
	var fillsView = false
	static let frameGenerationCornerSize = CGSize(width: 130, height: 90)

	/// Hot corner size in points, at the top-right and top-left of the view
	static let cornerSize = CGSize(width: 140, height: 90)

	/// Ask a ProMotion screen for 120 Hz while this view is on screen
	var highRefresh = true {
		didSet { if highRefresh != oldValue { updateDisplayLink() } }
	}
	private var displayLink: CADisplayLink?

	init(renderer: MetalRenderer) {
		self.renderer = renderer
		super.init(frame: .zero)
		backgroundColor = .black
		isMultipleTouchEnabled = true
		controls.isHidden = true
		layer.addSublayer(metalLayer)
		addSubview(controls)
		renderer.attach(metalLayer)
	}


	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	// MARK: Refresh rate

	override func didMoveToWindow() {
		super.didMoveToWindow()
		if window == nil {
			resetTouches()
			touchStarts.removeAll()
			threeFinger = nil
		}
		updateDisplayLink()
	}

	/// Frames are still drawn as soon as they're decoded. The display link only
	/// keeps the panel refreshing at 120 Hz, so a new frame waits at most ~8 ms
	/// for the next refresh instead of ~17 ms. It also measures the real rate.
	private func updateDisplayLink() {
		displayLink?.invalidate()
		displayLink = nil
		renderer.displayHz = 0
		guard let window, highRefresh else { return }
		let maxFPS = Float(window.screen.maximumFramesPerSecond)
		guard maxFPS > 60 else { return }
		let link = CADisplayLink(target: self, selector: #selector(displayTick))
		link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maxFPS), maximum: maxFPS, preferred: maxFPS)
		link.add(to: .main, forMode: .common)
		displayLink = link
		log.notice("Requesting \(Int(maxFPS)) Hz while streaming")
	}

	@objc private func displayTick(_ link: CADisplayLink) {
		let frame = link.targetTimestamp - link.timestamp
		if frame > 0 { renderer.displayHz = (1 / frame).rounded() }
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		// Native scale: render at the panel's real resolution, not the UIKit point scale
		let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
		contentScaleFactor = scale
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		metalLayer.frame = bounds
		metalLayer.contentsScale = scale
		let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
		renderer.setDrawableSize(size)
		CATransaction.commit()
		let area = bounds.inset(by: safeAreaInsets)
		let buttonY = bottomSystemButtonY(in: area)
		if controls.frame != bounds || controlsArea != area || systemButtonY != buttonY {
			resetTouches()
			controlsArea = area
			systemButtonY = buttonY
			controls.frame = bounds
			controls.setLayout(in: area, systemButtonY: buttonY)
		}
	}

	private func bottomSystemButtonY(in safeArea: CGRect) -> CGFloat {
		let halfHeight = VirtualControlsOverlay.systemButtonHeight / 2
		if let aspect = videoAspectForLetterbox, aspect > 0 {
			let videoBottom = bounds.midY + bounds.width / aspect / 2
			let firstCentreInBar = videoBottom + halfHeight + 4
			// The stream hides the system overlays. Let these two buttons extend below
			// the safe area if needed, but leave a gap at the bottom gesture edge.
			let lastCentreInBar = bounds.maxY - halfHeight - 12
			if firstCentreInBar <= lastCentreInBar {
				let preferredCentre = (videoBottom + safeArea.maxY) / 2
				return min(max(preferredCentre, firstCentreInBar), lastCentreInBar)
			}
		}
		return safeArea.maxY - halfHeight - 4
	}

	override func safeAreaInsetsDidChange() {
		super.safeAreaInsetsDidChange()
		setNeedsLayout()
	}

	/// Size, opacity and stick behaviour. A change lets go of anything held, since the layout moves.
	func setControlsStyle(_ style: VirtualControlsStyle) {
		guard controls.style != style else { return }
		resetTouches()
		controls.style = style
	}

	func setInputMode(acceptsInput: Bool, virtualControls: Bool, touchMouse: Bool) {
		let hideControls = !acceptsInput || !virtualControls
		guard self.acceptsInput != acceptsInput || controls.isHidden != hideControls || self.touchMouse != touchMouse else { return }
		resetTouches()
		self.acceptsInput = acceptsInput
		self.touchMouse = touchMouse
		controls.isHidden = hideControls
		// With a controller the whole picture points one-to-one; virtual controls leave the
		// top half, which works better as a trackpad
		mouse.mode = hideControls ? .direct : .trackpad
	}

	private func resetTouches() {
		frameGenerationTouches.removeAll()
		controls.reset()
		mouse.reset()
		onReset?()
	}

	/// Where the renderer draws the picture: centred, fitted or filling
	private var pictureRect: CGRect {
		let aspect = videoAspect > 0 ? videoAspect : 16.0 / 9.0
		var width = bounds.width, height = bounds.width / aspect
		if fillsView ? height < bounds.height : height > bounds.height {
			height = bounds.height
			width = height * aspect
		}
		return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
	}

	// MARK: Touches

	private var shortcutSize: CGSize {
		controls.isHidden ? Self.cornerSize : CGSize(width: 84, height: 52)
	}

	private var cornerRect: CGRect {
		let size = shortcutSize
		return CGRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: size.height)
	}

	private var leftCornerRect: CGRect {
		let size = shortcutSize
		return CGRect(x: bounds.minX, y: bounds.minY, width: size.width, height: size.height)
	}

	private var frameGenerationCornerRect: CGRect {
		let size = Self.frameGenerationCornerSize
		return CGRect(x: bounds.maxX - size.width, y: bounds.maxY - size.height, width: size.width, height: size.height)
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard acceptsInput else { return }
		let now = CACurrentMediaTime()
		for touch in touches { touchStarts[ObjectIdentifier(touch)] = (now, touch.location(in: self)) }
		if threeFinger != nil {
			// A fourth finger: not a three-finger tap after all
			threeFinger?.valid = false
			return
		}
		if touchStarts.count == 3, let first = touchStarts.values.map(\.time).min(),
		   now - first <= Self.threeFingerLanding {
			// Let go of whatever the first two fingers started
			resetTouches()
			threeFinger = (first, true)
			return
		}
		mouse.pictureRect = pictureRect
		for touch in touches {
			let p = touch.location(in: self)
			if cornerRect.contains(p) {
				onCornerTap?()
				continue
			}
			if leftCornerRect.contains(p) {
				onLeftCornerTap?()
				continue
			}
			let key = ObjectIdentifier(touch)
			let inFrameGenerationCorner = frameGenerationCornerRect.contains(p)
			if !controls.isHidden {
				// Fixed controls win over shortcuts, and sticks only start in free space:
				// the lower half when the top half is the mouse.
				let allowsStick = !inFrameGenerationCorner && (!touchMouse || p.y >= bounds.midY)
				let result = controls.begin(key, at: p, allowsStick: allowsStick)
				if let state = result.state { onVirtualPad?(state) }
				if result.handled { continue }
			}
			if inFrameGenerationCorner {
				frameGenerationTouches.insert(key)
				continue
			}
			if touchMouse {
				_ = mouse.begin(key, at: p)
			}
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		if threeFinger != nil {
			for touch in touches {
				guard let start = touchStarts[ObjectIdentifier(touch)]?.point else { continue }
				let p = touch.location(in: self)
				if hypot(p.x - start.x, p.y - start.y) > Self.threeFingerSlop { threeFinger?.valid = false }
			}
			return
		}
		mouse.pictureRect = pictureRect
		for touch in touches {
			let key = ObjectIdentifier(touch)
			let p = touch.location(in: self)
			if let state = controls.move(key, to: p) { onVirtualPad?(state) }
			mouse.move(key, to: p)
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches, allowsTap: true)
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches, allowsTap: false)
	}

	private func finishTouches(_ touches: Set<UITouch>, allowsTap: Bool) {
		for touch in touches { touchStarts.removeValue(forKey: ObjectIdentifier(touch)) }
		if var gesture = threeFinger {
			if !allowsTap { gesture.valid = false }
			guard touchStarts.isEmpty else {
				threeFinger = gesture
				return
			}
			threeFinger = nil
			if gesture.valid, CACurrentMediaTime() - gesture.began <= Self.threeFingerTapTime {
				onThreeFingerTap?()
			}
			return
		}
		for touch in touches {
			let key = ObjectIdentifier(touch)
			if frameGenerationTouches.remove(key) != nil {
				if allowsTap && frameGenerationCornerRect.contains(touch.location(in: self)) { onFrameGenerationTap?() }
				continue
			}
			if let state = controls.end(key) { onVirtualPad?(state) }
			mouse.end(key, cancelled: !allowsTap)
		}
	}
}
