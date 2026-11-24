import Foundation
import simd

/// Turns gyro readings into a right stick position, for gyro aiming.
///
/// Follows JoyShockMapper's gyro-to-stick output and Jibb Smart's GyroWiki:
/// - The stick leans as far as the controller is turning, so holding still stops the camera.
/// - Slow, small movements are averaged over a short window ("soft tiered smoothing"),
///   so sensor noise and a shaky hand don't jitter the camera, while real turns pass
///   straight through without delay.
/// - Any movement starts just past the game's stick dead zone
///   (JoyShockMapper's UNDEADZONE_INNER), so slow turns still move the camera.
///   Games differ, so `deadzone` is a setting.
/// - Left/right comes from turning, tilting like a steering wheel, or both
///   (Steam Input's "local space"), per `turning`.
struct GyroStick {
	/// 1 is a full stick at 180°/s
	var sensitivity: Float = 1
	var invertY = false
	var turning: GyroAimTurning = .turnAndTilt
	/// Multiplies up/down on top of `sensitivity`: games usually look up and down
	/// slower than left and right
	var verticalScale: Float = 1
	/// The game's stick dead zone, 0...0.5: any movement starts just past it
	var deadzone: Float = 0.15
	/// The power of the game's stick response curve, which this undoes
	/// (JoyShockMapper's STICK_UNPOWER). 1 is linear; 2 means the game squares
	/// the stick, so half a stick turns at a quarter speed.
	var responseCurve: Float = 1
	/// Push left/right and up/down past the dead zone separately (DS4Windows'
	/// Minimum X/Y), for games whose dead zone is a square (per axis) rather than
	/// a circle. Otherwise the small part of a diagonal can stay inside it.
	var perAxisDeadzone = false

	/// Turn speed (rad/s) that pushes the stick all the way at 1× sensitivity
	private static let fullTurnRate: Float = .pi
	/// Below this is sensor drift (rad/s, about 0.5°/s)
	private static let noiseFloor: Float = 0.01
	/// Turns slower than this are smoothed, faster ones aren't (rad/s, about 3°/s).
	/// Between half of it and all of it, it blends from one to the other.
	private static let smoothingThreshold: Float = 0.05
	/// How far back the smoothing looks, seconds
	private static let smoothingTime: Float = 0.05
	private var smoothed = SIMD2<Float>.zero
	private var lastTimestamp: UInt32?

	mutating func reset() {
		smoothed = .zero
		lastTimestamp = nil
	}

	/// `gyro` rad/s in DualSense axes (x right, y up, z towards the player).
	/// `timestamp` is the sensor's microseconds.
	/// Returns the stick with x right and y down, each -1...1.
	mutating func update(gyro: SIMD3<Float>, timestamp: UInt32) -> SIMD2<Float> {
		let dt: Float
		if let lastTimestamp {
			dt = min(max(Float(timestamp &- lastTimestamp) / 1_000_000, 0), 0.05)
		} else {
			dt = 0.01
		}
		lastTimestamp = timestamp

		// "Local space" as in Steam Input and GyroWiki: turning (yaw, gyro.y) and tilting
		// like a steering wheel (roll, gyro.z) both look left and right. Positive yaw
		// turns left, positive roll tips the top left, positive pitch (gyro.x) tips the
		// top away from you.
		let horizontal = (turning.usesYaw ? gyro.y : 0) + (turning.usesRoll ? gyro.z : 0)
		let rate = SIMD2(-horizontal, (invertY ? gyro.x : -gyro.x) * verticalScale)

		// Soft tiered smoothing
		let magnitude = simd_length(rate)
		let half = Self.smoothingThreshold / 2
		let direct = min(max((magnitude - half) / half, 0), 1)
		let alpha = 1 - exp(-dt / Self.smoothingTime)
		smoothed += (rate * (1 - direct) - smoothed) * alpha
		let input = rate * direct + smoothed

		if perAxisDeadzone {
			return SIMD2(stickAmount(abs(input.x)), stickAmount(abs(input.y))) * sign(input)
		}
		let speed = simd_length(input)
		guard speed > Self.noiseFloor else { return .zero }
		return input / speed * stickAmount(speed)
	}

	/// Stick deflection 0...1 for a turn speed (rad/s): past the dead zone, with the
	/// game's response curve undone
	private func stickAmount(_ speed: Float) -> Float {
		guard speed > Self.noiseFloor else { return 0 }
		let amount = (speed - Self.noiseFloor) * max(sensitivity, 0.01) / Self.fullTurnRate
		let dz = min(max(deadzone, 0), 0.5)
		let curved = pow(min(amount, 1), 1 / min(max(responseCurve, 1), 4))
		return min(1, dz + (1 - dz) * curved)
	}
}
