import GameController
import UIKit

/// A plain-text report people can attach to a GitHub issue: app, device and screen details,
/// settings, and the app's logs since it was opened. IP and MAC addresses, IDs, keys and
/// the names of the PCs are taken out before sharing.
struct DiagnosticsReport {
	let settings: StreamSettings
	/// How many PCs are saved, and how many of them are paired
	var pcs = 0
	var pairedPCs = 0
	/// The PCs' names, removed wherever they appear
	var privateText: [String] = []

	func writeFile() async throws -> URL {
		let summary = await MainActor.run { Self.summary(settings: settings, pcs: pcs, pairedPCs: pairedPCs) }
		let logs = Self.logLines()
		let text = redact(summary + "\n\n== Log since the app was opened ==\n" + logs.joined(separator: "\n") + "\n")

		let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("iPlayPC-diagnostics-\(stamp).txt")
		try text.write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	// MARK: - Contents

	@MainActor
	private static func summary(settings: StreamSettings, pcs: Int, pairedPCs: Int) -> String {
		let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
		let screen = scene?.screen
		let window = scene?.keyWindow?.bounds.size ?? .zero
		let controllers = GCController.controllers().map { "\($0.vendorName ?? "?") (\($0.productCategory))" }
		let settingsJSON = (try? JSONEncoder().encode(settings)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"

		return """
		== iPlayPC diagnostics ==
		App: \(AppInfo.version), source \(AppInfo.sourceRef)
		iOS: \(UIDevice.current.systemVersion)
		Model: \(DeviceLayout.modelIdentifier)
		Screen: \(size(screen?.bounds.size))pt, \(size(screen?.nativeBounds.size))px, scale \(screen?.scale ?? 0), native scale \(screen?.nativeScale ?? 0), max \(screen?.maximumFramesPerSecond ?? 0) Hz, EDR headroom \(screen?.potentialEDRHeadroom ?? 0)
		Window: \(size(window))pt, \(orientation(scene?.interfaceOrientation))
		Foldable: \(DeviceLayout.isFoldable), inner screen: \(DeviceLayout.isInnerScreen(window))
		Controllers: \(controllers.isEmpty ? "none" : controllers.joined(separator: ", "))
		PCs: \(pcs) saved, \(pairedPCs) paired
		Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue), Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)
		Settings: \(settingsJSON)
		"""
	}

	/// From the app's own copy of its log (AppLog): the system log can't be read back in
	/// App Store and TestFlight builds
	private static func logLines() -> [String] {
		AppLogBuffer.shared.snapshot().map { line in
			"\(line.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))) [\(line.category)] \(line.level.rawValue) \(line.text)"
		}
	}

	// MARK: - Redaction

	private static let redactions: [(pattern: String, replacement: String)] = [
		(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
		// MAC and IPv6 addresses (hex groups split by colons or dashes)
		(#"\b[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4}){4,7}\b"#, "<address>"),
		(#"\b[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}\b"#, "<address>"),
		(#"\b\d{1,3}(\.\d{1,3}){3}\b"#, "<ip>"),
		// Device and session ids
		(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<id>"),
		// Pairing keys and other long hex
		(#"\b[0-9A-Fa-f]{12,}\b"#, "<hex>"),
		// Steam and device ids
		(#"\b\d{12,}\b"#, "<id>"),
		// Other base64 blobs (a digit is required so long words survive)
		(#"(?=[A-Za-z+/]*\d)[A-Za-z0-9+/]{16,}={0,2}"#, "<base64>"),
	]

	private func redact(_ text: String) -> String {
		var text = text
		// Longest first, so a full name goes before a part of it
		for value in privateText.sorted(by: { $0.count > $1.count }) where value.count >= 3 {
			text = text.replacingOccurrences(of: value, with: "<pc>", options: .caseInsensitive)
		}
		for (pattern, replacement) in Self.redactions {
			text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
		}
		return text
	}

	// MARK: - Formatting

	private static func size(_ size: CGSize?) -> String {
		guard let size else { return "?" }
		return "\(Int(size.width))x\(Int(size.height))"
	}

	private static func orientation(_ orientation: UIInterfaceOrientation?) -> String {
		switch orientation {
		case .portrait: "portrait"
		case .portraitUpsideDown: "portrait upside down"
		case .landscapeLeft: "landscape left"
		case .landscapeRight: "landscape right"
		default: "unknown"
		}
	}
}
