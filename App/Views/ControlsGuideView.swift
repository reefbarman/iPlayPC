import SwiftUI

/// How the controller, touch, the virtual controls and the stream's hidden corner buttons work
struct ControlsGuideView: View {
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text("Controller").font(.headline)
				Text("PlayStation controllers show up on the PC as a DualSense, and everything else as an Xbox controller. Hold \(ControllerStyle.current.view) + \(ControllerStyle.current.menu) for a second to open the stream menu. The Home button is the \(ControllerStyle.current.home) button, which opens the Steam overlay or Big Picture, if iOS lets apps use it (see Settings › Controller).")

				Text("Touch").font(.headline)
				Text("With a controller, tap the picture to click there and drag to drag. With virtual controls, the top half works like a trackpad: drag to move the pointer, tap to click, and tap then drag to hold the button. Either way, press and hold or tap with two fingers to right-click, and drag with two fingers to scroll. Turn this off with Touch as mouse in Settings › Virtual controls.")

				Text("Virtual controls").font(.headline)
				Text("Touch open space on either side of the lower half to start a floating stick, or turn on Fixed sticks to keep them in one place. The PC sees them as an Xbox controller.")

				Text("Stream shortcuts").font(.headline)
				Text("Tap the top-right corner for the stream menu. Tap the top-left corner for the Xbox button and the keyboard, or tap with three fingers to open the keyboard. Tap the bottom-right corner to reveal Frame Generation, then tap again to toggle it. With Microphone on, the mute button is in the bottom-left corner.")
			}
			.frame(maxWidth: 680, alignment: .leading)
			.padding()
			.frame(maxWidth: .infinity)
		}
		.navigationTitle("Controls Guide")
		.navigationBarTitleDisplayMode(.inline)
	}
}
