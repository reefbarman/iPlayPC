import Foundation
import simd

/// Measures what the gyro reads at rest (its bias) and takes it off, so a controller
/// held still reads still.
///
/// Every gyro reads a little at rest. It differs from one controller to the next and
/// shifts as the controller warms up, and cheaper controllers can be off by several
/// degrees a second. Gyro aiming pushes any movement past the game's stick dead zone,
/// so even half a degree a second shows as the camera creeping, and games reading
/// motion themselves see it too.
///
/// Like JoyShockMapper's and Steam Input's continuous calibration (Jibb Smart's
/// GamepadMotionHelpers, "stillness" mode): whenever the controller sits still for a
/// moment, on a table or steady in the hands, its average reading becomes the bias.
/// - Still means the gyro and accelerometer both stay close to their recent average.
///   A steady slow turn could look still to the gyro, so once calibrated, an average
///   far from the current bias is taken as a turn, not a new bias.
/// - The first time it's still, the bias is set straight away. After that it eases
///   towards each new measurement, so one bad reading can't throw it far.
struct GyroCalibration {
	/// rad/s, in the gyro's own axes
	private(set) var bias = SIMD3<Float>.zero
	private(set) var calibrated = false

	/// How far a reading can stray from the recent average and still count as still:
	/// about 1°/s, and 0.02 g
	private static let gyroSteadiness: Float = 0.02
	private static let accelSteadiness: Float = 0.02
	/// Largest bias measured the first time, rad/s (about 9°/s)
	private static let maxBias: Float = 0.15
	/// Once calibrated, a still average further than this from the bias is a slow
	/// turn, rad/s (about 3°/s)
	private static let maxBiasChange: Float = 0.05
	/// Seconds still before measuring
	private static let stillTime: Float = 0.75
	/// Seconds the recent average looks back over
	private static let averageTime: Float = 0.2
	/// Seconds for the bias to move most of the way to a new measurement
	private static let easeTime: Float = 1

	private var gyroMean: SIMD3<Float>?
	private var accelMean = SIMD3<Float>.zero
	private var stillFor: Float = 0
	private var lastTimestamp: UInt32?

	/// Starts over, for a different controller
	mutating func reset() {
		self = GyroCalibration()
	}

	/// `gyro` rad/s, `accel` g, `timestamp` microseconds. Returns the gyro with the bias taken off.
	mutating func update(gyro: SIMD3<Float>, accel: SIMD3<Float>, timestamp: UInt32) -> SIMD3<Float> {
		let dt: Float
		if let lastTimestamp {
			dt = min(max(Float(timestamp &- lastTimestamp) / 1_000_000, 0), 0.05)
		} else {
			dt = 0
		}
		lastTimestamp = timestamp

		guard let mean = gyroMean else {
			gyroMean = gyro
			accelMean = accel
			return gyro - bias
		}
		let steady = simd_length(gyro - mean) < Self.gyroSteadiness
			&& simd_length(accel - accelMean) < Self.accelSteadiness
			&& simd_length(mean - bias) < (calibrated ? Self.maxBiasChange : Self.maxBias)
		stillFor = steady ? stillFor + dt : 0
		let k = min(1, dt / Self.averageTime)
		let newMean = mean + (gyro - mean) * k
		gyroMean = newMean
		accelMean += (accel - accelMean) * k

		if stillFor >= Self.stillTime {
			if calibrated {
				bias += (newMean - bias) * min(1, dt / Self.easeTime)
			} else {
				bias = newMean
				calibrated = true
			}
		}
		return gyro - bias
	}
}
