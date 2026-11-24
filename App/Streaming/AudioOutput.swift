import AVFoundation
import NVSTKit
import UIKit

/// Plays the stream's decoded 48 kHz stereo audio with a short output buffer.
///
/// The source node pulls straight from NVSTStream's ring buffer, which trims itself
/// if playback ever falls behind.
///
/// iOS stops the engine for phone calls, Siri, and output changes such as
/// AirPods connecting, so we restart it when those end.
final class AudioOutput {
	private var engine = AVAudioEngine()
	private var source: AVAudioSourceNode?
	private let scratchFrames = 4096
	private let scratch: UnsafeMutablePointer<Float>
	private var observers: [NSObjectProtocol] = []
	private var isMuted = false

	/// Read from the render thread. Set before start(), cleared after stop().
	private var stream: NVSTStream?
	private var primed = false
	/// ~20 ms of audio before playback starts or resumes after an underrun
	private let primeFrames = 960
	private static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)

	init() {
		scratch = .allocate(capacity: scratchFrames * 2)
		let center = NotificationCenter.default
		observers = [
			center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
				// Call, Siri, alarm... The engine is already stopped when it begins.
				let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
				if raw == AVAudioSession.InterruptionType.ended.rawValue {
					self?.restart(reason: "interruption ended")
				}
			},
			center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
				// Output route or format changed (AirPods, speaker, etc.): the engine stopped itself
				guard let self, note.object as? AVAudioEngine === self.engine else { return }
				self.restart(reason: "output changed")
			},
			center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
				self?.rebuild()
			},
			center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
				// Safety net for anything above that didn't tell us
				guard let self, self.source != nil, !self.engine.isRunning else { return }
				self.restart(reason: "app became active")
			},
		]
	}

	deinit {
		observers.forEach(NotificationCenter.default.removeObserver)
		stop()
		scratch.deallocate()
	}

	func start(stream: NVSTStream) {
		self.stream = stream
		activateAudioSession()

		guard let format = Self.format else { return }
		let node = AVAudioSourceNode(format: format) { [unowned self] isSilence, _, frameCount, bufferList -> OSStatus in
			let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
			guard buffers.count >= 2,
				let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
				let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
			else { return noErr }

			let total = Int(frameCount)
			guard let stream = self.stream else {
				memset(left, 0, total * 4)
				memset(right, 0, total * 4)
				isSilence.pointee = true
				return noErr
			}
			if !self.primed {
				if stream.audioBuffered() < self.primeFrames {
					memset(left, 0, total * 4)
					memset(right, 0, total * 4)
					isSilence.pointee = true
					return noErr
				}
				self.primed = true
			}

			var done = 0
			while done < total {
				let chunk = min(total - done, self.scratchFrames)
				let got = stream.readAudio(self.scratch, frames: chunk)
				for i in 0..<chunk {
					if i < got {
						left[done + i] = self.scratch[i * 2]
						right[done + i] = self.scratch[i * 2 + 1]
					} else {
						left[done + i] = 0
						right[done + i] = 0
					}
				}
				if got < chunk { self.primed = false }
				done += chunk
			}
			return noErr
		}
		source = node
		engine.attach(node)
		engine.connect(node, to: engine.mainMixerNode, format: format)
		engine.mainMixerNode.outputVolume = isMuted ? 0 : 1
		do {
			try engine.start()
		} catch {
			log.error("Audio engine: \(error.localizedDescription, privacy: .public)")
		}
	}

	func stop() {
		engine.stop()
		if let source {
			engine.detach(source)
		}
		source = nil
		stream = nil
		primed = false
	}

	var muted: Bool {
		get { isMuted }
		set {
			isMuted = newValue
			engine.mainMixerNode.outputVolume = newValue ? 0 : 1
		}
	}

	// MARK: - Recovery (main thread)

	private func activateAudioSession() {
		let audioSession = AVAudioSession.sharedInstance()
		do {
			try audioSession.setCategory(.playback, mode: .default, options: [])
			try audioSession.setPreferredSampleRate(48_000)
			try audioSession.setPreferredIOBufferDuration(0.005)
			try audioSession.setActive(true)
		} catch {
			log.error("Audio session: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Reconnects our node (the output format may have changed) and starts the engine again.
	private func restart(reason: String) {
		guard let source, stream != nil, let format = Self.format else { return }
		log.notice("Restarting audio: \(reason, privacy: .public)")
		activateAudioSession()
		engine.stop()
		engine.disconnectNodeOutput(source)
		engine.connect(source, to: engine.mainMixerNode, format: format)
		primed = false
		do {
			try engine.start()
		} catch {
			log.error("Audio engine restart: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// The audio server restarted: every engine is dead, so start over with a new one.
	private func rebuild() {
		guard let stream else { return }
		log.notice("Rebuilding audio after a media services reset")
		stop()
		engine = AVAudioEngine()
		start(stream: stream)
	}
}
