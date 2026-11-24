import NVSTKit
import UIKit

/// The touchscreen as a mouse on the game's picture, for launchers, menus and anything else
/// that wants a pointer. Two ways to point:
/// - direct (the whole picture, with a controller): the pointer goes where the finger is.
///   Tap clicks there, drag holds the left button while the pointer follows the finger.
/// - trackpad (the top half, with virtual controls): drag moves the pointer from where it is,
///   like a laptop trackpad. Tap clicks, and tap then drag holds the left button.
/// Both: press and hold, or tap with two fingers, right-clicks; drag with two fingers scrolls.
/// Main thread only.
final class TouchMouse {
	enum Mode { case direct, trackpad }

	enum Event: Equatable {
		/// Where the pointer is, 0...1 across and down the picture
		case move(CGPoint)
		/// Moves the pointer by a fraction of the picture's width and height
		case moveBy(CGVector)
		case button(NVSTMouseButton, pressed: Bool)
		/// Windows wheel units, 120 a notch, positive scrolls up
		case wheel(Int)
	}

	var onEvent: ((Event) -> Void)?
	/// The picture in view coordinates. It extends past the view when zoomed to fill.
	var pictureRect: CGRect = .zero
	/// Change it between gestures (reset() first)
	var mode = Mode.direct

	/// How far a finger can wander and still count as a tap or a hold
	private static let slop: CGFloat = 10
	private static let holdDelay: TimeInterval = 0.5
	/// The longest two-finger touch that still counts as a tap
	private static let twoFingerTapTime: CFTimeInterval = 0.35
	/// Two-finger travel for one wheel notch
	private static let pointsPerNotch: CGFloat = 24
	/// Trackpad: a finger crossing the picture's width moves the pointer this many widths,
	/// since the trackpad is only part of the screen
	private static let trackpadSpeed: CGFloat = 1.5
	/// Trackpad: touching again this soon after a tap and dragging holds the left button
	private static let tapDragWindow: CFTimeInterval = 0.3

	private struct Finger {
		let start: CGPoint
		var location: CGPoint
	}

	private enum Gesture {
		case idle
		/// One finger down: still a tap, a hold or the start of a drag
		case pending
		case dragging
		/// A hold right-clicked; the finger now just moves the pointer
		case held
		case twoFinger(began: CFTimeInterval, centroid: CGPoint, travelled: CGFloat, scrolled: Bool)
		/// Done with this gesture, waiting for the remaining fingers to lift
		case finished
	}

	private var fingers: [ObjectIdentifier: Finger] = [:]
	private var gesture = Gesture.idle
	private var hold: DispatchWorkItem?
	private var wheelRemainder: CGFloat = 0
	private var leftHeld = false
	/// Trackpad: when the last tap lifted, and whether this touch followed one quickly
	private var lastTap: CFTimeInterval = 0
	private var followsTap = false

	/// Takes the touch if it fits the current gesture. Direct mode only starts on the picture.
	func begin(_ id: ObjectIdentifier, at point: CGPoint) -> Bool {
		switch gesture {
		case .idle:
			if mode == .direct {
				guard pictureRect.contains(point) else { return false }
				emit(.move(normalised(point)))
			} else {
				followsTap = CACurrentMediaTime() - lastTap <= Self.tapDragWindow
			}
			fingers[id] = Finger(start: point, location: point)
			gesture = .pending
			scheduleHold(for: id)
			return true
		case .pending:
			// A second finger: scroll or right click, not the first finger's click
			cancelHold()
			fingers[id] = Finger(start: point, location: point)
			gesture = .twoFinger(began: CACurrentMediaTime(), centroid: centroid, travelled: 0, scrolled: false)
			return true
		default:
			return false
		}
	}

	func move(_ id: ObjectIdentifier, to point: CGPoint) {
		guard var finger = fingers[id] else { return }
		let previous = finger.location
		finger.location = point
		fingers[id] = finger
		switch gesture {
		case .pending:
			guard distance(finger.start, point) > Self.slop else { return }
			cancelHold()
			gesture = .dragging
			if mode == .direct {
				// The pointer is still where the finger landed, so the drag starts there
				press(true)
				emit(.move(normalised(point)))
			} else {
				if followsTap { press(true) }
				// Count the travel inside the slop too, so the pointer doesn't lag the finger
				pointerMoved(from: finger.start, to: point)
			}
		case .dragging, .held:
			pointerMoved(from: previous, to: point)
		case .twoFinger(let began, let last, var travelled, var scrolled):
			let now = centroid
			let dy = now.y - last.y
			travelled += hypot(now.x - last.x, dy)
			// Natural scrolling: fingers moving down pull the page down, which is the wheel scrolling up
			wheelRemainder += dy
			let notches = Int(wheelRemainder / Self.pointsPerNotch)
			if notches != 0 {
				wheelRemainder -= CGFloat(notches) * Self.pointsPerNotch
				scrolled = true
				emit(.wheel(notches * 120))
			}
			gesture = .twoFinger(began: began, centroid: now, travelled: travelled, scrolled: scrolled)
		case .idle, .finished:
			break
		}
	}

	func end(_ id: ObjectIdentifier, cancelled: Bool) {
		guard fingers.removeValue(forKey: id) != nil else { return }
		switch gesture {
		case .pending:
			cancelHold()
			if !cancelled {
				click(.left)
				lastTap = CACurrentMediaTime()
			}
		case .dragging:
			press(false)
		case .twoFinger(let began, _, let travelled, let scrolled):
			if !cancelled, !scrolled, travelled <= Self.slop, CACurrentMediaTime() - began <= Self.twoFingerTapTime {
				click(.right)
			}
		case .idle, .held, .finished:
			break
		}
		gesture = fingers.isEmpty ? .idle : .finished
		if fingers.isEmpty { wheelRemainder = 0 }
	}

	/// Forgets every finger and lets go of the left button
	func reset() {
		cancelHold()
		fingers.removeAll()
		gesture = .idle
		wheelRemainder = 0
		lastTap = 0
		followsTap = false
		press(false)
	}

	// MARK: -

	private func pointerMoved(from: CGPoint, to: CGPoint) {
		switch mode {
		case .direct:
			emit(.move(normalised(to)))
		case .trackpad:
			let rect = pictureRect
			guard rect.width > 0, rect.height > 0, from != to else { return }
			emit(.moveBy(CGVector(dx: (to.x - from.x) / rect.width * Self.trackpadSpeed,
				dy: (to.y - from.y) / rect.height * Self.trackpadSpeed)))
		}
	}

	private func scheduleHold(for id: ObjectIdentifier) {
		let work = DispatchWorkItem { [weak self] in
			guard let self, case .pending = self.gesture, self.fingers[id] != nil else { return }
			self.hold = nil
			self.gesture = .held
			self.click(.right)
		}
		hold = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
	}

	private func cancelHold() {
		hold?.cancel()
		hold = nil
	}

	private func press(_ pressed: Bool) {
		guard leftHeld != pressed else { return }
		leftHeld = pressed
		emit(.button(.left, pressed: pressed))
	}

	private func click(_ button: NVSTMouseButton) {
		emit(.button(button, pressed: true))
		emit(.button(button, pressed: false))
	}

	private var centroid: CGPoint {
		guard !fingers.isEmpty else { return .zero }
		let sum = fingers.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.location.x, y: $0.y + $1.location.y) }
		return CGPoint(x: sum.x / CGFloat(fingers.count), y: sum.y / CGFloat(fingers.count))
	}

	private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

	private func normalised(_ point: CGPoint) -> CGPoint {
		let rect = pictureRect
		guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
		return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
			y: min(1, max(0, (point.y - rect.minY) / rect.height)))
	}

	private func emit(_ event: Event) { onEvent?(event) }
}
