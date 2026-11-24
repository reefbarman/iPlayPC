import Foundation
import Observation
import UIKit

// MARK: - Stream settings

/// What to ask GeForce NOW for. The membership tier decides what's actually streamed; this is a ceiling.
enum StreamResolution: Int, Codable, CaseIterable, Identifiable {
	case p720 = 720
	case p1080 = 1080
	case p1440 = 1440
	case p2160 = 2160

	var id: Int { rawValue }
	var label: String { self == .p2160 ? "4K" : "\(rawValue)p" }
	var size: (width: Int, height: Int) {
		switch self {
		case .p720: (1280, 720)
		case .p1080: (1920, 1080)
		case .p1440: (2560, 1440)
		case .p2160: (3840, 2160)
		}
	}
}

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable {
	case h265
	case h264

	var id: String { rawValue }
	var label: String { self == .h265 ? "H.265 (HEVC)" : "H.264" }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
	/// Whole picture visible, black bars where the screen isn't 16:9
	case fit
	/// Fill the screen, cropping whatever overflows
	case zoom

	var id: String { rawValue }
	var label: String { self == .fit ? "Fit" : "Zoom to fill" }
}


enum VirtualControlsMode: String, Codable, CaseIterable, Identifiable {
	case auto, always, never

	var id: Self { self }
	var label: String {
		switch self {
		case .auto: "Auto"
		case .always: "Always show"
		case .never: "Never show"
		}
	}
}

enum UpscalingMode: String, Codable, CaseIterable, Identifiable {
	case bilinear, sharp, metalFX, metalFX4K

	var id: Self { self }
	var label: String {
		switch self {
		case .bilinear: "Bilinear"
		case .sharp: "Sharp"
		case .metalFX: "MetalFX Spatial"
		case .metalFX4K: "MetalFX 4K"
		}
	}
	var usesMetalFX: Bool { self == .metalFX || self == .metalFX4K }
}

/// Rumble played on the phone itself, when there's no controller or the controller has no motors
enum PhoneHaptics: String, Codable, CaseIterable, Identifiable {
	case off, light, full

	var id: Self { self }
	var label: String {
		switch self {
		case .off: "Off"
		case .light: "Light"
		case .full: "Full"
		}
	}
	var scale: Float {
		switch self {
		case .off: 0
		case .light: 0.45
		case .full: 1
		}
	}
}

/// Gyro aiming: turn the controller (or the phone) to move the right stick
enum GyroAimMode: String, Codable, CaseIterable, Identifiable {
	case off, always, holdingLT, holdingRB

	var id: Self { self }
	var label: String {
		switch self {
		case .off: "Off"
		case .always: "Always"
		case .holdingLT: "While holding \(ControllerStyle.current.lt)"
		case .holdingRB: "While holding \(ControllerStyle.current.rb)"
		}
	}
}

/// What looks left and right with gyro aiming
enum GyroAimTurning: String, Codable, CaseIterable, Identifiable {
	/// Steam Input's "local space"
	case turnAndTilt, turn, tilt

	var id: Self { self }
	var label: String {
		switch self {
		case .turnAndTilt: "Turn and tilt"
		case .turn: "Turn"
		case .tilt: "Tilt"
		}
	}
	var usesYaw: Bool { self != .tilt }
	var usesRoll: Bool { self != .turn }
}

enum ControlsSize: String, Codable, CaseIterable, Identifiable {
	case small, medium, large

	var id: Self { self }
	var label: String {
		switch self {
		case .small: "Small"
		case .medium: "Medium"
		case .large: "Large"
		}
	}
	var scale: CGFloat {
		switch self {
		case .small: 0.85
		case .medium: 1
		case .large: 1.15
		}
	}
}

enum StatsMode: String, Codable, CaseIterable, Identifiable {
	case off
	/// One line: resolution, fps, bitrate, ping, loss
	case simple
	/// Everything, laid out across the black bar
	case advanced

	var id: Self { self }
	var label: String {
		switch self {
		case .off: "Off"
		case .simple: "Simple"
		case .advanced: "Advanced"
		}
	}
}

struct StreamSettings: Codable, Equatable {
	static let fpsOptions = [30, 60, 120]
	/// NVIDIA's own client announces a 100 Mbps ceiling
	static let maxBitrateMbps = 100

	var resolution: StreamResolution = .p1080
	var fps: Int = 60
	var bitrateMbps: Int = 50
	var codec: VideoCodecChoice = .h265
	/// HDR10. Needs H.265, an HDR screen, Ultimate and a game that supports it.
	var hdr: Bool = false
	var displayMode: DisplayMode = .fit
	var upscaling: UpscalingMode = .sharp
	var statsMode: StatsMode = .off
	/// Gyro moves the right stick (the phone's gyro when the controller has none)
	var gyroAim: GyroAimMode = .off
	/// Multiplies how far the right stick moves for a given turn speed, 0.25...3
	var gyroAimSensitivity: Double = 1
	var gyroAimInvertY: Bool = false
	var gyroAimTurning: GyroAimTurning = .turnAndTilt
	/// Up/down speed relative to left/right, 0.5...3
	var gyroAimVerticalScale: Double = 1.5
	/// The game's own stick dead zone, which gyro movement starts past, 0...0.4
	var gyroAimDeadzone: Double = 0.15
	/// The game's stick response curve power, undone for gyro, 1...3 (1 is linear)
	var gyroAimResponseCurve: Double = 1.5
	/// Push left/right and up/down past the game's dead zone separately
	var gyroAimPerAxisDeadzone: Bool = false
	/// Master switch for rumble
	var rumble: Bool = true
	/// How strongly rumble plays on the phone (virtual controls, or a controller without motors)
	var phoneHaptics: PhoneHaptics = .full
	var virtualControls: VirtualControlsMode = .auto
	var controlsSize: ControlsSize = .medium
	/// 0.2...1, multiplies the virtual controls' own transparency
	var controlsOpacity: Double = 1
	/// Sticks stay put in their own spots instead of starting wherever a thumb lands
	var fixedSticks: Bool = false
	/// Touches on the picture work as a mouse: one-to-one with a controller, a trackpad in the
	/// top half with virtual controls
	var touchMouse: Bool = true
	/// Keep a ProMotion screen at 120 Hz while streaming, so frames wait less for the next refresh
	var highRefreshDisplay: Bool = true
	/// Experimental: make an in-between frame for each pair of real ones (FrameGen.metal)
	var frameGeneration: Bool = false

	/// HDR needs HEVC
	var effectiveCodec: VideoCodecChoice { hdr ? .h265 : codec }

	/// The video part, which a game can override
	var video: VideoSettings {
		get { VideoSettings(resolution: resolution, fps: fps, bitrateMbps: bitrateMbps, codec: codec, hdr: hdr) }
		set {
			resolution = newValue.resolution
			fps = newValue.fps
			bitrateMbps = newValue.bitrateMbps
			codec = newValue.codec
			hdr = newValue.hdr
		}
	}

	/// These settings with a game's own video settings on top
	func applying(_ custom: VideoSettings?) -> StreamSettings {
		guard let custom else { return self }
		var settings = self
		settings.video = custom
		return settings
	}

	/// The screen can show HDR (iPhone 12 and later, recent iPads)
	static var screenSupportsHDR: Bool { UIScreen.main.potentialEDRHeadroom > 1 }

	init() {}

	/// Missing keys keep their defaults, so adding a setting doesn't reset the others
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = StreamSettings()
		resolution = (try? c.decodeIfPresent(StreamResolution.self, forKey: .resolution)) ?? d.resolution
		let savedFPS = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
		fps = Self.fpsOptions.contains(savedFPS) ? savedFPS : d.fps
		bitrateMbps = min(Self.maxBitrateMbps, max(5, try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps))
		codec = (try? c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec)) ?? d.codec
		hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
		displayMode = (try? c.decodeIfPresent(DisplayMode.self, forKey: .displayMode)) ?? d.displayMode
		upscaling = (try? c.decodeIfPresent(UpscalingMode.self, forKey: .upscaling)) ?? d.upscaling
		statsMode = (try? c.decodeIfPresent(StatsMode.self, forKey: .statsMode)) ?? d.statsMode

		gyroAim = (try? c.decodeIfPresent(GyroAimMode.self, forKey: .gyroAim)) ?? d.gyroAim
		gyroAimSensitivity = min(3, max(0.25, try c.decodeIfPresent(Double.self, forKey: .gyroAimSensitivity) ?? d.gyroAimSensitivity))
		gyroAimInvertY = try c.decodeIfPresent(Bool.self, forKey: .gyroAimInvertY) ?? d.gyroAimInvertY
		gyroAimTurning = (try? c.decodeIfPresent(GyroAimTurning.self, forKey: .gyroAimTurning)) ?? d.gyroAimTurning
		gyroAimVerticalScale = min(3, max(0.5, try c.decodeIfPresent(Double.self, forKey: .gyroAimVerticalScale) ?? d.gyroAimVerticalScale))
		gyroAimDeadzone = min(0.4, max(0, try c.decodeIfPresent(Double.self, forKey: .gyroAimDeadzone) ?? d.gyroAimDeadzone))
		gyroAimResponseCurve = min(3, max(1, try c.decodeIfPresent(Double.self, forKey: .gyroAimResponseCurve) ?? d.gyroAimResponseCurve))
		gyroAimPerAxisDeadzone = try c.decodeIfPresent(Bool.self, forKey: .gyroAimPerAxisDeadzone) ?? d.gyroAimPerAxisDeadzone
		rumble = try c.decodeIfPresent(Bool.self, forKey: .rumble) ?? d.rumble
		phoneHaptics = (try? c.decodeIfPresent(PhoneHaptics.self, forKey: .phoneHaptics)) ?? d.phoneHaptics
		virtualControls = (try? c.decodeIfPresent(VirtualControlsMode.self, forKey: .virtualControls)) ?? d.virtualControls
		controlsSize = (try? c.decodeIfPresent(ControlsSize.self, forKey: .controlsSize)) ?? d.controlsSize
		controlsOpacity = min(1, max(0.2, try c.decodeIfPresent(Double.self, forKey: .controlsOpacity) ?? d.controlsOpacity))
		fixedSticks = try c.decodeIfPresent(Bool.self, forKey: .fixedSticks) ?? d.fixedSticks
		touchMouse = try c.decodeIfPresent(Bool.self, forKey: .touchMouse) ?? d.touchMouse
		highRefreshDisplay = try c.decodeIfPresent(Bool.self, forKey: .highRefreshDisplay) ?? d.highRefreshDisplay
		frameGeneration = try c.decodeIfPresent(Bool.self, forKey: .frameGeneration) ?? d.frameGeneration
	}
}

/// Resolution, frame rate, bitrate, codec and HDR: what GeForce NOW fixes for a session
struct VideoSettings: Codable, Hashable {
	var resolution: StreamResolution
	var fps: Int
	var bitrateMbps: Int
	var codec: VideoCodecChoice
	var hdr: Bool
}

/// Games with their own video settings, by game id
@Observable
final class GameSettingsStore {
	private(set) var custom: [String: VideoSettings] {
		didSet { save() }
	}

	@ObservationIgnored private let key = "gameVideoSettings"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode([String: VideoSettings].self, from: data)
		{
			custom = decoded
		} else {
			custom = [:]
		}
	}

	func settings(for gameID: String) -> VideoSettings? { custom[gameID] }

	func set(_ settings: VideoSettings?, for gameID: String) {
		custom[gameID] = settings
	}

	private func save() {
		if let data = try? JSONEncoder().encode(custom) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}

@Observable
final class SettingsStore {
	var settings: StreamSettings {
		didSet { save() }
	}

	@ObservationIgnored private let key = "streamSettings"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data)
		{
			settings = decoded
		} else {
			settings = StreamSettings()
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(settings) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}
