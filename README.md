<p align="center"><img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="iPlayPC, Steam Remote Play for iPhone and iPad"></p>

# iPlayPC: Steam Remote Play for iPhone and iPad

iPlayPC streams your PC's Steam library to your iPhone or iPad over your home network. Your PC only needs Steam with Remote Play turned on. It's the sibling of [iPlay5](https://github.com/reefbarman/iPlay5) (PS5 Remote Play) and [iPlayNow](https://github.com/reefbarman/iPlayNow) (GeForce NOW), with the same player, Metal renderer, frame generation, gyro aiming and virtual controls.

**Work in progress.** Nothing is playable yet.

## Controllers

Your controller shows up on the PC as a real gamepad, so Steam Input and games show the right buttons:

- **PlayStation controllers** (DualSense, DualShock 4) appear as a DualSense, with the touchpad, gyro, rumble and lightbar. Turn on **Steam > Settings > Controller > PlayStation Controller Support** on the PC to get the extras.
- **Everything else**, and the on-screen controls, appear as an Xbox controller with rumble.
- Controllers without motion sensors (such as a Backbone) use the phone's gyro.
- Switching controllers mid-game swaps what the PC sees.

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
