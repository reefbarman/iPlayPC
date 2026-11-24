import CoreHaptics
import GameController
import QuartzCore

/// Rumble from the game, played on the controller's motors, or on the phone itself when
/// there's no controller (on-screen controls) or the controller has no motors (e.g. a clamp
/// like the Backbone).
///
/// Call from the main thread unless noted.
final class ControllerFeedback {
	/// The Rumble setting
	var rumbleEnabled = true {
		didSet {
			let enabled = rumbleEnabled
			queue.async { self.motorsEnabled = enabled; if !enabled { self.silence() } }
		}
	}

	/// The Phone haptics setting: how strongly the phone plays rumble, 0...1
	var phoneHapticsScale: Float = 1 {
		didSet {
			let scale = phoneHapticsScale
			queue.async { self.phoneScale = scale; self.flushPhone() }
		}
	}

	private let queue = DispatchQueue(label: "iPlayNow.controller-feedback", qos: .userInteractive)

	// Main thread
	private var controller: GCController?
	/// What the game asked the lightbar to show, and the colour to put back afterwards
	private var lightbar: (UInt8, UInt8, UInt8)?
	private var savedLight: GCColor?

	// Feedback queue
	private var handles: [Motor] = []
	/// The phone's own haptics, when the controller has none
	private var phone: Motor?
	/// What rumble wants, per side (level, sharpness); the phone plays the strongest
	private var rumbleOut: [(Float, Float)] = [(0, 0.5), (0, 0.5)]
	private var motorsEnabled = true
	private var phoneScale: Float = 1

	// MARK: - Controller

	func attach(_ controller: GCController?) {
		detach()
		self.controller = controller
		savedLight = controller?.light?.color
		applyLightbar()
		let haptics = controller?.haptics
		let localities = haptics?.supportedLocalities ?? []
		let summary: String = queue.sync {
			if let haptics {
				if localities.contains(.leftHandle) && localities.contains(.rightHandle) {
					handles = [.leftHandle, .rightHandle].compactMap { Motor(haptics: haptics, locality: $0, queue: queue) }
				}
				if handles.count != 2 {
					handles = [Motor(haptics: haptics, locality: .default, queue: queue)].compactMap { $0 }
				}
			}
			if handles.isEmpty { phone = Motor.phone(queue: queue) }
			return "\(handles.count) rumble motor(s), phone haptics \(phone != nil ? "yes" : "no"), controller haptics [\(localities.map(\.rawValue).sorted().joined(separator: ", "))]"
		}
		log.notice("Feedback: \(summary, privacy: .public)")
	}

	/// Stops the motors and lets go of the controller
	func detach() {
		if let light = controller?.light, let savedLight { light.color = savedLight }
		savedLight = nil
		controller = nil
		queue.sync {
			(handles + [phone].compactMap { $0 }).forEach { $0.stop() }
			handles = []
			phone = nil
			rumbleOut = [(0, 0.5), (0, 0.5)]
		}
	}

	/// Silences anything the last session left running
	func reset() {
		lightbar = nil
		queue.async { self.silence() }
	}

	// MARK: - Lightbar

	/// The game's lightbar colour, for a controller with a light (DualSense, DualShock 4). Any thread.
	func lightbar(r: UInt8, g: UInt8, b: UInt8) {
		DispatchQueue.main.async {
			self.lightbar = (r, g, b)
			self.applyLightbar()
		}
	}

	private func applyLightbar() {
		guard let light = controller?.light, let (r, g, b) = lightbar else { return }
		light.color = GCColor(red: Float(r) / 255, green: Float(g) / 255, blue: Float(b) / 255)
	}

	// MARK: - Rumble (any thread)

	/// Xbox-style rumble: low = heavy low-frequency motor (left), high = light high-frequency motor (right), 0...1
	func rumble(low: Float, high: Float) {
		queue.async {
			self.drive(left: low, right: high, sharpness: (0.3, 0.8))
		}
	}

	/// Queue
	private func drive(left: Float, right: Float, sharpness: (Float, Float)) {
		guard motorsEnabled, !handles.isEmpty || phone != nil else { return }
		let l = min(1, max(0, left))
		let r = min(1, max(0, right))
		rumbleOut = [(l, sharpness.0), (r, sharpness.1)]
		if phone != nil {
			flushPhone()
		} else if handles.count == 2 {
			handles[0].set(intensity: l, sharpness: sharpness.0)
			handles[1].set(intensity: r, sharpness: sharpness.1)
		} else {
			let total = l + r
			let blended = total > 0 ? (sharpness.0 * l + sharpness.1 * r) / total : 0.5
			handles[0].set(intensity: max(l, r), sharpness: blended)
		}
	}

	/// Queue. One actuator for everything: play whatever is strongest right now.
	private func flushPhone() {
		guard let phone else { return }
		let strongest = rumbleOut.max { $0.0 < $1.0 } ?? (0, 0.5)
		phone.set(intensity: motorsEnabled ? strongest.0 * phoneScale : 0, sharpness: strongest.1)
	}

	/// Queue
	private func silence() {
		rumbleOut = [(0, 0.5), (0, 0.5)]
		(handles + [phone].compactMap { $0 }).forEach { $0.set(intensity: 0, sharpness: 0.5) }
	}
}

/// One haptic actuator: a continuous event whose intensity (and, on the phone,
/// sharpness) is changed as values arrive, which is cheaper than scheduling
/// new patterns. Used only on the feedback queue.
///
/// Controller engines are driven the way SDL drives them: one endless event,
/// intensity only, played only while there's something to feel. The phone gets
/// a looping pattern with sharpness as well.
private final class Motor {
	private let engine: CHHapticEngine
	private let queue: DispatchQueue
	private let name: String
	/// A game controller's actuator rather than the phone's Taptic Engine
	private let isController: Bool
	private var player: CHHapticPatternPlayer?
	/// The player is running (controllers stop it at zero)
	private var playing = false
	private var intensity: Float = 0
	private var sharpness: Float = 0.5
	private var needsRestart = false
	private var lastRestart: CFTimeInterval = 0
	private var stopped = false
	private var loggedError = false

	convenience init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality, queue: DispatchQueue) {
		guard let engine = haptics.createEngine(withLocality: locality) else {
			log.error("Haptics (\(locality.rawValue, privacy: .public)): the controller has no engine for it")
			return nil
		}
		self.init(engine: engine, name: locality.rawValue, isController: true, queue: queue)
	}

	/// The phone's Taptic Engine, if it has one
	static func phone(queue: DispatchQueue) -> Motor? {
		guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
		do {
			let engine = try CHHapticEngine()
			// Don't touch the audio session the game audio runs on
			engine.playsHapticsOnly = true
			return Motor(engine: engine, name: "phone", isController: false, queue: queue)
		} catch {
			log.error("Phone haptics: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	init?(engine: CHHapticEngine, name: String, isController: Bool, queue: DispatchQueue) {
		self.engine = engine
		self.queue = queue
		self.name = name
		self.isController = isController
		engine.isAutoShutdownEnabled = false
		// Interruptions (backgrounding, a server reset): start again on the next update
		engine.stoppedHandler = { [weak self] _ in queue.async { self?.needsRestart = true } }
		engine.resetHandler = { [weak self] in queue.async { self?.needsRestart = true } }
		do {
			try start()
		} catch {
			log.error("Haptics (\(name, privacy: .public)): \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	private func start() throws {
		try engine.start()
		playing = false
		if isController {
			let event = CHHapticEvent(
				eventType: .hapticContinuous,
				parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
				relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
			player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
			try update()
			return
		}
		let event = CHHapticEvent(
			eventType: .hapticContinuous,
			parameters: [
				CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
				CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
			], relativeTime: 0, duration: 30)
		let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
		player.loopEnabled = true
		try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
		try player.start(atTime: CHHapticTimeImmediate)
		self.player = player
		playing = true
	}

	private var parameters: [CHHapticDynamicParameter] {
		[
			CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
			// Added to the event's 0.5
			CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0),
		]
	}

	/// Sends the current values to the player
	private func update() throws {
		guard let player else { return }
		guard isController else {
			return try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
		}
		guard intensity > 0 else {
			if playing {
				playing = false
				try player.stop(atTime: CHHapticTimeImmediate)
			}
			return
		}
		if !playing {
			try player.start(atTime: CHHapticTimeImmediate)
			playing = true
		}
		try player.sendParameters(
			[CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)],
			atTime: CHHapticTimeImmediate)
	}

	/// Only the first failure, so a broken actuator doesn't flood the log
	private func logOnce(_ error: Error) {
		guard !loggedError else { return }
		loggedError = true
		log.error("Haptics (\(self.name, privacy: .public)) update failed: \(error.localizedDescription, privacy: .public)")
	}

	/// Restarts after an interruption, at most once a second
	private func ensureRunning() -> Bool {
		guard !stopped else { return false }
		guard needsRestart else { return true }
		let now = CACurrentMediaTime()
		guard now - lastRestart > 1 else { return false }
		lastRestart = now
		player = nil
		do {
			try start()
			needsRestart = false
			return true
		} catch {
			return false
		}
	}

	func set(intensity: Float, sharpness: Float) {
		let intensity = min(1, max(0, intensity))
		let sharpness = min(1, max(0, sharpness))
		// Each change is a packet to the controller: skip ones you couldn't feel
		guard abs(intensity - self.intensity) > 0.01 || abs(sharpness - self.sharpness) > 0.03 else { return }
		self.intensity = intensity
		self.sharpness = sharpness
		guard ensureRunning() else { return }
		do {
			try update()
		} catch {
			logOnce(error)
		}
	}

	func stop() {
		stopped = true
		if playing { try? player?.stop(atTime: CHHapticTimeImmediate) }
		playing = false
		player = nil
		engine.stop()
	}
}
