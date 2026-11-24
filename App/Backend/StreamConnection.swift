import Foundation

// One live stream, backend-neutral. The player (StreamSession, the decoder,
// renderer, audio and input) only sees these types; App/Backend/<Backend>/
// turns them into protocol.

/// What the player asks the PC for. The PC may send less.
struct StreamConfig: Equatable {
	/// Cap on the stream's resolution
	var width: Int
	var height: Int
	var fps: Int
	var maxBitrateKbps: Int
	var hevc: Bool
	var hdr: Bool
	/// This screen's own resolution in pixels
	var displayWidth: Int
	var displayHeight: Int
	var microphone: Bool
}

enum VideoCodec: Equatable {
	case h264, hevc
}

/// Xbox-style pad. Sticks -32768...32767, Y up is positive (GameController convention). Triggers 0...255.
struct GamepadState: Equatable {
	var buttons: UInt16 = 0
	var leftTrigger: UInt8 = 0
	var rightTrigger: UInt8 = 0
	var leftX: Int16 = 0
	var leftY: Int16 = 0
	var rightX: Int16 = 0
	var rightY: Int16 = 0
	/// PlayStation touchpad: the click, and up to two fingers at 0...1 (x left to right, y top to bottom)
	var touchpadPressed = false
	var touch1: SIMD2<Float>?
	var touch2: SIMD2<Float>?

	static let dpadUp: UInt16 = 0x0001
	static let dpadDown: UInt16 = 0x0002
	static let dpadLeft: UInt16 = 0x0004
	static let dpadRight: UInt16 = 0x0008
	static let start: UInt16 = 0x0010
	static let back: UInt16 = 0x0020
	static let leftThumb: UInt16 = 0x0040
	static let rightThumb: UInt16 = 0x0080
	static let leftShoulder: UInt16 = 0x0100
	static let rightShoulder: UInt16 = 0x0200
	static let guide: UInt16 = 0x0400
	static let a: UInt16 = 0x1000
	static let b: UInt16 = 0x2000
	static let x: UInt16 = 0x4000
	static let y: UInt16 = 0x8000
}

/// Which controller the PC sees
enum PadIdentity: Equatable {
	case xbox, dualSense

	/// PlayStation controllers appear as a DualSense, so the PC shows PlayStation
	/// buttons and offers gyro and touchpad; everything else (including the
	/// on-screen controls) as an Xbox pad
	init(_ style: ControllerStyle) {
		self = style.isPlayStation ? .dualSense : .xbox
	}
}

enum MouseButton: Hashable {
	case left, middle, right
}

/// Why a stream ended
enum StreamEnd: Equatable {
	/// The PC closed it (the player quit from Steam, or the PC went to sleep)
	case hostClosed
	case failed(String)

	/// Short player-facing text, nil for a normal end
	var message: String? {
		switch self {
		case .hostClosed: nil
		case .failed(let reason): reason
		}
	}
}

/// Set the callbacks, then `start()`. Callbacks arrive on backend threads.
protocol StreamConnection: AnyObject {
	/// The PC is about to send video in this codec and size
	var onVideoStart: ((VideoCodec, _ width: Int, _ height: Int) -> Void)? { get set }
	/// One Annex-B access unit. Decode it synchronously and return whether it worked:
	/// the PC adapts its bitrate from these results, and a failure asks for a keyframe.
	var onVideoFrame: ((UnsafeRawBufferPointer, _ keyframe: Bool) -> Bool)? { get set }
	/// 0...1 motor strengths
	var onRumble: ((_ low: Float, _ high: Float) -> Void)? { get set }
	var onLightbar: ((_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Void)? { get set }
	/// At most once; not called after `stop()`
	var onEnded: ((StreamEnd) -> Void)? { get set }

	/// Connects. Throws BackendError with a player-facing reason.
	func start() async throws
	/// Ends the stream. Idempotent. quittingGame first closes the game on the PC.
	func stop(quittingGame: Bool)
	/// Closes the game in front on the PC and keeps streaming. Returns false if
	/// no game is running.
	func quitGame() -> Bool

	/// 48 kHz stereo frames waiting to be read
	func audioBuffered() -> Int
	/// 48 kHz stereo interleaved Float32. Safe on the audio render thread.
	/// Returns frames copied; the caller zero-fills the rest.
	func readAudio(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Int

	/// Ask for a clean picture, e.g. after frames were dropped while paused
	func requestKeyframe()

	/// Which controller the PC should see. Re-announces the device if it changes.
	func setPad(_ identity: PadIdentity)
	func send(_ pad: GamepadState)
	/// Any thread. Gyro rad/s (x right, y up, z towards the player) and accel in g
	/// (+1 g up at rest). Only a DualSense identity passes it on, once the PC asks.
	func sendMotion(gyro: SIMD3<Float>, accel: SIMD3<Float>)

	/// Absolute pointer position within a width×height space covering the picture
	func sendMouseMove(x: Int, y: Int, width: Int, height: Int)
	/// Relative movement in stream pixels
	func sendMouseMove(dx: Int, dy: Int)
	func sendMouseButton(_ button: MouseButton, pressed: Bool)
	/// Vertical wheel in Windows WHEEL_DELTA units: 120 a notch, positive scrolls up
	func sendMouseWheel(_ delta: Int)
	/// Presses and lets go of a key, by Windows virtual-key code (StreamKey)
	func sendKey(virtualKey: UInt16)
	/// Types text as Unicode
	func sendText(_ text: String)
}

extension StreamConnection {
	func stop() { stop(quittingGame: false) }
}
