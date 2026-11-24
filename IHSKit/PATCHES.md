# ihslib patches

`IHSKit/CMakeLists.txt` (run by `scripts/build-ihskit.sh`) copies `vendor/ihslib/{src,include}` into the build directory and applies `IHSKit/patches/*.patch` in order with `patch -p1`; a rejected hunk fails the build. `vendor/ihslib` itself is never edited.

Base: [scaronni/ihslib](https://github.com/scaronni/ihslib) `f68de5f0` (2026-10-04), which is upstream [mariotaku/ihslib](https://github.com/mariotaku/ihslib) master `1881b9a0` plus two commits implementing Steam's 2026 PIN-masked X25519 pairing. Without them current Steam answers `AuthorizationFailed` after the PIN is typed. The fork's `auth` branch has since been merged into its `master` (`04688d19`) and deleted, which is why we vendor a copy instead of using a submodule. Most of the patches below don't apply to that newer `master`; rebasing onto it is a possible later job.

## From Steam-Link-PS5 (`0001` to `0030`)

Copied from [jmelovich/Steam-Link-PS5](https://github.com/jmelovich/Steam-Link-PS5) `patches/ihslib/` at `925eb0df` (GPL-3.0-or-later, see `Licenses/`). Summaries are theirs, from that repo's `PINS.md`. All verified on real hardware against current Steam (on a PS5, not iOS).

- `0001` data channel: an unexpected packet type is logged and dropped instead of `assert`ing (an abort on Wi-Fi loss).
- `0002` data channel: a packet window full of a partial frame is reset instead of staying stuck.
- `0003` session config: `IHS_SessionConfig` gains `maxBitrateKbps` and `quality`, replacing the hard-coded Balanced at 30000 kbit/s.
- `0004` session: exposes the id of the video frame being submitted, so the app can report decode stages and completion to the host.
- `0005` frame stats: drops the "network" stat that mixed the host clock with ours and made the host drop nearly every frame.
- `0006` retransmission: a NACK resends the named packet, and reliable retries back off from 60 ms to 1 s.
- `0007` window: resync when the host's packet id races more than a window ahead, instead of freezing the channel.
- `0008` HID: clamp a report to the length the host asked for instead of `abort()`ing.
- `0009` session config: `maxResolutionX/Y`, so the app can ask the host to downscale.
- `0010` video: only a forward sequence gap requests a keyframe; re-sent old frames are dropped silently.
- `0012` negotiation: advertise `enable_remote_hid = 1` so the host injects controller input.
- `0013` ACKs: send each ACK three times so reliable control handshakes survive a lossy uplink.
- `0014` data channel: THE stall fix. Run window discard before every poll and keep one slot free, so one lost packet no longer freezes video for 10 to 20 s.
- `0015` control: deliver a control message whose counter skipped ahead (fixes about 1 in 12 startups with no input or a black screen).
- `0016` control: window raised from 128 to 2048 slots to hold Big Picture's startup burst.
- `0018` video: keep decoding through a small frame gap and ask for a keyframe once, instead of freezing until an IDR arrives.
- `0019` video: same for a frame missing a fragment.
- `0020` negotiation: `refreshRateNum/Den` in `IHS_SessionConfig` instead of a hard-coded 59.94 Hz, so 120 Hz works.
- `0021` HID: feature-report replies return the byte count, and the fallback caps include gyro and accelerometer.
- `0030` negotiation: `displayWidth/Height` in `IHS_SessionConfig` instead of a hard-coded 1920x1080.

## Ours (`0100` and up)

Make them with `diff -ruN a b` against a copy that already has every earlier patch applied (paths `a/src/...`, applied with `patch -p1`).

- `0100` client: `IHS_ClientDiscoverAddress()` sends one discovery request to a given address instead of broadcasting. iOS blocks broadcast without the multicast entitlement, so the app sweeps its subnet and probes manual IPs with it.
- `0101` control: `k_EStreamControlSetActivity` is stored in the session state (activity and appid) and logged instead of dropped, so the app only closes the game on the PC when Steam says a game is in front.
- `0102` input: advertise `has_on_screen_keyboard` in the client caps and pass `k_EStreamControlShowOnScreenKeyboard` to a new `showOnScreenKeyboard` input callback, so the app can bring up the phone's keyboard when the host asks. A Mac host didn't ask in testing (Big Picture still draws its own keyboard). Unhandled control messages also log their number, since newer ones have no name in ihslib's protocol files.
- `0103` video: ask the host for HDR10. Adds the newer protocol fields Steam's HDR streaming uses to the generated protobuf-c code (`k_EStreamColorspace_HDR10`, `CStreamingClientConfig.hdr_mode` = 42 as an int32, `CStartVideoDataMsg.colorspace` = 6; hand-edited, since there's no `protoc-c` in the build). A new `enableHdr` session option advertises BT.709 plus HDR10 in the client caps, turns `hdr_mode` on and asks for the Beautiful preset, which Steam needs before it sends HDR. Without it nothing changes on the wire. The host's colour space reaches the application as `IHS_StreamVideoConfig.colorspace`.
- `0104` session: the session state records `hostDisconnected` when the host sends Disconnect, and `lastReceivedMs` for every valid packet. ihslib reports a host ending the stream and a broken connection the same way and has no receive timeout, so the app uses these to reconnect after a dropout (including one that just goes silent) but not after the PC ends the stream.
