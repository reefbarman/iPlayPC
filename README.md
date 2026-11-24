<p align="center"><img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="iPlayPC, Steam Remote Play for iPhone and iPad"></p>

# iPlayPC: Steam Remote Play for iPhone and iPad

iPlayPC streams your PC's Steam library to your iPhone or iPad over your home network. Your PC only needs Steam with Remote Play turned on. It's the sibling of [iPlay5](https://github.com/reefbarman/iPlay5) (PS5 Remote Play) and [iPlayNow](https://github.com/reefbarman/iPlayNow) (GeForce NOW), with the same player, Metal renderer, frame generation, gyro aiming and virtual controls.

**Early preview.** It streams and plays, but so far it's mostly been tried against Steam on a Mac. Windows PCs, controllers, HDR and voice chat should work but haven't had much testing yet. If something doesn't work, please [open an issue](https://github.com/reefbarman/iPlayPC/issues).

## Features

The highlights are below. The [guides](https://reefbarman.github.io/iPlayPC/) (also in [`docs/`](docs/README.md)) cover every feature and setting, and the [changelog](CHANGELOG.md) lists what changed in each release.

- **Easy setup:** finds PCs running Steam on your network, pairs with a PIN once, wakes a sleeping PC with Wake-on-LAN, and lets each PC have its own video settings. [PCs and setup](docs/pcs-and-setup.md)
- **Sharp, low-latency picture:** hardware H.265/H.264 decoding drawn with Metal, up to 4K and 120 fps, HDR10 from supported Windows PCs, Fit or Zoom to fill, Sharp or MetalFX upscaling, and a 120 Hz screen on ProMotion iPhones. [Picture](docs/picture.md)
- **Frame generation:** an in-between frame for each pair the PC sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. [Picture](docs/picture.md#frame-generation)
- **Real controllers on the PC:** PlayStation controllers show up as a DualSense with touchpad, gyro, rumble and lightbar, and everything else as an Xbox controller, so Steam Input and games show the right buttons. [Controllers](docs/controllers.md)
- **Gyro aiming:** turn the controller (or the phone) to aim with the right stick, even in games without gyro support. [Controllers](docs/controllers.md#gyro-aiming)
- **Virtual controls and touch:** on-screen sticks and buttons when you don't have a controller, touch as a mouse for the desktop, and the iPhone keyboard for typing. [Touch and virtual controls](docs/touch-and-virtual-controls.md)
- **A connection that looks after itself:** Auto bitrate learns what works for each PC on each network, Check connection suggests a bitrate, and the stream reconnects after a dropout. [Connection](docs/connection.md)
- **Voice chat:** the phone's mic shows up as the PC's microphone, with a mute button on the stream. [Audio](docs/audio.md)
- **Handy extras:** **Quit game** drops you back in Big Picture, and the stream menu shows battery and temperature. [The stream screen](docs/stream-screen.md)
- **Made for the iPhone Duo:** streams on the inner screen, waits on the outer one, and folding pauses the stream. [iPhone Duo](docs/iphone-duo.md)

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

Streaming from a Mac? Steam needs Screen & System Audio Recording permission and its streaming audio driver first. See [Streaming from a Mac](docs/pcs-and-setup.md#streaming-from-a-mac).

## Reporting a problem

[Open an issue](https://github.com/reefbarman/iPlayPC/issues/new) with your iPhone or iPad model, the PC's operating system and graphics card, and what happened. [Help and troubleshooting](docs/troubleshooting.md) has tips and known limitations.

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
- `docs/`: the feature guides, published as the website.

## Credits and license

- [ihslib](https://github.com/mariotaku/ihslib) (LGPL-3.0) by mariotaku implements Steam's Remote Play protocol, with Steam's current pairing from [scaronni's fork](https://github.com/scaronni/ihslib).
- [Steam-Link-PS5](https://github.com/jmelovich/Steam-Link-PS5) (GPL-3.0) by jmelovich found and fixed most of ihslib's stability problems. iPlayPC uses its patches.
- Also bundled: [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache-2.0), [Opus](https://opus-codec.org) (BSD) and [protobuf-c](https://github.com/protobuf-c/protobuf-c) (BSD).

iPlayPC is licensed under the [GNU Affero General Public License v3.0](LICENSE), like iPlay5. The app shows every licence under **Settings › About › Licences**, and [Licences and source code](docs/licensing.md) explains how to get the source for any version.

iPlayPC collects no data. It has no accounts, analytics or ads, and only talks to PCs on your own network. See the [privacy policy](docs/privacy.md).

Not affiliated with or endorsed by Valve. "Steam" and "Steam Remote Play" are trademarks of Valve Corporation.
