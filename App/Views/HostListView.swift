import SwiftUI

/// Home: the PCs you've added and the ones answering on your network.
struct HostListView: View {
	@Environment(HostStore.self) private var store
	@State private var gamepad = ListGamepadNavigator()
	@State private var pairing: PCHost?
	@State private var playing: PCHost?
	@State private var hostSettings: PCHost?
	@State private var showingAdd = false
	@State private var showingSettings = false
	/// The row a controller has selected: a saved PC's id or a found PC's id
	@State private var selection: String?

	/// The controller only drives the list when nothing is covering it
	private var gamepadActive: Bool {
		playing == nil && pairing == nil && hostSettings == nil && !showingAdd && !showingSettings
	}

	/// Every row in the order shown
	private var rowIDs: [String] { store.hosts.map(\.id) + store.newHosts.map(\.id) }

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
				List {
					if store.hosts.isEmpty && store.newHosts.isEmpty {
						ContentUnavailableView {
							Label("Looking for PCs", systemImage: "desktopcomputer")
						} description: {
							Text("Have Steam running on your PC, on the same network, with Remote Play turned on in Steam's settings.\n\nPlay with a connected game controller or use the virtual controls.")
						} actions: {
							Button("Enter IP address") { showingAdd = true }
								.buttonStyle(.borderedProminent)
						}
					}
					if !store.hosts.isEmpty {
						Section {
							ForEach(store.hosts) { host in
								savedRow(host)
							}
						}
					}
					if !store.newHosts.isEmpty {
						Section("On your network") {
							ForEach(store.newHosts) { found in
								let selected = isSelected(found.id)
								HostRow(
									name: found.name, address: found.address,
									status: found.isBusy ? .busy : .online, paired: false,
									confirmSymbol: selected ? gamepad.confirmSymbol : nil
								) {
									pairing = PCHost(found)
								}
								.id(found.id)
								.listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
							}
						}
					}
				}
				.onChange(of: selection) { _, id in
					guard let id, gamepad.confirmSymbol != nil else { return }
					withAnimation { proxy.scrollTo(id) }
				}
			}
			.navigationTitle("iPlayPC")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { showingAdd = true } label: { Image(systemName: "plus") }
						.accessibilityLabel("Add a PC")
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button { showingSettings = true } label: { Image(systemName: "gearshape") }
						.accessibilityLabel("Settings")
				}
			}
			.safeAreaInset(edge: .bottom) {
				if !hints.isEmpty { GamepadHintBar(hints: hints) }
			}
			.sheet(isPresented: $showingSettings) {
				SettingsView()
			}
			.sheet(item: $hostSettings) { host in
				HostSettingsView(host: host)
			}
			.sheet(isPresented: $showingAdd) {
				AddHostView { host in
					showingAdd = false
					pairing = host
				}
			}
			.fullScreenCover(item: $pairing) { host in
				PairView(host: host)
			}
			.fullScreenCover(item: $playing) { host in
				StreamView(host: host)
			}
			// The sweep isn't needed while streaming; keep the network quiet
			.onChange(of: playing == nil) { _, idle in
				if idle { store.startDiscovery() } else { store.stopDiscovery() }
			}
		}
		.onAppear {
			store.startDiscovery()
			gamepad.onMove = { move in
				switch move {
				case .up: moveSelection(by: -1)
				case .down: moveSelection(by: 1)
				case .left, .right: break
				}
			}
			gamepad.onConfirm = { activateSelection() }
			gamepad.onTop = { openSelectedSettings() }
			gamepad.onMenu = { showingSettings = true }
			gamepad.start()
			gamepad.setActive(gamepadActive)
			ensureSelection()
			// Development: `-autoplay` streams from the first paired PC (devicectl launch)
			if ProcessInfo.processInfo.arguments.contains("-autoplay"), playing == nil {
				playing = store.hosts.first { $0.isPaired }
			}
		}
		.onDisappear { gamepad.stop() }
		.onChange(of: gamepadActive) { _, active in gamepad.setActive(active) }
		.onChange(of: rowIDs) { _, _ in ensureSelection() }
	}

	private func savedRow(_ host: PCHost) -> some View {
		let selected = isSelected(host.id)
		return HostRow(
			name: host.name, address: host.address, status: store.status(of: host), paired: host.isPaired,
			confirmSymbol: selected ? gamepad.confirmSymbol : nil
		) {
			open(host)
		}
		.id(host.id)
		.listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
		.swipeActions {
			Button("Settings") { hostSettings = host }
				.tint(.gray)
		}
		.contextMenu {
			Button { hostSettings = host } label: {
				Label("PC settings", systemImage: "slider.horizontal.3")
			}
		}
	}

	private func open(_ host: PCHost) {
		if host.isPaired { playing = host } else { pairing = host }
	}

	// MARK: - Controller navigation

	private func isSelected(_ id: String) -> Bool {
		gamepad.confirmSymbol != nil && selection == id
	}

	private var selectedHost: PCHost? {
		selection.flatMap { store.host(id: $0) }
	}

	private var hints: [GamepadHint] {
		guard let confirm = gamepad.confirmSymbol, !rowIDs.isEmpty else { return [] }
		var hints = [GamepadHint(symbol: "dpad", label: "Move")]
		let label: String
		if let host = selectedHost {
			label = host.isPaired ? "Play" : "Pair"
		} else {
			label = "Pair"
		}
		hints.append(GamepadHint(symbol: confirm, label: label))
		if selectedHost != nil, let top = gamepad.topSymbol {
			hints.append(GamepadHint(symbol: top, label: "PC settings"))
		}
		if let menu = gamepad.menuSymbol {
			hints.append(GamepadHint(symbol: menu, label: "Settings"))
		}
		return hints
	}

	private func ensureSelection() {
		let ids = rowIDs
		if selection == nil || !ids.contains(where: { $0 == selection }) {
			selection = ids.first
		}
	}

	private func moveSelection(by delta: Int) {
		let ids = rowIDs
		guard !ids.isEmpty else { return }
		guard let current = selection, let index = ids.firstIndex(of: current) else {
			selection = ids.first
			return
		}
		selection = ids[min(max(index + delta, 0), ids.count - 1)]
	}

	private func activateSelection() {
		guard let id = selection else { return }
		if let host = store.host(id: id) {
			open(host)
		} else if let found = store.newHosts.first(where: { $0.id == id }) {
			pairing = PCHost(found)
		}
	}

	private func openSelectedSettings() {
		if let host = selectedHost { hostSettings = host }
	}
}

private struct HostRow: View {
	let name: String
	let address: String
	let status: HostStatus
	let paired: Bool
	/// SF Symbol for the controller's confirm button when this row is selected
	let confirmSymbol: String?
	let action: () -> Void

	var body: some View {
		HStack(spacing: 14) {
			Image(systemName: "desktopcomputer")
				.font(.title)
				.frame(width: 44)
			VStack(alignment: .leading, spacing: 3) {
				Text(name.isEmpty ? "PC" : name).font(.headline)
				Text(address).font(.caption).foregroundStyle(.secondary)
				statusLabel
			}
			Spacer()
			if paired {
				Button(action: action) { buttonLabel("Play") }
					.buttonStyle(.borderedProminent)
			} else {
				Button(action: action) { buttonLabel("Pair") }
					.buttonStyle(.bordered)
			}
		}
		.padding(.vertical, 6)
		.contentShape(Rectangle())
		.onTapGesture(perform: action)
	}

	@ViewBuilder private func buttonLabel(_ title: String) -> some View {
		if let confirmSymbol {
			// Not a Label: inside a List row its icon takes the accent tint,
			// which vanishes against the prominent button's accent background.
			HStack(spacing: 6) {
				Image(systemName: confirmSymbol)
				Text(title)
			}
		} else {
			Text(title)
		}
	}

	@ViewBuilder private var statusLabel: some View {
		switch status {
		case .online:
			Label(paired ? "Ready" : "Not paired", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
		case .busy:
			Label("In use", systemImage: "circle.fill").font(.caption).foregroundStyle(.orange)
		case .offline:
			Label("Not found", systemImage: "circle").font(.caption).foregroundStyle(.secondary)
		}
	}
}
