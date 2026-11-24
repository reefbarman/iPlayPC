import Metal

/// Must match FGParams in FrameGen.metal
private struct FGParams {
	var lumaSize: SIMD2<Float>
	var chromaSize: SIMD2<Float>
	var quarterSize: SIMD2<Float>
	var eighthSize: SIMD2<Float>
	var coarseCount: SIMD2<Int32>
	var fineCount: SIMD2<Int32>
}

/// Something that makes the picture halfway between two decoded frames
protocol FrameInterpolator: AnyObject {
	var outLuma: MTLTexture? { get }
	var outChroma: MTLTexture? { get }
	func reset()
	func push(
		luma: MTLTexture, chroma: MTLTexture, bt2020: Bool, fullRange: Bool, into commandBuffer: MTLCommandBuffer
	) -> Bool
	func interpolate(
		previous: (luma: MTLTexture, chroma: MTLTexture), current frame: (luma: MTLTexture, chroma: MTLTexture),
		into commandBuffer: MTLCommandBuffer)
	/// Steps quality down when generating takes too long (see QualityStepper).
	/// Call once per pair. Returns true if the level changed.
	func adapt(generateMs: Double, interval: Double) -> Bool
	/// What it's running at, for the stats overlay ("" for full quality)
	var status: String { get }
}


/// Steps a generator's quality level down when the GPU time per generated
/// frame is over budget for a while (e.g. the phone throttles as it warms
/// up), and back up when the next level up should fit with room to spare.
struct QualityStepper {
	/// Rough GPU time of each level relative to the first, best first
	let costs: [Double]
	/// Pairs since the last level change, and how long the GPU time has been
	/// over / under budget
	private var pairsSinceChange = 0
	private var overBudget = 0
	private var underBudget = 0

	init(costs: [Double]) {
		self.costs = costs
	}

	mutating func reset() {
		pairsSinceChange = 0
		overBudget = 0
		underBudget = 0
	}

	/// The level to use after this pair, given `generateMs` (smoothed GPU
	/// time per generated frame) at `level`. `interval` is the time between
	/// real frames; the budget is half of it, since the generated frame is
	/// shown half a frame before the real one and its GPU time adds to the
	/// delay. Call once per pair.
	mutating func next(from level: Int, generateMs: Double, interval: Double) -> Int {
		pairsSinceChange += 1
		// Let the smoothed time catch up with the last change first
		guard generateMs > 0, pairsSinceChange > 45, costs.indices.contains(level) else { return level }
		let budget = interval * 1000 * 0.5
		overBudget = generateMs > budget ? overBudget + 1 : 0
		let upCost = level > 0 ? generateMs / costs[level] * costs[level - 1] : .infinity
		underBudget = upCost < budget * 0.75 ? underBudget + 1 : 0
		var next = level
		if overBudget > 20, level + 1 < costs.count {
			next = level + 1
		} else if underBudget > 240, level > 0 {
			next = level - 1
		}
		if next != level { reset() }
		return next
	}
}

/// Custom frame generation: makes the picture halfway between two decoded
/// frames with a motion search (blocks, then Lucas-Kanade patches merged into
/// a per-pixel motion map) and a motion-compensated blend, all on the GPU
/// (see FrameGen.metal). Output is YCbCr in the same formats as the
/// decoder's, so the normal render pass draws it.
///
/// Used from the video thread only.
final class FrameGenerator: FrameInterpolator {
	private let device: MTLDevice
	private let reduce4: MTLComputePipelineState
	private let gradient: MTLComputePipelineState
	private let reduce2: MTLComputePipelineState
	private let coarse: MTLComputePipelineState
	private let smoothCoarse: MTLComputePipelineState
	private let global: MTLComputePipelineState
	private let fine: MTLComputePipelineState
	private let smooth: MTLComputePipelineState
	private let densify: MTLComputePipelineState
	/// fg_synth at each quality level (`fgSynthLevel` in FrameGen.metal)
	private let synth: [MTLComputePipelineState]

	/// Synthesis quality levels, best first, and their rough GPU time
	/// relative to the first (whole generator, scripts/fgbench on an M5 Pro
	/// with phone captures, rounded down so stepping back up is cautious).
	/// See `fgSynthLevel` in FrameGen.metal.
	private static let levels: [(name: String, cost: Double)] = [
		("", 1.0), ("one tap", 0.65), ("2x2", 0.58),
	]
	/// Settable for testing; `adapt` normally drives it
	var level = 0 {
		didSet { level = min(max(level, 0), Self.levels.count - 1) }
	}
	private var stepper = QualityStepper(costs: FrameGenerator.levels.map(\.cost))
	var status: String { level == 0 ? "" : "level \(level) (\(Self.levels[level].name))" }

	private struct Textures {
		var width: Int
		var height: Int
		var lumaFormat: MTLPixelFormat
		var chromaFormat: MTLPixelFormat
		/// Shrunk copies of the previous and current frame, swapped each frame
		var quarter: [MTLTexture]
		/// The 1/4 copies with their gradients (luma, d/dx, d/dy)
		var gradients: [MTLTexture]
		var eighth: [MTLTexture]
		var coarseField: MTLTexture
		/// coarseField after a median
		var coarseSmooth: MTLTexture
		var fineField: MTLTexture
		/// This pair's patch motion and the last pair's, swapped each time
		var smoothFields: [MTLTexture]
		/// This pair's dominant motion and the last pair's (1x1), swapped with smoothFields
		var globalMotion: [MTLTexture]
		/// Per 1/4 pixel motion
		var flow: MTLTexture
		var outLuma: MTLTexture
		var outChroma: MTLTexture
		var params: FGParams
	}
	private var textures: Textures?
	private var current = 0
	private var hasPrevious = false
	private var fieldIndex = 0
	/// The other smooth field holds motion from the pair just before this one
	private var hasPriorField = false

	/// The last generated frame
	var outLuma: MTLTexture? { textures?.outLuma }
	var outChroma: MTLTexture? { textures?.outChroma }
	/// The last motion map (half motion per 1/4 pixel), for scripts/fgbench
	var motion: MTLTexture? { textures?.flow }
	/// The last patch motion, before merging
	var patchMotion: MTLTexture? { textures.map { $0.smoothFields[fieldIndex ^ 1] } }
	/// The last coarse search and patch motion before the median, for scripts/fgbench
	var coarseMotion: MTLTexture? { textures?.coarseField }
	var rawPatchMotion: MTLTexture? { textures?.fineField }
	/// The last dominant motion (x, y, share of the frame that agreed), for scripts/fgbench
	var dominantMotion: MTLTexture? { textures.map { $0.globalMotion[fieldIndex ^ 1] } }
	/// Storage format of the motion map (`.rg16Float` or `.rg32Float`).
	/// Half precision is plenty for motion, quicker to read, and can be
	/// filtered on every GPU (32-bit float filtering is optional on iPhones).
	/// Settable for scripts/fgbench's A/B; changing it starts over.
	var flowFormat: MTLPixelFormat = .rg16Float {
		didSet { if flowFormat != oldValue { reset() } }
	}

	init?(device: MTLDevice, library: MTLLibrary) {
		func make(_ name: String) -> MTLComputePipelineState? {
			guard let function = library.makeFunction(name: name) else { return nil }
			return try? device.makeComputePipelineState(function: function)
		}
		func makeSynth(_ level: Int) -> MTLComputePipelineState? {
			let constants = MTLFunctionConstantValues()
			var value = Int32(level)
			constants.setConstantValue(&value, type: .int, index: 0)
			guard let function = try? library.makeFunction(name: "fg_synth", constantValues: constants) else { return nil }
			return try? device.makeComputePipelineState(function: function)
		}
		let synth = Self.levels.indices.compactMap(makeSynth)
		guard let reduce4 = make("fg_reduce4"), let gradient = make("fg_gradient"), let reduce2 = make("fg_reduce2"),
			let coarse = make("fg_coarse"), let smoothCoarse = make("fg_smooth_coarse"), let global = make("fg_global"),
			let fine = make("fg_fine"),
			let smooth = make("fg_smooth"),
			let densify = make("fg_densify"), synth.count == Self.levels.count
		else { return nil }
		self.device = device
		self.reduce4 = reduce4
		self.gradient = gradient
		self.reduce2 = reduce2
		self.coarse = coarse
		self.smoothCoarse = smoothCoarse
		self.global = global
		self.fine = fine
		self.smooth = smooth
		self.densify = densify
		self.synth = synth
	}

	/// Frees the textures and forgets the previous frame
	func reset() {
		textures = nil
		hasPrevious = false
		hasPriorField = false
		stepper.reset()
	}

	func adapt(generateMs: Double, interval: Double) -> Bool {
		let next = stepper.next(from: level, generateMs: generateMs, interval: interval)
		guard next != level else { return false }
		log.notice("Frame gen: \(String(format: "%.1f", generateMs)) ms per frame, quality level \(self.level) -> \(next)")
		level = next
		return true
	}

	/// Adds the newest frame. Returns true when there's a previous frame of the
	/// same size and format to generate from.
	func push(
		luma: MTLTexture, chroma: MTLTexture, bt2020: Bool, fullRange: Bool, into commandBuffer: MTLCommandBuffer
	) -> Bool {
		guard prepare(luma: luma, chroma: chroma), let t = textures,
			let encoder = commandBuffer.makeComputeCommandEncoder()
		else {
			hasPrevious = false
			hasPriorField = false
			return false
		}
		current ^= 1
		var params = t.params
		encoder.label = "Frame gen: shrink"
		encoder.setBytes(&params, length: MemoryLayout<FGParams>.stride, index: 0)
		dispatch(encoder, reduce4, [luma, t.quarter[current]], t.quarter[current])
		dispatch(encoder, gradient, [t.quarter[current], t.gradients[current]], t.gradients[current])
		dispatch(encoder, reduce2, [t.quarter[current], t.eighth[current]], t.eighth[current])
		encoder.endEncoding()

		let paired = hasPrevious
		hasPrevious = true
		return paired
	}

	/// Encodes the in-between frame of the previous and current frame into `outLuma`/`outChroma`
	func interpolate(
		previous: (luma: MTLTexture, chroma: MTLTexture), current frame: (luma: MTLTexture, chroma: MTLTexture),
		into commandBuffer: MTLCommandBuffer
	) {
		guard let t = textures, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
		let prev = current ^ 1
		var params = t.params
		encoder.label = "Frame gen: interpolate"
		encoder.setBytes(&params, length: MemoryLayout<FGParams>.stride, index: 0)
		let field = t.smoothFields[fieldIndex]
		let priorField = t.smoothFields[fieldIndex ^ 1]
		var hasPrior: Int32 = hasPriorField ? 1 : 0
		encoder.setBytes(&hasPrior, length: MemoryLayout<Int32>.size, index: 1)
		// One threadgroup per block (FG_COARSE_THREADS in FrameGen.metal)
		encoder.setComputePipelineState(coarse)
		encoder.setTextures([t.eighth[prev], t.eighth[current], t.coarseField], range: 0..<3)
		encoder.dispatchThreadgroups(
			MTLSize(width: Int(params.coarseCount.x), height: Int(params.coarseCount.y), depth: 1),
			threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
		dispatch(encoder, smoothCoarse, [t.coarseField, t.coarseSmooth], t.coarseSmooth)
		// One threadgroup for the whole frame (up to 1024 threads, FG_GLOBAL_SAMPLES)
		encoder.setComputePipelineState(global)
		encoder.setTextures(
			[t.coarseSmooth, t.globalMotion[fieldIndex], t.coarseField, t.eighth[prev], t.eighth[current]], range: 0..<5)
		encoder.dispatchThreadgroups(
			MTLSize(width: 1, height: 1, depth: 1),
			threadsPerThreadgroup: MTLSize(width: min(1024, global.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
		dispatch(
			encoder, fine,
			[t.quarter[prev], t.quarter[current], t.coarseSmooth, t.fineField, priorField, t.gradients[prev],
			 t.gradients[current], t.globalMotion[fieldIndex], t.globalMotion[fieldIndex ^ 1]],
			t.fineField, count: params.fineCount)
		dispatch(encoder, smooth, [t.fineField, field], field, count: params.fineCount)
		dispatch(encoder, densify, [t.quarter[prev], t.quarter[current], field, t.flow], t.flow)
		// One thread per chroma pixel, making the 2x2 luma pixels under it too
		dispatch(
			encoder, synth[level],
			[previous.luma, frame.luma, previous.chroma, frame.chroma, t.flow, t.outLuma, t.outChroma,
			 t.globalMotion[fieldIndex]], t.outChroma)
		encoder.endEncoding()
		fieldIndex ^= 1
		hasPriorField = true
	}

	// MARK: - Private

	private func dispatch(
		_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ inputs: [MTLTexture],
		_ grid: MTLTexture, count: SIMD2<Int32>? = nil
	) {

		encoder.setComputePipelineState(pipeline)
		encoder.setTextures(inputs, range: 0..<inputs.count)
		let size = count.map { MTLSize(width: Int($0.x), height: Int($0.y), depth: 1) }
			?? MTLSize(width: grid.width, height: grid.height, depth: 1)
		let w = pipeline.threadExecutionWidth
		let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
		encoder.dispatchThreads(size, threadsPerThreadgroup: MTLSize(width: w, height: min(h, 8), depth: 1))
	}

	private func prepare(luma: MTLTexture, chroma: MTLTexture) -> Bool {
		if let t = textures, t.width == luma.width, t.height == luma.height,
			t.lumaFormat == luma.pixelFormat, t.chromaFormat == chroma.pixelFormat,
			t.outChroma.width == chroma.width, t.outChroma.height == chroma.height
		{
			return true
		}
		reset()
		let width = luma.width
		let height = luma.height
		// Synthesis makes each chroma pixel with the 2x2 luma pixels under it
		guard chroma.width == (width + 1) / 2, chroma.height == (height + 1) / 2 else {
			log.error("Frame generation: needs 4:2:0, got \(width)x\(height) luma, \(chroma.width)x\(chroma.height) chroma")
			return false
		}
		let qw = max(width / 4, 1)
		let qh = max(height / 4, 1)
		let ew = max(qw / 2, 1)
		let eh = max(qh / 2, 1)
		let coarseCount = SIMD2<Int32>(Int32((ew + 3) / 4), Int32((eh + 3) / 4))
		let fineCount = SIMD2<Int32>(Int32((qw + 3) / 4), Int32((qh + 3) / 4))

		func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
			let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
			desc.usage = [.shaderRead, .shaderWrite]
			desc.storageMode = .private
			return device.makeTexture(descriptor: desc)
		}
		guard let q0 = texture(.r16Float, qw, qh), let q1 = texture(.r16Float, qw, qh),
			let g0 = texture(.rgba16Float, qw, qh), let g1 = texture(.rgba16Float, qw, qh),
			let flow = texture(flowFormat, qw, qh),
			let e0 = texture(.r16Float, ew, eh), let e1 = texture(.r16Float, ew, eh),
			let coarseField = texture(.rgba32Float, Int(coarseCount.x), Int(coarseCount.y)),
			let coarseSmooth = texture(.rg32Float, Int(coarseCount.x), Int(coarseCount.y)),
			let fineField = texture(.rg32Float, Int(fineCount.x), Int(fineCount.y)),
			let smooth0 = texture(.rg32Float, Int(fineCount.x), Int(fineCount.y)),
			let smooth1 = texture(.rg32Float, Int(fineCount.x), Int(fineCount.y)),
			let global0 = texture(.rgba32Float, 1, 1), let global1 = texture(.rgba32Float, 1, 1),
			let outLuma = texture(luma.pixelFormat, width, height),
			let outChroma = texture(chroma.pixelFormat, chroma.width, chroma.height)
		else {
			log.error("Frame generation: couldn't make textures for \(width)x\(height)")
			return false
		}
		let params = FGParams(
			lumaSize: SIMD2(Float(width), Float(height)),
			chromaSize: SIMD2(Float(chroma.width), Float(chroma.height)),
			quarterSize: SIMD2(Float(qw), Float(qh)),
			eighthSize: SIMD2(Float(ew), Float(eh)),
			coarseCount: coarseCount, fineCount: fineCount)
		textures = Textures(
			width: width, height: height, lumaFormat: luma.pixelFormat, chromaFormat: chroma.pixelFormat,
			quarter: [q0, q1], gradients: [g0, g1], eighth: [e0, e1], coarseField: coarseField,
			coarseSmooth: coarseSmooth, fineField: fineField,
			smoothFields: [smooth0, smooth1], globalMotion: [global0, global1], flow: flow, outLuma: outLuma, outChroma: outChroma, params: params)
		log.notice("Frame generation ready for \(width)x\(height)")
		return true
	}
}
