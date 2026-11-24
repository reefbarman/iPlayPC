<p align="center"><img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="iPlayPC, Steam Remote Play for iPhone and iPad"></p>

# iPlayPC: Steam Remote Play for iPhone and iPad

iPlayPC streams your PC's Steam library to your iPhone or iPad over your home network. Your PC only needs Steam with Remote Play turned on. It's the sibling of [iPlay5](https://github.com/reefbarman/iPlay5) (PS5 Remote Play) and [iPlayNow](https://github.com/reefbarman/iPlayNow) (GeForce NOW), with the same player, Metal renderer, frame generation, gyro aiming and virtual controls.

**Work in progress.** It streams and plays, but there's no release yet.

## Getting started

1. On the PC, open Steam and turn on **Settings › Remote Play**.
2. Open iPlayPC. PCs on your network show up by themselves. If yours doesn't, tap **+** and enter its IP address.
3. Tap **Pair** and type the PIN into Steam on the PC. You only do this once per PC.
4. Tap **Play**. Steam opens Big Picture.

Swipe left on a PC or long-press it for **PC settings**: rename it, change its IP address, add its MAC address (for waking it from sleep), give it its own video settings, or Forget it. With a controller, the d-pad moves through the list, A plays, Y opens PC settings and Menu opens Settings.

### Waking a sleeping PC

Add the PC's MAC address in its PC settings, and a sleeping PC shows **Wake** instead of Play. iPlayPC keeps trying for a minute and starts playing as soon as the PC answers. The PC needs Wake on LAN turned on (Windows: in the network adapter's settings and often the BIOS; Mac: **Wake for network access**). iPhones can't send network-wide wake packets, so iPlayPC sends it straight to the PC's last IP address. That works on most home networks, ideally with the PC wired and given a reserved IP on the router.

## Controllers

Your controller shows up on the PC as a real gamepad, so Steam Input and games show the right buttons:

- **PlayStation controllers** (DualSense, DualShock 4) appear as a DualSense, with the touchpad, gyro, rumble and lightbar. Turn on **Steam > Settings > Controller > PlayStation Controller Support** on the PC to get the extras.
- **Everything else**, and the on-screen controls, appear as an Xbox controller with rumble.
- Controllers without motion sensors (such as a Backbone) use the phone's gyro.
- Switching controllers mid-game swaps what the PC sees.

## Typing

Use the iPhone keyboard to type on your PC. Open or close it by tapping the screen with three fingers, with the keyboard button that appears when you tap the top-left corner, or with **Type with the keyboard** in the stream menu. What you type goes to whatever has focus on the PC, such as a search box in Big Picture.

## Voice chat

Turn on **Settings › Audio › Microphone** (off by default) to send your voice to the PC, where games, Discord and Steam hear it as the PC's microphone. It takes effect the next time you connect. While streaming, tap the mic button in the bottom-left corner, or use **Mute microphone** in the stream menu, to mute it. On the phone's speaker iPlayPC uses echo cancellation, so the game audio doesn't feed back into the mic.

## Quitting

The stream menu has two ways out:

- **Quit game** closes the game on your PC and keeps streaming, so you land back in Big Picture to pick something else.
- **Quit** ends the stream and closes the game too.

Both close the game the way you would at the PC (Alt+F4 on Windows and Linux, Cmd+Q on a Mac), so a game may ask before closing, and anything unsaved is lost. They only act when Steam reports a game is running, never on the desktop or in Big Picture.

Not affiliated with or endorsed by Valve. "Steam" and "Steam Remote Play" are trademarks of Valve Corporation.

## Build from source

Needs a Mac with Xcode 16 or later and Homebrew.

```sh
brew install cmake ninja xcodegen
git clone --recursive <this repo>
cd iPlayPC
scripts/build-ihskit.sh                                 # -> Frameworks/IHSKit.xcframework
cp Config/Local.xcconfig.example Config/Local.xcconfig  # set your team ID and a bundle ID
xcodegen generate                                       # -> iPlayPC.xcodeproj
open iPlayPC.xcodeproj
```

## Credits and license

- [ihslib](https://github.com/mariotaku/ihslib) (LGPL-3.0) by mariotaku implements Steam's Remote Play protocol, with Steam's current pairing from [scaronni's fork](https://github.com/scaronni/ihslib).
- [Steam-Link-PS5](https://github.com/jmelovich/Steam-Link-PS5) (GPL-3.0) by jmelovich found and fixed most of ihslib's stability problems. iPlayPC uses its patches.
- Also bundled: [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache-2.0), [Opus](https://opus-codec.org) (BSD) and [protobuf-c](https://github.com/protobuf-c/protobuf-c) (BSD).

iPlayPC is licensed under the [GNU Affero General Public License v3.0](LICENSE), like iPlay5.
