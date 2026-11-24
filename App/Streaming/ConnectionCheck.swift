import Foundation

/// "Check connection": watches the running stream for a short while and suggests a
/// maximum bitrate from what actually arrived.
///
/// Steam sends much less on a quiet screen than in busy gameplay, so this judges the
/// real stream: lost frames and how much of the bitrate turned up. The maximum is fixed
/// once a stream starts, so a suggestion applies from the next stream.
struct ConnectionCheck {
	static let duration = 20

	private struct Sample {
		let bitrateMbps: Double
		let videoLoss: Double
		let lostFrames: Int
	}

	private var samples: [Sample] = []

	var progress: Double { min(1, Double(samples.count) / Double(Self.duration)) }
	var isComplete: Bool { samples.count >= Self.duration }
	var secondsLeft: Int { max(0, Self.duration - samples.count) }

	mutating func add(_ stats: StreamStats) {
		samples.append(Sample(bitrateMbps: stats.bitrateMbps, videoLoss: stats.videoLoss, lostFrames: stats.totalFramesLost))
	}

	/// `requested` is the maximum bitrate this stream started with
	func result(requested: Int) -> ConnectionCheckResult {
		guard let first = samples.first, let last = samples.last else {
			return ConnectionCheckResult(
				verdict: .inconclusive, title: "Couldn't check the connection",
				detail: "The stream wasn't running long enough. Try again while playing.")
		}
		let averageLoss = samples.map(\.videoLoss).reduce(0, +) / Double(samples.count)
		let lost = max(0, last.lostFrames - first.lostFrames)
		let peak = samples.map(\.bitrateMbps).max() ?? 0
		let framesText = lost == 1 ? "1 frame" : "\(lost) frames"

		if averageLoss >= 0.01 || lost >= 3 {
			// Aim well under what was getting through, so there's headroom for busier scenes
			let basis = peak > 1 ? min(Double(requested), peak) : Double(requested)
			let suggestion = min(requested - 5, max(10, Self.roundDown5(basis * 0.7)))
			var detail = "\(framesText.capitalizedFirst) lost in \(Self.duration) seconds, with the PC sending up to \(Int(peak.rounded())) Mbps."
			if suggestion >= 10, suggestion < requested {
				detail += " Try a maximum of \(suggestion) Mbps."
			} else {
				detail += " The bitrate is already low. Moving closer to the router, 5 GHz Wi-Fi, or a wired connection for the PC should help."
			}
			return ConnectionCheckResult(
				verdict: .tooHigh, title: "Your connection is dropping video", detail: detail,
				bitrateMbps: suggestion >= 10 && suggestion < requested ? suggestion : nil)
		}

		if lost >= 1 {
			let detail = "\(framesText.capitalizedFirst) lost in \(Self.duration) seconds. That's a small hitch now and then, so keep the current bitrate."
			return ConnectionCheckResult(verdict: .minorHiccups, title: "Mostly smooth, a few hiccups", detail: detail)
		}

		// Clean. Only suggest more if the stream actually used most of what was allowed.
		if peak < Double(requested) * 0.6 {
			return ConnectionCheckResult(
				verdict: .inconclusive, title: "No loss, but not a full test",
				detail: "Nothing was lost, but the PC only sent up to \(Int(peak.rounded())) of the \(requested) Mbps allowed. That's normal on menus and quiet scenes. Check again during busy gameplay to see whether a higher bitrate would hold up.")
		}
		if requested < StreamSettings.maxBitrateMbps {
			let suggestion = min(StreamSettings.maxBitrateMbps, Self.roundDown5(Double(requested) * 1.5))
			return ConnectionCheckResult(
				verdict: .roomToGrow, title: "Clean connection",
				detail: "No loss at up to \(requested) Mbps. You could try \(suggestion) Mbps for a sharper picture in busy scenes, then check again.",
				bitrateMbps: suggestion)
		}
		return ConnectionCheckResult(
			verdict: .good, title: "Clean connection",
			detail: "No loss at up to \(requested) Mbps. Your current bitrate is a good fit.")
	}

	private static func roundDown5(_ value: Double) -> Int { Int(value / 5) * 5 }
}

struct ConnectionCheckResult: Equatable {
	enum Verdict { case good, roomToGrow, minorHiccups, tooHigh, inconclusive }

	let verdict: Verdict
	let title: String
	let detail: String
	/// The suggested maximum bitrate, nil where it suggests keeping the current one
	var bitrateMbps: Int?
}

private extension String {
	var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
