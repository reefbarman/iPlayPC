import Foundation
import Observation
import UIKit

/// Battery and temperature for the stream menu, plus a nudge when the phone gets hot.
@Observable
final class PhoneStatus {
	private(set) var batteryLevel: Float = -1
	private(set) var batteryState: UIDevice.BatteryState = .unknown
	private(set) var thermalState: ProcessInfo.ThermalState = .nominal

	@ObservationIgnored private var observers: [NSObjectProtocol] = []

	init() {
		let device = UIDevice.current
		device.isBatteryMonitoringEnabled = true
		refresh()
		let center = NotificationCenter.default
		for name in [
			UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
			ProcessInfo.thermalStateDidChangeNotification,
		] {
			observers.append(
				center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
		}
	}

	deinit {
		observers.forEach(NotificationCenter.default.removeObserver)
	}

	private func refresh() {
		batteryLevel = UIDevice.current.batteryLevel
		batteryState = UIDevice.current.batteryState
		thermalState = ProcessInfo.processInfo.thermalState
	}

	/// Hot enough that iOS may start throttling (and the phone is uncomfortable to hold)
	var isHot: Bool { thermalState == .serious || thermalState == .critical }

	var batteryText: String {
		guard batteryLevel >= 0 else { return "Unknown" }
		let percent = "\(Int((batteryLevel * 100).rounded()))%"
		switch batteryState {
		case .charging: return "\(percent), charging"
		case .full: return "\(percent), full"
		default: return percent
		}
	}

	var batterySymbol: String {
		if batteryState == .charging || batteryState == .full { return "battery.100percent.bolt" }
		switch batteryLevel {
		case ..<0: return "battery.0percent"
		case ..<0.15: return "battery.0percent"
		case ..<0.4: return "battery.25percent"
		case ..<0.65: return "battery.50percent"
		case ..<0.9: return "battery.75percent"
		default: return "battery.100percent"
		}
	}

	var thermalText: String {
		switch thermalState {
		case .nominal: "Normal"
		case .fair: "Warm"
		case .serious: "Hot"
		case .critical: "Very hot"
		@unknown default: "Unknown"
		}
	}
}
