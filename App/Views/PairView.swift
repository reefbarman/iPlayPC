import SwiftUI

/// Full-screen pairing: shows the PIN to type into Steam on the PC.
struct PairView: View {
	let host: PCHost
	@Environment(HostStore.self) private var store
	@Environment(\.dismiss) private var dismiss
	@State private var pin: String?
	@State private var error: String?
	@State private var attempt = 0
	@State private var gamepad = ListGamepadNavigator()

	private var hints: [GamepadHint] {
		guard let confirm = gamepad.confirmSymbol, let cancel = gamepad.cancelSymbol else { return [] }
		var hints: [GamepadHint] = []
		if error != nil { hints.append(GamepadHint(symbol: confirm, label: "Try again")) }
		hints.append(GamepadHint(symbol: cancel, label: "Cancel"))
		return hints
	}

	private func retry() {
		error = nil
		attempt += 1
	}

	var body: some View {
		VStack(spacing: 28) {
			Spacer()
			Image(systemName: "desktopcomputer")
				.font(.system(size: 52))
				.foregroundStyle(.secondary)
			Text(host.name.isEmpty ? "PC" : host.name)
				.font(.title2.weight(.semibold))
			if let error {
				Text(error)
					.multilineTextAlignment(.center)
					.foregroundStyle(.secondary)
				Button("Try again", action: retry)
					.buttonStyle(.borderedProminent)
			} else if let pin {
				Text("Enter this PIN in Steam on your PC")
					.foregroundStyle(.secondary)
				Text(pin)
					.font(.system(size: 64, weight: .semibold, design: .monospaced))
					.kerning(12)
			} else {
				ProgressView()
			}
			Spacer()
			Button("Cancel") { dismiss() }
				.padding(.bottom, hints.isEmpty ? 24 : 8)
			if !hints.isEmpty {
				GamepadHintBar(hints: hints)
					.padding(.bottom, 16)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color.black)
		.task(id: attempt) { await pair() }
		.onAppear {
			gamepad.onCancel = { dismiss() }
			gamepad.onConfirm = { if error != nil { retry() } }
			gamepad.start()
			gamepad.setActive(true)
		}
		.onDisappear { gamepad.stop() }
	}

	@MainActor
	private func pair() async {
		pin = nil
		do {
			try await store.pair(host) { step in
				if case let .showPIN(value) = step { pin = value }
			}
			dismiss()
		} catch is CancellationError {
			// Cancel was tapped
		} catch {
			self.error = error.localizedDescription
		}
	}
}
