import CoreGraphics
import Foundation
import SceneKit
import simd

/// The 3D controller in the Controller Test, an Xbox controller or a DualSense: lights up and
/// moves what's pressed, turns with the controller's motion (or a drag) and shows the
/// feedback that's playing.
///
/// The models are App/Resources/XboxController.usdz and DualSense.usdz, made by the scripts in
/// scripts/controller-model: +X right, +Y towards the triggers, +Z out of the face, 2 units
/// across. USD turns the `-` in the original part names into `_`.
///
/// Only SceneKit and Core Graphics, so scripts/controller-model/preview can render it on a Mac.
final class ControllerScene: NSObject, SCNSceneRendererDelegate {
	enum Model {
		case xbox, dualSense

		var resourceName: String {
			switch self {
			case .xbox: "XboxController"
			case .dualSense: "DualSense"
			}
		}
	}

	/// Named by where they are on an Xbox controller: `a` is the bottom face button (Cross),
	/// `view` is Create, `home` the Xbox or PS button
	enum Control: Hashable, CaseIterable {
		case a, b, x, y, up, down, left, right
		case lb, rb, leftStick, rightStick, view, menu, share, home, touchpad
	}

	enum TriggerLook { case off, resistance, weapon, vibration }

	/// A finger on the touchpad, 0...1 across and down
	struct Touch {
		var x: Float
		var y: Float
		/// Touching the touchpad on screen rather than the controller's own
		var fromScreen: Bool
	}

	struct Buzz {
		var left: Float
		var right: Float
		var hz: Double
	}

	struct State {
		var pressed: Set<Control> = []
		/// -1...1, +y down
		var leftStick = SIMD2<Float>.zero
		var rightStick = SIMD2<Float>.zero
		var lt: Float = 0
		var rt: Float = 0
		/// How the controller has turned, in the model's axes
		var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
		var touches: [Touch] = []
		var lightbar: CGColor?
		var player: Int?
		var triggerLook = TriggerLook.off
		/// The motors in the left and right triggers, 0...1
		var triggerRumble = SIMD2<Float>.zero
		var buzz: Buzz?
	}

	let model: Model
	let scene = SCNScene()

	/// Set from any thread; applied every frame
	var state: State {
		get { lock.withLock { pending } }
		set { lock.withLock { pending = newValue } }
	}

	/// Turning the model by dragging it, in radians (x turns it left and right, y tips it).
	/// nil once the finger lifts, and it eases back to front-on.
	var drag: SIMD2<Float>? {
		get { lock.withLock { pendingDrag } }
		set { lock.withLock { pendingDrag = newValue } }
	}

	/// Where the drag has left the model, for the next drag to carry on from
	var dragAngles: SIMD2<Float> { lock.withLock { shownDrag } }

	private let lock = NSLock()
	private var pending = State()
	private var pendingDrag: SIMD2<Float>?
	private var shownDrag = SIMD2<Float>.zero

	/// Turned by the controller's orientation
	private let rig = SCNNode()
	/// Shaken by rumble and haptics
	private let shaker = SCNNode()
	private let root: SCNNode
	private let look: Look

	private struct Part {
		let nodes: [SCNNode]
		let rest: [simd_float4x4]
		/// Lit up when pressed
		let materials: [SCNMaterial]
	}

	private var controls: [Control: Part] = [:]
	private var sticks: [Part] = []
	private var stickPivots: [SIMD3<Float>] = []
	private var triggers: [Part] = []
	private var triggerHinges: [SIMD3<Float>] = []
	private var lightbar: [SCNMaterial] = []
	private var touchpadGeometry: SCNNode?
	private var fingers: [SCNNode] = []
	private var playerLights: [SCNNode] = []
	private var ripples: [SCNNode] = []
	/// Glows behind the shoulder buttons and triggers, which hide behind the controller when it faces you
	private var halos: [SCNNode] = []
	/// A layer shaped to the touchpad's surface, shown when it's clicked
	private var padLight: SCNNode?
	private var padLightLevel: Float = 0
	private var lastTime: TimeInterval?

	/// Where fingers have been lately, fading out
	private struct TrailPoint {
		var x: Float
		var y: Float
		var time: TimeInterval
		var fromScreen: Bool
	}

	private var trail: [TrailPoint] = []
	private var trailDots: [SCNNode] = []
	/// Where each finger last left a trail point
	private var trailEnds: [SIMD2<Float>?] = []
	private static let trailSeconds: TimeInterval = 1.5

	// MARK: - Colours

	private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
		CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
	}

	/// A model's colours
	private struct Look {
		let shell: CGColor
		/// What the shoulders and triggers turn when pressed and pulled
		let pressed: CGColor
		/// The glow on sticks, the d-pad and the small buttons
		let accent: CGColor
		/// What each face button glows
		let faces: [Control: CGColor]
	}

	private static let looks: [Model: Look] = [
		.xbox: Look(
			shell: rgb(0.16, 0.165, 0.175), pressed: rgb(0.06, 0.75, 0.25), accent: rgb(0.06, 0.75, 0.25),
			faces: [.a: rgb(0.3, 0.8, 0.2), .b: rgb(0.95, 0.2, 0.2), .x: rgb(0.15, 0.5, 1), .y: rgb(1, 0.78, 0.1)]),
		.dualSense: Look(
			shell: rgb(0.92, 0.92, 0.94), pressed: rgb(0.1, 0.42, 1), accent: rgb(0.2, 0.5, 1),
			faces: [.y: rgb(0.2, 0.85, 0.7), .b: rgb(1, 0.3, 0.35), .a: rgb(0.4, 0.6, 1), .x: rgb(0.95, 0.45, 0.85)]),
	]

	private static let black = rgb(0.05, 0.055, 0.065)
	private static let key = rgb(0.14, 0.145, 0.16)
	private static let stick = rgb(0.11, 0.115, 0.125)
	private static let symbol = rgb(0.72, 0.73, 0.77)
	private static let lightbarOff = rgb(0.55, 0.57, 0.62)
	// Xbox
	private static let xboxBack = rgb(0.11, 0.115, 0.12)
	private static let xboxBlack = rgb(0.035, 0.037, 0.042)
	private static let xboxKey = rgb(0.07, 0.072, 0.08)
	private static let xboxStick = rgb(0.06, 0.062, 0.068)
	private static let xboxSymbol = rgb(0.8, 0.81, 0.84)
	private static let xboxLogo = rgb(0.85, 0.86, 0.88)
	/// The Xbox face buttons' letters glow a little at rest, to read through their smoky caps
	private static let letterGlow: CGFloat = 0.35
	/// Fingers on the touchpad on screen, and on the controller's own
	private static let screenFinger = rgb(0.1, 0.75, 1)
	private static let padFinger = rgb(1, 0.55, 0.1)
	private static let effectColours: [TriggerLook: CGColor] = [
		.resistance: rgb(1, 0.55, 0.1), .weapon: rgb(1, 0.35, 0.1), .vibration: rgb(0.65, 0.3, 1),
	]

	private static func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
		let space = CGColorSpace(name: CGColorSpace.sRGB)!
		guard let ca = a.converted(to: space, intent: .defaultIntent, options: nil)?.components,
			  let cb = b.converted(to: space, intent: .defaultIntent, options: nil)?.components,
			  ca.count >= 3, cb.count >= 3
		else { return t < 0.5 ? a : b }
		let t = min(max(t, 0), 1)
		return rgb(ca[0] + (cb[0] - ca[0]) * t, ca[1] + (cb[1] - ca[1]) * t, ca[2] + (cb[2] - ca[2]) * t)
	}

	private static func material(_ colour: CGColor, roughness: CGFloat, metalness: CGFloat = 0) -> SCNMaterial {
		let m = SCNMaterial()
		m.lightingModel = .physicallyBased
		m.diffuse.contents = colour
		m.roughness.contents = roughness
		m.metalness.contents = metalness
		m.emission.contents = CGColor(gray: 0, alpha: 1)
		return m
	}

	// MARK: - Setup

	init?(model: Model, url: URL) {
		guard let source = try? SCNScene(url: url, options: nil), let look = Self.looks[model] else { return nil }
		self.model = model
		self.look = look
		root = SCNNode()
		for child in source.rootNode.childNodes { root.addChildNode(child) }
		super.init()

		scene.rootNode.addChildNode(rig)
		rig.addChildNode(shaker)
		shaker.addChildNode(root)
		setUpLighting()
		switch model {
		case .xbox:
			setUpXboxMaterials()
			setUpXboxControls()
		case .dualSense:
			setUpDualSenseMaterials()
			setUpDualSenseControls()
			setUpDualSenseOverlays()
		}
		setUpSticksAndTriggers()
		setUpHalosAndRipples()
	}

	private func node(_ name: String) -> SCNNode? {
		root.childNode(withName: name, recursively: true)
	}

	/// The nodes under `name` that have geometry
	private func geometryNodes(_ name: String) -> [SCNNode] {
		guard let found = node(name) else { return [] }
		var nodes: [SCNNode] = []
		found.enumerateHierarchy { n, _ in if n.geometry != nil { nodes.append(n) } }
		return nodes
	}

	@discardableResult
	private func paint(_ names: [String], _ make: @autoclosure () -> SCNMaterial) -> [SCNMaterial] {
		var made: [SCNMaterial] = []
		for name in names {
			for n in geometryNodes(name) {
				let m = make()
				n.geometry?.materials = [m]
				made.append(m)
			}
		}
		return made
	}

	private func part(_ names: [String]) -> Part {
		let nodes = names.compactMap(node)
		var materials: [SCNMaterial] = []
		for name in names {
			for n in geometryNodes(name) { materials += n.geometry?.materials ?? [] }
		}
		return Part(nodes: nodes, rest: nodes.map(\.simdTransform), materials: materials)
	}

	private var stickNames: [(stem: String, cap: String)] {
		[("LeftThumb", "Joystick_Left_Ring"), ("RightThumb", "Joystick_Right_Ring")]
	}

	private let triggerNames = ["Shoulder_Left_Trigger", "Shoulder_Right_Trigger"]

	// Xbox

	private func setUpXboxMaterials() {
		paint(["MainBody", "MainBodyTop", "LeftShoulder", "RightShoulder"], Self.material(look.shell, roughness: 0.5))
		paint(["MainBodyBack", "MainBodySide", "BatteryDoor", "BatteryDoorInner"], Self.material(Self.xboxBack, roughness: 0.65))
		paint(triggerNames, Self.material(look.shell, roughness: 0.4))
		paint(["USBPortInner", "USBPortOuter"], Self.material(Self.xboxBlack, roughness: 0.5))
		paint(["Joystick_Left_Ring", "Joystick_Right_Ring"], Self.material(Self.xboxStick, roughness: 0.85))
		paint(["LeftThumb", "RightThumb"], Self.material(Self.xboxStick, roughness: 0.6))
		paint(["DPadUp", "DPadDown", "DPadLeft", "DPadRight", "Back", "Start", "ShareButton", "LogoOuter"],
			Self.material(Self.xboxKey, roughness: 0.3))
		paint(["BackSymbol", "StartSymbol", "ShareButtonSymbol"], Self.material(Self.xboxSymbol, roughness: 0.4))
		paint(["LogoInner"], Self.material(Self.xboxLogo, roughness: 0.15, metalness: 0.6))
		// Face buttons: coloured letters inside glossy, nearly clear caps
		let caps = ["A_Button", "B_Button", "X_Button", "Y_Button",
					"A_Interior2", "B_Interior2", "X_Interior2", "Y_Interior2"]
		paint(caps, Self.capMaterial())
		// See-through: draw after the letters inside them
		for name in caps { geometryNodes(name).forEach { $0.renderingOrder = 5 } }
		paint(["A_Interior", "B_Interior", "X_Interior", "Y_Interior"], Self.material(Self.xboxBlack, roughness: 0.3))
		for (name, control) in [("A", Control.a), ("B", .b), ("X", .x), ("Y", .y)] {
			let colour = look.faces[control] ?? Self.xboxSymbol
			let m = Self.material(colour, roughness: 0.3)
			m.isDoubleSided = true
			m.emission.contents = colour
			m.emission.intensity = Self.letterGlow
			paint([name], m)
		}
	}

	private static func capMaterial() -> SCNMaterial {
		let m = material(xboxBlack, roughness: 0.08)
		// Any more and the letters disappear
		m.transparency = 0.08
		m.transparencyMode = .dualLayer
		m.writesToDepthBuffer = false
		return m
	}

	private func setUpXboxControls() {
		// The letter first: it keeps a glow at rest
		func face(_ n: String) -> Part { part([n, "\(n)_Button", "\(n)_Interior", "\(n)_Interior2"]) }
		controls = [
			.a: face("A"), .b: face("B"), .x: face("X"), .y: face("Y"),
			.up: part(["DPadUp"]), .down: part(["DPadDown"]), .left: part(["DPadLeft"]), .right: part(["DPadRight"]),
			.lb: part(["LeftShoulder"]),
			.rb: part(["RightShoulder"]),
			.view: part(["Back", "BackSymbol"]),
			.menu: part(["Start", "StartSymbol"]),
			.share: part(["ShareButton", "ShareButtonSymbol"]),
			.home: part(["LogoOuter", "LogoInner"]),
		]
	}

	// DualSense

	private func setUpDualSenseMaterials() {
		paint(["MainBody", "MainBodyBack", "Touchpad", "LeftShoulder", "RightShoulder"] + triggerNames,
			Self.material(look.shell, roughness: 0.45))
		paint(["MainBodyFront", "Joystick_Left_Ring", "Joystick_Right_Ring", "B1", "B2", "B3", "B4",
			"AudioJack", "Charger", "USBPort", "LED3"], Self.material(Self.black, roughness: 0.55))
		paint(["LeftThumb", "RightThumb"], Self.material(Self.stick, roughness: 0.75))
		paint(["Special"], Self.material(Self.black, roughness: 0.2, metalness: 0.3))
		paint(["B1Button", "B2Button", "B3Button", "B4Button", "DPadUp", "DPadDown", "DPadLeft", "DPadRight",
			"DPadUpCover", "DPadDownCover", "DPadLeftCover", "DPadRightCover", "Back", "Start"],
			Self.material(Self.key, roughness: 0.3))
		paint(["B1ButtonSymbol", "B2ButtonSymbol", "B3ButtonSymbol", "B4ButtonSymbol", "DPadUpArrow", "DPadDownArrow",
			"DPadLeftArrow", "DPadRightArrow", "ShareSymbol", "MenuSymbol"], Self.material(Self.symbol, roughness: 0.4))
		lightbar = paint(["LED1", "LED2"], Self.material(Self.lightbarOff, roughness: 0.25))
	}

	private func setUpDualSenseControls() {
		// B1..B4 are Cross, Circle, Square and Triangle
		controls = [
			.a: part(["B1Button", "B1ButtonSymbol"]),
			.b: part(["B2Button", "B2ButtonSymbol"]),
			.x: part(["B3Button", "B3ButtonSymbol"]),
			.y: part(["B4Button", "B4ButtonSymbol"]),
			.up: part(["DPadUp", "DPadUpCover", "DPadUpArrow"]),
			.down: part(["DPadDown", "DPadDownCover", "DPadDownArrow"]),
			.left: part(["DPadLeft", "DPadLeftCover", "DPadLeftArrow"]),
			.right: part(["DPadRight", "DPadRightCover", "DPadRightArrow"]),
			.lb: part(["LeftShoulder"]),
			.rb: part(["RightShoulder"]),
			.view: part(["Back", "ShareSymbol"]),
			.menu: part(["Start", "MenuSymbol"]),
			.home: part(["Special"]),
			.touchpad: part(["Touchpad"]),
		]
		touchpadGeometry = geometryNodes("Touchpad").first
	}

	/// Fingers on the touchpad, its click light and trail, and the player lights
	private func setUpDualSenseOverlays() {
		for _ in 0..<4 {
			let dot = SCNNode(geometry: SCNSphere(radius: 0.022))
			dot.geometry?.materials = [Self.material(look.accent, roughness: 0.3)]
			dot.scale = SCNVector3(1, 1, 0.35)
			dot.isHidden = true
			root.addChildNode(dot)
			fingers.append(dot)
		}
		// The top row of dots under the touchpad
		let front = geometryNodes("MainBodyFront")
		for i in 0..<5 {
			let x = Float(i - 2) * 0.041
			let y: Float = 0.15
			var z: Float = 0.28
			for n in front {
				let from = root.convertPosition(SCNVector3(x, y, 1), to: n)
				let to = root.convertPosition(SCNVector3(x, y, -1), to: n)
				if let hit = n.hitTestWithSegment(from: from, to: to, options: nil).first {
					z = Float(root.convertPosition(hit.localCoordinates, from: n).z)
					break
				}
			}
			let light = SCNNode(geometry: SCNSphere(radius: 0.009))
			let m = Self.material(CGColor(gray: 1, alpha: 1), roughness: 0.2)
			m.emission.contents = CGColor(gray: 1, alpha: 1)
			m.emission.intensity = 2
			light.geometry?.materials = [m]
			light.simdPosition = SIMD3(x, y, z + 0.002)
			light.scale = SCNVector3(1, 1, 0.4)
			light.isHidden = true
			root.addChildNode(light)
			playerLights.append(light)
		}
		if let pad = touchpadGeometry {
			padLight = makePadLight(pad)
			for _ in 0..<160 {
				let plane = SCNPlane(width: 0.05, height: 0.05)
				plane.materials = [Self.overlayMaterial(look.accent, mask: Self.glowImage)]
				let dot = SCNNode(geometry: plane)
				dot.renderingOrder = 11
				dot.isHidden = true
				root.addChildNode(dot)
				trailDots.append(dot)
			}
		}
	}

	// Both

	private func setUpSticksAndTriggers() {
		// Sticks tip over from their base, cap and all
		for (stem, cap) in stickNames {
			let p = part([stem, cap])
			sticks.append(p)
			let (lo, _) = p.nodes.first?.boundingBox ?? (SCNVector3Zero, SCNVector3Zero)
			let base = p.nodes.first.map { $0.simdPosition + SIMD3(0, 0, Float(lo.z)) } ?? .zero
			stickPivots.append(base)
		}
		// Triggers swing from the top of the trigger, towards the face
		for name in triggerNames {
			let p = part([name])
			triggers.append(p)
			let (_, hi) = p.nodes.first?.boundingBox ?? (SCNVector3Zero, SCNVector3Zero)
			let hinge = p.nodes.first.map { $0.simdPosition + SIMD3(0, Float(hi.y), 0) } ?? .zero
			triggerHinges.append(hinge)
		}
	}

	/// Glows behind the shoulder buttons and triggers, and rumble ripples
	private func setUpHalosAndRipples() {
		let (shoulderBack, triggerBack): (Float, Float) = model == .xbox ? (0.08, 0.12) : (0.05, 0.2)
		// Behind and above each shoulder button and trigger, so the glow shows over the top edge
		for (name, back, size) in [("LeftShoulder", shoulderBack, CGFloat(0.75)), ("RightShoulder", shoulderBack, 0.75),
								   (triggerNames[0], triggerBack, 0.9), (triggerNames[1], triggerBack, 0.9)] {
			let plane = SCNPlane(width: size, height: size)
			let m = SCNMaterial()
			m.lightingModel = .constant
			m.diffuse.contents = Self.glowImage
			m.multiply.contents = look.pressed
			m.blendMode = .add
			m.writesToDepthBuffer = false
			m.isDoubleSided = true
			plane.materials = [m]
			let halo = SCNNode(geometry: plane)
			halo.simdPosition = (node(name)?.simdPosition ?? .zero) + SIMD3(0, 0.06, -back)
			halo.constraints = [SCNBillboardConstraint()]
			halo.renderingOrder = 10
			halo.opacity = 0
			root.addChildNode(halo)
			halos.append(halo)
		}
		let (y, z): (Float, Float) = model == .xbox ? (-0.3, 0.3) : (-0.22, 0.4)
		for x: Float in [-0.62, 0.62] {
			for _ in 0..<2 {
				let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.1, pipeRadius: 0.006))
				let m = Self.material(look.accent, roughness: 0.3)
				m.emission.contents = look.accent
				m.emission.intensity = 1.5
				ring.geometry?.materials = [m]
				ring.simdPosition = SIMD3(x, y, z)
				ring.eulerAngles.x = .pi / 2
				ring.isHidden = true
				shaker.addChildNode(ring)
				ripples.append(ring)
			}
		}
	}

	private func setUpLighting() {
		scene.lightingEnvironment.contents = Self.studio()
		scene.lightingEnvironment.intensity = model == .xbox ? 1.6 : 1.3

		let key = SCNNode()
		key.light = SCNLight()
		key.light?.type = .directional
		key.light?.intensity = model == .xbox ? 900 : 650
		key.light?.color = CGColor(gray: 1, alpha: 1)
		key.eulerAngles = SCNVector3(-0.7, -0.5, 0)
		scene.rootNode.addChildNode(key)

		if model == .xbox {
			// A cool rim from behind and above, so the dark shell's outline shows on a dark background
			let rim = SCNNode()
			rim.light = SCNLight()
			rim.light?.type = .directional
			rim.light?.intensity = 500
			rim.light?.color = CGColor(srgbRed: 0.8, green: 0.88, blue: 1, alpha: 1)
			rim.eulerAngles = SCNVector3(-2.4, 0.4, 0)
			scene.rootNode.addChildNode(rim)
		}

		let camera = SCNCamera()
		camera.fieldOfView = 26
		camera.zNear = 0.1
		camera.zFar = 20
		camera.wantsHDR = true
		// Only emissive parts are bright enough to bloom
		camera.bloomIntensity = 0.8
		camera.bloomThreshold = 1.05
		camera.bloomBlurRadius = 8
		camera.wantsExposureAdaptation = false
		let cameraNode = SCNNode()
		cameraNode.camera = camera
		cameraNode.position = SCNVector3(0, 0.05, 3.9)
		cameraNode.look(at: SCNVector3(0, 0.03, 0))
		cameraNode.name = "camera"
		scene.rootNode.addChildNode(cameraNode)
	}

	var cameraNode: SCNNode? { scene.rootNode.childNode(withName: "camera", recursively: false) }

	/// Solid colour laid over the model, faded out by the mask's alpha
	private static func overlayMaterial(_ colour: CGColor, mask: CGImage?) -> SCNMaterial {
		let m = SCNMaterial()
		m.lightingModel = .constant
		m.diffuse.contents = colour
		m.transparent.contents = mask
		m.transparencyMode = .aOne
		m.blendMode = .alpha
		m.writesToDepthBuffer = false
		return m
	}

	/// A grid that follows the touchpad's curved top just above it, so lighting it up covers the pad
	/// exactly. (Tinting the pad itself shows the ragged edge it was cut from the shell with.)
	private func makePadLight(_ pad: SCNNode) -> SCNNode {
		let columns = 32
		let rows = 16
		var vertices: [SCNVector3] = []
		var uvs: [CGPoint] = []
		for r in 0...rows {
			for c in 0...columns {
				let u = Float(c) / Float(columns)
				let v = Float(r) / Float(rows)
				var p = padSurface(pad, x: u, y: v)
				p.z += 0.003
				vertices.append(p)
				uvs.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
			}
		}
		var indices: [UInt16] = []
		for r in 0..<rows {
			for c in 0..<columns {
				let a = UInt16(r * (columns + 1) + c)
				let b = a + 1
				let d = a + UInt16(columns + 1)
				let e = d + 1
				indices += [a, d, b, b, d, e]
			}
		}
		let geometry = SCNGeometry(
			sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uvs)],
			elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
		let m = Self.overlayMaterial(look.pressed, mask: Self.padMask)
		m.isDoubleSided = true
		geometry.materials = [m]
		let node = SCNNode(geometry: geometry)
		node.renderingOrder = 10
		node.isHidden = true
		root.addChildNode(node)
		return node
	}

	/// The touchpad's outline, rounded at the corners and soft at the edges
	private static let padMask: CGImage? = {
		let w = 256
		let h = 128
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		ctx.setFillColor(CGColor(gray: 1, alpha: 1))
		ctx.setShadow(offset: .zero, blur: 6, color: CGColor(gray: 1, alpha: 1))
		ctx.addPath(CGPath(roundedRect: CGRect(x: 5, y: 5, width: w - 10, height: h - 10), cornerWidth: 22, cornerHeight: 22, transform: nil))
		ctx.fillPath()
		return ctx.makeImage()
	}()

	/// A soft round glow, fading to nothing at the edge (black as well as clear, for adding)
	private static let glowImage: CGImage? = {
		let size = 128
		guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
			let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
				colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 0, alpha: 0)] as CFArray,
				locations: [0, 0.35, 1])
		else { return nil }
		let c = CGPoint(x: size / 2, y: size / 2)
		ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
		return ctx.makeImage()
	}()

	/// A soft studio for reflections: bright overhead, a couple of softboxes, dark floor
	private static func studio() -> CGImage? {
		let w = 512
		let h = 256
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
		else { return nil }
		let colours = [rgb(0.95, 0.96, 1), rgb(0.5, 0.52, 0.56), rgb(0.12, 0.12, 0.13)] as CFArray
		if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 0.5, 1]) {
			// Core Graphics' origin is at the bottom
			ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
		}
		ctx.setFillColor(CGColor(gray: 1, alpha: 1))
		ctx.fill(CGRect(x: 60, y: 170, width: 90, height: 50))
		ctx.fill(CGRect(x: 300, y: 180, width: 140, height: 40))
		ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
		ctx.fill(CGRect(x: 200, y: 140, width: 60, height: 30))
		return ctx.makeImage()
	}

	// MARK: - Each frame

	func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
		apply(state, time: time)
	}

	func apply(_ s: State, time: TimeInterval) {
		let dt = lastTime.map { Float(max(0, min(0.1, time - $0))) } ?? 0
		lastTime = time

		// A drag turns the model; let go and it eases back to front-on
		let turned: SIMD2<Float> = lock.withLock {
			if let drag = pendingDrag {
				shownDrag = drag
			} else {
				shownDrag *= max(0, 1 - dt * 4)
			}
			return shownDrag
		}
		let dragTurn = simd_quatf(angle: turned.y, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: turned.x, axis: SIMD3(0, 1, 0))
		rig.simdOrientation = dragTurn * s.orientation

		// Buttons sink in and glow
		for (control, part) in controls {
			let on = s.pressed.contains(control)
			let push: SIMD3<Float> = switch control {
			case .lb, .rb: SIMD3(0, -0.014, 0)
			// The touchpad was cut out of the shell: moving it opens gaps
			case .touchpad: .zero
			case .view, .menu, .share, .home: SIMD3(0, 0, -0.008)
			default: SIMD3(0, 0, -0.012)
			}
			for (n, rest) in zip(part.nodes, part.rest) {
				n.simdTransform = on ? Self.translation(push) * rest : rest
			}
			switch control {
			case .touchpad:
				// Shown by the pad light (placeFingers): tinting the pad itself shows its ragged edge
				break
			case .lb, .rb:
				// Mostly hidden from the front, and a glow on the white DualSense hardly shows:
				// colour the whole button
				for m in part.materials {
					m.diffuse.contents = on ? look.pressed : look.shell
					m.emission.contents = look.pressed
					m.emission.intensity = on ? 0.5 : 0
				}
			case .a, .b, .x, .y:
				let glow = look.faces[control] ?? look.accent
				for (i, m) in part.materials.enumerated() {
					if model == .xbox {
						// Letters keep a faint glow at rest, and shine brighter than their caps when pressed
						let letter = i == 0
						m.emission.contents = on || letter ? glow : CGColor(gray: 0, alpha: 1)
						m.emission.intensity = on ? (letter ? 2.2 : 0.6) : (letter ? Self.letterGlow : 0)
					} else {
						m.emission.contents = on ? glow : CGColor(gray: 0, alpha: 1)
						m.emission.intensity = on ? 1.4 : 0
					}
				}
			default:
				let glow = look.accent
				for m in part.materials {
					m.emission.contents = on ? glow : CGColor(gray: 0, alpha: 1)
					m.emission.intensity = on ? 1.4 : 0
				}
			}
		}

		// Sticks tip towards where they're pushed, glowing more the further they go, and sink when clicked
		for (i, part) in sticks.enumerated() {
			let v = i == 0 ? s.leftStick : s.rightStick
			let clicked = s.pressed.contains(i == 0 ? .leftStick : .rightStick)
			let tip = simd_quatf(angle: v.y * 0.4, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: v.x * 0.4, axis: SIMD3(0, 1, 0))
			let pivot = stickPivots[i]
			let move = Self.translation(pivot + SIMD3(0, 0, clicked ? -0.015 : 0)) * simd_float4x4(tip) * Self.translation(-pivot)
			for (n, rest) in zip(part.nodes, part.rest) { n.simdTransform = move * rest }
			let pushed = min(1, simd_length(v))
			for m in part.materials {
				m.emission.contents = look.accent
				m.emission.intensity = clicked ? 1.4 : (pushed > 0.08 ? CGFloat(0.2 + pushed * 0.7) : 0)
			}
		}

		// Triggers swing in as they're pulled, tinted by the effect or motor on them
		let effect = Self.effectColours[s.triggerLook]
		for (i, part) in triggers.enumerated() {
			let pull = i == 0 ? s.lt : s.rt
			let motor = i == 0 ? s.triggerRumble.x : s.triggerRumble.y
			var jitter: Float = 0
			if (s.triggerLook == .vibration && pull > 0) || motor > 0 {
				jitter = Float(sin(time * 2 * .pi * 24)) * 0.006
			}
			let hinge = triggerHinges[i]
			let swing = Self.translation(hinge + SIMD3(jitter, 0, 0))
				* simd_float4x4(simd_quatf(angle: -0.45 * pull, axis: SIMD3(1, 0, 0))) * Self.translation(-hinge)
			for (n, rest) in zip(part.nodes, part.rest) { n.simdTransform = swing * rest }
			let tint = motor > 0 ? Self.effectColours[.vibration] : effect
			let base = tint.map { Self.mix(look.shell, $0, 0.5) } ?? look.shell
			for m in part.materials {
				if pull > 0.02 {
					m.diffuse.contents = Self.mix(base, look.pressed, CGFloat(0.35 + pull * 0.65))
					m.emission.contents = look.pressed
					m.emission.intensity = CGFloat(0.15 + pull * 0.4)
				} else {
					m.diffuse.contents = base
					m.emission.contents = tint ?? look.pressed
					m.emission.intensity = tint == nil ? 0 : 0.25
				}
			}
		}

		// Glows behind the shoulders and triggers: pressed, pulled, or faintly in the trigger effect's colour
		for (i, halo) in halos.enumerated() {
			let m = halo.geometry?.firstMaterial
			var amount: Float = 0
			switch i {
			case 0, 1:
				amount = s.pressed.contains(i == 0 ? .lb : .rb) ? 0.9 : 0
				m?.multiply.contents = look.pressed
			default:
				let pull = i == 2 ? s.lt : s.rt
				let motor = i == 2 ? s.triggerRumble.x : s.triggerRumble.y
				if pull > 0.02 {
					amount = 0.3 + pull * 0.7
					m?.multiply.contents = look.pressed
				} else if motor > 0 {
					amount = 0.4 + motor * 0.5
					m?.multiply.contents = Self.effectColours[.vibration]
				} else if let effect {
					amount = 0.3
					m?.multiply.contents = effect
				}
			}
			halo.opacity = CGFloat(amount)
			halo.isHidden = amount == 0
		}

		// Lightbar
		for m in lightbar {
			if let colour = s.lightbar {
				m.diffuse.contents = colour
				m.emission.contents = colour
				m.emission.intensity = 2.2
			} else {
				m.diffuse.contents = Self.lightbarOff
				m.emission.intensity = 0
			}
		}

		// Player lights, in the DualSense's patterns
		let lit: Set<Int> = switch s.player {
		case 1: [2]
		case 2: [1, 3]
		case 3: [0, 2, 4]
		case 4: [0, 1, 3, 4]
		default: []
		}
		for (i, light) in playerLights.enumerated() { light.isHidden = !lit.contains(i) }

		placeFingers(s.touches, clicked: s.pressed.contains(.touchpad), time: time, dt: dt)
		shake(s.buzz, time: time)
	}

	/// The touchpad's surface at x, y (0...1 across and down), in the model's coordinates
	private func padSurface(_ pad: SCNNode, x tx: Float, y ty: Float) -> SCNVector3 {
		let (lo, hi) = pad.boundingBox
		let x = Float(lo.x) + tx * Float(hi.x - lo.x)
		let y = Float(hi.y) - ty * Float(hi.y - lo.y)
		let from = SCNVector3(x, y, Float(hi.z) + 1)
		let to = SCNVector3(x, y, Float(lo.z) - 1)
		let surface = pad.hitTestWithSegment(from: from, to: to, options: nil).first?.localCoordinates
			?? SCNVector3(x, y, Float(hi.z))
		return root.convertPosition(surface, from: pad)
	}

	private func placeFingers(_ touches: [Touch], clicked: Bool, time: TimeInterval, dt: Float) {
		guard let pad = touchpadGeometry else { return }
		// The whole pad lights up when clicked, fading in and out quickly
		padLightLevel += ((clicked ? 1 : 0) - padLightLevel) * min(1, dt * 25)
		if dt == 0 { padLightLevel = clicked ? 1 : 0 }
		padLight?.opacity = CGFloat(padLightLevel * 0.6)
		padLight?.isHidden = padLightLevel < 0.01

		// Trail: a point every little way along each finger's path
		let spacing: Float = 0.012
		if trailEnds.count < touches.count { trailEnds += Array(repeating: nil, count: touches.count - trailEnds.count) }
		for i in trailEnds.indices where i >= touches.count { trailEnds[i] = nil }
		for (i, t) in touches.enumerated() {
			let now = SIMD2(t.x, t.y)
			guard let end = trailEnds[i] else {
				trail.append(TrailPoint(x: t.x, y: t.y, time: time, fromScreen: t.fromScreen))
				trailEnds[i] = now
				continue
			}
			let gap = simd_distance(end, now)
			// A big jump is a different finger, not a swipe
			guard gap >= spacing, gap < 0.3 else {
				if gap >= 0.3 { trailEnds[i] = now }
				continue
			}
			let steps = Int(gap / spacing)
			for s in 1...steps {
				let p = end + (now - end) * (Float(s) / Float(steps))
				trail.append(TrailPoint(x: p.x, y: p.y, time: time, fromScreen: t.fromScreen))
			}
			trailEnds[i] = now
		}
		trail.removeAll { time - $0.time > Self.trailSeconds }
		if trail.count > trailDots.count { trail.removeFirst(trail.count - trailDots.count) }
		for (i, dot) in trailDots.enumerated() {
			guard i < trail.count else {
				dot.isHidden = true
				continue
			}
			let t = trail[i]
			let life = Float(1 - (time - t.time) / Self.trailSeconds)
			var p = padSurface(pad, x: t.x, y: t.y)
			p.z += 0.005
			dot.position = p
			let size = CGFloat(0.5 + 0.5 * life)
			dot.scale = SCNVector3(size, size, 1)
			dot.opacity = CGFloat(life * 0.85)
			dot.geometry?.firstMaterial?.diffuse.contents = t.fromScreen ? Self.screenFinger : Self.padFinger
			dot.isHidden = false
		}

		for (i, dot) in fingers.enumerated() {
			guard i < touches.count else {
				dot.isHidden = true
				continue
			}
			let t = touches[i]
			dot.position = padSurface(pad, x: t.x, y: t.y)
			dot.isHidden = false
			let colour = t.fromScreen ? Self.screenFinger : Self.padFinger
			if let m = dot.geometry?.firstMaterial {
				m.diffuse.contents = colour
				m.emission.contents = colour
				m.emission.intensity = 1.5
			}
		}
	}

	/// Where a point on screen lands on the touchpad, 0...1 across and down (outside that range
	/// when it's off the pad), following the controller however it's turned. nil without a touchpad.
	func touchpadPoint(_ point: CGPoint, in view: SCNSceneRenderer) -> SIMD2<Float>? {
		guard let pad = touchpadGeometry else { return nil }
		let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
		let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
		let a = SIMD3<Float>(pad.presentation.convertPosition(near, from: nil))
		let b = SIMD3<Float>(pad.presentation.convertPosition(far, from: nil))
		let (lo, hi) = pad.boundingBox
		// The pad's top surface, as a flat plane
		let surface = Float(hi.z)
		guard abs(b.z - a.z) > 1e-6 else { return nil }
		let t = (surface - a.z) / (b.z - a.z)
		guard t > 0 else { return nil }
		let p = a + (b - a) * t
		return SIMD2((p.x - Float(lo.x)) / Float(hi.x - lo.x), (Float(hi.y) - p.y) / Float(hi.y - lo.y))
	}

	private func shake(_ buzz: Buzz?, time: TimeInterval) {
		guard let buzz else {
			shaker.simdTransform = matrix_identity_float4x4
			ripples.forEach { $0.isHidden = true }
			return
		}
		let amount = max(buzz.left, buzz.right) * (buzz.hz < 20 ? 0.018 : 0.008)
		let phase = time * 2 * .pi * buzz.hz
		shaker.simdPosition = SIMD3(Float(sin(phase)) * amount, Float(cos(phase * 1.3)) * amount * 0.5, 0)
		shaker.simdOrientation = simd_quatf(angle: Float(sin(phase * 0.7)) * amount * 0.6, axis: SIMD3(0, 0, 1))
		for (i, ring) in ripples.enumerated() {
			let side = i / 2
			let level = side == 0 ? buzz.left : buzz.right
			ring.isHidden = level <= 0
			let p = Float((time * 2.2 + Double(i % 2) * 0.5).truncatingRemainder(dividingBy: 1))
			let scale = 0.4 + p * 1.6
			ring.scale = SCNVector3(scale, scale, scale)
			ring.opacity = CGFloat((1 - p) * level * 0.8)
		}
	}

	private static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
		var m = matrix_identity_float4x4
		m.columns.3 = SIMD4(v, 1)
		return m
	}
}
