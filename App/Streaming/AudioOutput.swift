import AVFoundation
import UIKit

/// Plays the stream's decoded 48 kHz stereo audio with a short output buffer, and
/// optionally sends the phone's mic to the PC for voice chat.
///
/// The source node pulls straight from the connection's ring buffer, which trims itself
/// if playback ever falls behind.
///
/// iOS stops the engine for phone calls, Siri, and output changes such as
/// AirPods connecting, so we restart it when those end.
///
/// With the mic on, echo cancellation (voice processing) only runs while the game
/// plays from the phone's speaker. Headphones don't echo, and voice processing
/// would give the game audio the phone call treatment.
final class AudioOutput {
	private var engine = AVAudioEngine()
	private var source: AVAudioSourceNode?
	private let scratchFrames = 4096
	private let scratch: UnsafeMutablePointer<Float>
	private var observers: [NSObjectProtocol] = []
	private var isMuted = false

	/// Read from the render thread. Set before start(), cleared after stop().
	private var stream: StreamConnection?
	private var primed = false
	/// ~20 ms of audio before playback starts or resumes after an underrun
	private let primeFrames = 960
	private static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)

	/// The mic is captured (setting on and permission granted). Main thread.
	private(set) var micEnabled = false
	/// Guards what the mic tap reads: it runs on its own thread
	private let micLock = NSLock()
	private var micStream: StreamConnection?
	private var micSending = false
	/// What the stream's pushMicrophone wants: 48 kHz mono float
	private static let micFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)

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

	/// mic: capture the phone's mic too (needs record permission, otherwise it stays off)
	func start(stream: StreamConnection, mic: Bool = false) {
		self.stream = stream
		micEnabled = mic && AVAudioApplication.shared.recordPermission == .granted
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
		if micEnabled {
			micLock.withLock { micStream = stream }
			configureMic()
		}
		do {
			try engine.start()
		} catch {
			log.error("Audio engine: \(error.localizedDescription, privacy: .public)")
		}
	}

	func stop() {
		// Under the lock, so the tap can't be mid-push when the stream goes away
		micLock.withLock {
			micStream = nil
			micSending = false
		}
		engine.stop()
		if micEnabled {
			engine.inputNode.removeTap(onBus: 0)
		}
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

	/// Mic audio goes to the PC only while this is on (unmuted, not paused)
	var micLive: Bool {
		get { micLock.withLock { micSending } }
		set { micLock.withLock { micSending = newValue } }
	}

	/// Turns the mic on or off mid-stream. The audio session category changes, so the
	/// engine starts over (a brief gap in the game audio).
	func setMic(_ mic: Bool) {
		guard let stream else { return }
		let wanted = mic && AVAudioApplication.shared.recordPermission == .granted
		guard wanted != micEnabled else { return }
		log.notice("Restarting audio: mic \(wanted ? "on" : "off", privacy: .public)")
		let live = micLive
		stop()
		engine = AVAudioEngine()
		start(stream: stream, mic: mic)
		micLive = live
	}

	// MARK: - Mic

	/// Picks echo cancellation for the current output and installs the capture tap.
	/// The engine must be stopped.
	private func configureMic() {
		let input = engine.inputNode
		input.removeTap(onBus: 0)

		let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
		let speaker = outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
		if input.isVoiceProcessingEnabled != speaker {
			do {
				try input.setVoiceProcessingEnabled(speaker)
				log.notice("Mic echo cancellation \(speaker ? "on" : "off", privacy: .public)")
			} catch {
				log.error("Mic voice processing: \(error.localizedDescription, privacy: .public)")
			}
		}
		if speaker {
			// Our own game audio isn't ducked, but don't squash anything else either
			input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
		}

		let hardware = input.outputFormat(forBus: 0)
		guard hardware.sampleRate > 0, hardware.channelCount > 0,
			let target = Self.micFormat,
			let converter = AVAudioConverter(from: hardware, to: target)
		else {
			log.error("Mic: no usable input format (\(hardware.description, privacy: .public))")
			return
		}
		converter.downmix = true
		let ratio = target.sampleRate / hardware.sampleRate
		// ~20 ms per tap; the bridge regroups it into the 10 ms frames Steam wants
		input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hardware.sampleRate / 50), format: hardware) { [weak self] buffer, _ in
			self?.sendMic(buffer, converter: converter, target: target, ratio: ratio)
		}
	}

	/// Tap thread
	private func sendMic(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat, ratio: Double) {
		guard micLive, buffer.frameLength > 0 else { return }
		let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
		guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
		var fed = false
		var error: NSError?
		converter.convert(to: out, error: &error) { _, status in
			if fed {
				status.pointee = .noDataNow
				return nil
			}
			fed = true
			status.pointee = .haveData
			return buffer
		}
		guard error == nil, out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
		// Under the lock so stop() can't let the stream be torn down mid-push
		micLock.withLock {
			guard micSending, let micStream else { return }
			micStream.pushMicrophone(samples, frames: Int(out.frameLength))
		}
	}

	// MARK: - Recovery (main thread)

	private func activateAudioSession() {
		let audioSession = AVAudioSession.sharedInstance()
		do {
			if micEnabled {
				// A2DP keeps game audio full quality on Bluetooth headphones,
				// using the phone's mic. On iOS 26, AirPods that support it record at full quality
				// too, instead of dropping to the hands-free profile.
				var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
				if #available(iOS 26.0, *) {
					options.insert(.bluetoothHighQualityRecording)
				}
				try audioSession.setCategory(.playAndRecord, mode: .default, options: options)
			} else {
				try audioSession.setCategory(.playback, mode: .default, options: [])
			}
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
		// The route may have moved between the speaker and headphones
		if micEnabled { configureMic() }
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
		let mic = micEnabled
		let live = micLive
		stop()
		engine = AVAudioEngine()
		start(stream: stream, mic: mic)
		micLive = live
	}
}
