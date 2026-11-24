# IHSKit

Steam Remote Play for iPlayPC. It's [ihslib](https://github.com/mariotaku/ihslib) (LGPL-3.0, a clean-room implementation of Steam's In-Home Streaming protocol) plus [Steam-Link-PS5](https://github.com/jmelovich/Steam-Link-PS5)'s fixes, built for iOS with mbedTLS, Opus and protobuf-c, behind a small C API for Swift (`ihs_bridge.h`). It plays the same role as iPlay5's ChiakiKit.

| Path                           | What                                                                       |
| ------------------------------ | -------------------------------------------------------------------------- |
| `../vendor/ihslib`             | Untouched upstream source. Commit in `../Licenses/UPSTREAM_COMMITS`        |
| `patches/`                     | Applied in order to a copy at build time. See `PATCHES.md`                 |
| `CMakeLists.txt`               | iOS build of the patched copy and the bridge (to do)                       |
| `include/ihs_bridge.h`, `src/` | The C API Swift sees, the POSIX thread backend and the HID devices (to do) |

Build with `scripts/build-ihskit.sh`, which writes `Frameworks/IHSKit.xcframework`.
