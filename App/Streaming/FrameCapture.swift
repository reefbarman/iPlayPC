import Foundation
import Metal
import QuartzCore

/// Debug: keeps the last couple of seconds of frames sent to the screen,
/// real and generated, so a button on the stream can save them for a closer
/// look (scripts/fgcapture turns a saved capture into images). Frames are
/// copied on the GPU into a ring of textures, so the decoder's buffers aren't
/// held on to.
///
/// `frameStart`, `reserve`, `note` and `copy` are called from the video
/// thread, `presented` from Core Animation's, `requestSave` from any thread.
final class FrameCapture {
	enum Kind: String {
		case real, generated
		/// A repeat of the last real frame, dropped while generating
		case repeated
		/// An in-between frame that wasn't made because we were behind
		case skipped
		/// An in-between frame that wasn't made because frames were lost or
		/// late before this real one, so the two real frames aren't neighbours
		case gap
	}

	enum CaptureError: LocalizedError {
		case busy, empty, off
		var errorDescription: String? {
			switch self {
			case .busy: "Already saving a capture"
			case .empty: "No frames captured yet"
			case .off: "Frame capture is off"
			}
		}
	}

	private struct Entry {
		let seq: Int
		let kind: Kind
		/// Real frames since capture started: a generated frame shares the
		/// number of the real frame it was shown before
		let pair: Int
		let encodedAt: CFTimeInterval
		var presentedAt: CFTimeInterval = 0
		var slot: Int?
	}

	private struct Slot {
		let luma: MTLTexture
		let chroma: MTLTexture
		var owner = -1
	}

	private struct Format: Equatable {
		var width, height, chromaWidth, chromaHeight: Int
		var luma, chroma: MTLPixelFormat
		var bytesPerSample: Int { luma == .r16Unorm ? 2 : 1 }
		var bytes: Int { (width * height + chromaWidth * chromaHeight * 2) * bytesPerSample }
	}

	/// GPU memory for the ring: about 260 1080p SDR frames, a little over 2 s
	/// of 120 fps output (half that for HDR)
	private static let budgetBytes = 768 << 20

	private let device: MTLDevice
	private let lock = NSLock()
	private var entries: [Entry] = []
	private var slots: [Slot] = []
	private var nextSlot = 0
	private var nextSeq = 0
	private var format: Format?
	private var bt2020 = false
	private var fullRange = false
	private var generator = ""
	private var streamFps = 0
	/// The last command buffer with a copy in it, waited on before saving
	private var lastCommandBuffer: MTLCommandBuffer?
	private var saveRequest: ((Result<(URL, Int), Error>) -> Void)?
	private var saving = false

	init(device: MTLDevice) {
		self.device = device
	}

	// MARK: - Video thread

	/// Call at the start of each decoded frame. Starts a requested save here,
	/// on the video thread, so every copy so far has been committed.
	func frameStart(generator: String, streamFps: Int) {
		lock.lock()
		self.generator = generator
		self.streamFps = streamFps
		guard let completion = saveRequest, !saving else {
			lock.unlock()
			return
		}
		saveRequest = nil
		saving = true
		let commandBuffer = lastCommandBuffer
		lock.unlock()
		DispatchQueue.global(qos: .utility).async { [self] in
			let result = Result { try write(after: commandBuffer) }
			lock.withLock {
				entries.removeAll()
				for i in slots.indices { slots[i].owner = -1 }
				nextSlot = 0
				lastCommandBuffer = nil
				saving = false
			}
			DispatchQueue.main.async { completion(result) }
		}
	}

	/// A frame about to be shown; copy its pixels with `copy` once they're encoded
	func reserve(_ kind: Kind, pair: Int) -> Int? {
		lock.withLock {
			guard !saving else { return nil }
			let seq = nextSeq
			nextSeq += 1
			entries.append(Entry(seq: seq, kind: kind, pair: pair, encodedAt: CACurrentMediaTime()))
			// Far more entries than slots: the oldest have lost their pixels anyway
			if entries.count > 4000 { entries.removeFirst(1000) }
			return seq
		}
	}

	/// A frame that wasn't shown (repeat dropped, generation skipped)
	func note(_ kind: Kind, pair: Int) {
		_ = reserve(kind, pair: pair)
	}

	/// Encodes a copy of the frame's planes into the ring
	func copy(
		seq: Int, luma: MTLTexture, chroma: MTLTexture, bt2020: Bool, fullRange: Bool,
		into commandBuffer: MTLCommandBuffer
	) {
		lock.lock()
		defer { lock.unlock() }
		guard !saving, let index = entryIndex(seq) else { return }
		let fmt = Format(
			width: luma.width, height: luma.height, chromaWidth: chroma.width, chromaHeight: chroma.height,
			luma: luma.pixelFormat, chroma: chroma.pixelFormat)
		if fmt != format {
			// New size or format (HDR toggled, resolution change): start over
			slots = []
			nextSlot = 0
			for i in entries.indices { entries[i].slot = nil }
			format = fmt
		}
		self.bt2020 = bt2020
		self.fullRange = fullRange

		let slotIndex: Int
		if slots.count < max(8, Self.budgetBytes / fmt.bytes) {
			guard let slot = makeSlot(fmt) else { return }
			slots.append(slot)
			slotIndex = slots.count - 1
		} else {
			slotIndex = nextSlot % slots.count
			nextSlot += 1
			if let old = entryIndex(slots[slotIndex].owner) { entries[old].slot = nil }
		}
		guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
		blit.label = "Frame capture"
		blit.copy(from: luma, to: slots[slotIndex].luma)
		blit.copy(from: chroma, to: slots[slotIndex].chroma)
		blit.endEncoding()
		slots[slotIndex].owner = seq
		entries[index].slot = slotIndex
		lastCommandBuffer = commandBuffer
	}

	// MARK: - Other threads

	/// From a drawable's presented handler (0 if it was dropped)
	func presented(seq: Int, at time: CFTimeInterval) {
		lock.withLock {
			if let i = entryIndex(seq) { entries[i].presentedAt = time }
		}
	}

	/// Saves the ring at the next decoded frame. `completion` runs on the main
	/// thread with the folder and the number of images saved.
	func requestSave(_ completion: @escaping (Result<(URL, Int), Error>) -> Void) {
		let busy = lock.withLock { () -> Bool in
			guard !saving, saveRequest == nil else { return true }
			saveRequest = completion
			return false
		}
		if busy { DispatchQueue.main.async { completion(.failure(CaptureError.busy)) } }
	}

	// MARK: - Private

	/// Entries are in seq order with no gaps
	private func entryIndex(_ seq: Int) -> Int? {
		guard let first = entries.first?.seq else { return nil }
		let i = seq - first
		return i >= 0 && i < entries.count ? i : nil
	}

	private func makeSlot(_ fmt: Format) -> Slot? {
		func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
			let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
			desc.usage = .shaderRead
			desc.storageMode = .shared
			return device.makeTexture(descriptor: desc)
		}
		guard let luma = texture(fmt.luma, fmt.width, fmt.height),
			let chroma = texture(fmt.chroma, fmt.chromaWidth, fmt.chromaHeight)
		else {
			log.error("Frame capture: out of memory for another frame")
			return nil
		}
		return Slot(luma: luma, chroma: chroma)
	}

	/// Writes each frame still in the ring as raw planes (luma, then
	/// interleaved CbCr), plus frames.json describing them all
	private func write(after commandBuffer: MTLCommandBuffer?) throws -> (URL, Int) {
		commandBuffer?.waitUntilCompleted()
		// Let the presented handlers for the last frames come in
		Thread.sleep(forTimeInterval: 0.25)
		let (entries, slots, format, bt2020, fullRange, generator, streamFps) = lock.withLock {
			(self.entries, self.slots, self.format, self.bt2020, self.fullRange, self.generator, self.streamFps)
		}
		guard let format, let first = entries.first(where: { $0.slot != nil }) else { throw CaptureError.empty }

		let stamp = DateFormatter()
		stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
		let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let dir = documents.appendingPathComponent("Frame captures").appendingPathComponent(stamp.string(from: Date()))
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

		let bps = format.bytesPerSample
		let lumaBytes = format.width * format.height * bps
		var buffer = [UInt8](repeating: 0, count: format.bytes)
		var frames: [[String: Any]] = []
		var images = 0
		let base = first.encodedAt
		for entry in entries where entry.seq >= first.seq {
			var item: [String: Any] = [
				"seq": entry.seq, "kind": entry.kind.rawValue, "pair": entry.pair,
				"encodedMs": (entry.encodedAt - base) * 1000,
			]
			if entry.presentedAt > 0 { item["presentedMs"] = (entry.presentedAt - base) * 1000 }
			if let s = entry.slot, slots[s].owner == entry.seq {
				let name = String(format: "%06d-%@.yuv", entry.seq, entry.kind.rawValue)
				buffer.withUnsafeMutableBytes { raw in
					slots[s].luma.getBytes(
						raw.baseAddress!, bytesPerRow: format.width * bps,
						from: MTLRegionMake2D(0, 0, format.width, format.height), mipmapLevel: 0)
					slots[s].chroma.getBytes(
						raw.baseAddress! + lumaBytes, bytesPerRow: format.chromaWidth * 2 * bps,
						from: MTLRegionMake2D(0, 0, format.chromaWidth, format.chromaHeight), mipmapLevel: 0)
				}
				try Data(buffer).write(to: dir.appendingPathComponent(name))
				item["file"] = name
				images += 1
			}
			frames.append(item)
		}
		let manifest: [String: Any] = [
			"version": 1, "width": format.width, "height": format.height,
			"chromaWidth": format.chromaWidth, "chromaHeight": format.chromaHeight,
			"bytesPerSample": bps, "fullRange": fullRange, "bt2020": bt2020,
			"generator": generator, "streamFps": streamFps, "frames": frames,
		]
		let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
		try json.write(to: dir.appendingPathComponent("frames.json"))
		log.notice("Frame capture: saved \(images) frames to \(dir.lastPathComponent, privacy: .public)")
		return (dir, images)
	}
}
