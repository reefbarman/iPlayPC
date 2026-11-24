# Agent instructions

## What this is

iPlayPC streams a PC running Steam to iPhone and iPad over the local network, using Steam's own Remote Play protocol. It's from the same lineage as iPlay5 (`../iPlaystation`, PS5 Remote Play) and iPlayNow (`../iPlayGFN`, GeForce NOW): same app structure, player, renderer, settings, virtual controls and UX. Read those repos freely; don't edit them from here.

The protocol comes from ihslib, built as `IHSKit` the way iPlay5 builds `ChiakiKit`. Everything the player sees is ours. Keep the app's streaming code behind the backend protocol in `App/Backend/` so a Moonlight backend can be added later without touching the player.

Product rules (same as the sibling apps):

- Start simple and add features when asked. Good defaults, everything tweakable in Settings.
- No tutorials, guided setup or interrupting prompts.
- Nothing in the UI mentions ihslib or Steam-Link-PS5. Credit lives in the README and the licences screen.

## Third-party code

- `vendor/ihslib` is an untouched copy of upstream (see `Licenses/UPSTREAM_COMMITS`). Never edit it. Changes go in `IHSKit/patches/` as numbered patch files, applied to a copy at build time, and each one gets a line in `IHSKit/PATCHES.md`.
- Patches `0001` to `0030` come from Steam-Link-PS5 (GPL-3.0-or-later). Our own patches start at `0100`.
- `vendor/mbedtls`, `vendor/opus` and `vendor/protobuf-c` are pinned submodules.

## Building

Device builds, installs and git commands need to run natively: sandboxed `xcodebuild` can't reach the Metal toolchain or the keychain. Git routes GitHub over SSH on this machine, so fetches and submodule updates also run natively.

```sh
git -C vendor/mbedtls submodule update --init --depth 1 framework   # once; mbedTLS 3.6's CMake needs it
scripts/build-ihskit.sh   # -> Frameworks/IHSKit.xcframework
xcodegen generate
```

## Commits

Conventional Commits, one commit per logical step, using the repo-local identity (Tristan Cartledge <tristan.cartledge@gmail.com>). The repo is public at `reefbarman/iPlayPC` (remote `git@github-personal:reefbarman/iPlayPC.git`); commit and push straight to `main`.

## Releases

Once published, releases follow iPlayNow's `AGENTS.md`: push a `vX.Y.Z` tag, wait for the Release workflow, then replace the generated notes with a player-facing summary and New/Fixes/Notes changelog, and add the same entries to `CHANGELOG.md`.

## Documentation

`README.md` has the highlights. `docs/` has a guide per area (see `docs/README.md`) that describes every feature and setting. When a change adds or changes something players can see, update the matching guide in the same change, and the README highlights if it's a headline feature. Use the names, defaults and settings paths the app shows.

`docs/` is also published with GitHub Pages at https://reefbarman.github.io/iPlayPC/. `docs/index.md` is the site's home page (a short, player-facing version of the README) and `docs/_config.yml` holds each guide's sidebar order and search description. The site uses the Just the Docs theme with a custom colour scheme in `docs/_sass/`. When adding or renaming a guide, update both, plus the table in `docs/README.md`. Links inside `docs/` must stay within `docs/`, so use full GitHub URLs for files elsewhere in the repo.

`docs/privacy.md` is the privacy policy that Settings › About links to, and `App/PrivacyInfo.xcprivacy` is the app's privacy manifest. If a change stores new data, contacts a new service, asks for a new permission or uses a new required-reason API, update both.
