import NVSTKit
import UIKit

/// An occupied stick (even at its centre) owns that axis until its finger lifts.
/// Stick Y is up-positive, like NVSTGamepad.
struct VirtualPadState: Equatable {
	var buttons: UInt16 = 0
	var leftTrigger: UInt8 = 0
	var rightTrigger: UInt8 = 0
	var leftStick: SIMD2<Int16>?
	var rightStick: SIMD2<Int16>?
}

/// The Virtual controls settings: size, see-through-ness and stick behaviour
struct VirtualControlsStyle: Equatable {
	var scale: CGFloat = 1
	/// 0.2...1, multiplies each control's own transparency
	var opacity: CGFloat = 1
	/// Sticks sit in fixed spots instead of starting wherever a thumb lands
	var fixedSticks = false

	init() {}

	init(_ settings: StreamSettings) {
		scale = settings.controlsSize.scale
		opacity = CGFloat(min(1, max(0.2, settings.controlsOpacity)))
		fixedSticks = settings.fixedSticks
	}
}

/// Drawn above Metal. StreamMetalView owns the UIKit touches so that fixed controls,
/// floating sticks, the touchpad and the stream menu all agree on who gets each finger.
final class VirtualControlsOverlay: UIView {
	private enum Action {
		case button(UInt16), trigger(left: Bool), dpad(UInt16)
	}

	private struct Control {
		let label: String
		let rect: CGRect
		let action: Action
		let rounded: Bool
		let icon: UIImage?
		/// The face buttons' Xbox colours
		let tint: UIColor?

		init(_ label: String, _ rect: CGRect, _ action: Action, rounded: Bool = false, icon: UIImage? = nil, tint: UIColor? = nil) {
			self.label = label
			self.rect = rect
			self.action = action
			self.rounded = rounded
			self.icon = icon
			self.tint = tint
		}
	}

	/// A green, B red, X blue, Y yellow, a little lighter than the controller so they read on a dark game
	private static let green = UIColor(red: 0.42, green: 0.80, blue: 0.29, alpha: 1)
	private static let red = UIColor(red: 0.95, green: 0.27, blue: 0.27, alpha: 1)
	private static let blue = UIColor(red: 0.25, green: 0.60, blue: 0.98, alpha: 1)
	private static let yellow = UIColor(red: 0.99, green: 0.80, blue: 0.20, alpha: 1)

	private enum Finger {
		case button(UInt16), trigger(left: Bool), dpad(UInt16)
		case stick(left: Bool, origin: CGPoint, location: CGPoint)
	}

	private var fingers: [ObjectIdentifier: Finger] = [:]
	private var controls: [Control] = []
	private var dpadCentre = CGPoint.zero
	private var dpadRect = CGRect.zero
	/// Where the fixed sticks sit (left, right), when they're fixed
	private var fixedStickCentres: [CGPoint] = []
	private var lastLayout: (safeArea: CGRect, systemButtonY: CGFloat)?

	private var pad = VirtualPadState()
	static let systemButtonHeight: CGFloat = 44
	private var stickRadius: CGFloat { 42 * style.scale }
	/// A fixed stick picks up a thumb this far from its centre
	private var fixedStickReach: CGFloat { stickRadius * 1.6 }

	var style = VirtualControlsStyle() {
		didSet {
			guard style != oldValue else { return }
			if let lastLayout { setLayout(in: lastLayout.safeArea, systemButtonY: lastLayout.systemButtonY) }
		}
	}

	private static func symbol(_ name: String) -> UIImage? {
		UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
			.withTintColor(.white.withAlphaComponent(0.9), renderingMode: .alwaysOriginal)
	}

	/// Xbox View (two overlapping windows) and Menu (three lines)
	private static let viewIcon = symbol("rectangle.on.rectangle")
	private static let menuIcon = symbol("line.3.horizontal")

	override init(frame: CGRect) {
		super.init(frame: frame)
		isOpaque = false
		isUserInteractionEnabled = false
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func setLayout(in safeArea: CGRect, systemButtonY: CGFloat) {
		lastLayout = (safeArea, systemButtonY)
		// Everything but the bottom shortcut row grows and shrinks around the D-pad and face buttons
		let s = style.scale
		// The D-pad and face buttons keep a 10-point margin to the safe area edges.
		let x = safeArea.minX + 10 + 58 * s, right = safeArea.maxX - 10 - 58 * s
		// Keep the D-pad and face buttons above the 44-point bottom shortcut row.
		let row = safeArea.maxY - 71 - 54 * s
		// Sit just above the D-pad and face buttons, even on the taller inner screen.
		let shoulders = row - 86 * s
		let middle = safeArea.midX
		func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 44, _ h: CGFloat = 44) -> CGRect {
			CGRect(x: x - w * s / 2, y: y - h * s / 2, width: w * s, height: h * s)
		}
		func button(_ label: String, _ x: CGFloat, _ y: CGFloat, _ bit: UInt16, tint: UIColor? = nil) -> Control {
			Control(label, rect(x, y), .button(bit), tint: tint)
		}
		/// The bottom shortcut row stays one size so it fits the letterbox
		func systemRect(_ x: CGFloat) -> CGRect {
			CGRect(x: x - 26, y: systemButtonY - Self.systemButtonHeight / 2, width: 52, height: Self.systemButtonHeight)
		}
		dpadCentre = CGPoint(x: x, y: row)
		dpadRect = rect(x, row, 116, 116)
		// In the open space inside the D-pad and face buttons, clear of L3/R3
		fixedStickCentres = [CGPoint(x: x + 150 * s, y: row - 20 * s), CGPoint(x: right - 150 * s, y: row - 20 * s)]
		controls = [
			Control("LT", rect(x - 32 * s, shoulders, 56, 44), .trigger(left: true), rounded: true),
			Control("LB", rect(x + 32 * s, shoulders, 56, 44), .button(NVSTGamepad.leftShoulder), rounded: true),
			Control("RB", rect(right - 32 * s, shoulders, 56, 44), .button(NVSTGamepad.rightShoulder), rounded: true),
			Control("RT", rect(right + 32 * s, shoulders, 56, 44), .trigger(left: false), rounded: true),
			Control("▲", rect(x, row - 36 * s, 36, 36), .dpad(NVSTGamepad.dpadUp), rounded: true),
			Control("◀", rect(x - 36 * s, row, 36, 36), .dpad(NVSTGamepad.dpadLeft), rounded: true),
			Control("▶", rect(x + 36 * s, row, 36, 36), .dpad(NVSTGamepad.dpadRight), rounded: true),
			Control("▼", rect(x, row + 36 * s, 36, 36), .dpad(NVSTGamepad.dpadDown), rounded: true),
			button("Y", right, row - 36 * s, NVSTGamepad.y, tint: Self.yellow),
			button("X", right - 36 * s, row, NVSTGamepad.x, tint: Self.blue),
			button("B", right + 36 * s, row, NVSTGamepad.b, tint: Self.red),
			button("A", right, row + 36 * s, NVSTGamepad.a, tint: Self.green),
			button("LS", x + 76 * s, row + 37 * s, NVSTGamepad.leftThumb),
			button("RS", right - 76 * s, row + 37 * s, NVSTGamepad.rightThumb),
			Control("View", systemRect(middle - 32), .button(NVSTGamepad.back), rounded: true, icon: Self.viewIcon),
			Control("Menu", systemRect(middle + 32), .button(NVSTGamepad.start), rounded: true, icon: Self.menuIcon),
		]
		setNeedsDisplay()
	}

	private func stickIsFree(left: Bool) -> Bool {
		!fingers.values.contains {
			if case .stick(let side, _, _) = $0 { return side == left }
			return false
		}
	}

	func reset() {
		fingers.removeAll()
		pad = VirtualPadState()
		setNeedsDisplay()
	}

	/// A fixed control can claim a touch even when its initial state is neutral.
	func begin(_ id: ObjectIdentifier, at point: CGPoint, allowsStick: Bool) -> (handled: Bool, state: VirtualPadState?) {
		if let control = controls.first(where: { $0.rect.contains(point) }) {
			switch control.action {
			case .button(let bit): fingers[id] = .button(bit)
			case .trigger(let left): fingers[id] = .trigger(left: left)
			case .dpad: fingers[id] = .dpad(direction(at: point))
			}
		} else if dpadRect.contains(point) {
			fingers[id] = .dpad(direction(at: point))
		} else if style.fixedSticks {
			// Measured from the stick's own centre, so touching off-centre pushes it straight away.
			// Each stick's reach wins over the touchpad, which it can overlap on short screens.
			guard let side = fixedStickCentres.indices.first(where: {
				hypot(point.x - fixedStickCentres[$0].x, point.y - fixedStickCentres[$0].y) <= fixedStickReach
			}) else { return (false, nil) }
			let left = side == 0
			guard stickIsFree(left: left) else { return (false, nil) }
			fingers[id] = .stick(left: left, origin: fixedStickCentres[side], location: point)
		} else {
			guard allowsStick else { return (false, nil) }
			let left = point.x < bounds.midX
			guard stickIsFree(left: left) else { return (false, nil) }
			fingers[id] = .stick(left: left, origin: point, location: point)
		}
		return (true, publish())
	}

	func move(_ id: ObjectIdentifier, to point: CGPoint) -> VirtualPadState? {
		switch fingers[id] {
		case .stick(let left, let origin, _): fingers[id] = .stick(left: left, origin: origin, location: point)
		case .dpad: fingers[id] = .dpad(direction(at: point))
		default: return nil
		}
		return publish()
	}

	func end(_ id: ObjectIdentifier) -> VirtualPadState? {
		guard fingers.removeValue(forKey: id) != nil else { return nil }
		return publish()
	}

	private func direction(at point: CGPoint) -> UInt16 {
		let dx = point.x - dpadCentre.x, dy = point.y - dpadCentre.y
		let distance = max(abs(dx), abs(dy))
		guard distance > 9 else { return 0 }
		let threshold = distance * 0.42
		var bits: UInt16 = 0
		if dx < -threshold { bits |= NVSTGamepad.dpadLeft }
		if dx > threshold { bits |= NVSTGamepad.dpadRight }
		if dy < -threshold { bits |= NVSTGamepad.dpadUp }
		if dy > threshold { bits |= NVSTGamepad.dpadDown }
		return bits
	}

	private func publish() -> VirtualPadState? {
		var next = VirtualPadState()
		for finger in fingers.values {
			switch finger {
			case .button(let bit), .dpad(let bit): next.buttons |= bit
			case .trigger(let left):
				if left { next.leftTrigger = 255 } else { next.rightTrigger = 255 }
			case .stick(let left, let origin, let location):
				let dx = location.x - origin.x, dy = location.y - origin.y
				let distance = hypot(dx, dy)
				let deadZone: CGFloat = 5
				let scale = distance > deadZone ? 32767 * min(1, (distance - deadZone) / (stickRadius - deadZone)) / distance : 0
				// Screen Y grows downwards; the pad's grows upwards
				let axis = SIMD2(Int16(clamping: Int((dx * scale).rounded())), Int16(clamping: Int((-dy * scale).rounded())))
				if left { next.leftStick = axis } else { next.rightStick = axis }
			}
		}
		setNeedsDisplay()
		guard next != pad else { return nil }
		pad = next
		return next
	}

	override func draw(_ rect: CGRect) {
		for control in controls {
			let pressed: Bool
			switch control.action {
			case .button(let bit), .dpad(let bit): pressed = pad.buttons & bit != 0
			case .trigger(let left): pressed = (left ? pad.leftTrigger : pad.rightTrigger) != 0
			}
			drawControl(control.rect, radius: control.rounded ? 10 : control.rect.height / 2, pressed: pressed,
				label: control.label, icon: control.icon, tint: control.tint)
		}

		let radius = stickRadius
		let knobRadius = 18 * style.scale
		func drawStick(origin: CGPoint, location: CGPoint, active: Bool) {
			let dx = location.x - origin.x, dy = location.y - origin.y
			let scale = radius / max(radius, hypot(dx, dy))
			let knob = CGPoint(x: origin.x + dx * scale, y: origin.y + dy * scale)
			drawControl(CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2), radius: radius, pressed: false)
			drawControl(CGRect(x: knob.x - knobRadius, y: knob.y - knobRadius, width: knobRadius * 2, height: knobRadius * 2),
				radius: knobRadius, pressed: active)
		}
		var occupied: Set<Bool> = []
		for case .stick(let left, let origin, let location) in fingers.values {
			occupied.insert(left)
			drawStick(origin: origin, location: location, active: true)
		}
		// Fixed sticks are always shown, resting at their centres
		if style.fixedSticks {
			for (side, centre) in fixedStickCentres.enumerated() where !occupied.contains(side == 0) {
				drawStick(origin: centre, location: centre, active: false)
			}
		}
	}

	private func drawControl(_ rect: CGRect, radius: CGFloat, pressed: Bool, label: String? = nil, icon: UIImage? = nil,
		tint: UIColor? = nil) {
		// A pressed control stays easy to see however faint the rest are
		let alpha = pressed ? max(style.opacity, 0.7) : style.opacity
		let path = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: radius)
		let fill: UIColor = if let tint {
			pressed ? tint.withAlphaComponent(0.55 * alpha) : UIColor.black.withAlphaComponent(0.36 * alpha)
		} else {
			pressed ? UIColor.white.withAlphaComponent(0.42 * alpha) : UIColor.black.withAlphaComponent(0.36 * alpha)
		}
		fill.setFill()
		path.fill()
		(tint ?? .white).withAlphaComponent((pressed ? 0.85 : 0.5) * alpha).setStroke()
		path.lineWidth = 1
		path.stroke()
		if let icon {
			icon.draw(at: CGPoint(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2), blendMode: .normal, alpha: alpha)
			return
		}
		guard let label else { return }
		let attributes: [NSAttributedString.Key: Any] = [
			.font: UIFont.systemFont(ofSize: (label.count == 1 ? 23 : 12) * style.scale, weight: .semibold),
			.foregroundColor: (pressed || tint == nil ? UIColor.white : tint!).withAlphaComponent(0.9 * alpha),
		]
		let size = label.size(withAttributes: attributes)
		label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
	}
}
