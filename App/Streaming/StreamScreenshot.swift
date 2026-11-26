import ImageIO
import Photos
import UniformTypeIdentifiers

/// Saves the game picture to Photos, from the stream menu
@MainActor
enum StreamScreenshot {
	enum ScreenshotError: LocalizedError {
		case noFrame, renderFailed, encodingFailed, notAllowed

		var errorDescription: String? {
			switch self {
			case .noFrame: "No picture is ready yet. Try again once the game is showing."
			case .renderFailed: "Couldn't copy the game picture."
			case .encodingFailed: "Couldn't turn the game picture into an image."
			case .notAllowed: "iPlayPC isn't allowed to add photos. You can allow it in the Settings app."
			}
		}
	}

	/// Saves the last frame shown as a PNG in the photo library (add-only access)
	static func save(renderer: MetalRenderer) async throws {
		let image = try await renderer.renderScreenshot()
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
		else { throw ScreenshotError.encodingFailed }
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.encodingFailed }

		let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
		guard status == .authorized || status == .limited else { throw ScreenshotError.notAllowed }
		try await PHPhotoLibrary.shared().performChanges {
			PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data as Data, options: nil)
		}
		log.notice("Screenshot saved to Photos: \(image.width, privacy: .public)x\(image.height, privacy: .public)")
	}
}
