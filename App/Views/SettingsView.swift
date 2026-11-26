import AVFoundation
import CoreHaptics
import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings
	/// Off in the stream menu: the video settings are fixed for a stream
	var showsVideo = true

	var body: some View {
		if showsVideo {
			VideoSettingsSection(settings: $settings)
		}

		Section {
			SettingsLink(title: "Display", systemImage: "tv", summary: settings.displaySummary, page: .display)
			SettingsLink(title: "Controller", systemImage: "gamecontroller", summary: settings.controllerSummary,
				page: .controller)
			SettingsLink(title: "Virtual controls", systemImage: "hand.tap", summary: settings.virtualControlsSummary,
				page: .virtualControls)
			SettingsLink(title: "Audio", systemImage: "mic", summary: settings.microphone ? "Microphone on" : "Microphone off",
				page: .audio)
		}
	}

	/// The rows above, for a controller. `bitrateMemory` adds Auto bitrate's rows to the video ones.
	static func gamepadRows(_ settings: Binding<StreamSettings>, showsVideo: Bool = true,
		bitrateMemory: BitrateMemory? = nil, open: @escaping (SettingsPage) -> Void) -> [GamepadRow] {
		(showsVideo ? VideoSettingsSection.gamepadRows(settings, bitrateMemory: bitrateMemory) : [])
			+ [SettingsPage.display, .controller, .virtualControls, .audio].map { page in
				GamepadRow.link(page.rowID) { open(page) }
			}
	}
}

/// A settings page under the main list. Pushed by value, so a controller can open one too.
enum SettingsPage: Hashable {
	case display, controller, gyroAim, virtualControls, audio

	var rowID: String { "page.\(self)" }
}

/// The settings pages open in a navigation stack, so a controller can open and leave them
@Observable
final class SettingsNavigation {
	var path: [SettingsPage] = []

	func open(_ page: SettingsPage) { path.append(page) }
}

extension View {
	/// Where `SettingsPage` links go. Put on the root of a `NavigationStack(path:)` bound to
	/// `navigation.path` that shows `StreamSettingsForm`.
	func settingsPages(_ settings: Binding<StreamSettings>, navigation: SettingsNavigation) -> some View {
		navigationDestination(for: SettingsPage.self) { page in
			Group {
				switch page {
				case .display: DisplaySettingsPage(settings: settings)
				case .controller: ControllerSettingsPage(settings: settings)
				case .gyroAim: GyroAimSettingsPage(settings: settings)
				case .virtualControls: VirtualControlsSettingsPage(settings: settings)
				case .audio: AudioSettingsPage(settings: settings)
				}
			}
			.environment(navigation)
		}
	}
}

/// One-line summaries of each settings page, shown under its row
private extension StreamSettings {
	static func summary(_ parts: [String?]) -> String {
		parts.compactMap { $0 }.joined(separator: " · ")
	}

	var displaySummary: String {
		let upscaling = upscaling.usesMetalFX && !MetalRenderer.supportsMetalFX ? UpscalingMode.sharp : upscaling
		let hasHighRefresh = UIScreen.main.maximumFramesPerSecond > 60
		return Self.summary([
			displayMode.label,
			upscaling.label,
			hasHighRefresh ? (highRefreshDisplay ? "120 Hz" : "60 Hz") : nil,
			frameGeneration ? "Frame gen" : nil,
			statsMode == .off ? nil : "\(statsMode.label) stats",
		])
	}

	var controllerSummary: String {
		let gyro: String? = switch gyroAim {
		case .off: nil
		case .always: "Gyro aim always"
		case .holdingLT: "Gyro aim on \(ControllerStyle.current.lt)"
		case .holdingRB: "Gyro aim on \(ControllerStyle.current.rb)"
		}
		return Self.summary([rumble ? "Rumble on" : "Rumble off", gyro])
	}

	var virtualControlsSummary: String {
		let mouse: String? = touchMouse ? "Touch mouse" : nil
		guard virtualControls != .never else { return Self.summary([virtualControls.label, mouse]) }
		return Self.summary([
			virtualControls.label,
			mouse,
			controlsSize.label,
			"\(Int((controlsOpacity * 100).rounded()))%",
			fixedSticks ? "Fixed sticks" : nil,
		])
	}
}

/// A row that opens a settings page. `value` sits on the right, `summary` under the title.
private struct SettingsLink: View {
	let title: String
	let systemImage: String
	var value: String?
	var summary: String?
	let page: SettingsPage

	var body: some View {
		NavigationLink(value: page) {
			LabeledContent {
				if let value { Text(value) }
			} label: {
				Label {
					Text(title)
					if let summary {
						Text(summary)
					}
				} icon: {
					Image(systemName: systemImage)
				}
			}
		}
		.gamepadRow(page.rowID)
	}
}

/// A slider with its title and current value above it
private struct LabeledSlider: View {
	let title: String
	@Binding var value: Double
	let range: ClosedRange<Double>
	let step: Double
	let valueText: String

	var body: some View {
		VStack(alignment: .leading) {
			HStack {
				Text(title)
				Spacer()
				Text(valueText).foregroundStyle(.secondary).monospacedDigit()
			}
			Slider(value: $value, in: range, step: step)
		}
	}
}

private extension View {
	func settingsPage(_ title: String) -> some View {
		navigationTitle(title).navigationBarTitleDisplayMode(.inline)
	}
}

/// A pushed settings page driven by a controller while it's on top, with B going back
private struct GamepadSettingsPage: ViewModifier {
	let page: SettingsPage
	let rows: [GamepadRow]
	/// Something full screen covers the page
	var covered = false
	@Environment(SettingsNavigation.self) private var navigation

	func body(content: Content) -> some View {
		content.gamepadForm(rows, active: navigation.path.last == page && !covered) {
			if navigation.path.last == page { navigation.path.removeLast() }
		}
	}
}

private extension View {
	func gamepadPage(_ page: SettingsPage, _ rows: [GamepadRow], covered: Bool = false) -> some View {
		modifier(GamepadSettingsPage(page: page, rows: rows, covered: covered))
	}
}

private func multiplier(_ value: Double) -> String {
	"\(value.formatted(.number.precision(.fractionLength(0...2))))×"
}

/// Picture fit, upscaling, refresh rate, frame generation and stats
private struct DisplaySettingsPage: View {
	@Binding var settings: StreamSettings

	private var upscalingSelection: Binding<UpscalingMode> {
		Binding(
			get: { settings.upscaling.usesMetalFX && !MetalRenderer.supportsMetalFX ? .sharp : settings.upscaling },
			set: { settings.upscaling = $0 })
	}

	private var upscalingOptions: [UpscalingMode] {
		UpscalingMode.allCases.filter { !$0.usesMetalFX || MetalRenderer.supportsMetalFX }
	}

	private var rows: [GamepadRow] {
		var rows = [
			GamepadRow.picker("picture", $settings.displayMode, DisplayMode.allCases),
			.picker("upscaling", upscalingSelection, upscalingOptions),
		]
		if UIScreen.main.maximumFramesPerSecond > 60 { rows.append(.toggle("120hz", $settings.highRefreshDisplay)) }
		rows.append(.toggle("framegen", $settings.frameGeneration))
		rows.append(.picker("stats", $settings.statsMode, StatsMode.allCases))
		return rows
	}

	var body: some View {
		Form {
			Section {
				Picker("Picture", selection: $settings.displayMode) {
					ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
				}
				.gamepadRow("picture")
			} footer: {
				Text("Fit shows the whole picture, with black bars where the screen is a different shape to 16:9. Zoom fills the screen and crops the overflow.")
			}

			Section {
				Picker("Upscaling", selection: upscalingSelection) {
					ForEach(upscalingOptions) { Text($0.label).tag($0) }
				}
				.gamepadRow("upscaling")
			} footer: {
				if MetalRenderer.supportsMetalFX {
					Text("MetalFX Spatial enlarges the picture to the screen's resolution. MetalFX 4K enlarges it to 3840×2160 and then scales it down to the screen, which can look smoother but uses more GPU and battery.")
				}
			}

			Section {
				if UIScreen.main.maximumFramesPerSecond > 60 {
					Toggle("120 Hz screen", isOn: $settings.highRefreshDisplay)
						.gamepadRow("120hz")
				}
				Toggle("Frame generation (experimental)", isOn: $settings.frameGeneration)
					.gamepadRow("framegen")
			} header: {
				Text("Smoothness")
			} footer: {
				if UIScreen.main.maximumFramesPerSecond > 60 {
					Text("120 Hz screen gets each frame on screen sooner, for a little more battery.")
				}
				Text("Frame generation makes an extra frame between each pair the stream sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. 60 fps needs the 120 Hz screen. The FG button in the bottom-right corner of the stream turns it on and off.")
			}

			Section {
				Picker("Stats", selection: $settings.statsMode) {
					ForEach(StatsMode.allCases) { Text($0.label).tag($0) }
				}
				.gamepadRow("stats")
			} footer: {
				Text("Stats sit in the black bar above the picture. Simple shows the essentials, Advanced shows everything.")
			}
		}
		.settingsPage("Display")
		.gamepadPage(.display, rows)
	}
}

/// Vibration, gyro aiming and the Controller Test
private struct ControllerSettingsPage: View {
	@Binding var settings: StreamSettings
	private static let deviceHasHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
	@Environment(SettingsNavigation.self) private var navigation
	@Environment(\.lendController) private var lendController
	@State private var testing = false

	private var rows: [GamepadRow] {
		var rows = [GamepadRow.link("test") { testing = true }, .toggle("rumble", $settings.rumble)]
		if settings.rumble {
			rows.append(.picker("vibration", $settings.controllerVibration, ControllerVibration.allCases))
			rows.append(.slider("rumbleRate", $settings.controllerRumbleRate, 10...100, step: 5))
			if Self.deviceHasHaptics {
				rows.append(.picker("haptics", $settings.phoneHaptics, PhoneHaptics.allCases))
			}
		}
		rows.append(.link(SettingsPage.gyroAim.rowID) { navigation.open(.gyroAim) })
		return rows
	}

	var body: some View {
		Form {
			Section {
				ControllerTestLink(isPresented: $testing, onActiveChange: lendController)
					.gamepadRow("test")
			} footer: {
				Text("See every button, stick and trigger as the game gets it, and try rumble.")
			}

			Section {
				Toggle("Rumble", isOn: $settings.rumble)
					.gamepadRow("rumble")
				Picker("Controller vibration", selection: $settings.controllerVibration) {
					ForEach(ControllerVibration.allCases) { Text($0.label).tag($0) }
				}
				.disabled(!settings.rumble)
				.gamepadRow("vibration")
				LabeledSlider(title: "Rumble updates", value: $settings.controllerRumbleRate, range: 10...100, step: 5,
					valueText: settings.controllerRumbleRate >= 100 ? "Unlimited" : "\(Int(settings.controllerRumbleRate)) per second")
					.disabled(!settings.rumble)
					.gamepadRow("rumbleRate")
				// iPads have no vibration motor
				if Self.deviceHasHaptics {
					Picker("Phone haptics", selection: $settings.phoneHaptics) {
						ForEach(PhoneHaptics.allCases) { Text($0.label).tag($0) }
					}
					.disabled(!settings.rumble)
					.gamepadRow("haptics")
				}
			} header: {
				Text("Vibration")
			} footer: {
				if Self.deviceHasHaptics {
					Text("Rumble turns all vibration on or off. Controller vibration sets how strongly a controller's motors play it. Phone haptics sets how strongly the phone itself vibrates, which it does with virtual controls or a controller that has no motors (like a Backbone).")
				} else {
					Text("Rumble turns controller vibration on or off. Controller vibration sets how strongly the controller's motors play it.")
				}
				Text("Rumble updates limits how often vibration changes are sent to a wireless controller. They share its Bluetooth connection with your button presses, so too many can make the controls stop responding for a moment during heavy vibration. Lower it if that happens, raise it if vibration feels less detailed.")
			}

			Section {
				SettingsLink(title: "Gyro aiming", systemImage: "scope", value: settings.gyroAim.label, page: .gyroAim)
			} header: {
				Text("Motion")
			} footer: {
				Text("Hold \(ControllerStyle.current.view) + \(ControllerStyle.current.menu) for a second during a stream to open the menu.")
			}
		}
		.settingsPage("Controller")
		.gamepadPage(.controller, rows, covered: testing)
	}
}

/// Turning controller (or phone) motion into right stick movement, and tuning it to the game
private struct GyroAimSettingsPage: View {
	@Binding var settings: StreamSettings

	private var rows: [GamepadRow] {
		var rows = [GamepadRow.picker("mode", $settings.gyroAim, GyroAimMode.allCases)]
		guard settings.gyroAim != .off else { return rows }
		rows += [
			.picker("turning", $settings.gyroAimTurning, GyroAimTurning.allCases),
			.slider("sensitivity", $settings.gyroAimSensitivity, 0.25...3, step: 0.05),
			.slider("vertical", $settings.gyroAimVerticalScale, 0.5...3, step: 0.05),
			.toggle("invert", $settings.gyroAimInvertY),
			.slider("deadzone", $settings.gyroAimDeadzone, 0...0.4, step: 0.01),
			.toggle("perAxis", $settings.gyroAimPerAxisDeadzone),
			.slider("curve", $settings.gyroAimResponseCurve, 1...3, step: 0.1),
		]
		return rows
	}

	var body: some View {
		Form {
			Section {
				Picker("Gyro aiming", selection: $settings.gyroAim) {
					ForEach(GyroAimMode.allCases) { Text($0.label).tag($0) }
				}
				.gamepadRow("mode")
			} footer: {
				Text("Turns the controller's motion (or the phone's, if the controller has none) into right stick movement, on top of the stick itself.")
			}

			if settings.gyroAim != .off {
				Section {
					Picker("Look left/right by", selection: $settings.gyroAimTurning) {
						ForEach(GyroAimTurning.allCases) { Text($0.label).tag($0) }
					}
					.gamepadRow("turning")
					LabeledSlider(title: "Gyro sensitivity", value: $settings.gyroAimSensitivity, range: 0.25...3, step: 0.05,
						valueText: multiplier(settings.gyroAimSensitivity))
						.gamepadRow("sensitivity")
					LabeledSlider(title: "Up/down speed", value: $settings.gyroAimVerticalScale, range: 0.5...3, step: 0.05,
						valueText: multiplier(settings.gyroAimVerticalScale))
						.gamepadRow("vertical")
					Toggle("Invert gyro up/down", isOn: $settings.gyroAimInvertY)
						.gamepadRow("invert")
				} header: {
					Text("Aiming")
				} footer: {
					Text("Tilt like a steering wheel or turn left and right to look around (Look left/right by picks which), and tip the top towards or away from you to look up and down.")
					Text("Up/down speed makes looking up and down faster than left and right, as most games turn slower vertically.")
				}

				Section {
					LabeledSlider(title: "Game dead zone", value: $settings.gyroAimDeadzone, range: 0...0.4, step: 0.01,
						valueText: "\(Int((settings.gyroAimDeadzone * 100).rounded()))%")
						.gamepadRow("deadzone")
					Toggle("Dead zone per direction", isOn: $settings.gyroAimPerAxisDeadzone)
						.gamepadRow("perAxis")
				} header: {
					Text("Match the game")
				} footer: {
					Text("Game dead zone is how much stick movement the game ignores. Raise it until small, slow movements move the camera, and lower it if the camera creeps when you're nearly still.")
					Text("Dead zone per direction pushes left/right and up/down past the dead zone separately, so the small part of a diagonal correction isn't lost.")
				}

				Section {
					LabeledSlider(title: "Fine aim boost", value: $settings.gyroAimResponseCurve, range: 1...3, step: 0.1,
						valueText: settings.gyroAimResponseCurve.formatted(.number.precision(.fractionLength(1))))
						.gamepadRow("curve")
				} footer: {
					Text("Undoes games slowing down small stick movements. Raise it if small corrections feel sluggish, lower it if they overshoot. 1 turns it off.")
				}
			}
		}
		.settingsPage("Gyro Aiming")
		.gamepadPage(.gyroAim, rows)
	}
}

/// Microphone for voice chat
private struct AudioSettingsPage: View {
	@Binding var settings: StreamSettings
	@State private var micDenied = AVAudioApplication.shared.recordPermission == .denied

	private var rows: [GamepadRow] { [.toggle("microphone", $settings.microphone)] }

	var body: some View {
		Form {
			Section {
				Toggle("Microphone", isOn: $settings.microphone)
					.gamepadRow("microphone")
					.onChange(of: settings.microphone) { _, on in
						guard on else { return }
						AVAudioApplication.requestRecordPermission { granted in
							DispatchQueue.main.async {
								micDenied = !granted
								if !granted { settings.microphone = false }
							}
						}
					}
			} footer: {
				if micDenied {
					Text("iPlayPC doesn't have access to the microphone. Turn it on in Settings › Apps › iPlayPC.")
				}
				Text("Sends your voice to the PC for voice chat in games, Discord and Steam. Tap the mic button in the bottom-left corner of the stream to mute it. Turning it on takes effect the next time you connect.")
			}
		}
		.settingsPage("Audio")
		.gamepadPage(.audio, rows)
	}
}

/// On-screen controls
private struct VirtualControlsSettingsPage: View {
	@Binding var settings: StreamSettings

	private var rows: [GamepadRow] {
		var rows = [GamepadRow.toggle("touchMouse", $settings.touchMouse),
			.picker("show", $settings.virtualControls, VirtualControlsMode.allCases)]
		guard settings.virtualControls != .never else { return rows }
		rows += [
			.picker("size", $settings.controlsSize, ControlsSize.allCases),
			.slider("opacity", $settings.controlsOpacity, 0.2...1, step: 0.05),
			.toggle("fixedSticks", $settings.fixedSticks),
		]
		return rows
	}

	var body: some View {
		Form {
			Section {
				Toggle("Touch as mouse", isOn: $settings.touchMouse)
					.gamepadRow("touchMouse")
			} footer: {
				Text("With a controller, tap the picture to click there and drag to drag. With virtual controls, the top half works like a trackpad: drag to move the pointer, tap to click, and tap then drag to hold the button. Either way, press and hold or tap with two fingers to right-click, and drag with two fingers to scroll.")
			}

			Section {
				Picker("Show virtual controls", selection: $settings.virtualControls) {
					ForEach(VirtualControlsMode.allCases) { Text($0.label).tag($0) }
				}
				.gamepadRow("show")
			} footer: {
				Text("Auto shows virtual controls when no supported controller is connected.")
			}

			if settings.virtualControls != .never {
				Section {
					Picker("Size", selection: $settings.controlsSize) {
						ForEach(ControlsSize.allCases) { Text($0.label).tag($0) }
					}
					.gamepadRow("size")
					LabeledSlider(title: "Opacity", value: $settings.controlsOpacity, range: 0.2...1, step: 0.05,
						valueText: "\(Int((settings.controlsOpacity * 100).rounded()))%")
						.gamepadRow("opacity")
				}

				Section {
					Toggle("Fixed sticks", isOn: $settings.fixedSticks)
						.gamepadRow("fixedSticks")
				} footer: {
					Text("Sticks normally start wherever your thumb lands in the lower half. Fixed sticks stay in one spot on each side instead, and a touch near one moves it straight away.")
				}
			}
		}
		.settingsPage("Virtual Controls")
		.gamepadPage(.virtualControls, rows)
	}
}

/// Resolution, frame rate, bitrate, codec and HDR: what to ask the PC for. A PC can have its own.
struct VideoSettingsSection: View {
	@Binding var settings: StreamSettings
	var customHostName: String?

	@Environment(BitrateMemory.self) private var bitrateMemory

	/// The rows below, for a controller. Auto bitrate's rows (shared settings only) come with `bitrateMemory`.
	static func gamepadRows(_ settings: Binding<StreamSettings>, bitrateMemory: BitrateMemory? = nil) -> [GamepadRow] {
		let s = settings.wrappedValue
		var rows = [
			GamepadRow.picker("video.resolution", settings.resolution, StreamResolution.allCases),
			.picker("video.fps", settings.fps, StreamSettings.fpsOptions),
			GamepadRow(id: "video.bitrate", adjust: { step in
				let mbps = settings.wrappedValue.bitrateMbps + step * 5
				settings.wrappedValue.bitrateMbps = mbps < 5 ? StreamSettings.automaticBitrate
					: StreamSettings.clampBitrate(mbps)
			}),
		]
		if !s.hdr {
			let flip = { settings.wrappedValue.codec = settings.wrappedValue.effectiveCodec == .h265 ? .h264 : .h265 }
			rows.append(GamepadRow(id: "video.codec", confirmLabel: "Change", activate: flip, adjust: { _ in flip() }))
		}
		if StreamSettings.screenSupportsHDR || s.hdr {
			rows.append(.toggle("video.hdr", settings.hdr))
		}
		if let bitrateMemory {
			rows.append(.toggle("video.autoBitrate", settings.autoBitrate))
			if s.autoBitrate && !bitrateMemory.entries.isEmpty {
				rows.append(GamepadRow(id: "video.forgetBitrates", confirmLabel: "Forget", activate: { bitrateMemory.forgetAll() }))
			}
		}
		return rows
	}

	var body: some View {
		Section {
			Picker("Resolution", selection: $settings.resolution) {
				ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
			}
			.gamepadRow("video.resolution")
			Picker("Frame rate", selection: $settings.fps) {
				ForEach(StreamSettings.fpsOptions.reversed(), id: \.self) { Text("\($0) fps").tag($0) }
			}
			.gamepadRow("video.fps")
			VStack(alignment: .leading) {
				HStack {
					Text("Maximum bitrate")
					Spacer()
					Text(settings.bitrateLabel).foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }),
					in: 0...Double(StreamSettings.maxBitrateMbps), step: 5)
			}
			.gamepadRow("video.bitrate")
			Picker("Codec", selection: Binding(get: { settings.effectiveCodec }, set: { settings.codec = $0 })) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
			.disabled(settings.hdr)
			.gamepadRow("video.codec")
			if StreamSettings.screenSupportsHDR || settings.hdr {
				Toggle("HDR", isOn: $settings.hdr)
					.gamepadRow("video.hdr")
			}
		} header: {
			Text(customHostName.map { "Video for \($0)" } ?? "Video")
		} footer: {
			Text("These are the most to ask for: the PC's own Remote Play settings in Steam can lower them. Automatic bitrate lets the PC decide. HDR needs H.265 and a game that supports it. These can't change during a stream.")
			if customHostName == nil {
				Text("To give a PC its own video settings, open its settings from the PC list.")
			}
		}
		if customHostName == nil {
			Section {
				Toggle("Auto bitrate", isOn: $settings.autoBitrate)
					.gamepadRow("video.autoBitrate")
				if settings.autoBitrate && !bitrateMemory.entries.isEmpty {
					Button("Forget learned bitrates", role: .destructive) { bitrateMemory.forgetAll() }
						.gamepadRow("video.forgetBitrates")
				}
			} footer: {
				Text("Learns the maximum bitrate that works for each PC on each Wi-Fi network. After a stream that dropped video it asks for less next time, and after a long clean one it tries a little more, up to Maximum bitrate. On mobile data, Maximum bitrate is used as is.")
			}
		}
	}
}

extension StreamSettings {
	var bitrateLabel: String {
		bitrateMbps == Self.automaticBitrate ? "Automatic" : "\(bitrateMbps) Mbps"
	}
}

/// The stream menu's view of the video settings: what this stream asked for, not editable
struct VideoSettingsSummary: View {
	let settings: StreamSettings
	let stats: StreamStats
	var customHostName: String?
	/// The maximum bitrate came from Auto bitrate
	var learnedBitrate = false

	var body: some View {
		Section {
			LabeledContent("Resolution", value: settings.resolution.label)
			LabeledContent("Frame rate", value: "\(settings.fps) fps")
			LabeledContent(learnedBitrate ? "Maximum bitrate (Auto)" : "Maximum bitrate", value: settings.bitrateLabel)
			LabeledContent("Codec", value: settings.effectiveCodec.label)
			LabeledContent("HDR", value: settings.hdr ? "On" : "Off")
			if stats.width > 0 {
				LabeledContent("Streaming at", value: "\(stats.width)×\(stats.height)")
			}
		} header: {
			Text(customHostName.map { "Video for \($0)" } ?? "Video")
		} footer: {
			Text("These are fixed when the stream starts, so change them in Settings (or the PC's own video settings) before you play. Streaming at is what the PC is actually sending.")
		}
	}
}

/// One PC: its name, address, MAC address for waking it, its own video settings
/// (for example 4K on the desktop and 1080p120 on the laptop), and Forget.
struct HostSettingsView: View {
	let host: PCHost

	@Environment(HostStore.self) private var hosts
	@Environment(SettingsStore.self) private var store
	@Environment(\.dismiss) private var dismiss
	/// Text fields are saved when editing ends, not per keystroke
	@State private var name = ""
	@State private var address = ""
	@State private var mac = ""
	@State private var confirmingForget = false

	private var saved: PCHost { hosts.host(id: host.id) ?? host }

	private var rows: [GamepadRow] {
		let toggle = GamepadRow.toggle("custom", custom)
		let forget = GamepadRow(id: "forget", confirmLabel: "Forget", activate: { confirmingForget = true })
		guard saved.settings.video != nil else { return [toggle, forget] }
		return [toggle] + VideoSettingsSection.gamepadRows(settings) + [forget]
	}

	private var addressValid: Bool { LocalNetwork.normalizedIPv4(address) != nil }
	private var macValid: Bool {
		mac.trimmingCharacters(in: .whitespaces).isEmpty || LocalNetwork.normalizedMAC(mac) != nil
	}

	private func saveFields() {
		guard hosts.host(id: host.id) != nil else { return }
		var updated = saved
		let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		if !trimmedName.isEmpty { updated.name = trimmedName }
		if let ip = LocalNetwork.normalizedIPv4(address) { updated.address = ip }
		if mac.trimmingCharacters(in: .whitespaces).isEmpty {
			updated.macAddress = nil
		} else if let normalized = LocalNetwork.normalizedMAC(mac) {
			updated.macAddress = normalized
			mac = normalized
		}
		if updated != saved { hosts.update(updated) }
	}

	private var custom: Binding<Bool> {
		Binding(
			get: { saved.settings.video != nil },
			// Start from the shared settings, so turning it on changes nothing until you edit
			set: { on in
				var updated = saved
				updated.settings.video = on ? store.settings.video : nil
				hosts.update(updated)
			})
	}

	private var settings: Binding<StreamSettings> {
		Binding(
			get: { store.settings.applying(saved.settings.video) },
			set: { new in
				guard saved.settings.video != nil else { return }
				var updated = saved
				updated.settings.video = new.video
				hosts.update(updated)
			})
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					LabeledContent("Name") {
						TextField("PC", text: $name)
							.multilineTextAlignment(.trailing)
							.submitLabel(.done)
							.onSubmit(saveFields)
					}
					LabeledContent("IP address") {
						TextField("192.168.1.50", text: $address)
							.multilineTextAlignment(.trailing)
							.keyboardType(.numbersAndPunctuation)
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()
							.submitLabel(.done)
							.onSubmit(saveFields)
							.foregroundStyle(addressValid ? .primary : Color.red)
					}
				} footer: {
					Text("The address follows the PC automatically when it's found on your network.")
				}
				Section {
					LabeledContent("MAC address") {
						TextField("AA:BB:CC:DD:EE:FF", text: $mac)
							.multilineTextAlignment(.trailing)
							.textInputAutocapitalization(.characters)
							.autocorrectionDisabled()
							.submitLabel(.done)
							.onSubmit(saveFields)
							.foregroundStyle(macValid ? .primary : Color.red)
					}
				} footer: {
					Text("Lets iPlayPC wake \(saved.name) from sleep. On Windows, run `ipconfig /all` and use the Physical Address of the network adapter it's connected with, and turn on Wake on LAN for that adapter. On a Mac, it's in System Settings › Network › Details › Hardware, and Wake for network access needs to be on in System Settings › Energy.")
				}
				Section {
					Toggle("Custom video settings", isOn: custom)
						.gamepadRow("custom")
				} footer: {
					Text("Give \(saved.name) its own resolution, frame rate, bitrate, codec and HDR. Display and controller settings are always shared.")
				}
				if saved.settings.video != nil {
					VideoSettingsSection(settings: settings, customHostName: saved.name)
				}
				Section {
					Button("Forget \(saved.name)", role: .destructive) { confirmingForget = true }
						.gamepadRow("forget")
				} footer: {
					Text("Removes the PC and its pairing. To play it again you'll pair with a new PIN.")
				}
			}
			.navigationTitle(saved.name)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") {
						saveFields()
						dismiss()
					}
				}
			}
			.gamepadForm(rows, backLabel: "Done", active: !confirmingForget) {
				saveFields()
				dismiss()
			}
			.confirmationDialog("Forget \(saved.name)?", isPresented: $confirmingForget, titleVisibility: .visible) {
				Button("Forget", role: .destructive) {
					hosts.remove(saved)
					dismiss()
				}
			} message: {
				Text("You'll need to pair again to play it.")
			}
		}
		.onAppear {
			name = saved.name
			address = saved.address
			mac = saved.macAddress ?? ""
		}
		.onDisappear(perform: saveFields)
	}
}

/// The stream settings shared by every PC
struct SettingsView: View {
	@Environment(SettingsStore.self) private var store
	@Environment(BitrateMemory.self) private var bitrateMemory
	@Environment(\.dismiss) private var dismiss
	@State private var navigation = SettingsNavigation()

	private var rows: [GamepadRow] {
		StreamSettingsForm.gamepadRows(settingsBinding, bitrateMemory: bitrateMemory) { navigation.open($0) }
	}

	private var settingsBinding: Binding<StreamSettings> {
		Binding(get: { store.settings }, set: { store.settings = $0 })
	}

	var body: some View {
		@Bindable var navigation = navigation
		NavigationStack(path: $navigation.path) {
			Form {
				StreamSettingsForm(settings: settingsBinding)
				AboutSection()
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
			.settingsPages(settingsBinding, navigation: navigation)
			.gamepadForm(rows, backLabel: "Done", active: navigation.path.isEmpty) { dismiss() }
		}
	}
}
