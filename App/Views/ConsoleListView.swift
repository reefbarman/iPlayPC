import GameController
import SwiftUI

struct ConsoleListView: View {
	@Environment(ConsoleStore.self) private var store
	@Environment(SettingsStore.self) private var settings
	@State private var monitor = HostMonitor()
	@State private var discovery = LANDiscovery()
	@State private var gamepad = ListGamepadNavigator()
	@State private var showingAdd = false
	@State private var showingSettings = false
	@State private var playing: Console?
	/// Whether `playing` dials the console's remote address
	@State private var playingRemote = false
	@State private var consoleSettings: Console?
	@State private var waking: UUID?
	@State private var selection: UUID?

	/// The controller only drives the list when nothing is covering it
	private var gamepadActive: Bool {
		playing == nil && !showingAdd && !showingSettings && consoleSettings == nil
	}

	var body: some View {
		NavigationStack {
			ScrollViewReader { proxy in
			List {
				if store.consoles.isEmpty {
					ContentUnavailableView {
						Label("No consoles yet", systemImage: "playstation.logo")
					} description: {
						Text("Link your PS5 to start streaming. Have it on the same Wi-Fi, then open Settings › System › Remote Play › Link Device on the PS5 to get a PIN.\n\nPlay with a connected game controller or use the virtual controls.")
					} actions: {
						Button("Add console") { showingAdd = true }
							.buttonStyle(.borderedProminent)
					}
				}
				ForEach(store.consoles) { console in
					let selected = gamepad.confirmSymbol != nil && selection == console.id
					ConsoleRow(
						console: console,
						status: monitor.statuses[console.id],
						remote: monitor.usesRemote(console),
						waking: waking == console.id,
						confirmSymbol: selected ? gamepad.confirmSymbol : nil,
						play: { connect(console) },
						wake: { wake(console) }
					)
					.id(console.id)
					.listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
					.swipeActions {
						Button("Remove", role: .destructive) { store.remove(console) }
						Button("Settings") { consoleSettings = console }
							.tint(.gray)
					}
					.contextMenu {
						Button { consoleSettings = console } label: {
							Label("Console settings", systemImage: "slider.horizontal.3")
						}
					}
				}
			}
			.onChange(of: selection) { _, id in
				guard let id else { return }
				withAnimation { proxy.scrollTo(id) }
			}
			}
			.navigationTitle("iPlay5")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button { showingSettings = true } label: { Image(systemName: "gearshape") }
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button { showingAdd = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showingAdd, onDismiss: { if playing == nil { discovery.start() } }) {
				AddConsoleView()
					.onAppear { discovery.stop() } // the sheet runs its own sweep
			}
			.sheet(isPresented: $showingSettings) { SettingsView() }
			.sheet(item: $consoleSettings) { console in ConsoleSettingsView(consoleID: console.id) }
			.fullScreenCover(item: $playing) { console in
				StreamView(console: console, remote: playingRemote)
			}
		}
		.onAppear {
			monitor.sync(with: store.consoles)
			discovery.start()
			gamepad.onMove = { moveSelection(by: $0) }
			gamepad.onConfirm = { activateSelection() }
			gamepad.start()
			gamepad.setActive(gamepadActive)
			ensureSelection()
		}
		.onDisappear { gamepad.stop() }
		.onChange(of: gamepadActive) { _, active in gamepad.setActive(active) }
		.onChange(of: gamepad.confirmSymbol) { _, _ in ensureSelection() }
		.onChange(of: store.consoles) { _, consoles in
			monitor.sync(with: consoles)
			ensureSelection()
		}
		.onChange(of: playing) { _, playing in
			// Don't poll or sweep the network while streaming
			if playing == nil {
				monitor.sync(with: store.consoles)
				discovery.start()
			} else {
				monitor.stopAll()
				discovery.stop()
			}
		}
		.onChange(of: discovery.consoles) { _, found in
			// Follow a linked console to its new IP if DHCP moved it
			for console in store.consoles {
				if let match = found.first(where: { $0.id == console.hostID }), match.host != console.host {
					var updated = console
					updated.host = match.host
					store.update(updated)
				}
			}
		}
		.onChange(of: monitor.statuses) { _, statuses in
			// Auto-connect once a console we woke up reports ready
			if let id = waking, statuses[id]?.state == .ready, let console = store.consoles.first(where: { $0.id == id }) {
				waking = nil
				connect(console)
			}
		}
	}

	private func connect(_ console: Console) {
		playingRemote = monitor.usesRemote(console)
		playing = console
	}

	// MARK: - Controller navigation

	private func ensureSelection() {
		if selection == nil || !store.consoles.contains(where: { $0.id == selection }) {
			selection = store.consoles.first?.id
		}
	}

	private func moveSelection(by delta: Int) {
		let ids = store.consoles.map(\.id)
		guard !ids.isEmpty else { return }
		guard let current = selection, let index = ids.firstIndex(of: current) else {
			selection = ids.first
			return
		}
		selection = ids[min(max(index + delta, 0), ids.count - 1)]
	}

	/// Same rules as the row's buttons: wake from rest mode, otherwise play
	/// when the console is ready (or hasn't reported a status yet).
	private func activateSelection() {
		guard let id = selection, waking != id,
			  let console = store.consoles.first(where: { $0.id == id }) else { return }
		let status = monitor.statuses[id]
		if status?.state == .standby {
			wake(console)
		} else if status == nil || status?.state == .ready {
			connect(console)
		}
	}

	private func wake(_ console: Console) {
		if ConsoleWaker.wake(console.dialing(remote: monitor.usesRemote(console))) {
			waking = console.id
			// Give up auto-connecting after a while
			DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
				if waking == console.id { waking = nil }
			}
		}
	}
}

private struct ConsoleRow: View {
	let console: Console
	let status: HostStatus?
	/// Dialling the remote address because the console isn't on the local network
	let remote: Bool
	let waking: Bool
	/// SF Symbol for the controller's confirm button when this row is selected
	let confirmSymbol: String?
	let play: () -> Void
	let wake: () -> Void

	var body: some View {
		HStack(spacing: 14) {
			Image(systemName: "playstation.logo")
				.font(.title)
				.frame(width: 44)
			VStack(alignment: .leading, spacing: 3) {
				Text(console.name).font(.headline)
				if remote, let address = console.remoteAddress {
					Label(address, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
				} else {
					Text(console.host).font(.caption).foregroundStyle(.secondary)
				}
				statusLabel
			}
			Spacer()
			if waking {
				ProgressView()
			} else if status?.state == .standby {
				Button(action: wake) { buttonLabel("Wake") }.buttonStyle(.bordered)
			} else {
				Button(action: play) { buttonLabel("Play") }
					.buttonStyle(.borderedProminent)
					.disabled(status?.state != .ready && status != nil)
			}
		}
		.padding(.vertical, 6)
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
		switch status?.state {
		case .ready:
			Label(status?.runningApp.isEmpty == false ? status!.runningApp : "Ready", systemImage: "circle.fill")
				.font(.caption).foregroundStyle(.green)
		case .standby:
			Label("Rest mode", systemImage: "moon.fill").font(.caption).foregroundStyle(.orange)
		default:
			Label(waking ? "Waking…" : "Not found", systemImage: "circle").font(.caption).foregroundStyle(.secondary)
		}
	}
}

/// Lets a game controller drive app screens outside the stream: the d-pad or
/// left stick moves a selection, the bottom face button (✕ on PlayStation pads,
/// A on Xbox-style pads) confirms and the right one (○ / B) cancels. Used by
/// the console list and by the stream screen's connecting and error overlays.
///
/// Uses per-element handlers so it never touches the gamepad-wide
/// `valueChangedHandler` that `ControllerInput` owns while streaming, and
/// detaches entirely whenever its screen is covered or busy.
@Observable
final class ListGamepadNavigator {
	@ObservationIgnored var onMove: ((Int) -> Void)?
	@ObservationIgnored var onConfirm: (() -> Void)?
	@ObservationIgnored var onCancel: (() -> Void)?
	/// SF Symbol for the connected controller's confirm button, nil without a controller
	private(set) var confirmSymbol: String?
	/// SF Symbol for the connected controller's cancel button, nil without a controller
	private(set) var cancelSymbol: String?

	/// The navigator whose handlers are on the controller. Only one screen drives it
	/// at a time, and a screen going away mustn't clear handlers the next one set.
	private static weak var owner: ListGamepadNavigator?

	@ObservationIgnored private var controller: GCController?
	@ObservationIgnored private var observers: [NSObjectProtocol] = []
	@ObservationIgnored private var active = false
	@ObservationIgnored private var confirmArmed = false
	@ObservationIgnored private var cancelArmed = false
	@ObservationIgnored private var direction = 0
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
	}

	func setActive(_ active: Bool) {
		self.active = active
		refresh()
	}

	private func refresh() {
		let candidates = GCController.controllers().filter { $0.extendedGamepad != nil }
		let next = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		confirmSymbol = next.map(Self.confirmSymbol(for:))
		cancelSymbol = next.map(Self.cancelSymbol(for:))

		let wanted = active ? next : nil
		guard wanted !== controller || (wanted != nil && Self.owner !== self) else { return }
		detach()
		guard let wanted, let pad = wanted.extendedGamepad else { return }
		controller = wanted
		Self.owner = self
		pad.dpad.valueChangedHandler = { [weak self] _, _, _ in self?.updateDirection(pad) }
		pad.leftThumbstick.valueChangedHandler = { [weak self] _, _, _ in self?.updateDirection(pad) }
		pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
			guard let self else { return }
			// Fire on release so the press doesn't carry into the stream as Cross
			if pressed {
				self.confirmArmed = true
			} else if self.confirmArmed {
				self.confirmArmed = false
				self.onConfirm?()
			}
		}
		pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
			guard let self else { return }
			if pressed {
				self.cancelArmed = true
			} else if self.cancelArmed {
				self.cancelArmed = false
				self.onCancel?()
			}
		}
	}

	/// The controller's own symbol for its confirm button when the system can
	/// render it. Some controllers report names that aren't available as SF
	/// Symbols on the phone, which leaves an empty gap in the button.
	private static func confirmSymbol(for controller: GCController) -> String {
		if let name = controller.extendedGamepad?.buttonA.sfSymbolsName,
		   UIImage(systemName: name) != nil {
			return name
		}
		let pad = controller.extendedGamepad
		return pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? "xmark.circle" : "a.circle"
	}

	private static func cancelSymbol(for controller: GCController) -> String {
		if let name = controller.extendedGamepad?.buttonB.sfSymbolsName,
		   UIImage(systemName: name) != nil {
			return name
		}
		let pad = controller.extendedGamepad
		return pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? "circle.circle" : "b.circle"
	}

	private func detach() {
		if Self.owner === self, let pad = controller?.extendedGamepad {
			pad.dpad.valueChangedHandler = nil
			pad.leftThumbstick.valueChangedHandler = nil
			pad.buttonA.pressedChangedHandler = nil
			pad.buttonB.pressedChangedHandler = nil
			Self.owner = nil
		}
		controller = nil
		confirmArmed = false
		cancelArmed = false
		setDirection(0)
	}

	private func updateDirection(_ pad: GCExtendedGamepad) {
		let y = pad.leftThumbstick.yAxis.value
		if pad.dpad.up.isPressed || y > 0.6 {
			setDirection(-1)
		} else if pad.dpad.down.isPressed || y < -0.6 {
			setDirection(1)
		} else if abs(y) < 0.4 {
			setDirection(0)
		}
	}

	/// Moves once, then repeats while held
	private func setDirection(_ dir: Int) {
		guard dir != direction else { return }
		direction = dir
		repeatTimer?.invalidate()
		repeatTimer = nil
		guard dir != 0 else { return }
		onMove?(dir)
		repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
			self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
				guard let self, self.direction != 0 else { return }
				self.onMove?(self.direction)
			}
		}
	}
}
