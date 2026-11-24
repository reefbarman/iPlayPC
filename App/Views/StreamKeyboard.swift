import SwiftUI
import UIKit

/// Keys the iPhone keyboard can't type as text, by Windows virtual-key code
enum StreamKey: UInt16 {
	case backspace = 0x08
	case tab = 0x09
	case enter = 0x0D
	case escape = 0x1B
	case left = 0x25
	case up = 0x26
	case right = 0x27
	case down = 0x28
}

/// The iPhone keyboard for the game. Every letter goes to the game as it's typed, so it works in
/// whatever text box has focus, password fields included. A bar above it adds Esc, Tab and the
/// arrow keys. A hardware keyboard types through it too while it's open.
struct StreamKeyboard: UIViewRepresentable {
	@Binding var isPresented: Bool
	let onText: (String) -> Void
	let onKey: (StreamKey) -> Void

	func makeUIView(context: Context) -> KeyboardInputView {
		KeyboardInputView()
	}

	func updateUIView(_ view: KeyboardInputView, context: Context) {
		view.onText = onText
		view.onKey = onKey
		view.onDismiss = { if isPresented { isPresented = false } }
		if isPresented, !view.isFirstResponder {
			// Needs to be in a window first
			DispatchQueue.main.async { if isPresented { _ = view.becomeFirstResponder() } }
		} else if !isPresented, view.isFirstResponder {
			_ = view.resignFirstResponder()
		}
	}
}

final class KeyboardInputView: UIView, UIKeyInput {
	var onText: ((String) -> Void)?
	var onKey: ((StreamKey) -> Void)?
	var onDismiss: (() -> Void)?

	// Plain typing: logins and names mustn't be corrected, capitalised or curled
	var autocapitalizationType: UITextAutocapitalizationType = .none
	var autocorrectionType: UITextAutocorrectionType = .no
	var spellCheckingType: UITextSpellCheckingType = .no
	var smartQuotesType: UITextSmartQuotesType = .no
	var smartDashesType: UITextSmartDashesType = .no
	var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
	var inlinePredictionType: UITextInlinePredictionType = .no
	var keyboardType: UIKeyboardType = .default
	var returnKeyType: UIReturnKeyType = .default
	var keyboardAppearance: UIKeyboardAppearance = .dark

	override var canBecomeFirstResponder: Bool { true }

	/// Always true, so backspace keeps working in the game's text box, which we can't see into
	var hasText: Bool { true }

	func insertText(_ text: String) {
		// Return arrives as a newline: send it as the Enter key, which games listen for
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
		for (index, line) in lines.enumerated() {
			if index > 0 { onKey?(.enter) }
			if !line.isEmpty { onText?(String(line)) }
		}
	}

	func deleteBackward() { onKey?(.backspace) }

	override func resignFirstResponder() -> Bool {
		let resigned = super.resignFirstResponder()
		if resigned { onDismiss?() }
		return resigned
	}

	private lazy var accessory: UIView = makeAccessory()
	override var inputAccessoryView: UIView? { accessory }

	private func makeAccessory() -> UIView {
		let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
		bar.allowsSelfSizing = true
		func button(_ title: String?, symbol: String?, label: String, action: @escaping () -> Void) -> UIButton {
			var config = UIButton.Configuration.gray()
			config.title = title
			if let symbol { config.image = UIImage(systemName: symbol) }
			config.baseForegroundColor = .label
			config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
			let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
			button.accessibilityLabel = label
			return button
		}
		let keys: [(String?, String?, String, StreamKey)] = [
			("Esc", nil, "Escape", .escape),
			("Tab", nil, "Tab", .tab),
			(nil, "arrow.left", "Left arrow", .left),
			(nil, "arrow.up", "Up arrow", .up),
			(nil, "arrow.down", "Down arrow", .down),
			(nil, "arrow.right", "Right arrow", .right),
		]
		var views: [UIView] = keys.map { title, symbol, label, key in
			button(title, symbol: symbol, label: label) { [weak self] in self?.onKey?(key) }
		}
		views.append(UIView())
		views.append(button(nil, symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in
			_ = self?.resignFirstResponder()
		})
		let stack = UIStackView(arrangedSubviews: views)
		stack.spacing = 8
		stack.alignment = .center
		stack.translatesAutoresizingMaskIntoConstraints = false
		bar.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 8),
			stack.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor, constant: -8),
			stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
			stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
			bar.heightAnchor.constraint(equalToConstant: 44),
		])
		return bar
	}
}
