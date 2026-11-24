# ihslib patches

`scripts/build-ihskit.sh` copies `vendor/ihslib/{src,include}` into the build directory and applies `IHSKit/patches/*.patch` in order with `patch -p1`. `vendor/ihslib` itself is never edited.

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

None yet. Expected first: unicast discovery (see `plans/build-plan.md`, step 1).
