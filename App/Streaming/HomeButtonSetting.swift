import GameController
import UIKit

/// iOS 27's setting for what a controller's Home button does inside apps.
///
/// Out of the box ("system default") iOS opens its Game Overlay on Home and
/// ignores the app's `preferredSystemGestureState`, so Home can't reach the PC
/// as the Xbox or PS button. The user can switch it to defer to the app, after which
/// `ControllerInput.claimSystemGestures` gets the button. Earlier iOS versions
/// have no such setting and already honour the claim.
enum HomeButtonSetting {
	/// The setting exists on this iOS version
	static var isSupported: Bool {
		if #available(iOS 27, *) { true } else { false }
	}

	/// iOS keeps Home for itself whatever the app asks. False when it can't tell,
	/// including when no controller is connected (iOS only answers while one is).
	@MainActor static var blocksApps: Bool {
		guard #available(iOS 27, *), ControllerInput.hasSupportedController else { return false }
		do {
			let setting = try GCControllerHomeButtonSettingsManager().controllerHomeButtonInAppAction
			log.notice("Controller Home button in apps: \(setting.action.rawValue, privacy: .public)")
			return setting.action == .systemDefault
		} catch {
			log.error("Couldn't read the controller Home button setting: \(error, privacy: .public)")
			return false
		}
	}

	/// Opens the Settings app at the screen where the user picks what Home does in apps
	@MainActor static func openSettings() {
		guard #available(iOS 27, *) else { return }
		do {
			try GCControllerHomeButtonSettingsManager().openControllerHomeButtonSettings(for: .customizeInAppAction)
		} catch {
			log.error("Couldn't open the controller Home button settings: \(error, privacy: .public)")
			if let url = URL(string: UIApplication.openSettingsURLString) {
				UIApplication.shared.open(url)
			}
		}
	}
}
