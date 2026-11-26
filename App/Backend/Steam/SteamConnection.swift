import Foundation
import IHSKit
import os

private let sessionLog = AppLog(subsystem: logSubsystem, category: "steam")

/// One Steam Remote Play stream over an IHSKit session.
///
/// ihslib runs the session on its own threads and calls back on them. Tearing it
/// down joins those threads, so that always happens on a background queue, never
/// inside a callback.
final class SteamConnection: StreamConnection, @unchecked Sendable {
	var onVideoStart: ((VideoCodec, Int, Int) -> Void)?
	var onVideoFrame: ((UnsafeRawBufferPointer, Bool) -> Bool)?
	var onRumble: ((Float, Float) -> Void)?
	var onLightbar: ((UInt8, UInt8, UInt8) -> Void)?
	var onShowKeyboard: (() -> Void)?
	var onMicrophone: ((Bool) -> Void)?
	var onEnded: ((StreamEnd) -> Void)?

	private struct State {
		var session: OpaquePointer?
		var connected = false
		var stopped = false
		var ended = false
		var waiter: CheckedContinuation<Void, Error>?
		/// Applied to the session before it connects, so the PC sees the right controller from the start
		var pad = PadIdentity.xbox
	}

	/// The session pointer is only handed between threads under this lock
	private let state = OSAllocatedUnfairLock(uncheckedState: State())
	private let teardownQueue = DispatchQueue(label: "dev.reefbarman.iplaypc.steam.teardown")
	private let deviceID: UInt64
	private let deviceName: String
	private let secretKey: Data
	private let grant: IHKStreamGrant
	private let config: StreamConfig
	/// Games close with Cmd+Q on a Mac, Alt+F4 elsewhere
	private let macHost: Bool

	init(deviceID: UInt64, deviceName: String, secretKey: Data, grant: IHKStreamGrant, config: StreamConfig,
		 macHost: Bool) {
		self.deviceID = deviceID
		self.deviceName = deviceName
		self.secretKey = secretKey
		self.grant = grant
		self.config = config
		self.macHost = macHost
	}

	deinit {
		// stop() normally got here first and handed the session to the teardown queue
		if let session = state.withLockUnchecked({ $0.session }) {
			ihk_session_destroy(session)
		}
	}

	// MARK: - Lifecycle

	func start() async throws {
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				guard let session = makeSession() else {
					continuation.resume(throwing: BackendError("Couldn't start the stream. Try again."))
					return
				}
				let proceed = state.withLockUnchecked { state -> Bool in
					guard !state.stopped else { return false }
					state.session = session
					state.waiter = continuation
					return true
				}
				guard proceed else {
					ihk_session_destroy(session)
					continuation.resume(throwing: CancellationError())
					return
				}
				guard ihk_session_start(session) else {
					finishStart(.failure(BackendError("Couldn't connect to the PC. Try again.")))
					return
				}
				// ihslib keeps retrying a host that never answers; don't wait forever
				DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
					self?.finishStart(.failure(BackendError("The PC didn't answer. Check it's awake and try again.")))
				}
			}
		} onCancel: {
			self.stop()
		}
	}

	func stop(quittingGame: Bool) {
		let (session, waiter, connected) = state.withLockUnchecked {
			state -> (OpaquePointer?, CheckedContinuation<Void, Error>?, Bool) in
			guard !state.stopped else { return (nil, nil, false) }
			state.stopped = true
			let session = state.session
			state.session = nil
			let waiter = state.waiter
			state.waiter = nil
			return (session, waiter, state.connected && !state.ended)
		}
		waiter?.resume(throwing: CancellationError())
		guard let session else { return }
		let handle = SessionHandle(pointer: session)
		let closing = quittingGame && connected && ihk_session_game_running(session)
		if closing {
			// The teardown queue is serial, so the keys go out before the disconnect
			closeGameLater(handle)
		} else {
			if quittingGame { consoleLog("No game running on the PC to quit") }
			ihk_session_stop(session)
		}
		// Keeps self alive until ihslib's threads have finished calling into it. The
		// keys are queued on the control channel; give them a moment to reach the PC
		// before the disconnect tears the channel down
		teardownQueue.asyncAfter(deadline: .now() + (closing ? 0.5 : 0)) { [self] in
			ihk_session_stop(handle.pointer)
			ihk_session_destroy(handle.pointer)
			_ = self
		}
	}

	func quitGame() -> Bool {
		guard let session else { return false }
		guard ihk_session_game_running(session) else {
			consoleLog("No game running on the PC to quit")
			return false
		}
		closeGameLater(SessionHandle(pointer: session))
		return true
	}

	/// The keys are spaced out, so they're pressed on the teardown queue rather than
	/// the caller's. stop() destroys the session on the same serial queue, so it's
	/// still alive here.
	private func closeGameLater(_ handle: SessionHandle) {
		let macHost = macHost
		teardownQueue.async { [self] in
			if ihk_session_quit_game(handle.pointer, macHost) {
				sessionLog.notice("Closed the game on the PC")
				consoleLog("Closed the game on the PC (\(macHost ? "Cmd+Q" : "Alt+F4"))")
			}
			_ = self
		}
	}

	/// Lets the session pointer cross to the teardown queue; nothing else holds it by then
	private struct SessionHandle: @unchecked Sendable {
		let pointer: OpaquePointer
	}

	/// Resumes start() once: connected, failed, timed out or cancelled
	private func finishStart(_ result: Result<Void, Error>) {
		let waiter = state.withLockUnchecked { state -> CheckedContinuation<Void, Error>? in
			defer { state.waiter = nil }
			return state.waiter
		}
		guard let waiter else { return }
		waiter.resume(with: result)
		if case .failure = result { stop() }
	}

	private func makeSession() -> OpaquePointer? {
		var sessionConfig = IHKSessionConfig()
		sessionConfig.enable_audio = true
		sessionConfig.enable_microphone = config.microphone
		sessionConfig.enable_hevc = config.hevc
		sessionConfig.enable_hdr = config.hdr && config.hevc
		sessionConfig.max_bitrate_kbps = Int32(clamping: config.maxBitrateKbps)
		sessionConfig.quality = 0
		sessionConfig.max_width = Int32(clamping: config.width)
		sessionConfig.max_height = Int32(clamping: config.height)
		sessionConfig.refresh_num = Int32(clamping: config.fps)
		sessionConfig.refresh_den = 1
		sessionConfig.display_width = Int32(clamping: config.displayWidth)
		sessionConfig.display_height = Int32(clamping: config.displayHeight)

		var callbacks = IHKSessionCallbacks()
		callbacks.user = Unmanaged.passUnretained(self).toOpaque()
		callbacks.on_connected = { user in
			SteamConnection.from(user)?.connected()
		}
		callbacks.on_disconnected = { user, hostClosed in
			SteamConnection.from(user)?.disconnected(hostClosed: hostClosed)
		}
		callbacks.on_video_start = { user, codec, width, height in
			guard let self = SteamConnection.from(user) else { return }
			sessionLog.info("Video \(width)x\(height) codec \(codec.rawValue)")
			consoleLog("Video \(width)x\(height) codec \(codec.rawValue)")
			self.onVideoStart?(codec == IHK_VIDEO_HEVC ? .hevc : .h264, Int(width), Int(height))
		}
		callbacks.on_video_frame = { user, data, length, keyframe in
			guard let self = SteamConnection.from(user), let data else { return false }
			return self.onVideoFrame?(UnsafeRawBufferPointer(start: data, count: length), keyframe) ?? true
		}
		callbacks.on_audio_start = { _, channels, rate in
			sessionLog.info("Audio \(rate) Hz, \(channels) channels")
			consoleLog("Audio \(rate) Hz, \(channels) channels")
		}
		callbacks.on_target_framerate = { _, numerator, denominator in
			sessionLog.info("PC frame rate \(numerator)/\(denominator)")
			consoleLog("PC frame rate \(numerator)/\(denominator)")
		}
		callbacks.on_target_bitrate = { _, bitrate in
			sessionLog.info("PC bitrate \(bitrate / 1000) kbit/s")
			consoleLog("PC bitrate \(bitrate / 1000) kbit/s")
		}
		callbacks.on_rumble = { user, low, high in
			SteamConnection.from(user)?.onRumble?(Float(low) / 65535, Float(high) / 65535)
		}
		callbacks.on_lightbar = { user, r, g, b in
			SteamConnection.from(user)?.onLightbar?(r, g, b)
		}
		callbacks.on_show_keyboard = { user in
			SteamConnection.from(user)?.onShowKeyboard?()
		}
		callbacks.on_microphone = { user, active in
			consoleLog("PC microphone \(active ? "open" : "closed")")
			SteamConnection.from(user)?.onMicrophone?(active)
		}

		var grant = grant
		let session = secretKey.withUnsafeBytes { key in
			deviceName.withCString { name in
				ihk_session_create(deviceID, name, key.bindMemory(to: UInt8.self).baseAddress, &grant, &sessionConfig, &callbacks)
			}
		}
		if let session {
			ihk_session_set_pad_type(session, Self.wirePad(state.withLockUnchecked { $0.pad }))
		}
		return session
	}

	private static func wirePad(_ identity: PadIdentity) -> IHKPadType {
		identity == .dualSense ? IHK_PAD_DUALSENSE : IHK_PAD_XBOX
	}

	private static func from(_ user: UnsafeMutableRawPointer?) -> SteamConnection? {
		user.map { Unmanaged<SteamConnection>.fromOpaque($0).takeUnretainedValue() }
	}

	private func connected() {
		sessionLog.notice("Stream connected")
		state.withLockUnchecked { $0.connected = true }
		finishStart(.success(()))
	}

	/// hostClosed: the PC sent Disconnect. Otherwise ihslib gave up on a broken connection.
	private func disconnected(hostClosed: Bool) {
		let report = state.withLockUnchecked { state -> Bool in
			guard !state.stopped, !state.ended else { return false }
			state.ended = true
			return true
		}
		sessionLog.notice("Stream disconnected (\(hostClosed ? "PC ended it" : "connection broke", privacy: .public))")
		guard report else { return }
		let wasConnected = state.withLockUnchecked { $0.connected }
		if wasConnected {
			onEnded?(hostClosed ? .hostClosed : .connectionLost)
		} else {
			finishStart(.failure(BackendError("Couldn't connect to the PC. Try again.")))
		}
		// Hop off ihslib's thread before tearing down
		DispatchQueue.global().async { [self] in stop() }
	}

	private var session: OpaquePointer? { state.withLockUnchecked { $0.session } }

	// MARK: - Audio

	func audioBuffered() -> Int {
		guard let session else { return 0 }
		return ihk_session_audio_buffered(session)
	}

	func readAudio(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
		guard let session else { return 0 }
		return ihk_session_read_audio(session, out, frames)
	}

	func pushMicrophone(_ samples: UnsafePointer<Float>, frames: Int) {
		guard let session else { return }
		_ = ihk_session_push_mic(session, samples, frames)
	}

	// MARK: - Input

	/// ihslib has no direct request; a failed decode asks for a keyframe instead
	func requestKeyframe() {}

	/// Gaps in the PC's frame numbers, counted by the bridge
	func lostFrames() -> Int {
		guard let session else { return 0 }
		return Int(clamping: ihk_session_lost_frames(session))
	}

	func secondsSinceReceive() -> Double {
		guard let session else { return 0 }
		return Double(ihk_session_ms_since_receive(session)) / 1000
	}

	func setPad(_ identity: PadIdentity) {
		let session = state.withLockUnchecked { state -> OpaquePointer? in
			state.pad = identity
			return state.session
		}
		guard let session else { return }
		ihk_session_set_pad_type(session, Self.wirePad(identity))
	}

	func send(_ pad: GamepadState) {
		guard let session else { return }
		var state = IHKPadState()
		state.buttons = Self.wireButtons(pad)
		state.left_x = pad.leftX
		state.left_y = pad.leftY
		state.right_x = pad.rightX
		state.right_y = pad.rightY
		state.left_trigger = pad.leftTrigger
		state.right_trigger = pad.rightTrigger
		let touches = [pad.touch1, pad.touch2].compactMap { $0 }
		state.touches = UInt8(touches.count)
		if touches.count > 0 { state.touch_x.0 = touches[0].x; state.touch_y.0 = touches[0].y }
		if touches.count > 1 { state.touch_x.1 = touches[1].x; state.touch_y.1 = touches[1].y }
		ihk_session_send_pad(session, &state)
	}

	func sendMotion(gyro: SIMD3<Float>, accel: SIMD3<Float>) {
		guard let session else { return }
		var g = (gyro.x, gyro.y, gyro.z)
		var a = (accel.x, accel.y, accel.z)
		withUnsafePointer(to: &g) { gp in
			withUnsafePointer(to: &a) { ap in
				gp.withMemoryRebound(to: Float.self, capacity: 3) { gyro in
					ap.withMemoryRebound(to: Float.self, capacity: 3) { accel in
						ihk_session_send_motion(session, gyro, accel)
					}
				}
			}
		}
	}

	/// Our Xbox-style bits -> the SDL numbering Steam's report uses
	private static func wireButtons(_ pad: GamepadState) -> UInt32 {
		let map: [(UInt16, UInt32)] = [
			(GamepadState.a, UInt32(IHK_PAD_A)),
			(GamepadState.b, UInt32(IHK_PAD_B)),
			(GamepadState.x, UInt32(IHK_PAD_X)),
			(GamepadState.y, UInt32(IHK_PAD_Y)),
			(GamepadState.back, UInt32(IHK_PAD_BACK)),
			(GamepadState.guide, UInt32(IHK_PAD_GUIDE)),
			(GamepadState.start, UInt32(IHK_PAD_START)),
			(GamepadState.leftThumb, UInt32(IHK_PAD_LEFT_STICK)),
			(GamepadState.rightThumb, UInt32(IHK_PAD_RIGHT_STICK)),
			(GamepadState.leftShoulder, UInt32(IHK_PAD_LEFT_SHOULDER)),
			(GamepadState.rightShoulder, UInt32(IHK_PAD_RIGHT_SHOULDER)),
			(GamepadState.dpadUp, UInt32(IHK_PAD_DPAD_UP)),
			(GamepadState.dpadDown, UInt32(IHK_PAD_DPAD_DOWN)),
			(GamepadState.dpadLeft, UInt32(IHK_PAD_DPAD_LEFT)),
			(GamepadState.dpadRight, UInt32(IHK_PAD_DPAD_RIGHT)),
		]
		var wire: UInt32 = 0
		for (ours, theirs) in map where pad.buttons & ours != 0 { wire |= theirs }
		if pad.touchpadPressed { wire |= UInt32(IHK_PAD_TOUCHPAD) }
		return wire
	}

	func sendMouseMove(x: Int, y: Int, width: Int, height: Int) {
		guard let session, width > 0, height > 0 else { return }
		let nx = Float(max(0, min(width, x))) / Float(width)
		let ny = Float(max(0, min(height, y))) / Float(height)
		ihk_session_mouse_position(session, nx, ny)
	}

	func sendMouseMove(dx: Int, dy: Int) {
		guard let session, dx != 0 || dy != 0 else { return }
		ihk_session_mouse_move(session, Int32(clamping: dx), Int32(clamping: dy))
	}

	func sendMouseButton(_ button: MouseButton, pressed: Bool) {
		guard let session else { return }
		let wire: IHKMouseButton = switch button {
		case .left: IHK_MOUSE_LEFT
		case .middle: IHK_MOUSE_MIDDLE
		case .right: IHK_MOUSE_RIGHT
		}
		ihk_session_mouse_button(session, wire, pressed)
	}

	/// Steam takes wheel notches, not deltas
	private var wheelRemainder = 0

	func sendMouseWheel(_ delta: Int) {
		guard let session else { return }
		wheelRemainder += delta
		while abs(wheelRemainder) >= 120 {
			let up = wheelRemainder > 0
			ihk_session_mouse_wheel(session, up ? IHK_WHEEL_UP : IHK_WHEEL_DOWN)
			wheelRemainder += up ? -120 : 120
		}
	}

	func sendKey(virtualKey: UInt16) {
		guard let session, let usage = Self.hidUsage(virtualKey: virtualKey) else { return }
		ihk_session_key(session, usage, true)
		ihk_session_key(session, usage, false)
	}

	func sendText(_ text: String) {
		guard let session, !text.isEmpty else { return }
		text.withCString { _ = ihk_session_text(session, $0) }
	}

	/// Windows virtual-key code -> USB HID keyboard usage, for the keys StreamKey sends
	private static func hidUsage(virtualKey: UInt16) -> UInt32? {
		switch virtualKey {
		case 0x08: 0x2A  // Backspace
		case 0x09: 0x2B  // Tab
		case 0x0D: 0x28  // Return
		case 0x1B: 0x29  // Escape
		case 0x25: 0x50  // Left
		case 0x26: 0x52  // Up
		case 0x27: 0x4F  // Right
		case 0x28: 0x51  // Down
		default: nil
		}
	}
}
