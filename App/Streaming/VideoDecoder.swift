import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

/// Hardware H.264/HEVC decoder for chiaki's Annex-B access units.
///
/// Decodes synchronously on the calling (chiaki video) thread and hands each
/// frame straight to `onFrame`, so nothing waits in a queue between the network
/// and the screen.
final class VideoDecoder {
	var onFrame: ((CVPixelBuffer) -> Void)?

	private let hevc: Bool
	/// Ask VideoToolbox for 10-bit output (HDR streams)
	private let tenBit: Bool
	private var session: VTDecompressionSession?
	private var format: CMVideoFormatDescription?
	private var parameterSets: [Data] = []

	// Stats, read approximately from the main thread
	private(set) var decodedFrames: Int = 0
	private(set) var failedFrames: Int = 0
	private(set) var lastDecodeMs: Double = 0
	private(set) var dimensions: CMVideoDimensions = .init(width: 0, height: 0)

	init(hevc: Bool, tenBit: Bool) {
		self.hevc = hevc
		self.tenBit = tenBit
	}

	deinit { invalidate() }

	func invalidate() {
		if let session {
			VTDecompressionSessionWaitForAsynchronousFrames(session)
			VTDecompressionSessionInvalidate(session)
		}
		session = nil
	}

	/// Returns false if the frame couldn't be decoded and an IDR frame should be requested.
	func decode(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
		let nals = Self.splitAnnexB(bytes, count: count)
		var newParams: [Int: Data] = [:]
		var payload: [Range<Int>] = []

		for nal in nals where !nal.isEmpty {
			let header = bytes[nal.lowerBound]
			if hevc {
				let type = Int((header >> 1) & 0x3F)
				switch type {
				case 32, 33, 34: newParams[type] = Data(bytes: bytes + nal.lowerBound, count: nal.count)  // VPS SPS PPS
				case 35: continue  // AUD
				default: payload.append(nal)
				}
			} else {
				let type = Int(header & 0x1F)
				switch type {
				case 7, 8: newParams[type] = Data(bytes: bytes + nal.lowerBound, count: nal.count)  // SPS PPS
				case 9: continue  // AUD
				default: payload.append(nal)
				}
			}
		}

		if !newParams.isEmpty {
			let ordered = newParams.keys.sorted().compactMap { newParams[$0] }
			if ordered != parameterSets {
				parameterSets = ordered
				if !rebuildFormat() { return false }
			}
		}

		guard let format, !payload.isEmpty else {
			// No stream configuration yet: wait for (and ask for) a keyframe
			return format != nil
		}
		if session == nil, !createSession(format) { return false }
		guard let session else { return false }

		guard let sample = makeSample(bytes, nals: payload, format: format) else { return false }

		let start = CACurrentMediaTime()
		var infoFlags = VTDecodeInfoFlags()
		let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: &infoFlags) {
			[weak self] status, _, imageBuffer, _, _ in
			guard let self else { return }
			guard status == noErr, let imageBuffer else {
				self.failedFrames += 1
				return
			}
			self.decodedFrames += 1
			self.onFrame?(imageBuffer)
		}
		lastDecodeMs = (CACurrentMediaTime() - start) * 1000

		if status != noErr {
			failedFrames += 1
			log.error("Decode failed: \(status)")
			if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
				// e.g. after the app was backgrounded: start over from the next keyframe
				invalidate()
			}
			return false
		}
		return true
	}

	// MARK: - Setup

	private func rebuildFormat() -> Bool {
		let expected = hevc ? 3 : 2
		guard parameterSets.count == expected else { return false }

		let buffers = parameterSets.map { data -> UnsafeMutablePointer<UInt8> in
			let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
			data.copyBytes(to: p, count: data.count)
			return p
		}
		defer { buffers.forEach { $0.deallocate() } }
		let pointers = buffers.map { UnsafePointer($0) }
		let sizes = parameterSets.map(\.count)

		var newFormat: CMVideoFormatDescription?
		let status: OSStatus
		if hevc {
			status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
				allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
				parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
		} else {
			status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
				allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
				parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
		}
		guard status == noErr, let newFormat else {
			log.error("Format description failed: \(status)")
			return false
		}

		if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
			format = newFormat
		} else {
			invalidate()
			format = newFormat
		}
		dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
		log.info("Video format \(self.dimensions.width)x\(self.dimensions.height) \(self.hevc ? "HEVC" : "H264")")
		return true
	}

	private func createSession(_ format: CMVideoFormatDescription) -> Bool {
		let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
		let attributes: [CFString: Any] = [
			kCVPixelBufferPixelFormatTypeKey: pixelFormat,
			kCVPixelBufferMetalCompatibilityKey: true,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
		]
		var newSession: VTDecompressionSession?
		let status = VTDecompressionSessionCreate(
			allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
			imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &newSession)
		guard status == noErr, let newSession else {
			log.error("VTDecompressionSessionCreate failed: \(status)")
			return false
		}
		VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
		session = newSession
		return true
	}

	private func makeSample(_ bytes: UnsafePointer<UInt8>, nals: [Range<Int>], format: CMVideoFormatDescription) -> CMSampleBuffer? {
		// Annex-B start codes -> 4-byte big-endian lengths (AVCC/HVCC)
		let total = nals.reduce(0) { $0 + 4 + $1.count }
		var block: CMBlockBuffer?
		guard CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total, blockAllocator: kCFAllocatorDefault,
			customBlockSource: nil, offsetToData: 0, dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag,
			blockBufferOut: &block) == noErr, let block
		else { return nil }

		var offset = 0
		for nal in nals {
			var length = UInt32(nal.count).bigEndian
			CMBlockBufferReplaceDataBytes(with: &length, blockBuffer: block, offsetIntoDestination: offset, dataLength: 4)
			CMBlockBufferReplaceDataBytes(with: bytes + nal.lowerBound, blockBuffer: block, offsetIntoDestination: offset + 4, dataLength: nal.count)
			offset += 4 + nal.count
		}

		var sample: CMSampleBuffer?
		var size = total
		guard CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
			sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
			sampleBufferOut: &sample) == noErr
		else { return nil }
		return sample
	}

	/// Splits an Annex-B buffer into NAL unit ranges (start codes removed).
	static func splitAnnexB(_ p: UnsafePointer<UInt8>, count n: Int) -> [Range<Int>] {
		var result: [Range<Int>] = []
		var start: Int?
		var i = 0
		while i + 2 < n {
			if p[i] == 0, p[i + 1] == 0, p[i + 2] == 1 {
				if let s = start {
					var end = i
					if end > s, p[end - 1] == 0 { end -= 1 }  // 4-byte start code
					result.append(s..<end)
				}
				i += 3
				start = i
			} else {
				i += 1
			}
		}
		if let s = start, s < n { result.append(s..<n) }
		return result
	}
}
