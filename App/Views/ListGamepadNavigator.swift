import GameController
import SwiftUI

/// Lets a game controller drive app screens outside the stream: the d-pad or
/// left stick moves a selection (up/down, or around a grid), the bottom face
/// button (A, or ✕ on PlayStation pads) confirms and the right one (B / ○) cancels.
/// Y (△), X (□), Menu, View and the shoulder buttons are free for a screen's own actions.
///
/// Uses per-element handlers so it never touches the gamepad-wide
/// `valueChangedHandler` that `ControllerInput` owns while streaming, and
/// detaches entirely whenever its screen is covered or busy.
@Observable
final class ListGamepadNavigator {
	enum Move { case up, down, left, right }

	@ObservationIgnored var onMove: ((Move) -> Void)?
	@ObservationIgnored var onConfirm: (() -> Void)?
	@ObservationIgnored var onCancel: (() -> Void)?
	/// Y / △
	@ObservationIgnored var onTop: (() -> Void)?
	/// X / □
	@ObservationIgnored var onLeft: (() -> Void)?
	/// Menu (☰ / Options)
	@ObservationIgnored var onMenu: (() -> Void)?
	/// View (⧉ / Create)
	@ObservationIgnored var onView: (() -> Void)?
	/// LB (-1) and RB (+1)
	@ObservationIgnored var onShoulder: ((Int) -> Void)?
	/// SF Symbol for the connected controller's confirm button, nil without a controller
	private(set) var confirmSymbol: String?
	/// SF Symbol for the connected controller's cancel button, nil without a controller
	private(set) var cancelSymbol: String?
	private(set) var topSymbol: String?
	private(set) var leftSymbol: String?
	private(set) var menuSymbol: String?
	/// nil on controllers without a View button
	private(set) var viewSymbol: String?
	private(set) var leftShoulderSymbol: String?
	private(set) var rightShoulderSymbol: String?

	/// The navigator whose handlers are on the controller. Only one screen drives it
	/// at a time, and a screen going away mustn't clear handlers the next one set.
	private static weak var owner: ListGamepadNavigator?

	@ObservationIgnored private var controller: GCController?
	@ObservationIgnored private var observers: [NSObjectProtocol] = []
	@ObservationIgnored private var active = false
	@ObservationIgnored private var direction: Move?
	@ObservationIgnored private var repeatTimer: Timer?

	func start() {
		guard observers.isEmpty else { return }
		for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent] {
			observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
				self?.refresh()
			})
		}
		refresh()
	}

	func stop() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		detach()
		confirmSymbol = nil
		cancelSymbol = nil
		topSymbol = nil
		leftSymbol = nil
		menuSymbol = nil
		viewSymbol = nil
		leftShoulderSymbol = nil
		rightShoulderSymbol = nil
	}

	func setActive(_ active: Bool) {
		self.active = active
		refresh()
	}

	private func refresh() {
		let candidates = GCController.controllers().filter { $0.extendedGamepad != nil }
		let next = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		let pad = next?.extendedGamepad
		let playStation = pad is GCDualSenseGamepad || pad is GCDualShockGamepad
		confirmSymbol = pad.map { Self.symbol($0.buttonA, fallback: playStation ? "xmark.circle" : "a.circle") }
		cancelSymbol = pad.map { Self.symbol($0.buttonB, fallback: playStation ? "circle.circle" : "b.circle") }
		topSymbol = pad.map { Self.symbol($0.buttonY, fallback: playStation ? "triangle.circle" : "y.circle") }
		leftSymbol = pad.map { Self.symbol($0.buttonX, fallback: playStation ? "square.circle" : "x.circle") }
		menuSymbol = pad.map { Self.symbol($0.buttonMenu, fallback: "line.3.horizontal.circle") }
		viewSymbol = pad?.buttonOptions.map { Self.symbol($0, fallback: "rectangle.on.rectangle.circle") }
		leftShoulderSymbol = pad.map { Self.symbol($0.leftShoulder, fallback: playStation ? "l1.rectangle.roundedbottom" : "lb.rectangle.roundedbottom") }
		rightShoulderSymbol = pad.map { Self.symbol($0.rightShoulder, fallback: playStation ? "r1.rectangle.roundedbottom" : "rb.rectangle.roundedbottom") }

		let wanted = active ? next : nil
		guard wanted !== controller || (wanted != nil && Self.owner !== self) else { return }
		detach()
		guard let wanted, let pad = wanted.extendedGamepad else { return }
		controller = wanted
		Self.owner = self
		pad.dpad.valueChangedHandler = { [weak self] _, _, _ in self?.updateDirection(pad) }
		pad.leftThumbstick.valueChangedHandler = { [weak self] _, _, _ in self?.updateDirection(pad) }
		onRelease(pad.buttonA) { $0.onConfirm?() }
		onRelease(pad.buttonB) { $0.onCancel?() }
		onRelease(pad.buttonY) { $0.onTop?() }
		onRelease(pad.buttonX) { $0.onLeft?() }
		onRelease(pad.buttonMenu) { $0.onMenu?() }
		if let view = pad.buttonOptions { onRelease(view) { $0.onView?() } }
		onRelease(pad.leftShoulder) { $0.onShoulder?(-1) }
		onRelease(pad.rightShoulder) { $0.onShoulder?(1) }
	}

	/// Fires on release so the press doesn't carry into the stream or the next screen
	private func onRelease(_ button: GCControllerButtonInput, _ action: @escaping (ListGamepadNavigator) -> Void) {
		var armed = false
		button.pressedChangedHandler = { [weak self] _, _, pressed in
			guard let self else { return }
			if pressed {
				armed = true
			} else if armed {
				armed = false
				action(self)
			}
		}
	}

	/// The controller's own symbol for a button when the system can render it
	private static func symbol(_ button: GCControllerButtonInput, fallback: String) -> String {
		if let name = button.sfSymbolsName, UIImage(systemName: name) != nil { return name }
		return fallback
	}

	private func detach() {
		if Self.owner === self, let pad = controller?.extendedGamepad {
			pad.dpad.valueChangedHandler = nil
			pad.leftThumbstick.valueChangedHandler = nil
			pad.buttonA.pressedChangedHandler = nil
			pad.buttonB.pressedChangedHandler = nil
			pad.buttonX.pressedChangedHandler = nil
			pad.buttonY.pressedChangedHandler = nil
			pad.buttonMenu.pressedChangedHandler = nil
			pad.buttonOptions?.pressedChangedHandler = nil
			pad.leftShoulder.pressedChangedHandler = nil
			pad.rightShoulder.pressedChangedHandler = nil
			Self.owner = nil
		}
		controller = nil
		setDirection(nil)
	}

	private func updateDirection(_ pad: GCExtendedGamepad) {
		let x = pad.leftThumbstick.xAxis.value
		let y = pad.leftThumbstick.yAxis.value
		if pad.dpad.up.isPressed || y > 0.6 {
			setDirection(.up)
		} else if pad.dpad.down.isPressed || y < -0.6 {
			setDirection(.down)
		} else if pad.dpad.left.isPressed || x < -0.6 {
			setDirection(.left)
		} else if pad.dpad.right.isPressed || x > 0.6 {
			setDirection(.right)
		} else if abs(x) < 0.4 && abs(y) < 0.4 {
			setDirection(nil)
		}
	}

	/// Moves once, then repeats while held
	private func setDirection(_ dir: Move?) {
		guard dir != direction else { return }
		direction = dir
		repeatTimer?.invalidate()
		repeatTimer = nil
		guard let dir else { return }
		onMove?(dir)
		repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
			self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
				guard let self, let direction = self.direction else { return }
				self.onMove?(direction)
			}
		}
	}
}

/// One button and what it does on this screen
struct GamepadHint: Identifiable {
	let symbol: String
	let label: String
	/// A second button doing the same, e.g. LB and RB for previous and next
	var pairedSymbol: String?
	var id: String { label }
}

/// What each controller button does here, along the bottom like a console's
struct GamepadHintBar: View {
	let hints: [GamepadHint]

	var body: some View {
		HStack(spacing: 16) {
			ForEach(hints) { hint in
				HStack(spacing: 5) {
					Image(systemName: hint.symbol).imageScale(.large)
					if let paired = hint.pairedSymbol {
						Image(systemName: paired).imageScale(.large)
					}
					Text(hint.label)
				}
			}
		}
		.font(.subheadline.weight(.medium))
		.foregroundStyle(.secondary)
		.lineLimit(1)
		.minimumScaleFactor(0.8)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 6)
		.padding(.horizontal, 12)
		// Sink into the home indicator's strip (keeping 18 pt clear of the screen edge) instead of
		// stacking on top of it. Negative padding shrinks the space the bar takes from the content.
		.padding(.bottom, -max(0, Self.bottomInset - 12))
		// Centred on the screen, not on the covers, which leave room for the side toolbar
		.background(.bar, ignoresSafeAreaEdges: [.bottom, .horizontal])
		.ignoresSafeArea(.container, edges: .horizontal)
	}

	private static var bottomInset: CGFloat {
		UIApplication.shared.connectedScenes
			.compactMap { ($0 as? UIWindowScene)?.keyWindow }
			.first?.safeAreaInsets.bottom ?? 0
	}
}
