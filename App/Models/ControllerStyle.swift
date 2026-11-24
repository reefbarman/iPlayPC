import GameController
import Observation

/// Which buttons to name: PlayStation names while a DualSense or DualShock 4 is the controller
/// in use, Xbox names for anything else. The game always gets an Xbox pad; this is only what
/// the app calls the buttons (and which model the Controller Test shows).
enum ControllerStyle: Equatable {
	case xbox, dualSense, dualShock

	init(_ controller: GCController?) {
		switch controller?.extendedGamepad {
		case is GCDualSenseGamepad: self = .dualSense
		case is GCDualShockGamepad: self = .dualShock
		default: self = .xbox
		}
	}

	/// The style of the controller in use right now, picked the way the stream picks it
	static var current: ControllerStyle { ConnectedController.shared.style }

	var isPlayStation: Bool { self != .xbox }

	/// The bottom face button
	var a: String { isPlayStation ? "Cross" : "A" }
	var b: String { isPlayStation ? "Circle" : "B" }
	var x: String { isPlayStation ? "Square" : "X" }
	var y: String { isPlayStation ? "Triangle" : "Y" }
	var lb: String { isPlayStation ? "L1" : "LB" }
	var rb: String { isPlayStation ? "R1" : "RB" }
	var lt: String { isPlayStation ? "L2" : "LT" }
	var rt: String { isPlayStation ? "R2" : "RT" }
	var leftStickClick: String { isPlayStation ? "L3" : "Left stick" }
	var rightStickClick: String { isPlayStation ? "R3" : "Right stick" }
	/// Xbox View
	var view: String {
		switch self {
		case .xbox: "View"
		case .dualSense: "Create"
		case .dualShock: "Share"
		}
	}
	/// Xbox Menu
	var menu: String { isPlayStation ? "Options" : "Menu" }
	var home: String { isPlayStation ? "PS" : "Xbox" }
}

/// Watches which controller is in use, so text naming buttons follows it
@Observable
final class ConnectedController {
	static let shared = ConnectedController()

	private(set) var style = ControllerStyle.xbox
	@ObservationIgnored private var observers: [NSObjectProtocol] = []

	private init() {
		for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent] {
			observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				self?.refresh()
			})
		}
		refresh()
	}

	private func refresh() {
		let candidates = GCController.controllers().filter { $0.extendedGamepad != nil }
		let controller = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		let next = ControllerStyle(controller)
		if next != style { style = next }
	}
}
