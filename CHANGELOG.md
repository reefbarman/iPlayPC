# Changelog

Every iPlayPC release, written for players. The same notes are on each [GitHub release](https://github.com/reefbarman/iPlayPC/releases).

## v0.2.0 (2026-11-26)

### New
- **Keep playing in the background:** the game audio keeps playing when you switch to another app or lock the phone, and the stream stays connected for as long as you're away. The picture and controller pause, and the microphone is muted until you come back. On by default, in Settings › Audio.
- **Save screenshot to Photos:** a new row in the stream menu saves the whole game picture at the stream's resolution, without the virtual controls or black bars. HDR games are converted to normal colour.
- **Share diagnostics:** a new Help section in Settings and at the bottom of the stream menu makes a text report with your device model, screen, settings and the app's logs since it was opened, ready to attach to a GitHub issue. IP and MAC addresses, IDs, pairing keys and your PCs' names are removed first. **Report a problem on GitHub** opens a new issue.
- **Controller vibration:** Light, Medium or Full (the default) in Settings › Controller › Vibration sets how strongly a controller's motors play rumble.
- **Rumble updates:** a new slider in Settings › Controller › Vibration sets how many vibration changes per second go to a wireless controller, from 10 to Unlimited (default 25). Lower it if the controls freeze during heavy rumble, raise it if vibration feels less detailed.
- **Controls Guide:** Settings › Controller › Controls Guide explains the controller shortcuts, touch as a mouse, the virtual controls and the hidden corner buttons on the stream.
- **No controller? Pick how to play:** if you tap Play with no controller connected, the stream waits and asks. Turn a controller on and it starts straight away, or choose **Use virtual controls** or **Connect without controls** for that stream.
- **Home Button Settings:** on iOS 27, iOS opens its Game Overlay when you press a controller's Home button unless you let apps use it. The first time you play with a controller while iOS keeps Home for itself, iPlayPC offers to open that setting, and Settings › Controller › Home Button Settings opens it any time. Once apps can use it, Home opens the Steam overlay or Big Picture.

### Fixes
- Heavy rumble could make a wireless controller stop responding for a moment while the game carried on. Rumble now sends fewer, smaller updates, so your button presses get through.
- Rumble that faded out gently could leave the controller's motors running quietly. They now always stop when the game stops rumbling.
- The picture could come back broken or frozen after switching apps, or after a run of damaged frames. It now starts again from a fresh frame.

### Notes
- With no controller connected, Play now asks how you want to play before it connects. Set Settings › Virtual controls › Show virtual controls to Always show to skip the question.
- The first screenshot asks to let iPlayPC add photos. It can only add photos, not see your library.
- Still an early preview: most testing has been against Steam on a Mac. Please [open an issue](https://github.com/reefbarman/iPlayPC/issues) if something doesn't work, with Share diagnostics attached if you can.

## v0.1.0 (2026-11-25)

The first release, an early preview: stream your PC's Steam games to your iPhone or iPad over your home network, using Steam's own Remote Play. Your PC only needs Steam with Remote Play turned on. It shares its player, controls and settings with iPlay5 and iPlayNow, so it's tuned for the iPhone Duo and works on any iPhone or iPad running iOS 17 or later.

### New
- **Find and pair your PC:** PCs running Steam on your network show up by themselves, or tap **+** and enter an IP address. Tap **Pair** and type the PIN into Steam once per PC, then **Play** opens Big Picture.
- **PC settings:** swipe left on a PC or long-press it to rename it, change its IP address, add its MAC address, give it its own video settings or Forget it. A controller can move through the PC list, A plays and Y opens PC settings.
- **Wake a sleeping PC:** with its MAC address added, a sleeping PC shows **Wake**. iPlayPC keeps trying for a minute and starts playing as soon as the PC answers.
- **Video:** resolution, frame rate, maximum bitrate and H.264 or H.265, set in Settings or per PC, with hardware decoding and Metal.
- **HDR:** turn on **HDR** in Settings and iPlayPC asks the PC for HDR10. Steam only sends it from a Windows PC with an NVIDIA or AMD graphics card and HDR turned on.
- **Controllers:** PlayStation controllers show up on the PC as a DualSense, with touchpad, gyro, rumble and lightbar. Everything else, and the on-screen controls, show up as an Xbox controller with rumble. Switching controllers mid-game swaps what the PC sees.
- **Gyro aiming** with the controller or the phone, and **virtual controls** when you don't have a controller connected.
- **Typing:** tap the screen with three fingers to open the iPhone keyboard and type on the PC.
- **Voice chat:** turn on **Settings › Audio › Microphone** to send your voice to the PC, with a mute button while you play.
- **Auto bitrate** learns the maximum bitrate that works for each PC on each Wi-Fi network, and **Check connection** in the stream menu tells you how the connection is doing and can suggest a maximum.
- **Reconnecting:** if the connection drops mid-stream, iPlayPC reconnects on its own, up to three tries. If those don't work, the end screen offers **Reconnect**.
- **Quit game** closes the game on your PC and drops you back in Big Picture. **Quit** ends the stream and closes the game too.

### Notes
- This is an early preview. Most testing so far has been against Steam on a Mac. Windows PCs, controllers, HDR and voice chat should work but haven't had much testing yet. Please [open an issue](https://github.com/reefbarman/iPlayPC/issues) if something doesn't work.
- Streaming from a Mac: Steam needs **Screen & System Audio Recording** permission in macOS Privacy & Security, and its streaming audio driver installed, or there's no picture or no sound. Steam on a Mac also streams at the display's scaled size, so an ultrawide gives a small letterboxed picture.
- iPlayPC isn't on the App Store. Install it with SideStore or AltStore using the source in the README, or sign the IPA yourself.
