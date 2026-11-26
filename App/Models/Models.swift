import Foundation
import Observation
import UIKit

// MARK: - Stream settings

/// The most to ask the PC for. Steam scales its picture to fit and may send less.
enum StreamResolution: Int, Codable, CaseIterable, Identifiable {
	case p720 = 720
	case p1080 = 1080
	case p1440 = 1440
	case p2160 = 2160
	/// This screen's own pixels
	case native = 0

	var id: Int { rawValue }
	var label: String {
		switch self {
		case .p2160: "4K"
		case .native: "Native"
		default: "\(rawValue)p"
		}
	}
	var size: (width: Int, height: Int) {
		switch self {
		case .p720: (1280, 720)
		case .p1080: (1920, 1080)
		case .p1440: (2560, 1440)
		case .p2160: (3840, 2160)
		case .native: Self.screenSize
		}
	}

	/// The screen's pixels, landscape
	static var screenSize: (width: Int, height: Int) {
		let size = UIScreen.main.nativeBounds.size
		return (Int(max(size.width, size.height)), Int(min(size.width, size.height)))
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

/// How strongly a controller's motors play rumble
enum ControllerVibration: String, Codable, CaseIterable, Identifiable {
	case light, medium, full

	var id: Self { self }
	var label: String {
		switch self {
		case .light: "Light"
		case .medium: "Medium"
		case .full: "Full"
		}
	}
	var scale: Float {
		switch self {
		case .light: 0.35
		case .medium: 0.65
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
	static let maxBitrateMbps = 100
	/// Automatic: the PC's own Remote Play bandwidth setting decides. Steam-Link-PS5 found
	/// that any lower cap from the client only holds the stream back, so this is the default.
	static let automaticBitrate = 0

	var resolution: StreamResolution = .p1080
	var fps: Int = 60
	/// 0 is Automatic
	var bitrateMbps: Int = automaticBitrate
	/// Learn the maximum bitrate that works for each PC on each Wi-Fi network (BitrateMemory).
	/// Used when a stream starts.
	var autoBitrate: Bool = true
	/// H.265 when the PC can send it, otherwise Steam falls back to H.264
	var codec: VideoCodecChoice = .h265
	/// HDR10. Needs H.265, an HDR screen and a game that supports it.
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
	/// How strongly a controller with motors plays rumble
	var controllerVibration: ControllerVibration = .full
	/// Most rumble updates per second sent to a controller's motors, 10...100. Each is a
	/// Bluetooth packet on the link the controller's input uses; too many can stall input.
	var controllerRumbleRate: Double = 25
	/// Send the phone's mic to the PC for voice chat
	var microphone: Bool = false
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

	/// What to cap the PC's bitrate at, in kbit/s
	var bitrateCapKbps: Int {
		(bitrateMbps == Self.automaticBitrate ? Self.maxBitrateMbps : bitrateMbps) * 1000
	}

	/// The video part, which a PC can override
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

	/// These settings with a PC's own video settings on top
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
		bitrateMbps = Self.clampBitrate(try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps)
		autoBitrate = try c.decodeIfPresent(Bool.self, forKey: .autoBitrate) ?? d.autoBitrate
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
		controllerVibration = (try? c.decodeIfPresent(ControllerVibration.self, forKey: .controllerVibration)) ?? d.controllerVibration
		controllerRumbleRate = min(100, max(10, try c.decodeIfPresent(Double.self, forKey: .controllerRumbleRate) ?? d.controllerRumbleRate))
		microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? d.microphone
		virtualControls = (try? c.decodeIfPresent(VirtualControlsMode.self, forKey: .virtualControls)) ?? d.virtualControls
		controlsSize = (try? c.decodeIfPresent(ControlsSize.self, forKey: .controlsSize)) ?? d.controlsSize
		controlsOpacity = min(1, max(0.2, try c.decodeIfPresent(Double.self, forKey: .controlsOpacity) ?? d.controlsOpacity))
		fixedSticks = try c.decodeIfPresent(Bool.self, forKey: .fixedSticks) ?? d.fixedSticks
		touchMouse = try c.decodeIfPresent(Bool.self, forKey: .touchMouse) ?? d.touchMouse
		highRefreshDisplay = try c.decodeIfPresent(Bool.self, forKey: .highRefreshDisplay) ?? d.highRefreshDisplay
		frameGeneration = try c.decodeIfPresent(Bool.self, forKey: .frameGeneration) ?? d.frameGeneration
	}

	/// 0 (Automatic) or 5...100 Mbps
	static func clampBitrate(_ value: Int) -> Int {
		value <= automaticBitrate ? automaticBitrate : min(maxBitrateMbps, max(5, value))
	}
}

/// Resolution, frame rate, bitrate, codec and HDR: fixed for a stream, and what a PC can override
struct VideoSettings: Codable, Hashable {
	var resolution: StreamResolution
	var fps: Int
	var bitrateMbps: Int
	var codec: VideoCodecChoice
	var hdr: Bool

	init(resolution: StreamResolution, fps: Int, bitrateMbps: Int, codec: VideoCodecChoice, hdr: Bool) {
		self.resolution = resolution
		self.fps = fps
		self.bitrateMbps = bitrateMbps
		self.codec = codec
		self.hdr = hdr
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = StreamSettings()
		resolution = (try? c.decodeIfPresent(StreamResolution.self, forKey: .resolution)) ?? d.resolution
		let savedFPS = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
		fps = StreamSettings.fpsOptions.contains(savedFPS) ? savedFPS : d.fps
		bitrateMbps = StreamSettings.clampBitrate(try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps)
		codec = (try? c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec)) ?? d.codec
		hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
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
