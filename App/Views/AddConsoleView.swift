import SwiftUI

struct AddConsoleView: View {
	@Environment(ConsoleStore.self) private var store
	@Environment(\.dismiss) private var dismiss

	@AppStorage("lastPSNAccountID") private var accountID = ""
	@State private var discovery = LANDiscovery()
	@State private var selectedID: String?
	@State private var manualEntry = false
	@State private var manualHost = ""
	@State private var manualPS5 = true
	@State private var editingAccountID = false
	@State private var showingSignIn = false
	@State private var pin = ""
	@State private var registering = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				consoleSection
				accountSection

				Section {
					TextField("8-digit PIN", text: $pin)
						.keyboardType(.numberPad)
						.font(.body.monospaced())
				} header: {
					Text("Link code")
				} footer: {
					Text("On the PS5: Settings › System › Remote Play › Link Device.")
				}

				if let error {
					Section { Text(error).foregroundStyle(.red) }
				}
			}
			.navigationTitle("Add console")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					if registering {
						ProgressView()
					} else {
						Button("Link") { Task { await register() } }
							.disabled(!canSubmit)
					}
				}
			}
			.sheet(isPresented: $showingSignIn) {
				PSNSignInView { id in
					accountID = id
					editingAccountID = false
				}
			}
		}
		.onAppear { discovery.start() }
		.onDisappear { discovery.stop() }
		.onChange(of: discovery.consoles) { _, consoles in
			// Pick the only console automatically
			if selectedID == nil, !manualEntry, consoles.count == 1 { selectedID = consoles[0].id }
		}
	}

	// MARK: Console

	@ViewBuilder private var consoleSection: some View {
		Section {
			if !manualEntry {
				if discovery.consoles.isEmpty {
					HStack(spacing: 10) {
						ProgressView()
						Text("Looking for consoles…").foregroundStyle(.secondary)
					}
				}
				ForEach(discovery.consoles) { console in
					Button {
						selectedID = console.id
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(console.name.isEmpty ? "PlayStation" : console.name).foregroundStyle(.primary)
								Text("\(console.host) · \(stateText(console))").font(.caption).foregroundStyle(.secondary)
							}
							Spacer()
							if selectedID == console.id {
								Image(systemName: "checkmark").foregroundStyle(.tint)
							}
						}
					}
				}
			} else {
				TextField("IP address, e.g. 192.168.1.50", text: $manualHost)
					.keyboardType(.numbersAndPunctuation)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Toggle("PS5", isOn: $manualPS5)
			}
			Button(manualEntry ? "Search the network instead" : "Enter IP address manually") {
				manualEntry.toggle()
			}
			.font(.callout)
		} header: {
			Text("Console")
		} footer: {
			Text(manualEntry
				? "Find it on the PS5 under Settings › System › System Software › Console Information."
				: "The PS5 needs to be on, or in rest mode with Remote Play enabled, and on the same Wi-Fi.")
		}
	}

	private func stateText(_ console: DiscoveredConsole) -> String {
		switch console.state {
		case .ready: "On"
		case .standby: "Rest mode"
		case .unknown: "Unknown"
		}
	}

	private var selectedConsole: DiscoveredConsole? {
		discovery.consoles.first { $0.id == selectedID }
	}

	private var target: (host: String, ps5: Bool)? {
		if manualEntry {
			let host = manualHost.trimmingCharacters(in: .whitespaces)
			return host.isEmpty ? nil : (host, manualPS5)
		}
		return selectedConsole.map { ($0.host, $0.ps5) }
	}

	// MARK: Account

	@ViewBuilder private var accountSection: some View {
		Section {
			if accountID.isEmpty || editingAccountID {
				Button {
					showingSignIn = true
				} label: {
					Label("Sign in to PSN", systemImage: "person.crop.circle")
				}
				TextField("Or paste it, e.g. AbCdEfGhIjk=", text: $accountID)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.font(.body.monospaced())
			} else {
				HStack {
					Text(accountID).font(.body.monospaced())
					Spacer()
					Button("Change") { editingAccountID = true }.font(.callout)
				}
			}
		} header: {
			Text("PSN account")
		} footer: {
			Text("Signing in only looks up your account ID, which the PS5 needs to link. Your password and login aren't stored.")
		}
	}

	// MARK: Register

	private var canSubmit: Bool {
		target != nil && !accountID.isEmpty && pin.count == 8 && UInt32(pin) != nil
	}

	@MainActor
	private func register() async {
		guard let pinValue = UInt32(pin), let target else { return }
		registering = true
		error = nil
		do {
			let registered = try await Registrar.register(host: target.host, ps5: target.ps5, psnAccountIDBase64: accountID, pin: pinValue)
			store.add(registered.console(host: target.host))
			dismiss()
		} catch {
			self.error = error.localizedDescription
		}
		registering = false
	}
}
