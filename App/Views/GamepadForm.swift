import SwiftUI

/// One row of a settings form that a controller can select. A form lists its rows in the
/// order shown, and each row's view is marked with `.gamepadRow(id)` for the highlight.
struct GamepadRow {
	let id: String
	/// What A does, for the hint bar; nil when A does nothing here
	var confirmLabel: String?
	var activate: (() -> Void)?
	/// Left (-1) and right (+1)
	var adjust: ((Int) -> Void)?

	static func toggle(_ id: String, _ value: Binding<Bool>) -> GamepadRow {
		GamepadRow(id: id, confirmLabel: "Toggle",
			activate: { value.wrappedValue.toggle() },
			adjust: { value.wrappedValue = $0 > 0 })
	}

	/// Left and right step through `options`; A moves to the next one, wrapping round
	static func picker<T: Equatable>(_ id: String, _ value: Binding<T>, _ options: [T]) -> GamepadRow {
		func index() -> Int { options.firstIndex(of: value.wrappedValue) ?? 0 }
		return GamepadRow(id: id, confirmLabel: "Next",
			activate: {
				guard !options.isEmpty else { return }
				value.wrappedValue = options[(index() + 1) % options.count]
			},
			adjust: { step in
				guard !options.isEmpty else { return }
				value.wrappedValue = options[min(max(index() + step, 0), options.count - 1)]
			})
	}

	static func slider(_ id: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> GamepadRow {
		GamepadRow(id: id, adjust: { direction in
			let next = (value.wrappedValue + Double(direction) * step) / step
			value.wrappedValue = min(max(next.rounded() * step, range.lowerBound), range.upperBound)
		})
	}

	static func link(_ id: String, open: @escaping () -> Void) -> GamepadRow {
		GamepadRow(id: id, confirmLabel: "Open", activate: open)
	}
}

private struct GamepadSelectionKey: EnvironmentKey {
	static let defaultValue: String? = nil
}

extension EnvironmentValues {
	/// The row a controller has selected in the enclosing `gamepadForm`, nil without a controller
	var gamepadSelection: String? {
		get { self[GamepadSelectionKey.self] }
		set { self[GamepadSelectionKey.self] = newValue }
	}
}

extension View {
	/// Marks a form row a controller can select: highlighted when selected, and scrolled to
	func gamepadRow(_ id: String) -> some View {
		modifier(GamepadRowHighlight(id: id))
	}

	/// Lets a controller drive a form: up and down move through `rows`, left and right change
	/// the selected one, A activates it and B runs `back`. Shows a hint bar while a controller
	/// is connected. `active` is false while something covers the form.
	func gamepadForm(_ rows: [GamepadRow], backLabel: String = "Back", active: Bool = true,
		back: @escaping () -> Void) -> some View {
		modifier(GamepadFormModifier(rows: rows, backLabel: backLabel, active: active, back: back))
	}
}

private struct GamepadRowHighlight: ViewModifier {
	let id: String
	@Environment(\.gamepadSelection) private var selection

	func body(content: Content) -> some View {
		content
			.id(id)
			.listRowBackground(selection == id ? Color.accentColor.opacity(0.18) : nil)
	}
}

/// The latest rows and back action, for the controller's handlers to read
private final class GamepadFormState {
	var rows: [GamepadRow] = []
	var back: () -> Void = {}
}

private struct GamepadFormModifier: ViewModifier {
	let rows: [GamepadRow]
	let backLabel: String
	let active: Bool
	let back: () -> Void

	@State private var gamepad = ListGamepadNavigator()
	@State private var selection: String?
	@State private var state = GamepadFormState()

	/// The selected row, or the first while nothing (still shown) is selected
	private var selected: GamepadRow? {
		rows.first { $0.id == selection } ?? rows.first
	}

	private var hints: [GamepadHint] {
		guard let confirm = gamepad.confirmSymbol, let cancel = gamepad.cancelSymbol else { return [] }
		var hints = [GamepadHint(symbol: "dpad", label: "Move")]
		if selected?.adjust != nil { hints.append(GamepadHint(symbol: "arrow.left.and.right", label: "Change")) }
		if let label = selected?.confirmLabel { hints.append(GamepadHint(symbol: confirm, label: label)) }
		hints.append(GamepadHint(symbol: cancel, label: backLabel))
		return hints
	}

	func body(content: Content) -> some View {
		state.rows = rows
		state.back = back
		return ScrollViewReader { proxy in
			content
				.environment(\.gamepadSelection, gamepad.confirmSymbol == nil ? nil : selected?.id)
				.onChange(of: selection) { _, id in
					guard let id, gamepad.confirmSymbol != nil else { return }
					withAnimation { proxy.scrollTo(id) }
				}
		}
		.safeAreaInset(edge: .bottom) {
			if !hints.isEmpty { GamepadHintBar(hints: hints) }
		}
		.onAppear {
			gamepad.onMove = { move in
				let rows = state.rows
				guard !rows.isEmpty else { return }
				let index = rows.firstIndex { $0.id == selection } ?? 0
				let current = rows[index]
				switch move {
				case .up: selection = rows[max(index - 1, 0)].id
				case .down: selection = rows[min(index + 1, rows.count - 1)].id
				case .left: current.adjust?(-1)
				case .right: current.adjust?(1)
				}
			}
			gamepad.onConfirm = {
				let rows = state.rows
				(rows.first { $0.id == selection } ?? rows.first)?.activate?()
			}
			gamepad.onCancel = { state.back() }
			gamepad.start()
			gamepad.setActive(active)
		}
		.onDisappear { gamepad.stop() }
		.onChange(of: active) { _, active in gamepad.setActive(active) }
	}
}
