<p align="center"><img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="iPlayPC, Steam Remote Play for iPhone and iPad"></p>

# iPlayPC: Steam Remote Play for iPhone and iPad

iPlayPC streams your PC's Steam library to your iPhone or iPad over your home network. Your PC only needs Steam with Remote Play turned on. It's the sibling of [iPlay5](https://github.com/reefbarman/iPlay5) (PS5 Remote Play) and [iPlayNow](https://github.com/reefbarman/iPlayNow) (GeForce NOW), with the same player, Metal renderer, frame generation, gyro aiming and virtual controls.

**Early preview.** It streams and plays, but so far it's mostly been tried against Steam on a Mac. Windows PCs, controllers, HDR and voice chat should work but haven't had much testing yet. If something doesn't work, please [open an issue](https://github.com/reefbarman/iPlayPC/issues).

## Install

iPlayPC isn't on the App Store. You install the `.ipa` from [Releases](https://github.com/reefbarman/iPlayPC/releases) yourself with a sideloading tool, signed with your own Apple ID. A free Apple ID is enough. Free-account apps expire after 7 days unless they're refreshed, which SideStore and AltStore do in the background.

**SideStore or AltStore (recommended, gets updates):** add this source, then install iPlayPC from it:

```
https://raw.githubusercontent.com/reefbarman/iPlayPC/main/altstore-source.json
```

**Sideloadly or another signer:** download `iPlayPC.ipa` from the latest release and install it as you would any other IPA.

**Developer account:** if you have a paid Apple Developer account, you can build from source (below) and the app lasts a year.

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

## HDR

On an iPhone or iPad with an HDR screen, turn on **HDR** under Settings (it switches the codec to H.265). iPlayPC then asks the PC for HDR10 and Steam's best quality preset. Steam only sends HDR from a Windows PC with an NVIDIA or AMD graphics card doing the encoding and HDR turned on in Windows display settings, and only while something HDR is on screen. Otherwise the stream stays in normal colour and still looks right.

## Voice chat

Turn on **Settings › Audio › Microphone** (off by default) to send your voice to the PC, where games, Discord and Steam hear it as the PC's microphone. It takes effect the next time you connect. While streaming, tap the mic button in the bottom-left corner, or use **Mute microphone** in the stream menu, to mute it. On the phone's speaker iPlayPC uses echo cancellation, so the game audio doesn't feed back into the mic.

## Connection

Steam adjusts the bitrate itself while you play, up to **Maximum bitrate** (Automatic, 100 Mbps, by default). Two things help it fit your Wi-Fi:

- **Auto bitrate** (Settings, on by default) learns the maximum that works for each PC on each Wi-Fi network. After a stream that dropped video it asks for less next time, and after a long clean stream it tries a little more, never above your **Maximum bitrate**. Until a stream drops video (or you pick a bitrate with Check connection), your setting is used as is. On mobile data the setting is always used as is. **Forget learned bitrates** clears what it has learned.
- **Check connection** (stream menu, under Connection) watches the next 20 seconds of the stream for lost video, then tells you how the connection is doing and can suggest a maximum. Tap **Use … Mbps next time** to use it from your next stream: with Auto bitrate on it's remembered for that PC on that network, otherwise it becomes your **Maximum bitrate** (the PC's own, if it has custom video settings). Play something busy while it checks, since the PC sends much less on menus and quiet scenes.
- **Reconnecting:** if the connection drops mid-stream (including Wi-Fi just going quiet for 15 seconds), the app reconnects on its own, up to three tries a few seconds apart. If those don't work, the end screen offers **Reconnect**. When the PC ends the stream itself (you quit from Steam, or it goes to sleep) the app doesn't try to reconnect.

## Quitting

The stream menu has two ways out:

- **Quit game** closes the game on your PC and keeps streaming, so you land back in Big Picture to pick something else.
- **Quit** ends the stream and closes the game too.

Both close the game the way you would at the PC (Alt+F4 on Windows and Linux, Cmd+Q on a Mac), so a game may ask before closing, and anything unsaved is lost. They only act when Steam reports a game is running, never on the desktop or in Big Picture.

## Settings

Tap the gear on the PC list. Everything has a sensible default, so you only need to change what bothers you:

- **Video:** resolution, frame rate, maximum bitrate, codec (H.264 or H.265) and HDR. Each PC can have its own in its PC settings. **Auto bitrate** sits below them (see [Connection](#connection)).
- **Display, Controller (including Gyro aiming), Virtual controls and Audio** each have their own page.
- **About:** the version, a link to the exact source the build came from, and **Licences** for everything bundled into the app.

## Build from source

Needs a Mac with Xcode 16 or later and Homebrew.

```sh
brew install cmake ninja xcodegen
git clone --recursive https://github.com/reefbarman/iPlayPC.git
cd iPlayPC
git -C vendor/mbedtls submodule update --init --depth 1 framework  # mbedTLS's CMake needs it
scripts/build-ihskit.sh                                 # -> Frameworks/IHSKit.xcframework
cp Config/Local.xcconfig.example Config/Local.xcconfig  # set your team ID and a bundle ID
xcodegen generate                                       # -> iPlayPC.xcodeproj
open iPlayPC.xcodeproj
```

`scripts/package-ipa.sh` builds an unsigned `build/iPlayPC.ipa` for sideloading. Pushing a `vX.Y.Z` tag runs the Release workflow, which builds the IPA, publishes a GitHub release and updates the sideload source. After bumping a submodule or ihslib, run `scripts/update-licenses.sh` and commit the result.

### Layout

- `App/`: the SwiftUI app, player, renderer and settings. Everything Steam-specific lives in `App/Backend/Steam`, behind the neutral types in `App/Backend`.
- `IHSKit/`: builds ihslib with our patches (`IHSKit/patches`, listed in `IHSKit/PATCHES.md`) and a small C bridge into `IHSKit.xcframework`.
- `vendor/`: ihslib (an untouched upstream copy), and Mbed TLS, Opus and protobuf-c as submodules.

## Credits and license

- [ihslib](https://github.com/mariotaku/ihslib) (LGPL-3.0) by mariotaku implements Steam's Remote Play protocol, with Steam's current pairing from [scaronni's fork](https://github.com/scaronni/ihslib).
- [Steam-Link-PS5](https://github.com/jmelovich/Steam-Link-PS5) (GPL-3.0) by jmelovich found and fixed most of ihslib's stability problems. iPlayPC uses its patches.
- Also bundled: [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache-2.0), [Opus](https://opus-codec.org) (BSD) and [protobuf-c](https://github.com/protobuf-c/protobuf-c) (BSD).

iPlayPC is licensed under the [GNU Affero General Public License v3.0](LICENSE), like iPlay5. The app shows every licence under **Settings › About › Licences**.

Not affiliated with or endorsed by Valve. "Steam" and "Steam Remote Play" are trademarks of Valve Corporation.
