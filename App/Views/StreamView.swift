import GameController
import SwiftUI

struct StreamView: View {
	let host: PCHost

	@Environment(SettingsStore.self) private var settingsStore
	@Environment(HostStore.self) private var hosts
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var scenePhase
	@State private var session: StreamSession?
	@State private var showMenu = false
	@State private var showMenuButton = false
	@State private var hideMenuButton: Task<Void, Never>?
	@State private var folded = false
	/// Unfolded but the window is portrait: we wait (or pause) and ask the user
	/// to turn the phone. Once a stream is landscape, AppDelegate locks it there.
	@State private var portrait = false
	@State private var windowSize: CGSize = .zero
	@State private var hasController = ControllerInput.hasSupportedController
	@State private var autoShowsControls = !ControllerInput.hasSupportedController
	@State private var showSettingsHint = false
	@State private var showGuideButton = false
	@State private var hideGuideButton: Task<Void, Never>?
	@State private var showFGButton = false
	@State private var hideFGButton: Task<Void, Never>?
	@State private var phone = PhoneStatus()
	@State private var showHeatWarning = false
	/// The corner hints show once per stream screen
	@State private var hintShown = false
	@State private var menuNavigation = SettingsNavigation()
	/// A controller quits with a second press of A
	@State private var quitArmed = false
	/// Same for closing the game
	@State private var quitGameArmed = false
	/// Quit game was pressed but Steam says no game is running
	@State private var noGameToQuit = false
	/// The iPhone keyboard is up, typing into the game
	@State private var showKeyboard = false

	/// The shared settings with this PC's own video settings on top
	private var settings: StreamSettings { settingsStore.settings.applying(hosts.host(id: host.id)?.settings.video) }

	private var wantsVirtualControls: Bool {
		switch settings.virtualControls {
		case .auto: !hasController && autoShowsControls
		case .always: true
		case .never: false
		}
	}

	private var acceptsScreenInput: Bool {
		guard let session else { return false }
		return session.state == .streaming && !folded && !portrait && scenePhase == .active && !showMenu
	}

	private var showsVirtualControls: Bool { acceptsScreenInput && wantsVirtualControls }

	var body: some View {
		GeometryReader { geo in
			content
				.onAppear { updateFolded(geo.size) }
				.onChange(of: geo.size) { _, size in updateFolded(size) }
		}
		.ignoresSafeArea(.keyboard)
		.statusBarHidden()
		.persistentSystemOverlays(.hidden)
		.defersSystemGestures(on: .all)
		// The session itself starts from updateFolded, once we know we're on a usable screen
		.onAppear {
			AppDelegate.setStreaming(true)
			refreshControllerPresence()
		}
		.onDisappear(perform: stop)
		.onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
			// A flip between the two landscapes keeps the same window size, so pick
			// up iOS's new orientation (for controller motion) once it has rotated
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { update() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshControllerPresence() }
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshControllerPresence() }
		.task(id: hasController) {
			guard !hasController, !autoShowsControls else { return }
			try? await Task.sleep(for: .seconds(1))
			guard !Task.isCancelled, !hasController else { return }
			autoShowsControls = true
		}
		.onChange(of: session?.state == .streaming) { _, streaming in
			guard streaming, !hintShown else { return }
			hintShown = true
			flashSettingsHint()
			revealFGButton()
		}
		.onChange(of: phone.isHot) { _, hot in
			if hot, settings.fps > 30 { flashHeatWarning() }
		}
		.onChange(of: settings) { _, new in session?.apply(new) }
		.onChange(of: session?.needsPairing == true) { _, needs in
			if needs { hosts.markUnpaired(host) }
		}
		.onChange(of: scenePhase) { _, phase in
			if phase == .active { refreshControllerPresence() } else { session?.setPaused(true) }
		}
		.sheet(isPresented: $showMenu) { menu }
		.onChange(of: acceptsScreenInput) { _, accepts in
			// Folding, backgrounding, the menu or the stream ending puts the keyboard away
			if !accepts { showKeyboard = false }
		}
		.onChange(of: showMenu) { _, open in
			session?.setInputHeld(open)
			if !open {
				menuNavigation.path.removeAll()
				quitArmed = false
				quitGameArmed = false
				noGameToQuit = false
			}
		}
	}

	private var content: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let session, let renderer = session.renderer {
				MetalStreamView(
					renderer: renderer,
					highRefresh: session.settings.highRefreshDisplay,
					acceptsInput: acceptsScreenInput,
					virtualControls: showsVirtualControls,
					controlsStyle: VirtualControlsStyle(settings),
					videoAspectForLetterbox: letterboxAspect(for: session),
					videoAspect: videoAspect(for: session),
					fillsView: session.settings.displayMode == .zoom,
					touchMouse: session.settings.touchMouse,
					onFrameGenerationTap: activateFrameGenerationShortcut,
					onVirtualPad: { [weak session] in session?.setVirtualPad($0) },
					onMouse: { [weak session] in session?.sendMouse($0) },
					onReset: { [weak session] in session?.resetScreenInput() },
					onCornerTap: revealMenuButton,
					onLeftCornerTap: revealGuideButton,
					onThreeFingerTap: { showKeyboard.toggle() }
				)
				.ignoresSafeArea()
			}


			if let session {
				overlay(for: session)
			}

			if showSettingsHint && !showMenuButton {
				settingsHint.transition(.opacity)
			}

			if showMenuButton {
				menuButton.transition(.opacity)
			}

			if showGuideButton && acceptsScreenInput {
				guideButton.transition(.opacity)
			}

			if let session {
				StreamKeyboard(isPresented: $showKeyboard,
					onText: { [weak session] in session?.typeText($0) },
					onKey: { [weak session] in session?.pressKey($0) })
					.frame(width: 1, height: 1)
					.allowsHitTesting(false)
			}

			if acceptsScreenInput {
				frameGenButton(compact: showsVirtualControls)
			}

			if let session, session.micActive {
				micButton(session)
			}

			if showHeatWarning {
				heatWarning.transition(.opacity)
			}

			if folded {
				pausedOverlay
			} else if portrait {
				rotateOverlay
			}
		}
	}

	// MARK: - Lifecycle

	private func refreshControllerPresence() {
		hasController = ControllerInput.hasSupportedController
		if hasController { autoShowsControls = false }
		update()
	}

	/// Used to map controller motion to the screen
	private var interfaceOrientation: UIInterfaceOrientation? {
		(UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
	}

	private func startSession() {
		let session = hosts.makeSession(for: host, settings: settings)
		if let orientation = interfaceOrientation {
			session.input.interfaceOrientation = orientation
		}
		session.input.onMenuCombo = { showMenu = true }
		// Steam asks for our keyboard when a text field on the PC is picked
		session.onShowKeyboard = { if acceptsScreenInput { showKeyboard = true } }
		self.session = session
		session.start()
	}

	private func stop() {
		session?.stop()
		session = nil
		AppDelegate.setStreaming(false)
	}

	/// On a foldable, streaming only happens on the inner screen: we wait for the
	/// unfold before connecting, and pause if it's folded mid-stream.
	/// iPhones play in landscape, while an iPad plays in any window shape.
	private func updateFolded(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		AppDelegate.windowSizeChanged(size)
		windowSize = size
		update()
	}

	private func update() {
		let size = windowSize
		guard size.width > 0, size.height > 0 else { return }
		let isFolded = DeviceLayout.isFolded(size)
		folded = isFolded
		portrait = !isFolded && !DeviceLayout.isPad && size.height > size.width
		let canPlay = !isFolded && !portrait
		guard session != nil else {
			if canPlay && scenePhase == .active { startSession() }
			return
		}
		session?.setPaused(!canPlay || scenePhase != .active)
		if let orientation = interfaceOrientation {
			session?.input.interfaceOrientation = orientation
		}
	}

	// MARK: - Hot corners

	private func revealMenuButton() {
		withAnimation(.easeOut(duration: 0.2)) { showMenuButton = true }
		hideMenuButton?.cancel()
		hideMenuButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showMenuButton = false }
		}
	}

	private func revealGuideButton() {
		withAnimation(.easeOut(duration: 0.2)) { showGuideButton = true }
		scheduleGuideButtonHide()
	}

	private func scheduleGuideButtonHide() {
		hideGuideButton?.cancel()
		hideGuideButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showGuideButton = false }
		}
	}

	/// The Xbox button, which opens the Steam overlay, and the keyboard
	private var guideButton: some View {
		HStack(spacing: 12) {
			Button {
				session?.pressGuideButton()
				scheduleGuideButtonHide()
			} label: {
				cornerIcon("xbox.logo")
			}
			.accessibilityLabel("Xbox button")
			Button {
				showKeyboard.toggle()
				scheduleGuideButtonHide()
			} label: {
				cornerIcon(showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
			}
			.accessibilityLabel(showKeyboard ? "Hide keyboard" : "Type with the keyboard")
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.padding(.top, 14)
		.padding(.leading, 20)
		.ignoresSafeArea()
	}

	private func cornerIcon(_ systemName: String) -> some View {
		Image(systemName: systemName)
			.font(.title2)
			.foregroundStyle(.white)
			.frame(width: 52, height: 52)
			.background(.black.opacity(0.55), in: Circle())
	}

	/// From the menu: wait for the sheet to go, or it takes the keyboard with it
	private func openKeyboardFromMenu() {
		showMenu = false
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(500))
			if acceptsScreenInput { showKeyboard = true }
		}
	}

	private var menuButton: some View {
		Button {
			hideMenuButton?.cancel()
			showMenuButton = false
			showMenu = true
		} label: {
			Image(systemName: "gearshape.fill")
				.font(.title2)
				.foregroundStyle(.white)
				.frame(width: 52, height: 52)
				.background(.black.opacity(0.55), in: Circle())
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
		.padding(.top, 14)
		.padding(.trailing, 20)
		.ignoresSafeArea()
	}

	/// Each time a stream starts, point at the hidden corners, then fade out
	private func flashSettingsHint() {
		withAnimation(.easeOut(duration: 0.3)) { showSettingsHint = true }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(4))
			withAnimation(.easeIn(duration: 0.8)) { showSettingsHint = false }
		}
	}

	private var settingsHint: some View {
		ViewThatFits(in: .horizontal) {
			settingsHintRow(guide: "Tap this corner for the Xbox button and keyboard", settings: "Tap this corner for settings")
			settingsHintRow(guide: "Xbox button, keyboard", settings: "Settings")
		}
		.foregroundStyle(.white)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.padding(.top, 14)
		.padding(.horizontal, 20)
		.ignoresSafeArea()
		.allowsHitTesting(false)
	}

	private func settingsHintRow(guide: String, settings: String) -> some View {
		HStack(alignment: .top) {
			if !showGuideButton {
				HStack(spacing: 10) {
					hintIcon("xbox.logo")
					Image(systemName: "arrow.left").font(.title3.weight(.bold))
					hintLabel(guide)
				}
			}
			Spacer(minLength: 16)
			HStack(spacing: 10) {
				hintLabel(settings)
				Image(systemName: "arrow.right").font(.title3.weight(.bold))
				hintIcon("gearshape.fill")
			}
		}
	}

	private func hintLabel(_ text: String) -> some View {
		Text(text)
			.font(.subheadline.weight(.semibold))
			.padding(.horizontal, 14)
			.padding(.vertical, 8)
			.background(.black.opacity(0.65), in: Capsule())
	}

	private func hintIcon(_ systemName: String) -> some View {
		Image(systemName: systemName)
			.font(.title2)
			.frame(width: 52, height: 52)
			.background(.black.opacity(0.55), in: Circle())
	}

	// MARK: - Frame generation toggle (bottom right)

	private func revealFGButton() {
		withAnimation(.easeOut(duration: 0.2)) { showFGButton = true }
		hideFGButton?.cancel()
		hideFGButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showFGButton = false }
		}
	}

	private func activateFrameGenerationShortcut() {
		// The stream picks the change up from onChange(of: settings)
		if showFGButton { settingsStore.settings.frameGeneration.toggle() }
		revealFGButton()
	}

	private func letterboxAspect(for session: StreamSession) -> CGFloat? {
		guard session.settings.displayMode == .fit else { return nil }
		return videoAspect(for: session)
	}

	private func videoAspect(for session: StreamSession) -> CGFloat {
		let stats = session.stats
		if stats.width > 0, stats.height > 0 { return CGFloat(stats.width) / CGFloat(stats.height) }
		return 16.0 / 9.0
	}

	private func frameGenButton(compact: Bool) -> some View {
		let on = settings.frameGeneration
		let (text, colour): (String, Color) = on ? ("FG on", .green.opacity(0.85)) : ("FG off", .black.opacity(0.45))
		return Button(action: activateFrameGenerationShortcut) {
			Text(text)
				.font(.caption.weight(.bold))
				.foregroundStyle(.white)
				.padding(.horizontal, 10)
				.frame(minWidth: 52, minHeight: 30)
				.background(colour, in: Capsule())
				.fixedSize()
				.opacity(showFGButton ? 1 : 0)
				.padding(.bottom, 12)
				.padding(.trailing, 16)
				.frame(width: compact ? 84 : StreamMetalView.frameGenerationCornerSize.width,
					height: compact ? 54 : StreamMetalView.frameGenerationCornerSize.height, alignment: .bottomTrailing)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Frame generation \(on ? "on" : "off"). Tap to turn it \(on ? "off" : "on").")
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.ignoresSafeArea()
	}

	// MARK: - Microphone (bottom left)

	/// Mutes and unmutes the mic
	private func micButton(_ session: StreamSession) -> some View {
		Button {
			session.toggleMicMuted()
		} label: {
			Image(systemName: session.micMuted ? "mic.slash.fill" : "mic.fill")
				.font(.title3)
				.foregroundStyle(session.micMuted ? .red : .white)
				.frame(width: 24, height: 24)
				.padding(.horizontal, 10)
				.padding(.vertical, 6)
				.background(.black.opacity(0.45), in: Capsule())
				.opacity(session.micMuted ? 1 : 0.6)
				.padding(.bottom, 12)
				.padding(.leading, 16)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(session.micMuted ? "Unmute microphone" : "Mute microphone")
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
		.ignoresSafeArea()
	}

	// MARK: - Heat warning

	private func flashHeatWarning() {
		withAnimation(.easeOut(duration: 0.3)) { showHeatWarning = true }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(8))
			withAnimation(.easeIn(duration: 0.8)) { showHeatWarning = false }
		}
	}

	private var heatWarning: some View {
		HStack(spacing: 8) {
			Image(systemName: "thermometer.high")
			Text("Your \(DeviceLayout.deviceNoun) is getting hot. 30 fps in settings will help it cool down.")
		}
		.font(.subheadline.weight(.semibold))
		.foregroundStyle(.white)
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(.black.opacity(0.7), in: Capsule())
		.padding(.horizontal, 20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
		.padding(.bottom, 16)
		.allowsHitTesting(false)
	}

	// MARK: - Overlays

	@ViewBuilder
	private func overlay(for session: StreamSession) -> some View {
		switch session.state {
		case .connecting:
			statusCard {
				ProgressView().controlSize(.large)
				Text("Connecting to \(host.name)…").font(.headline)
				Button("Cancel") { dismiss() }.buttonStyle(.bordered)
			}
		case .streaming:
			if session.noPicture {
				statusCard {
					Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.secondary)
					Text("No picture from \(host.name) yet").font(.headline)
					Text("If it's a Mac, Steam needs permission to record the screen. Look for a prompt on the Mac (it can hide behind Steam), or allow Steam in System Settings › Privacy & Security › Screen & System Audio Recording.")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.frame(maxWidth: 420)
					Button("Quit") { dismiss() }.buttonStyle(.bordered)
				}
				.transition(.opacity)
			} else if session.settings.statsMode != .off && !(showSettingsHint && !showMenuButton) {
				StatsOverlay(stats: session.stats, settings: session.settings, videoAspect: letterboxAspect(for: session))
					.allowsHitTesting(false)
					.transition(.opacity)
			}
		case .ended(let error):
			statusCard {
				if let error {
					Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
					Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
				} else {
					Text("Stream ended").font(.headline)
				}
				HStack {
					Button("Close") { dismiss() }.buttonStyle(.bordered)
					if !session.needsPairing {
						Button("Play again") { session.playAgain() }.buttonStyle(.borderedProminent)
					}
				}
			}
		}
	}

	private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		VStack(spacing: 12, content: content)
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
	}

	private var rotateOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rotate.right").font(.largeTitle)
				Text("Turn your phone sideways").font(.title2.bold())
				Text("Turn to landscape to play.").foregroundStyle(.secondary)
				Button(session == nil ? "Cancel" : "Quit", action: quit).buttonStyle(.bordered).padding(.top, 8)
			}
		}
	}

	private var pausedOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rectangle.portrait.and.arrow.forward").font(.largeTitle)
				if session == nil {
					Text("Open your phone to play").font(.title2.bold())
					Text("\(host.name) connects as soon as you unfold.").foregroundStyle(.secondary)
					Button("Cancel") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
				} else {
					Text("Paused").font(.title2.bold())
					Text("Unfold to keep playing.").foregroundStyle(.secondary)
					Button("Quit", action: quit).buttonStyle(.bordered).padding(.top, 8)
				}
			}
		}
	}

	private var menuSettings: Binding<StreamSettings> {
		Binding(get: { settingsStore.settings }, set: { settingsStore.settings = $0 })
	}

	/// Leaving mid-stream closes the game on the PC too
	private func quit() {
		showMenu = false
		session?.stop(quittingGame: true)
		dismiss()
	}

	/// Closes the game and keeps streaming, back to Big Picture
	private func quitGame() {
		quitGameArmed = false
		if session?.quitGame() == true {
			showMenu = false
		} else {
			noGameToQuit = true
		}
	}

	private var quitGameLabel: String {
		if noGameToQuit { return "No game running" }
		return quitGameArmed ? "Press again to quit the game" : "Quit game"
	}

	private var menuRows: [GamepadRow] {
		let mic: [GamepadRow] = session?.micActive == true
			? [GamepadRow(id: "mic", confirmLabel: session?.micMuted == true ? "Unmute" : "Mute",
				activate: { session?.toggleMicMuted() })]
			: []
		return [
			GamepadRow(id: "resume", confirmLabel: "Resume", activate: { showMenu = false }),
			GamepadRow(id: "keyboard", confirmLabel: "Open", activate: openKeyboardFromMenu),
		] + mic + [
			GamepadRow(id: "quitGame", confirmLabel: quitGameArmed ? "Confirm" : "Quit game", activate: {
				if quitGameArmed { quitGame() } else { quitGameArmed = true }
			}),
			GamepadRow(id: "quit", confirmLabel: quitArmed ? "Confirm quit" : "Quit", activate: {
				if quitArmed { quit() } else { quitArmed = true }
			}),
		] + StreamSettingsForm.gamepadRows(menuSettings, showsVideo: false) { menuNavigation.open($0) }
	}

	private var menu: some View {
		@Bindable var menuNavigation = menuNavigation
		return NavigationStack(path: $menuNavigation.path) {
			Form {
				Section {
					Button("Resume") { showMenu = false }
						.gamepadRow("resume")
					Button("Type with the keyboard", action: openKeyboardFromMenu)
						.gamepadRow("keyboard")
					if let session, session.micActive {
						Button(session.micMuted ? "Unmute microphone" : "Mute microphone") {
							session.toggleMicMuted()
						}
						.gamepadRow("mic")
					}
					Button(quitGameLabel, role: .destructive, action: quitGame)
						.gamepadRow("quitGame")
						.disabled(noGameToQuit)
					Button(quitArmed ? "Press again to quit" : "Quit", role: .destructive, action: quit)
						.gamepadRow("quit")
				} footer: {
					Text("Quit game closes the game and takes you back to Big Picture. Quit ends the stream and closes the game too.")
				}
				Section {
					LabeledContent {
						Text(phone.batteryText)
					} label: {
						Label("Battery", systemImage: phone.batterySymbol)
					}
					LabeledContent {
						Text(phone.thermalText).foregroundStyle(phone.isHot ? .orange : .secondary)
					} label: {
						Label("Temperature", systemImage: "thermometer.medium")
					}
				} header: {
					Text(DeviceLayout.isPad ? "iPad" : "Phone")
				}
				// Resolution, frame rate, bitrate, codec and HDR are fixed once the stream starts
				if let session {
					VideoSettingsSummary(settings: session.streamSettings, stats: session.stats,
						customHostName: hosts.host(id: host.id)?.settings.video != nil ? host.name : nil)
				}
				StreamSettingsForm(settings: menuSettings, showsVideo: false)
			}
			.navigationTitle(host.name)
			.navigationBarTitleDisplayMode(.inline)
			.settingsPages(menuSettings, navigation: menuNavigation)
			.gamepadForm(menuRows, backLabel: "Resume", active: menuNavigation.path.isEmpty) { showMenu = false }
			.task(id: quitArmed) {
				guard quitArmed else { return }
				try? await Task.sleep(for: .seconds(3))
				quitArmed = false
			}
			.task(id: quitGameArmed || noGameToQuit) {
				guard quitGameArmed || noGameToQuit else { return }
				try? await Task.sleep(for: .seconds(3))
				quitGameArmed = false
				noGameToQuit = false
			}
		}
		// The Controller Test (on the Controller page) borrows the stream's controller while it's open
		.environment(\.lendController, { [weak session] lend in session?.lendController(lend) })
	}
}

/// Stats, centred along the top. With a letterboxed picture they sit in the black bar
/// above it and spread across it; otherwise they float over the top of the picture.
private struct StatsOverlay: View {
	let stats: StreamStats
	let settings: StreamSettings
	/// The picture's aspect ratio when it's fitted (letterboxed), nil when it fills the screen
	let videoAspect: CGFloat?

	/// Keeps clear of the Xbox button and settings hot corners
	private static let cornerReserve: CGFloat = 84
	/// Below this there's no usable bar, so float over the picture instead
	private static let minBarHeight: CGFloat = 28

	private struct Item: Identifiable {
		let label: String
		let value: String
		var warn = false
		var id: String { label }
	}

	var body: some View {
		GeometryReader { geo in
			let bar = barHeight(in: geo.size)
			let inBar = bar >= Self.minBarHeight
			content(roomy: inBar && bar >= 44)
				.padding(.horizontal, inBar ? 0 : 10)
				.padding(.vertical, inBar ? 4 : 6)
				.background(.black.opacity(inBar ? 0 : 0.55), in: RoundedRectangle(cornerRadius: 8))
				.frame(maxWidth: max(0, geo.size.width - Self.cornerReserve * 2))
				.frame(minHeight: inBar ? bar : nil)
				.padding(.top, inBar ? 0 : 12)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		}
		.ignoresSafeArea()
		.foregroundStyle(.white)
	}

	private func barHeight(in size: CGSize) -> CGFloat {
		guard let videoAspect, size.width > 0 else { return 0 }
		return max(0, (size.height - size.width / videoAspect) / 2)
	}

	@ViewBuilder
	private func content(roomy: Bool) -> some View {
		switch settings.statsMode {
		case .off:
			EmptyView()
		case .simple:
			HStack(spacing: roomy ? 20 : 14) {
				ForEach(simpleItems) { cell($0, valueFirst: true) }
			}
			.font((roomy ? Font.footnote : .caption2).monospaced())
		case .advanced:
			StatsFlow(spacing: 10, lineSpacing: 2) {
				ForEach(advancedItems) { cell($0) }
			}
			.font(.caption2.monospaced())
		}
	}

	private func cell(_ item: Item, valueFirst: Bool = false) -> some View {
		let label = Text(item.label).foregroundStyle(.white.opacity(0.55))
		let value = Text(item.value).foregroundStyle(item.warn ? .orange : .white)
		return HStack(spacing: 4) {
			if valueFirst {
				value
				if !item.label.isEmpty { label }
			} else {
				label
				value
			}
		}
		.lineLimit(1)
		.minimumScaleFactor(0.7)
	}

	private var codec: String { "\(settings.effectiveCodec == .h265 ? "HEVC" : "H.264")\(settings.hdr ? " HDR" : "")" }

	private var simpleItems: [Item] {
		var items = [
			Item(label: "", value: stats.height > 0 ? "\(stats.height)p" : "–"),
			Item(label: "fps", value: "\(Int(stats.fps.rounded()))"),
			Item(label: "Mbps", value: String(format: "%.1f", stats.bitrateMbps)),
		]
		if settings.frameGeneration {
			items.append(Item(label: "FG", value: stats.frameGenActive ? "+\(stats.generatedFPS)" : "off", warn: !stats.frameGenActive))
		}
		return items
	}

	private var advancedItems: [Item] {
		let hz = stats.displayHz > 0 ? " @\(Int(stats.displayHz))Hz" : ""
		var items = [
			Item(label: "", value: "\(stats.width)×\(stats.height) \(codec)"),
			Item(label: "fps", value: "\(Int(stats.fps.rounded()))\(hz)"),
			Item(label: "Mbps", value: settings.bitrateMbps == StreamSettings.automaticBitrate
				? String(format: "%.1f", stats.bitrateMbps)
				: String(format: "%.1f/%d", stats.bitrateMbps, settings.bitrateMbps)),
			Item(label: "dec", value: String(format: "%.1fms", stats.decodeMs)),
		]
		if settings.frameGeneration {
			if stats.frameGenActive {
				var fg = String(format: "+%d %.1fms", stats.generatedFPS, stats.generateMs)
				if let status = stats.frameGenStatus, !status.isEmpty { fg += " \(status)" }
				items.append(Item(label: "FG", value: fg))
				items.append(Item(label: "skip/rep", value: "\(stats.skippedFrames)/\(stats.repeatedFrames)"))
			} else {
				items.append(Item(label: "FG", value: "off (\(stats.frameGenOffReason ?? "measuring"))", warn: true))
			}
		}
		if let controller = stats.controller {
			let short = controller
				.replacingOccurrences(of: " Wireless Controller", with: "")
				.replacingOccurrences(of: " Controller", with: "")
			items.append(Item(label: "pad", value: short))
		}
		return items
	}
}

/// Lays cells out left to right in centred rows, each cell only taking the
/// width it needs. Uses as few rows as fit, then narrows them until they're
/// about even, rather than one full row and a short leftover.
private struct StatsFlow: Layout {
	var spacing: CGFloat
	var lineSpacing: CGFloat

	private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
		let maxWidth = width.isFinite ? width : .greatestFiniteMagnitude
		let count = greedyRows(subviews, width: maxWidth).count
		guard count > 1 else { return greedyRows(subviews, width: maxWidth) }
		// The narrowest width that still needs no more rows
		var low = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
		var high = min(maxWidth, rowWidth(greedyRows(subviews, width: .greatestFiniteMagnitude)[0]))
		while high - low > 1 {
			let mid = (low + high) / 2
			if greedyRows(subviews, width: mid).count <= count { high = mid } else { low = mid }
		}
		return greedyRows(subviews, width: high)
	}

	private func greedyRows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
		var rows: [[(index: Int, size: CGSize)]] = [[]]
		var x: CGFloat = 0
		for (index, view) in subviews.enumerated() {
			let size = view.sizeThatFits(.unspecified)
			if x > 0, x + spacing + size.width > width {
				rows.append([])
				x = 0
			}
			x += (x > 0 ? spacing : 0) + size.width
			rows[rows.count - 1].append((index, size))
		}
		return rows
	}

	private func rowWidth(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
		row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1))
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let rows = rows(subviews, width: proposal.width ?? .infinity)
		let width = rows.map(rowWidth).max() ?? 0
		let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) }
			+ lineSpacing * CGFloat(max(0, rows.count - 1))
		return CGSize(width: width, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var y = bounds.minY
		for row in rows(subviews, width: bounds.width) {
			var x = bounds.minX + (bounds.width - rowWidth(row)) / 2
			let height = row.map(\.size.height).max() ?? 0
			for cell in row {
				subviews[cell.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(cell.size))
				x += cell.size.width + spacing
			}
			y += height + lineSpacing
		}
	}
}

/// Hosts the CAMetalLayer-backed view in SwiftUI.
private struct MetalStreamView: UIViewRepresentable {
	let renderer: MetalRenderer
	let highRefresh: Bool
	let acceptsInput: Bool
	let virtualControls: Bool
	let controlsStyle: VirtualControlsStyle
	let videoAspectForLetterbox: CGFloat?
	let videoAspect: CGFloat
	let fillsView: Bool
	let touchMouse: Bool
	let onFrameGenerationTap: () -> Void
	let onVirtualPad: (VirtualPadState) -> Void
	let onMouse: (TouchMouse.Event) -> Void
	let onReset: () -> Void
	let onCornerTap: () -> Void
	let onLeftCornerTap: () -> Void
	let onThreeFingerTap: () -> Void

	func makeUIView(context: Context) -> StreamMetalView {
		let view = StreamMetalView(renderer: renderer)
		updateUIView(view, context: context)
		return view
	}

	func updateUIView(_ uiView: StreamMetalView, context: Context) {
		uiView.highRefresh = highRefresh
		uiView.onCornerTap = onCornerTap
		uiView.onLeftCornerTap = onLeftCornerTap
		uiView.onThreeFingerTap = onThreeFingerTap
		uiView.videoAspectForLetterbox = videoAspectForLetterbox
		uiView.onFrameGenerationTap = onFrameGenerationTap
		uiView.onVirtualPad = onVirtualPad
		uiView.onMouse = onMouse
		uiView.videoAspect = videoAspect
		uiView.fillsView = fillsView
		uiView.onReset = onReset
		uiView.setControlsStyle(controlsStyle)
		uiView.setInputMode(acceptsInput: acceptsInput, virtualControls: virtualControls, touchMouse: touchMouse)
	}
}
