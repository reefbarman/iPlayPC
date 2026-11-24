import AVFoundation
import Foundation
import Observation
import UIKit

struct StreamStats: Equatable {
	var fps: Double = 0
	var bitrateMbps: Double = 0
	var width: Int = 0
	var height: Int = 0
	var decodeMs: Double = 0
	/// Video frames lost (never arrived, or failed to decode) in the last second, and since connecting
	var framesLost = 0
	var totalFramesLost = 0
	/// Share of the last second's frames that were lost, 0...1
	var videoLoss: Double = 0
	var controller: String?
	/// The screen's refresh rate, 0 if unknown
	var displayHz: Double = 0
	/// Frame generation is running (on, and the game's frame rate fits twice into the screen's)
	var frameGenActive = false
	/// Why frame generation is on in Settings but not running, e.g. "game at 90 fps, needs 60 or less"
	var frameGenOffReason: String?
	/// In-between frames made and skipped in the last second, and GPU ms per frame
	var generatedFPS = 0
	var skippedFrames = 0
	/// Repeated stream frames dropped in the last second (a 30 fps game in a 60 fps stream)
	var repeatedFrames = 0
	var generateMs: Double = 0
	/// Extra frame generation detail, e.g. a stepped-down quality level
	var frameGenStatus: String?
}

/// Decodes the connection's video straight onto the renderer, on the backend's video
/// thread, and counts what went through for the stats.
private final class VideoSink: @unchecked Sendable {
	private let lock = NSLock()
	private var decoder: VideoDecoder?
	private weak var renderer: MetalRenderer?
	private let tenBit: Bool
	private(set) var frames = 0
	private(set) var bytes = 0
	/// Frames that arrived but couldn't be decoded
	private(set) var failed = 0

	init(renderer: MetalRenderer, tenBit: Bool) {
		self.renderer = renderer
		self.tenBit = tenBit
	}

	func start(codec: VideoCodec) {
		let decoder = VideoDecoder(hevc: codec == .hevc, tenBit: tenBit && codec == .hevc)
		decoder.onFrame = { [weak renderer] frame in renderer?.display(frame) }
		lock.withLock { self.decoder = decoder }
	}

	func decode(_ data: UnsafeRawBufferPointer) -> Bool {
		guard let base = data.bindMemory(to: UInt8.self).baseAddress, let decoder = lock.withLock({ decoder }) else {
			return false
		}
		let ok = decoder.decode(base, count: data.count)
		lock.withLock {
			bytes += data.count
			if ok { frames += 1 } else { failed += 1 }
		}
		return ok
	}

	/// Frames decoded, failed and bytes received so far, the last decode time and the picture size
	func sample() -> (frames: Int, failed: Int, bytes: Int, decodeMs: Double, width: Int, height: Int) {
		lock.withLock {
			let size = decoder?.dimensions
			return (frames, failed, bytes, decoder?.lastDecodeMs ?? 0, Int(size?.width ?? 0), Int(size?.height ?? 0))
		}
	}

	func stop() {
		let old = lock.withLock { () -> VideoDecoder? in
			defer { decoder = nil }
			return decoder
		}
		old?.invalidate()
	}
}

/// One play session on a PC: connect, then the stream with the renderer, audio and
/// controller input around it.
@MainActor @Observable
final class StreamSession {
	enum State: Equatable {
		case connecting
		case streaming
		/// The connection dropped: connecting again. 1...maxReconnectAttempts.
		case reconnecting(attempt: Int)
		case ended(error: String?)
	}

	static let maxReconnectAttempts = 3
	/// Nothing from the PC for this long while streaming counts as a dropped connection
	static let silenceTimeout = 15

	private(set) var state: State = .connecting
	/// The ended screen can offer Reconnect: the connection dropped, the PC didn't end the stream
	private(set) var canReconnect = false
	private(set) var stats = StreamStats()
	/// Folded or backgrounded: video isn't drawn and audio is muted, the stream stays up
	private(set) var paused = false
	/// The mic is being captured for this stream (Microphone on when it connected)
	private(set) var micActive = false
	/// The player muted the mic. Kept across reconnects.
	private(set) var micMuted = false
	private(set) var settings: StreamSettings
	/// The stream ended because the PC no longer knows this phone
	private(set) var needsPairing = false
	/// Streaming for a few seconds without a single frame. Usually a Mac host where Steam
	/// isn't allowed to record the screen yet (the permission prompt can hide behind Steam).
	private(set) var noPicture = false
	/// Check connection: running, or its verdict waiting to be read
	private(set) var connectionCheck: ConnectionCheck?
	private(set) var connectionCheckResult: ConnectionCheckResult?
	/// How each connection went, for Auto bitrate (Play again adds another)
	@ObservationIgnored private(set) var qualityReports: [StreamQualityReport] = []
	/// The maximum bitrate the current connection asked for (Play again changes `streamSettings` first)
	@ObservationIgnored private var qualityBitrate = 0
	@ObservationIgnored private var qualityStreamingSeconds = 0
	@ObservationIgnored private var qualitySeconds = 0
	@ObservationIgnored private var qualityLossSum: Double = 0
	@ObservationIgnored private var qualityPeak: Double = 0
	@ObservationIgnored private var qualityLostAtStart = 0
	@ObservationIgnored private var qualityLost = 0
	@ObservationIgnored private var reconnectWork: DispatchWorkItem?
	@ObservationIgnored private var reconnectAttempt = 0
	/// Stats ticks in a row with nothing from the PC (the timer doesn't run while iOS suspends us)
	@ObservationIgnored private var silentSeconds = 0

	let host: PCHost

	@ObservationIgnored private let backend: StreamBackend
	@ObservationIgnored let renderer: MetalRenderer?
	@ObservationIgnored let input = ControllerInput()
	@ObservationIgnored private let audio = AudioOutput()
	@ObservationIgnored private var stream: StreamConnection?
	/// Told the PC about the mic when connecting (it's only negotiated then)
	@ObservationIgnored private var micAdvertised = false
	/// A text field on the PC wants typing (main thread)
	@ObservationIgnored var onShowKeyboard: (() -> Void)?
	@ObservationIgnored private var video: VideoSink?
	@ObservationIgnored private var connectTask: Task<Void, Never>?
	/// The settings the stream was started with: its resolution, frame rate, bitrate, codec and HDR
	@ObservationIgnored private(set) var streamSettings: StreamSettings
	@ObservationIgnored private var physicalPad = GamepadState()
	@ObservationIgnored private var virtualPad = VirtualPadState()
	@ObservationIgnored private var guideRelease: DispatchWorkItem?
	@ObservationIgnored private var gyroStick = GyroStick()
	/// Where gyro aiming is pushing the right stick, on top of the sticks themselves
	@ObservationIgnored private var gyroStickPosition = SIMD2<Float>.zero
	/// Mouse buttons the touchscreen is holding down, and the trackpad's sub-pixel leftovers
	@ObservationIgnored private var heldMouseButtons: Set<MouseButton> = []
	@ObservationIgnored private var mouseRemainder = CGVector.zero
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var lastSample: (frames: Int, lost: Int, bytes: Int, time: CFTimeInterval)?
	@ObservationIgnored private var streamingSince: CFTimeInterval = 0
	@ObservationIgnored private var lastGenerated = 0
	@ObservationIgnored private var lastSkipped = 0
	@ObservationIgnored private var lastRepeated = 0
	@ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
	/// Bumped on every teardown, so late callbacks from an old stream are ignored
	@ObservationIgnored private var streamID = 0

	init(host: PCHost, backend: StreamBackend, settings: StreamSettings) {
		self.host = host
		self.backend = backend
		self.settings = settings
		self.streamSettings = settings
		renderer = MetalRenderer()
		let center = NotificationCenter.default
		lifecycleObservers = [
			center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.releaseInput() }
			},
		]
	}

	/// The view calls stop() when it goes away; this just drops the observers
	deinit {
		lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
	}

	// MARK: - Lifecycle

	/// Asks the PC for a stream and connects
	func start() {
		guard let renderer else {
			state = .ended(error: "Metal isn't available on this device.")
			return
		}
		teardown()
		// A reconnect keeps its own card up until the picture is back
		if case .reconnecting = state {} else { state = .connecting }
		needsPairing = false
		silentSeconds = 0
		let id = streamID
		let s = streamSettings
		let size = s.resolution.size
		let screen = StreamResolution.screenSize
		let config = StreamConfig(
			width: size.width, height: size.height, fps: s.fps, maxBitrateKbps: s.bitrateCapKbps,
			hevc: s.effectiveCodec == .h265, hdr: s.hdr, displayWidth: screen.width, displayHeight: screen.height,
			microphone: settings.microphone && AVAudioApplication.shared.recordPermission == .granted)
		micAdvertised = config.microphone

		configureRenderer()
		renderer.resetSmoothing()
		renderer.setPaused(paused)
		lastGenerated = renderer.generatedFrames
		lastSkipped = renderer.skippedFrames
		lastRepeated = renderer.repeatedFrames
		lastSample = nil
		qualityBitrate = s.bitrateCapKbps / 1000
		qualityStreamingSeconds = 0
		qualitySeconds = 0
		qualityLossSum = 0
		qualityPeak = 0
		qualityLostAtStart = 0
		qualityLost = 0

		connectTask = Task { [weak self, backend, host] in
			do {
				let stream = try await backend.connect(host, config: config)
				guard let self, self.streamID == id else {
					stream.stop()
					return
				}
				try await self.run(stream, id: id, renderer: renderer)
			} catch {
				guard let self, self.streamID == id else { return }
				if error is CancellationError { return }
				log.error("Stream start failed: \(error.localizedDescription, privacy: .public)")
				consoleLog("Stream start failed: \(error.localizedDescription)")
				self.teardown()
				self.needsPairing = (error as? BackendError)?.needsPairing ?? false
				if case .reconnecting = self.state, !self.needsPairing {
					self.reconnectFailed(error.localizedDescription)
					return
				}
				self.cancelReconnect()
				self.state = .ended(error: error.localizedDescription)
			}
		}
	}

	private func run(_ stream: StreamConnection, id: Int, renderer: MetalRenderer) async throws {
		self.stream = stream
		let video = VideoSink(renderer: renderer, tenBit: streamSettings.hdr)
		self.video = video

		stream.onVideoStart = { codec, _, _ in video.start(codec: codec) }
		stream.onVideoFrame = { data, _ in video.decode(data) }
		let feedback = input.feedback
		stream.onRumble = { low, high in feedback.rumble(low: low, high: high) }
		stream.onLightbar = { r, g, b in feedback.lightbar(r: r, g: g, b: b) }
		stream.onEnded = { [weak self] end in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamEnded(end, id: id) } }
		}
		stream.onShowKeyboard = { [weak self] in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self, self.streamID == id else { return }
					self.onShowKeyboard?()
				}
			}
		}

		input.gyroAimEnabled = settings.gyroAim != .off
		input.feedback.rumbleEnabled = settings.rumble
		input.feedback.phoneHapticsScale = settings.phoneHaptics.scale
		input.onPad = { [weak self] pad in
			self?.physicalPad = pad
			self?.sendPad()
		}
		input.onGyroAim = { [weak self] gyro, ts in self?.gyroAimed(gyro: gyro, timestamp: ts) }
		input.onIdentity = { identity in stream.setPad(identity) }
		input.onPadMotion = { gyro, accel in stream.sendMotion(gyro: gyro, accel: accel) }
		input.start()
		stream.setPad(input.padIdentity)

		try await stream.start()
		guard streamID == id else { return }
		consoleLog("Streaming")
		if reconnectAttempt > 0 { log.notice("Reconnected after \(self.reconnectAttempt) attempt(s)") }
		reconnectAttempt = 0
		state = .streaming
		streamingSince = CACurrentMediaTime()
		audio.start(stream: stream, mic: micAdvertised)
		audio.muted = paused
		applyMicState()
		sendPad()
		UIApplication.shared.isIdleTimerDisabled = true
		statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.sampleStats() }
		}
	}

	/// Ends the stream. Safe to call more than once. quittingGame also asks the PC
	/// to close the game.
	func stop(quittingGame: Bool = false) {
		teardown(quittingGame: quittingGame)
		cancelReconnect()
		canReconnect = false
		if case .ended = state {} else { state = .ended(error: nil) }
	}

	/// Closes the game on the PC and keeps streaming, so the player lands back in
	/// Big Picture. Returns false if no game is running.
	func quitGame() -> Bool {
		stream?.quitGame() ?? false
	}

	/// From the "ended" screen: a fresh stream with the latest settings
	func playAgain() {
		cancelReconnect()
		canReconnect = false
		streamSettings = settings
		start()
	}

	private func streamEnded(_ end: StreamEnd, id: Int) {
		guard id == streamID else { return }
		log.notice("Stream ended: \(String(describing: end), privacy: .public)")
		consoleLog("Stream ended: \(end)")
		let wasPlaying = state == .streaming
		teardown()
		if end == .connectionLost, wasPlaying {
			beginReconnect(reason: "ihslib gave up on the connection")
		} else {
			state = .ended(error: end.message)
		}
	}

	// MARK: - Reconnect

	/// From the ended screen: try again with the same video settings
	func reconnect() {
		guard case .ended = state, canReconnect else { return }
		cancelReconnect()
		canReconnect = false
		reconnectAttempt = 1
		state = .reconnecting(attempt: 1)
		start()
	}

	private func beginReconnect(reason: String) {
		cancelReconnect()
		log.notice("Connection lost (\(reason, privacy: .public)), reconnecting")
		consoleLog("Connection lost (\(reason)), reconnecting")
		reconnectAttempt = 1
		state = .reconnecting(attempt: 1)
		scheduleReconnect(after: 1)
	}

	/// A reconnect attempt didn't work: wait longer and try again, or give up
	private func reconnectFailed(_ message: String) {
		guard case .reconnecting = state else { return }
		log.notice("Reconnect attempt \(self.reconnectAttempt) failed: \(message, privacy: .public)")
		guard reconnectAttempt < Self.maxReconnectAttempts else {
			reconnectAttempt = 0
			canReconnect = true
			state = .ended(error: "Couldn't reconnect to \(host.name). Check your connection, then try again.")
			return
		}
		reconnectAttempt += 1
		state = .reconnecting(attempt: reconnectAttempt)
		// 1 s, 2 s, 4 s
		scheduleReconnect(after: pow(2, Double(reconnectAttempt - 1)))
	}

	private func scheduleReconnect(after delay: Double) {
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				guard let self, case .reconnecting = self.state else { return }
				self.reconnectWork = nil
				self.start()
			}
		}
		reconnectWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func cancelReconnect() {
		reconnectWork?.cancel()
		reconnectWork = nil
		reconnectAttempt = 0
	}

	// MARK: - Microphone

	func toggleMicMuted() {
		micMuted.toggle()
		applyMicState()
	}

	/// Mic audio goes to the PC while it's captured, not muted, and the stream is on screen
	private func applyMicState() {
		micActive = state == .streaming && audio.micEnabled
		audio.micLive = micActive && !micMuted && !paused
	}

	private func teardown(quittingGame: Bool = false) {
		finishQualityReport()
		// A new connection starts fresh counters, so a check in progress can't carry on
		connectionCheck = nil
		streamID &+= 1
		micActive = false
		connectTask?.cancel()
		connectTask = nil
		statsTimer?.invalidate()
		statsTimer = nil
		lastSample = nil
		noPicture = false
		input.stop()
		physicalPad = GamepadState()
		virtualPad = VirtualPadState()
		gyroStickPosition = .zero
		gyroStick.reset()
		guideRelease?.cancel()
		guideRelease = nil
		heldMouseButtons.removeAll()
		mouseRemainder = .zero
		audio.stop()
		stream?.stop(quittingGame: quittingGame)
		stream = nil
		video?.stop()
		video = nil
		input.feedback.reset()
		UIApplication.shared.isIdleTimerDisabled = false
	}

	// MARK: - Settings

	/// Applies new settings. Resolution, frame rate, bitrate and codec are fixed for a session
	/// (the stream menu doesn't offer them), so those keep coming from `streamSettings`.
	func apply(_ new: StreamSettings) {
		let micChanged = new.microphone != settings.microphone
		settings = new
		if micChanged, stream != nil, state == .streaming {
			// Turning it on only works if the PC heard about the mic when connecting
			audio.setMic(new.microphone && micAdvertised)
			applyMicState()
		}
		input.gyroAimEnabled = new.gyroAim != .off
		if new.gyroAim == .off, gyroStickPosition != .zero {
			gyroStickPosition = .zero
			sendPad()
		}
		input.feedback.rumbleEnabled = new.rumble
		input.feedback.phoneHapticsScale = new.phoneHaptics.scale
		renderer?.setDisplayMode(new.displayMode)
		configureRenderer()
	}

	private var screenHz: Int {
		settings.highRefreshDisplay ? UIScreen.main.maximumFramesPerSecond : 60
	}

	/// The renderer decides when frame generation runs, from the game's measured frame rate:
	/// a 60 fps game in a 120 fps stream still gets it on a 120 Hz screen
	private func configureRenderer() {
		renderer?.configure(
			hdr: streamSettings.hdr, displayMode: settings.displayMode, upscaling: settings.upscaling,
			frameGeneration: settings.frameGeneration, fps: streamSettings.fps,
			frameCapture: false, smoothing: false, screenHz: screenHz)
	}

	/// Plain words for why frame generation isn't running
	private func frameGenOffReason(gameFPS: Double) -> String {
		guard gameFPS > 0 else { return "measuring" }
		let canDouble = gameFPS <= Double(UIScreen.main.maximumFramesPerSecond) / 2 * 1.05
		if !settings.highRefreshDisplay, UIScreen.main.maximumFramesPerSecond > 60, canDouble {
			return "turn on 120 Hz screen"
		}
		return "game at \(Int(gameFPS.rounded())) fps, needs \(screenHz / 2) or less"
	}

	func setPaused(_ paused: Bool) {
		guard paused != self.paused else { return }
		self.paused = paused
		renderer?.setPaused(paused)
		audio.muted = paused
		applyMicState()
		if paused {
			releaseInput()
		} else {
			// We dropped frames while paused, so get a clean keyframe
			stream?.requestKeyframe()
		}
	}

	/// Lets go of every button and stick, so nothing stays held in the game
	/// while we can't see the controller (iOS doesn't send controller input to background apps)
	private func releaseInput() {
		physicalPad = GamepadState()
		gyroStickPosition = .zero
		resetScreenInput()
		sendPad()
	}

	// MARK: - Input (main thread)

	/// The stream menu is open: the controller drives the menu, so the game sees nothing held
	private var inputHeld = false

	func setInputHeld(_ held: Bool) {
		guard held != inputHeld else { return }
		inputHeld = held
		if held { releaseInput() }
	}

	/// The Controller Test is open over the stream menu: let go of the controller so the test
	/// can read it, and pick it up again when it closes
	func lendController(_ lend: Bool) {
		if lend {
			releaseInput()
			input.suspend()
		} else if stream != nil {
			input.start()
		}
	}

	private func sendPad() {
		guard let stream else { return }
		guard !inputHeld else {
			stream.send(GamepadState())
			return
		}
		var pad = physicalPad
		pad.buttons |= virtualPad.buttons
		if guideRelease != nil { pad.buttons |= GamepadState.guide }
		pad.leftTrigger = max(pad.leftTrigger, virtualPad.leftTrigger)
		pad.rightTrigger = max(pad.rightTrigger, virtualPad.rightTrigger)
		if let stick = virtualPad.leftStick { (pad.leftX, pad.leftY) = (stick.x, stick.y) }
		if let stick = virtualPad.rightStick { (pad.rightX, pad.rightY) = (stick.x, stick.y) }
		if gyroStickPosition != .zero {
			pad.rightX = Int16(clamping: Int(pad.rightX) + Int((gyroStickPosition.x * 32767).rounded()))
			pad.rightY = Int16(clamping: Int(pad.rightY) + Int((gyroStickPosition.y * 32767).rounded()))
		}
		stream.send(pad)
	}

	private func gyroAimed(gyro: SIMD3<Float>, timestamp: UInt32) {
		gyroStick.sensitivity = Float(settings.gyroAimSensitivity)
		gyroStick.invertY = settings.gyroAimInvertY
		gyroStick.turning = settings.gyroAimTurning
		gyroStick.verticalScale = Float(settings.gyroAimVerticalScale)
		gyroStick.deadzone = Float(settings.gyroAimDeadzone)
		gyroStick.responseCurve = Float(settings.gyroAimResponseCurve)
		gyroStick.perAxisDeadzone = settings.gyroAimPerAxisDeadzone
		// Keeps smoothing while the hold button is up
		let position = gyroStick.update(gyro: gyro, timestamp: timestamp)
		let next = gyroAimHeld ? position : .zero
		guard next != gyroStickPosition else { return }
		gyroStickPosition = next
		sendPad()
	}

	/// The button for gyro aiming is down, if it needs one. The game still gets the button.
	private var gyroAimHeld: Bool {
		switch settings.gyroAim {
		case .off: false
		case .always: true
		case .holdingLT: max(physicalPad.leftTrigger, virtualPad.leftTrigger) > 30
		case .holdingRB: (physicalPad.buttons | virtualPad.buttons) & GamepadState.rightShoulder != 0
		}
	}

	func setVirtualPad(_ pad: VirtualPadState) {
		virtualPad = pad
		sendPad()
	}

	func resetScreenInput() {
		let hadButtons = virtualPad != VirtualPadState() || guideRelease != nil
		virtualPad = VirtualPadState()
		guideRelease?.cancel()
		guideRelease = nil
		if hadButtons { sendPad() }
		for button in heldMouseButtons { stream?.sendMouseButton(button, pressed: false) }
		heldMouseButtons.removeAll()
		mouseRemainder = .zero
	}

	/// Typed on the iPhone keyboard: sent as it's typed, so it works in any text box
	func typeText(_ text: String) {
		guard let stream, !inputHeld else { return }
		stream.sendText(text)
	}

	func pressKey(_ key: StreamKey) {
		guard let stream, !inputHeld else { return }
		stream.sendKey(virtualKey: key.rawValue)
	}

	/// The touchscreen as a mouse. Positions are in the stream's own resolution.
	func sendMouse(_ event: TouchMouse.Event) {
		guard let stream, !inputHeld else { return }
		let size = streamSettings.resolution.size
		switch event {
		case .move(let point):
			stream.sendMouseMove(x: Int((point.x * CGFloat(size.width)).rounded()),
				y: Int((point.y * CGFloat(size.height)).rounded()), width: size.width, height: size.height)
		case .moveBy(let fraction):
			mouseRemainder.dx += fraction.dx * CGFloat(size.width)
			mouseRemainder.dy += fraction.dy * CGFloat(size.height)
			let dx = mouseRemainder.dx.rounded(.towardZero), dy = mouseRemainder.dy.rounded(.towardZero)
			guard dx != 0 || dy != 0 else { return }
			mouseRemainder.dx -= dx
			mouseRemainder.dy -= dy
			stream.sendMouseMove(dx: Int(dx), dy: Int(dy))
		case .button(let button, let pressed):
			if pressed { heldMouseButtons.insert(button) } else { heldMouseButtons.remove(button) }
			stream.sendMouseButton(button, pressed: pressed)
		case .wheel(let delta):
			stream.sendMouseWheel(delta)
		}
	}

	/// On-screen Xbox button, for controllers whose home button iOS keeps for itself
	func pressGuideButton() {
		guideRelease?.cancel()
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				self?.guideRelease = nil
				self?.sendPad()
			}
		}
		guideRelease = work
		sendPad()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
	}

	// MARK: - Stats

	private func sampleStats() {
		// A connection that drops silently (out of Wi-Fi range) never ends on its own
		if state == .streaming, let stream {
			silentSeconds = stream.secondsSinceReceive() >= 2 ? silentSeconds + 1 : 0
			if silentSeconds >= Self.silenceTimeout {
				log.notice("Nothing from the PC for \(Self.silenceTimeout) s")
				teardown()
				beginReconnect(reason: "nothing from the PC for \(Self.silenceTimeout) s")
				return
			}
		}
		guard let video else { return }
		let now = CACurrentMediaTime()
		let n = video.sample()
		let waiting = n.frames == 0 && now - streamingSince >= 5
		if waiting != noPicture {
			noPicture = waiting
			if waiting { consoleLog("No video from the PC after 5 s") }
		}
		let lost = (stream?.lostFrames() ?? 0) + n.failed
		defer { lastSample = (n.frames, lost, n.bytes, now) }
		guard let last = lastSample else { return }
		let seconds = max(0.25, now - last.time)
		var s = StreamStats()
		s.fps = Double(n.frames - last.frames) / seconds
		s.bitrateMbps = Double(n.bytes - last.bytes) * 8 / seconds / 1_000_000
		s.totalFramesLost = lost
		s.framesLost = max(0, lost - last.lost)
		let arrived = max(0, n.frames - last.frames) + s.framesLost
		s.videoLoss = arrived > 0 ? Double(s.framesLost) / Double(arrived) : 0
		s.width = n.width
		s.height = n.height
		s.decodeMs = n.decodeMs
		s.controller = input.controllerName
		if Int(now) % 10 == 0 {
			let line = "Stream \(s.width)x\(s.height) \(Int(s.fps)) fps \(String(format: "%.1f", s.bitrateMbps)) Mbps, decode \(String(format: "%.1f", s.decodeMs)) ms, \(s.totalFramesLost) frames lost, audio buffered \(stream?.audioBuffered() ?? 0)"
			log.info("\(line, privacy: .public)")
			consoleLog(line)
		}
		if let renderer {
			s.displayHz = renderer.displayHz
			s.frameGenActive = settings.frameGeneration && renderer.frameGenRunning
			if settings.frameGeneration, !s.frameGenActive {
				s.frameGenOffReason = frameGenOffReason(gameFPS: renderer.gameFPS)
			}
			s.generatedFPS = renderer.generatedFrames - lastGenerated
			s.skippedFrames = renderer.skippedFrames - lastSkipped
			s.repeatedFrames = renderer.repeatedFrames - lastRepeated
			s.generateMs = renderer.generateMs
			s.frameGenStatus = renderer.frameGenStatus
			lastGenerated = renderer.generatedFrames
			lastSkipped = renderer.skippedFrames
			lastRepeated = renderer.repeatedFrames
		}
		stats = s
		sampleQuality(s)
		sampleConnectionCheck(s)
	}

	// MARK: - Check connection

	/// Watches the next few seconds of the stream, then suggests a bitrate for next time
	func startConnectionCheck() {
		guard state == .streaming else { return }
		connectionCheckResult = nil
		connectionCheck = ConnectionCheck()
	}

	func dismissConnectionCheck() {
		connectionCheck = nil
		connectionCheckResult = nil
	}

	private func sampleConnectionCheck(_ stats: StreamStats) {
		// Paused (folded, another app): nothing useful to measure
		guard var check = connectionCheck, state == .streaming, !paused else { return }
		check.add(stats)
		if check.isComplete {
			let result = check.result(requested: streamSettings.bitrateCapKbps / 1000)
			log.notice("Connection check: \(result.title, privacy: .public). \(result.detail, privacy: .public)")
			connectionCheck = nil
			connectionCheckResult = result
		} else {
			connectionCheck = check
		}
	}

	// MARK: - Auto bitrate

	/// Seconds after connecting that are left out: the start can be rough on any network
	private static let qualityWarmupSeconds = 5

	private func sampleQuality(_ s: StreamStats) {
		guard state == .streaming, !paused else { return }
		qualityStreamingSeconds += 1
		if qualityStreamingSeconds == Self.qualityWarmupSeconds { qualityLostAtStart = s.totalFramesLost }
		guard qualityStreamingSeconds > Self.qualityWarmupSeconds else { return }
		qualitySeconds += 1
		qualityLossSum += s.videoLoss
		qualityPeak = max(qualityPeak, s.bitrateMbps)
		qualityLost = s.totalFramesLost
	}

	private func finishQualityReport() {
		guard qualitySeconds > 0 else { return }
		qualityReports.append(StreamQualityReport(
			bitrateMbps: qualityBitrate, seconds: qualitySeconds,
			averageLoss: qualityLossSum / Double(qualitySeconds),
			lostFrames: max(0, qualityLost - qualityLostAtStart), peakMbps: qualityPeak))
		qualitySeconds = 0
	}
}
