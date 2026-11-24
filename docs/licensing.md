# Licences and source code

iPlayPC is free and open source under the [GNU Affero General Public License v3.0](https://github.com/reefbarman/iPlayPC/blob/main/LICENSE) (AGPL-3.0-only).

## What that means for you

- You can use iPlayPC for free, read its source, change it and share it.
- If you distribute a modified build, you must make its source available under the same licence.

## Settings › About

- **Version:** the app's version and build number.
- **Source code:** opens the exact source the build came from (the release tag, or `main` for builds made from source).
- **Licences:** the licence text of iPlayPC and everything bundled into it.
- **Privacy policy:** opens the [privacy policy](privacy.md).

## Getting the source for a version

Every release is tagged in the [GitHub repository](https://github.com/reefbarman/iPlayPC), and **Source code** in Settings › About links to the tag your build came from. The [README](https://github.com/reefbarman/iPlayPC#build-from-source) explains how to build it.

## Bundled components

- **[ihslib](https://github.com/mariotaku/ihslib)** (LGPL-3.0-or-later) by mariotaku implements Steam's Remote Play protocol, with Steam's current pairing from [scaronni's fork](https://github.com/scaronni/ihslib).
- **[Steam-Link-PS5](https://github.com/jmelovich/Steam-Link-PS5)** (GPL-3.0-or-later) by jmelovich found and fixed most of ihslib's stability problems. iPlayPC applies its patches to ihslib.
- **[Mbed TLS](https://github.com/Mbed-TLS/mbedtls)** (Apache-2.0), **[Opus](https://opus-codec.org)** (BSD-3-Clause) and **[protobuf-c](https://github.com/protobuf-c/protobuf-c)** (BSD-2-Clause).

The player, controls and settings come from [iPlay5](https://github.com/reefbarman/iPlay5) and [iPlayNow](https://github.com/reefbarman/iPlayNow), which are also AGPL-3.0.

iPlayPC is not affiliated with or endorsed by Valve Corporation. "Steam" and "Steam Remote Play" are trademarks of Valve Corporation.
