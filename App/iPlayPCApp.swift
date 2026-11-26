import SwiftUI
import os

let logSubsystem = Bundle.main.bundleIdentifier ?? "iplaypc"
let log = AppLog(subsystem: logSubsystem, category: "app")

/// Development: launched with `-console` (devicectl --console), streaming logs go to stderr too
let mirrorsLogToConsole = ProcessInfo.processInfo.arguments.contains("-console")

func consoleLog(_ message: @autoclosure () -> String) {
	guard mirrorsLogToConsole else { return }
	FileHandle.standardError.write(Data((message() + "\n").utf8))
}

@main
struct iPlayPCApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@State private var hosts = HostStore()
	@State private var settings = SettingsStore()
	@State private var bitrateMemory = BitrateMemory()

	var body: some Scene {
		WindowGroup {
			HostListView()
				.environment(hosts)
				.environment(settings)
				.environment(bitrateMemory)
				.preferredColorScheme(.dark)
				.background {
					// Track the window shape so orientation follows fold/unfold
					GeometryReader { geo in
						Color.clear
							.onAppear { AppDelegate.windowSizeChanged(geo.size) }
							.onChange(of: geo.size) { _, size in AppDelegate.windowSizeChanged(size) }
					}
					.ignoresSafeArea()
				}
		}
	}
}


/// Orientation is left to iOS: Info.plist allows portrait and both landscapes on
/// every screen, which is what lets unfolding the Duo land the right way round.
///
/// The one addition: while a stream is landscape it's locked there with
/// `prefersInterfaceOrientationLocked` (iOS 26+), so tilting the phone can't flip
/// it to portrait. The lock lets go while the phone is turned to the other
/// landscape, so iOS can flip the stream over, then locks again.
final class AppDelegate: NSObject, UIApplicationDelegate {
	private static var streaming = false
	/// Read by every view controller's prefersInterfaceOrientationLocked (see installOrientationLockHook)
	fileprivate static var lockOrientation = false

	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
		Self.installOrientationLockHook()
		UIDevice.current.beginGeneratingDeviceOrientationNotifications()
		NotificationCenter.default.addObserver(
			forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
		) { _ in
			Self.deviceOrientationChanged()
		}
		return true
	}

	/// SwiftUI owns the view controllers (including the full-screen stream cover),
	/// so we can't subclass them. Instead, point UIViewController's
	/// prefersInterfaceOrientationLocked at our flag for all of them. The flag is
	/// only ever true while streaming.
	private static func installOrientationLockHook() {
		guard #available(iOS 26.0, *) else { return }
		let selector = #selector(getter: UIViewController.prefersInterfaceOrientationLocked)
		guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return }
		let block: @convention(block) (UIViewController) -> Bool = { _ in AppDelegate.lockOrientation }
		method_setImplementation(method, imp_implementationWithBlock(block))
	}

	private static func updateLock() {
		guard #available(iOS 26.0, *),
			let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
		else { return }
		let current = scene.interfaceOrientation
		let target = landscapeTarget(for: UIDevice.current.orientation, screen: scene.screen.bounds.size)
		let lock = streaming && current.isLandscape && (target == nil || target == current)

		guard lock != lockOrientation else { return }
		lockOrientation = lock
		var controller = scene.keyWindow?.rootViewController
		while let current = controller {
			current.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
			controller = current.presentedViewController
		}
	}

	/// The landscape orientation for how the phone is held, or nil if it's held
	/// portrait (or flat). UIDevice orientation is relative to the phone's body,
	/// and the Duo's inner screen is mounted sideways in it, so an upright body
	/// there means the inner screen is landscape-left (confirmed on device).
	private static func landscapeTarget(for device: UIDeviceOrientation, screen: CGSize) -> UIInterfaceOrientation? {
		if DeviceLayout.isFoldable && DeviceLayout.isInnerScreen(screen) {
			switch device {
			case .portrait: return .landscapeLeft
			case .portraitUpsideDown: return .landscapeRight
			default: return nil
			}
		}
		switch device {
		case .landscapeLeft: return .landscapeRight
		case .landscapeRight: return .landscapeLeft
		default: return nil
		}
	}

	private static func deviceOrientationChanged() {
		updateLock()
		// Flipping between the two landscapes doesn't change the window size, so
		// nothing else tells us when iOS has finished; check again to relock
		for delay in [0.6, 1.2] {
			DispatchQueue.main.asyncAfter(deadline: .now() + delay) { updateLock() }
		}
	}

	static func setStreaming(_ value: Bool) {
		streaming = value
		updateLock()
	}

	static func windowSizeChanged(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		DeviceLayout.noteWindowSize(size)
		updateLock()
	}
}

