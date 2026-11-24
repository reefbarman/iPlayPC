import SceneKit
import SwiftUI

/// Shows `ControllerScene`, redrawn every frame so rumble and easing animate smoothly.
/// Dragging turns the controller to look at it from another side; it eases back when let go.
/// On a DualSense, fingers that land on its touchpad draw on it instead, and a quick tap clicks it.
struct ControllerSceneView: UIViewRepresentable {
	let model: ControllerScene.Model
	let state: ControllerScene.State
	var onTouch: (PadTouch) -> Void = { _ in }

	/// A finger on the touchpad on screen, 0...1 across and down. Slots are 0 and 1.
	enum PadTouch {
		case down(slot: Int, x: Float, y: Float)
		case move(slot: Int, x: Float, y: Float)
		case up(slot: Int)
		/// A quick tap: click the touchpad where the finger is
		case tap(slot: Int)
	}

	final class Coordinator: NSObject, UIGestureRecognizerDelegate {
		var controller: ControllerScene?
		private var dragStart = SIMD2<Float>.zero

		func load(_ model: ControllerScene.Model, into view: TouchView) {
			guard controller?.model != model else { return }
			controller = Bundle.main.url(forResource: model.resourceName, withExtension: "usdz")
				.flatMap { ControllerScene(model: model, url: $0) }
			view.controller = controller
			view.scene = controller?.scene
			view.pointOfView = controller?.cameraNode
			view.delegate = controller
			view.rendersContinuously = controller != nil
			view.isPlaying = controller != nil
		}

		@objc func pan(_ gesture: UIPanGestureRecognizer) {
			guard let controller else { return }
			switch gesture.state {
			case .began:
				dragStart = controller.dragAngles
				fallthrough
			case .changed:
				let t = gesture.translation(in: gesture.view)
				var angles = dragStart + SIMD2(Float(t.x), Float(t.y)) * 0.01
				angles.y = min(max(angles.y, -1.3), 1.3)
				controller.drag = angles
			default:
				controller.drag = nil
			}
		}

		/// A drag that starts on the touchpad is a finger on it, not a turn
		func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
			guard let view = gesture.view as? TouchView else { return true }
			return !view.isOnTouchpad(gesture.location(in: view))
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeUIView(context: Context) -> TouchView {
		let view = TouchView()
		view.backgroundColor = .clear
		view.antialiasingMode = .multisampling4X
		view.preferredFramesPerSecond = 60
		view.isMultipleTouchEnabled = true
		let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
		pan.delegate = context.coordinator
		view.addGestureRecognizer(pan)
		context.coordinator.load(model, into: view)
		return view
	}

	func updateUIView(_ view: TouchView, context: Context) {
		context.coordinator.load(model, into: view)
		context.coordinator.controller?.state = state
		view.onTouch = onTouch
	}

	static func dismantleUIView(_ view: TouchView, coordinator: Coordinator) {
		view.isPlaying = false
		view.rendersContinuously = false
	}

	/// Tracks up to two fingers that start on the touchpad
	final class TouchView: SCNView {
		weak var controller: ControllerScene?
		var onTouch: ((PadTouch) -> Void)?

		// The same rules as tapping the stream
		private static let tapMaxDuration: TimeInterval = 0.25
		private static let tapMaxMovement: CGFloat = 12

		private struct Tracked {
			let slot: Int
			let start: CGPoint
			let time: TimeInterval
			var moved = false
		}

		private var tracked: [ObjectIdentifier: Tracked] = [:]

		/// On the touchpad, 0...1. A finger has to land on the pad, give or take a little,
		/// but can slide off its edge.
		private func padPoint(_ p: CGPoint, starting: Bool) -> SIMD2<Float>? {
			guard let pad = controller?.touchpadPoint(p, in: self) else { return nil }
			if starting, pad.x < -0.06 || pad.x > 1.06 || pad.y < -0.1 || pad.y > 1.1 { return nil }
			return simd_clamp(pad, .zero, SIMD2(1, 1))
		}

		func isOnTouchpad(_ p: CGPoint) -> Bool { padPoint(p, starting: true) != nil }

		override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
			for touch in touches {
				let used = Set(tracked.values.map(\.slot))
				guard let slot = [0, 1].first(where: { !used.contains($0) }) else { continue }
				let p = touch.location(in: self)
				guard let pad = padPoint(p, starting: true) else { continue }
				tracked[ObjectIdentifier(touch)] = Tracked(slot: slot, start: p, time: touch.timestamp)
				onTouch?(.down(slot: slot, x: pad.x, y: pad.y))
			}
		}

		override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
			for touch in touches {
				let key = ObjectIdentifier(touch)
				guard var t = tracked[key] else { continue }
				let p = touch.location(in: self)
				if !t.moved, hypot(p.x - t.start.x, p.y - t.start.y) > Self.tapMaxMovement {
					t.moved = true
					tracked[key] = t
				}
				guard let pad = padPoint(p, starting: false) else { continue }
				onTouch?(.move(slot: t.slot, x: pad.x, y: pad.y))
			}
		}

		override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
			finish(touches, allowsTap: true)
		}

		override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
			finish(touches, allowsTap: false)
		}

		private func finish(_ touches: Set<UITouch>, allowsTap: Bool) {
			for touch in touches {
				guard let t = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
				let p = touch.location(in: self)
				if allowsTap, !t.moved, hypot(p.x - t.start.x, p.y - t.start.y) <= Self.tapMaxMovement,
				   touch.timestamp - t.time <= Self.tapMaxDuration {
					onTouch?(.tap(slot: t.slot))
				} else {
					onTouch?(.up(slot: t.slot))
				}
			}
		}
	}
}
