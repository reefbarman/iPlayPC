# Picture

iPlayPC decodes the stream with the phone's hardware H.265/H.264 decoder and draws it with Metal at the screen's native resolution.

## Video

Settings › Video, or per PC (see [PC settings](pcs-and-setup.md#pc-settings)).

- **Resolution:** 720p, 1080p (the default), 1440p, 4K or Native (the screen's own resolution).
- **Frame rate:** 30, 60 (the default) or 120 fps.
- **Maximum bitrate:** Automatic (the default, which lets the PC decide) or 5 to 100 Mbps. With **Auto bitrate** on, iPlayPC learns a maximum for each PC on each Wi-Fi network (see [Connection](connection.md)).
- **Codec:** H.265 (HEVC, the default) or H.264.
- **HDR:** only shown on HDR screens, and switches the codec to H.265. See [HDR](#hdr).

These are the most iPlayPC asks for. The PC's own Remote Play settings in Steam can lower them, and a Mac streams at its display's scaled size (see [Streaming from a Mac](pcs-and-setup.md#streaming-from-a-mac)).

They're fixed when the stream starts, so change them before you play. The stream menu shows what the stream asked for, and **Streaming at** shows the size the PC is actually sending.

## HDR

On an iPhone or iPad with an HDR screen, turn on **HDR** in Settings › Video. iPlayPC then asks the PC for HDR10 and Steam's best quality preset.

Steam only sends HDR from a Windows PC with an NVIDIA or AMD graphics card doing the encoding and HDR turned on in Windows display settings, and only while something HDR is on screen. Otherwise the stream stays in normal colour and still looks right.

## Display

Settings › Display. These can also be changed mid-game from the stream menu.

- **Picture:** Fit (the default) shows the whole picture, with black bars where the screen is a different shape to 16:9. Zoom to fill fills the screen and crops the overflow.
- **Upscaling:** Bilinear, Sharp (the default), MetalFX Spatial (enlarges the picture to the screen's resolution) or MetalFX 4K (enlarges it to 3840×2160 and then scales it down to the screen). MetalFX is only offered on devices that support it.
- **120 Hz screen:** on ProMotion iPhones, gets each frame on screen sooner, for a little more battery. On by default.
- **Stats:** Off, Simple or Advanced. Stats sit in the black bar above the picture. Simple shows the essentials, Advanced shows everything.

## Frame generation

Settings › Display › **Frame generation (experimental)**. Off by default.

Makes an extra frame between each pair the stream sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay.

Tap the bottom-right corner of the stream to turn it on and off while you play.
