import Foundation
import os

/// The app's log: goes to the system log as before, and keeps the recent lines in memory
/// for Settings › Share diagnostics.
///
/// Reading the system log back (OSLogStore) doesn't work in App Store and TestFlight
/// builds: their binaries are encrypted, so iOS can't read the message formats and every
/// line comes out as "<compose failure>". The in-memory copy is plain text.
struct AppLog: Sendable {
	private let logger: Logger
	let category: String

	init(subsystem: String, category: String) {
		logger = Logger(subsystem: subsystem, category: category)
		self.category = category
	}

	func debug(_ message: AppLogMessage) { write(.debug, message.text) }
	func info(_ message: AppLogMessage) { write(.info, message.text) }
	func notice(_ message: AppLogMessage) { write(.notice, message.text) }
	func warning(_ message: AppLogMessage) { write(.warning, message.text) }
	func error(_ message: AppLogMessage) { write(.error, message.text) }
	func fault(_ message: AppLogMessage) { write(.fault, message.text) }

	private func write(_ level: AppLogLevel, _ text: String) {
		switch level {
		case .debug: logger.debug("\(text, privacy: .public)")
		case .info: logger.info("\(text, privacy: .public)")
		case .notice: logger.notice("\(text, privacy: .public)")
		case .warning: logger.warning("\(text, privacy: .public)")
		case .error: logger.error("\(text, privacy: .public)")
		case .fault: logger.fault("\(text, privacy: .public)")
		}
		// Debug lines are too chatty to keep
		guard level != .debug else { return }
		AppLogBuffer.shared.append(AppLogLine(date: Date(), category: category, level: level, text: text))
	}
}

enum AppLogLevel: String, Sendable {
	case debug, info, notice
	case warning = "WARNING"
	case error = "ERROR"
	case fault = "FAULT"
}

struct AppLogLine: Sendable {
	let date: Date
	let category: String
	let level: AppLogLevel
	let text: String
}

/// The last few thousand log lines since the app was opened. Any thread.
final class AppLogBuffer: @unchecked Sendable {
	static let shared = AppLogBuffer()

	private let capacity = 5000
	private let lock = NSLock()
	private var lines: [AppLogLine] = []
	/// Where the oldest line is once the buffer is full
	private var start = 0

	func append(_ line: AppLogLine) {
		lock.withLock {
			if lines.count < capacity {
				lines.append(line)
			} else {
				lines[start] = line
				start = (start + 1) % capacity
			}
		}
	}

	/// Oldest first
	func snapshot() -> [AppLogLine] {
		lock.withLock { Array(lines[start...] + lines[..<start]) }
	}
}

/// Accepts the same `\(value, privacy: .public)` interpolations as `Logger`, so call sites
/// don't change. Everything is kept: the diagnostics report redacts addresses, IDs, keys
/// and your PCs' names before it's shared.
struct AppLogMessage: ExpressibleByStringInterpolation {
	let text: String

	init(stringLiteral value: String) { text = value }
	init(stringInterpolation: Interpolation) { text = stringInterpolation.text }

	struct Interpolation: StringInterpolationProtocol {
		var text = ""
		init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
		mutating func appendLiteral(_ literal: String) { text += literal }
		mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy = .auto) {
			text += String(describing: value)
		}
	}
}
