import Foundation
import Observation

/// How one connection went, for Auto bitrate. Built up second by second while streaming.
struct StreamQualityReport {
	/// The maximum bitrate the connection asked the PC for
	let bitrateMbps: Int
	/// Seconds actually streaming (not paused)
	let seconds: Int
	/// Share of video frames lost, averaged over the seconds
	let averageLoss: Double
	/// Frames lost or failed to decode
	let lostFrames: Int
	/// The most the PC actually sent in any second
	let peakMbps: Double
}

/// Auto bitrate: remembers the maximum bitrate that works for each PC on each Wi-Fi network,
/// stepping down after lossy streams and back up after clean ones. Steam adapts the bitrate
/// itself under that maximum; this keeps the maximum where the network can carry it.
/// Learned values are used from the next stream.
@Observable
final class BitrateMemory {
	struct Entry: Codable, Equatable {
		var bitrateMbps: Int
		/// A bitrate that dropped video here. Stepping up stays below it until the network proves better.
		var ceilingMbps: Int?
		/// Clean sessions in a row just under the ceiling
		var cleanStreak = 0
	}

	/// Sessions shorter than this don't say much either way
	static let minimumSeconds = 60
	/// Stepping up needs a longer clean session
	static let stepUpSeconds = 180

	private(set) var entries: [String: Entry] = [:]

	@ObservationIgnored private let key = "bitrateMemory"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
		{
			entries = decoded
		}
	}

	static func key(host: String, network: String) -> String { "\(host)|\(network)" }

	func bitrate(for key: String) -> Int? { entries[key]?.bitrateMbps }

	/// The player picked a bitrate for this PC and network (from Check connection): start from it
	func setManual(_ bitrate: Int, for key: String) {
		guard entries[key] != Entry(bitrateMbps: bitrate) else { return }
		entries[key] = Entry(bitrateMbps: bitrate)
		save()
	}

	/// Learns from a finished connection. `starting` is the Maximum bitrate setting (100 for
	/// Automatic), the most it climbs back to.
	func record(_ report: StreamQualityReport, for key: String, starting: Int) {
		guard report.seconds >= Self.minimumSeconds else { return }
		let rate = report.bitrateMbps
		// From before the player picked a different bitrate: their choice wins
		if let current = entries[key], current.bitrateMbps != rate { return }
		var entry = entries[key] ?? Entry(bitrateMbps: rate)
		let lostPerMinute = Double(report.lostFrames) / (Double(report.seconds) / 60)
		let percent = String(format: "%.2f%%", report.averageLoss * 100)

		if report.averageLoss >= 0.01 || lostPerMinute >= 2 {
			// Lossy: back off a quarter from what actually flowed (Steam often sends well under
			// the maximum, so lowering an unused maximum wouldn't change anything), and don't
			// climb back to this soon
			let used = report.peakMbps > 1 ? min(Double(rate), report.peakMbps) : Double(rate)
			entry.bitrateMbps = max(10, min(rate - 5, Self.roundDown5(used * 0.75)))
			entry.ceilingMbps = rate
			entry.cleanStreak = 0
			log.notice("Auto bitrate: \(rate) Mbps lost \(percent, privacy: .public), \(report.lostFrames) frames in \(report.seconds) s, next time \(entry.bitrateMbps) Mbps")
		} else if report.averageLoss < 0.003, lostPerMinute < 0.5, report.seconds >= Self.stepUpSeconds,
			report.peakMbps >= Double(rate) * 0.6
		{
			// Clean, and the stream really used the bitrate: step up a fifth
			let cap = min(StreamSettings.maxBitrateMbps, starting, (entry.ceilingMbps ?? .max) - 5)
			let next = min(cap, max(rate + 5, Self.roundDown5(Double(rate) * 1.2)))
			if next > rate {
				entry.bitrateMbps = next
				log.notice("Auto bitrate: \(rate) Mbps was clean for \(report.seconds) s, next time \(next) Mbps")
			} else if entry.ceilingMbps != nil {
				// Sitting just under an old failure: after a few clean sessions, try past it again
				entry.cleanStreak += 1
				if entry.cleanStreak >= 3 {
					entry.ceilingMbps = nil
					entry.cleanStreak = 0
					log.notice("Auto bitrate: \(rate) Mbps clean three times in a row, allowing higher again")
				}
			}
		} else {
			log.notice("Auto bitrate: \(rate) Mbps, no change (\(percent, privacy: .public) loss, \(report.lostFrames) frames, \(report.seconds) s)")
		}

		// Nothing learned yet and nothing to change: keep following the setting
		if entries[key] == nil, entry == Entry(bitrateMbps: rate) { return }
		if entries[key] != entry {
			entries[key] = entry
			save()
		}
	}

	func forgetAll() {
		entries = [:]
		save()
	}

	private func save() {
		if let data = try? JSONEncoder().encode(entries) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}

	private static func roundDown5(_ value: Double) -> Int { Int(value / 5) * 5 }
}
