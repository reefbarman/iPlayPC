import Foundation
import Observation
import UIKit

struct StreamStats: Equatable {
	var fps: Double = 0
	var bitrateMbps: Double = 0
	var width: Int = 0
	var height: Int = 0
	var decodeMs: Double = 0
	var pingMs: Double = 0
	/// Packets lost in the last second, and since connecting
	var packetsLost = 0
	var totalPacketsLost = 0
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
			if ok { frames += 1 }
		}
		return ok
	}

	/// Frames decoded and bytes received so far, the last decode time and the picture size
	func sample() -> (frames: Int, bytes: Int, decodeMs: Double, width: Int, height: Int) {
		lock.withLock {
			let size = decoder?.dimensions
			return (frames, bytes, decoder?.lastDecodeMs ?? 0, Int(size?.width ?? 0), Int(size?.height ?? 0))
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
		case ended(error: String?)
	}

	private(set) var state: State = .connecting
	private(set) var stats = StreamStats()
	/// Folded or backgrounded: video isn't drawn and audio is muted, the stream stays up
	private(set) var paused = false
	private(set) var settings: StreamSettings
	/// The stream ended because the PC no longer knows this phone
	private(set) var needsPairing = false

	let host: PCHost

	@ObservationIgnored private let backend: StreamBackend
	@ObservationIgnored let renderer: MetalRenderer?
	@ObservationIgnored let input = ControllerInput()
	@ObservationIgnored private let audio = AudioOutput()
	@ObservationIgnored private var stream: StreamConnection?
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
	@ObservationIgnored private var lastSample: (frames: Int, bytes: Int, time: CFTimeInterval)?
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
		state = .connecting
		needsPairing = false
		let id = streamID
		let s = streamSettings
		let size = s.resolution.size
		let screen = StreamResolution.screenSize
		let config = StreamConfig(
			width: size.width, height: size.height, fps: s.fps, maxBitrateKbps: s.bitrateCapKbps,
			hevc: s.effectiveCodec == .h265, hdr: s.hdr, displayWidth: screen.width, displayHeight: screen.height,
			microphone: false)

		configureRenderer()
		renderer.resetSmoothing()
		renderer.setPaused(paused)
		lastGenerated = renderer.generatedFrames
		lastSkipped = renderer.skippedFrames
		lastRepeated = renderer.repeatedFrames
		lastSample = nil

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
		stream.onEnded = { [weak self] end in
			DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamEnded(end, id: id) } }
		}

		input.gyroAimEnabled = settings.gyroAim != .off
		input.feedback.rumbleEnabled = settings.rumble
		input.feedback.phoneHapticsScale = settings.phoneHaptics.scale
		input.onPad = { [weak self] pad in
			self?.physicalPad = pad
			self?.sendPad()
		}
		input.onGyroAim = { [weak self] gyro, ts in self?.gyroAimed(gyro: gyro, timestamp: ts) }
		input.start()

		try await stream.start()
		guard streamID == id else { return }
		consoleLog("Streaming")
		state = .streaming
		audio.start(stream: stream)
		audio.muted = paused
		sendPad()
		UIApplication.shared.isIdleTimerDisabled = true
		statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.sampleStats() }
		}
	}

	/// Ends the stream. Safe to call more than once.
	func stop() {
		teardown()
		if case .ended = state {} else { state = .ended(error: nil) }
	}

	/// From the "ended" screen: a fresh stream with the latest settings
	func playAgain() {
		streamSettings = settings
		start()
	}

	private func streamEnded(_ end: StreamEnd, id: Int) {
		guard id == streamID else { return }
		log.notice("Stream ended: \(String(describing: end), privacy: .public)")
		consoleLog("Stream ended: \(end)")
		teardown()
		state = .ended(error: end.message)
	}

	private func teardown() {
		streamID &+= 1
		connectTask?.cancel()
		connectTask = nil
		statsTimer?.invalidate()
		statsTimer = nil
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
		stream?.stop()
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
		settings = new
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
		guard let video else { return }
		let now = CACurrentMediaTime()
		let n = video.sample()
		defer { lastSample = (n.frames, n.bytes, now) }
		guard let last = lastSample else { return }
		let seconds = max(0.25, now - last.time)
		var s = StreamStats()
		s.fps = Double(n.frames - last.frames) / seconds
		s.bitrateMbps = Double(n.bytes - last.bytes) * 8 / seconds / 1_000_000
		s.width = n.width
		s.height = n.height
		s.decodeMs = n.decodeMs
		s.controller = input.controllerName
		if Int(now) % 10 == 0 {
			let line = "Stream \(s.width)x\(s.height) \(Int(s.fps)) fps \(String(format: "%.1f", s.bitrateMbps)) Mbps, decode \(String(format: "%.1f", s.decodeMs)) ms, audio buffered \(stream?.audioBuffered() ?? 0)"
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
	}
}
