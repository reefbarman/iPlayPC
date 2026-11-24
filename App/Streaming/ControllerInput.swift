import CoreMotion
import GameController
import os
import UIKit

/// Maps the connected game controller to an Xbox-style NVST pad.
///
/// - Buttons are mapped by name (A = A, B = B, Menu = Start, Options/View = Back, Home = Guide).
/// - The Home button and the other system buttons are claimed from iOS so
///   pressing Home opens the game's guide instead of the iOS overlay.
/// - GeForce NOW has no motion input, so the gyro is only read for gyro aiming: from the
///   controller if it has sensors, otherwise from the phone (e.g. a Backbone).
final class ControllerInput {
	/// Called on the main thread with the latest pad state.
	var onPad: ((GamepadState) -> Void)?
	/// Any thread, whenever motion is read: gyro rad/s and accel g (+1 g up at rest), in the
	/// same axes as `onGyroAim`, and the sensor's microseconds. For the Controller Test.
	var onMotion: ((SIMD3<Float>, SIMD3<Float>, UInt32) -> Void)?
	/// Gyro aiming, on the main thread: gyro rad/s (x right, y up, z towards the player) and the sensor's microseconds
	var onGyroAim: ((SIMD3<Float>, UInt32) -> Void)?
	/// View + Menu held for a second
	var onMenuCombo: (() -> Void)?

	/// Gyro aiming: motion goes to `onGyroAim`. Uses the phone's gyro when the controller has none.
	var gyroAimEnabled = false {
		didSet {
			guard gyroAimEnabled != oldValue else { return }
			let enabled = gyroAimEnabled
			gyroAim.withLock { $0 = enabled }
			// Before start() pickController sorts out the motion source
			guard !observers.isEmpty, controller?.motion?.hasRotationRate != true else { return }
			if enabled {
				startPhoneMotion()
			} else {
				motionManager.stopDeviceMotionUpdates()
			}
		}
	}
	/// `gyroAimEnabled` for the motion queue
	private let gyroAim = OSAllocatedUnfairLock(initialState: false)
	/// Takes the gyro's resting reading off, for whichever motion source is in use
	private let calibration = OSAllocatedUnfairLock(initialState: GyroCalibration())

	private(set) var controllerName: String?
	private var controller: GCController?
	/// The controller being read, if any
	var activeController: GCController? { controller }
	private let motionManager = CMMotionManager()
	private let motionQueue = OperationQueue()
	private var observers: [NSObjectProtocol] = []
	private var comboTimer: Timer?
	private var lastPad = GamepadState()

	/// Rumble on the controller or the phone
	let feedback = ControllerFeedback()

	init() {
		motionQueue.maxConcurrentOperationCount = 1
		motionQueue.qualityOfService = .userInteractive
	}

	func start() {
		GCController.shouldMonitorBackgroundEvents = false
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		// Phone haptics until (unless) a controller with its own turns up
		feedback.attach(nil)
		pickController()
	}

	func stop() {
		suspend()
		feedback.reset()
	}

	/// Lets go of the controller; `start()` picks it up again
	func suspend() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		comboTimer?.invalidate()
		comboTimer = nil
		motionManager.stopDeviceMotionUpdates()
		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
			controller.motion?.sensorsActive = false
		}
		controller = nil
		controllerName = nil
		lastPad = GamepadState()
		feedback.detach()
	}

	// MARK: - Controller selection

	private static var candidates: [GCController] {
		GCController.controllers().filter { $0.extendedGamepad != nil }
	}

	static var hasSupportedController: Bool { !candidates.isEmpty }

	private func pickController() {
		let candidates = Self.candidates
		let next = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		guard next !== controller else {
			if next == nil { startPhoneMotion() }
			return
		}

		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
			controller.motion?.sensorsActive = false
			updateMenuCombo(select: false, start: false)
		}
		controller = next
		controllerName = next?.vendorName
		calibration.withLock { $0.reset() }
		feedback.attach(next)
		guard let next, let pad = next.extendedGamepad else {
			lastPad = GamepadState()
			onPad?(lastPad)
			startPhoneMotion()
			return
		}
		log.notice("Using controller: \(next.vendorName ?? "?", privacy: .public) (\(next.productCategory, privacy: .public))")

		claimSystemGestures(next)
		pad.valueChangedHandler = { [weak self] pad, _ in
			guard let self, self.controller?.extendedGamepad === pad else { return }
			self.padChanged(pad)
		}

		if let motion = next.motion, motion.hasRotationRate {
			motionManager.stopDeviceMotionUpdates()
			motion.sensorsActive = true
			motion.valueChangedHandler = { [weak self] motion in self?.controllerMotion(motion) }
		} else {
			startPhoneMotion()
		}
		padChanged(pad)
	}

	private func claimSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .disabled
		}
	}

	private func restoreSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .enabled
		}
	}

	// MARK: - Buttons and sticks

	private func padChanged(_ pad: GCExtendedGamepad) {
		var b: UInt16 = 0
		func set(_ pressed: Bool, _ flag: UInt16) { if pressed { b |= flag } }

		set(pad.buttonA.isPressed, GamepadState.a)
		set(pad.buttonB.isPressed, GamepadState.b)
		set(pad.buttonX.isPressed, GamepadState.x)
		set(pad.buttonY.isPressed, GamepadState.y)
		set(pad.dpad.left.isPressed, GamepadState.dpadLeft)
		set(pad.dpad.right.isPressed, GamepadState.dpadRight)
		set(pad.dpad.up.isPressed, GamepadState.dpadUp)
		set(pad.dpad.down.isPressed, GamepadState.dpadDown)
		set(pad.leftShoulder.isPressed, GamepadState.leftShoulder)
		set(pad.rightShoulder.isPressed, GamepadState.rightShoulder)
		set(pad.leftThumbstickButton?.isPressed ?? false, GamepadState.leftThumb)
		set(pad.rightThumbstickButton?.isPressed ?? false, GamepadState.rightThumb)
		set(pad.buttonMenu.isPressed, GamepadState.start)
		set(pad.buttonHome?.isPressed ?? false, GamepadState.guide)
		let viewPressed = pad.buttonOptions?.isPressed ?? false
		set(viewPressed, GamepadState.back)

		var state = GamepadState()
		state.buttons = b
		state.leftTrigger = UInt8(clamping: Int((pad.leftTrigger.value * 255).rounded()))
		state.rightTrigger = UInt8(clamping: Int((pad.rightTrigger.value * 255).rounded()))
		// NVST is Y-up like GameController, so no flip
		state.leftX = Self.axis(pad.leftThumbstick.xAxis.value)
		state.leftY = Self.axis(pad.leftThumbstick.yAxis.value)
		state.rightX = Self.axis(pad.rightThumbstick.xAxis.value)
		state.rightY = Self.axis(pad.rightThumbstick.yAxis.value)

		lastPad = state
		onPad?(state)
		updateMenuCombo(select: viewPressed, start: pad.buttonMenu.isPressed)
	}

	private static func axis(_ v: Float) -> Int16 {
		Int16(clamping: Int((v * 32767).rounded()))
	}

	private func updateMenuCombo(select: Bool, start: Bool) {
		if select && start {
			guard comboTimer == nil else { return }
			comboTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
				self?.comboTimer = nil
				self?.onMenuCombo?()
			}
		} else {
			comboTimer?.invalidate()
			comboTimer = nil
		}
	}

	// MARK: - Motion

	private func controllerMotion(_ motion: GCMotion) {
		// GameController's rotation axes for a controller are x right, y towards the
		// player, z up. Reorder to x right, y up, z towards the player (the axes GyroStick
		// expects), as SDL does (src/joystick/apple/SDL_mfijoystick.m).
		let r = motion.rotationRate
		let gyro = SIMD3<Float>(Float(r.x), Float(r.z), Float(-r.y))
		// Some controllers only report raw acceleration: gravity and userAcceleration stay zero
		let a: GCAcceleration
		if motion.hasGravityAndUserAcceleration {
			let g = motion.gravity
			let u = motion.userAcceleration
			a = GCAcceleration(x: g.x + u.x, y: g.y + u.y, z: g.z + u.z)
		} else {
			a = motion.acceleration
		}
		let accel = -SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
		sendMotion(gyro: gyro, accel: accel, timestamp: Self.nowMicros())
	}

	/// Any thread
	private func sendMotion(gyro rawGyro: SIMD3<Float>, accel: SIMD3<Float>, timestamp: UInt32) {
		let gyro = calibration.withLock { $0.update(gyro: rawGyro, accel: accel, timestamp: timestamp) }
		onMotion?(gyro, accel, timestamp)
		guard gyroAim.withLock({ $0 }) else { return }
		if Thread.isMainThread {
			onGyroAim?(gyro, timestamp)
		} else {
			DispatchQueue.main.async { [weak self] in self?.onGyroAim?(gyro, timestamp) }
		}
	}

	private func startPhoneMotion() {
		guard gyroAimEnabled, motionManager.isDeviceMotionAvailable else { return }
		guard !motionManager.isDeviceMotionActive else { return }
		motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
		motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
			guard let self, let data else { return }
			self.phoneMotion(data)
		}
	}

	/// Interface orientation, cached on the main thread for the motion queue.
	var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

	private func phoneMotion(_ m: CMDeviceMotion) {
		// Device axes: x right / y up in portrait, z out of the screen.
		// Map to the screen as held in landscape, which lines up with a controller's
		// axes when the phone is upright in a clamp controller.
		let r = m.rotationRate
		let a = (x: m.gravity.x + m.userAcceleration.x, y: m.gravity.y + m.userAcceleration.y, z: m.gravity.z + m.userAcceleration.z)
		let gyro: SIMD3<Float>
		let accel: SIMD3<Float>
		switch interfaceOrientation {
		case .landscapeLeft:  // device top on the right
			gyro = SIMD3(Float(r.y), Float(-r.x), Float(r.z))
			accel = SIMD3(Float(a.y), Float(-a.x), Float(a.z))
		default:  // landscapeRight: device top on the left
			gyro = SIMD3(Float(-r.y), Float(r.x), Float(r.z))
			accel = SIMD3(Float(-a.y), Float(a.x), Float(a.z))
		}
		// CoreMotion reports gravity's direction; calibration expects the reaction (+1 g up at rest)
		sendMotion(gyro: gyro, accel: -accel, timestamp: UInt32(truncatingIfNeeded: UInt64(m.timestamp * 1_000_000)))
	}

	private static func nowMicros() -> UInt32 {
		UInt32(truncatingIfNeeded: UInt64(CACurrentMediaTime() * 1_000_000))
	}
}
