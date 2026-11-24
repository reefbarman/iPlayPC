import CoreVideo
import Foundation
import QuartzCore

/// The renderer's half of "Smooth network hiccups": an adaptive smoothing buffer.
///
/// Normally a frame is drawn the moment it's decoded, so uneven arrival (Wi-Fi jitter,
/// a clump of frames after a stall) shows as uneven motion. While arrivals are uneven
/// this holds back one or two frames and shows them on a steady clock from its own
/// display link. Once the network has been calm for a while it steps back down, and at
/// zero frames are drawn straight away again, with no added delay. Each frame held back
/// costs one stream frame of delay (about 17 ms at 60 fps).
final class FramePacer {
	static let maxDepth = 2
	/// Uneven gaps within `troubleWindow` that start holding a frame back
	private static let troubleEvents = 3
	private static let troubleWindow: CFTimeInterval = 2
	/// A gap of this many frames is a stall: start holding a frame back right away
	private static let stallFrames: Double = 4
	/// Running dry this often while holding frames back: hold one more
	private static let underrunEvents = 2
	private static let underrunWindow: CFTimeInterval = 3
	/// Calm for this long: hold one frame fewer
	private static let calmTime: CFTimeInterval = 10

	private struct Entry {
		let pixelBuffer: CVPixelBuffer
		var lost: Bool
		let arrival: CFTimeInterval
	}

	/// Draws a frame. Called on the pacer's thread.
	private let render: (CVPixelBuffer, Bool) -> Void

	private let lock = NSLock()
	private var depth = 0
	private var queue: [Entry] = []
	private var interval: CFTimeInterval = 1.0 / 60
	private var screenHz = 60
	private var lastArrival: CFTimeInterval = 0
	private var troubleTimes: [CFTimeInterval] = []
	private var underrunTimes: [CFTimeInterval] = []
	private var lastTrouble: CFTimeInterval = 0
	/// Pacer thread: when the next stream frame is due on screen
	private var nextDue: CFTimeInterval = 0
	/// Wait for a cushion before showing the next frame (at the start and after running dry)
	private var rebuffer = true
	private var stopped = false
	private var thread: Thread?

	/// Stats: frames dropped to keep the delay bounded, and times the buffer ran dry
	private var droppedFrames = 0
	private var underruns = 0

	init(render: @escaping (CVPixelBuffer, Bool) -> Void) {
		self.render = render
	}

	deinit {
		stop()
	}

	/// Frames currently being held back (0...maxDepth)
	var currentDepth: Int { lock.withLock { depth } }
	var stats: (dropped: Int, underruns: Int) { lock.withLock { (droppedFrames, underruns) } }

	func configure(fps: Int, screenHz: Int) {
		let restart = lock.withLock { () -> Bool in
			interval = 1.0 / Double(max(fps, 1))
			let changed = self.screenHz != screenHz
			self.screenHz = screenHz
			return changed && thread != nil
		}
		if restart {
			stop()
		}
		start()
	}

	/// Forget the previous connection's timing (the gap before its first frame isn't a stall)
	func reset() {
		lock.withLock {
			depth = 0
			queue.removeAll()
			lastArrival = 0
			troubleTimes.removeAll()
			underrunTimes.removeAll()
			lastTrouble = 0
			rebuffer = true
		}
	}

	func stop() {
		let thread = lock.withLock { () -> Thread? in
			stopped = true
			queue.removeAll()
			let thread = self.thread
			self.thread = nil
			return thread
		}
		thread?.cancel()
	}

	private func start() {
		lock.withLock {
			guard thread == nil else { return }
			stopped = false
			let hz = screenHz
			let thread = Thread { [weak self] in self?.runLoop(screenHz: hz) }
			thread.name = "iPlayNow frame pacer"
			thread.qualityOfService = .userInteractive
			self.thread = thread
			thread.start()
		}
	}

	// MARK: - Video thread

	/// Hands a decoded frame over. Returns false when nothing is being held back: the
	/// caller draws it straight away, as without smoothing.
	func submit(_ pixelBuffer: CVPixelBuffer, lost: Bool) -> Bool {
		let now = CACurrentMediaTime()
		return lock.withLock { () -> Bool in
			guard thread != nil, !stopped else { return false }
			noteArrival(now)
			guard depth > 0 else {
				// Just stepped down to zero: anything still held is older than this frame
				queue.removeAll()
				return false
			}
			queue.append(Entry(pixelBuffer: pixelBuffer, lost: lost, arrival: now))
			// Never hold more than one frame beyond the target, so the delay stays bounded
			// (a clump after a stall skips ahead instead of playing out late)
			while queue.count > depth + 1 {
				dropOldest()
			}
			return true
		}
	}

	/// Watches the gaps between frames and steps the depth. Lock held.
	private func noteArrival(_ now: CFTimeInterval) {
		defer { lastArrival = now }
		guard lastArrival > 0 else { return }
		let gap = now - lastArrival
		let uneven = gap > interval * 1.5 || gap < interval * 0.5
		if uneven {
			lastTrouble = now
			troubleTimes.append(now)
			troubleTimes.removeAll { now - $0 > Self.troubleWindow }
			let stall = gap > interval * Self.stallFrames
			if depth == 0, stall || troubleTimes.count >= Self.troubleEvents {
				setDepth(1, reason: stall ? "a \(Int(gap * 1000)) ms stall" : "uneven frame arrival")
				troubleTimes.removeAll()
			}
		} else if depth > 0, lastTrouble > 0, now - lastTrouble > Self.calmTime {
			lastTrouble = now
			setDepth(depth - 1, reason: "calm for \(Int(Self.calmTime)) s")
		}
	}

	/// Lock held
	private func setDepth(_ new: Int, reason: String) {
		guard new != depth else { return }
		log.notice("Network smoothing: holding back \(new) frame(s) (\(reason, privacy: .public))")
		depth = new
		rebuffer = true
	}

	/// Lock held. A dropped frame's loss flag moves to the next one, so the renderer
	/// still knows frames are missing before it.
	private func dropOldest() {
		let dropped = queue.removeFirst()
		droppedFrames += 1
		if dropped.lost, !queue.isEmpty { queue[0].lost = true }
	}

	// MARK: - Pacer thread

	private func runLoop(screenHz: Int) {
		let target = LinkTarget(self)
		let link = CADisplayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
		let hz = Float(screenHz)
		link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, hz), maximum: hz, preferred: hz)
		link.add(to: .current, forMode: .default)
		while !Thread.current.isCancelled {
			_ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
		}
		link.invalidate()
	}

	fileprivate func tick(_ link: CADisplayLink) {
		let shows = link.targetTimestamp
		let refresh = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
		let next = lock.withLock { () -> Entry? in
			guard depth > 0 else { return nil }
			guard let head = queue.first else {
				// Ran dry: a frame was due and none had arrived
				if !rebuffer, shows > nextDue + interval * 0.5 {
					rebuffer = true
					underruns += 1
					lastTrouble = shows
					underrunTimes.append(shows)
					underrunTimes.removeAll { shows - $0 > Self.underrunWindow }
					if underrunTimes.count >= Self.underrunEvents, depth < Self.maxDepth {
						setDepth(depth + 1, reason: "ran dry \(underrunTimes.count) times")
						underrunTimes.removeAll()
					}
				}
				return nil
			}
			if rebuffer {
				// Start the clock so this frame goes out `depth` frames after it arrived
				nextDue = head.arrival + interval * Double(depth)
				rebuffer = false
			}
			// Not due yet (with half a refresh of slack so it lands on the nearest one)
			guard shows + refresh / 2 >= nextDue else { return nil }
			nextDue += interval
			// Far behind the clock (e.g. the app was busy): start it again from now
			if nextDue < shows - interval { nextDue = shows }
			return queue.removeFirst()
		}
		if let next {
			render(next.pixelBuffer, next.lost)
		}
	}

	/// CADisplayLink retains its target
	private final class LinkTarget {
		weak var pacer: FramePacer?
		init(_ pacer: FramePacer) { self.pacer = pacer }
		@objc func tick(_ link: CADisplayLink) {
			guard let pacer else {
				link.invalidate()
				return
			}
			pacer.tick(link)
		}
	}
}
