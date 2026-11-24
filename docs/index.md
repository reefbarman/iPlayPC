---
layout: default
title: Steam Remote Play for iPhone and iPad
---

<div class="hero">
  <img class="hero-icon" src="{{ '/images/app-icon.png' | relative_url }}" alt="iPlayPC, Steam Remote Play for iPhone and iPad">
  <h1>Steam Remote Play for iPhone and iPad</h1>
  <p class="hero-lead">iPlayPC is a free, open-source app that streams your PC's Steam games to your iPhone or iPad over your home network, using Steam's own Remote Play. Your PC only needs Steam. Tuned for the iPhone Duo, and works on any iPhone or iPad running iOS 17 or later.</p>
  <div class="hero-actions">
    <a class="btn btn-primary fs-5" href="#install">Install iPlayPC</a>
    <a class="btn fs-5" href="https://github.com/reefbarman/iPlayPC">View on GitHub</a>
  </div>
</div>

**Early preview.** So far iPlayPC has mostly been tried against Steam on a Mac. Windows PCs, controllers, HDR and voice chat should work but haven't had much testing yet. If something doesn't work, please [open an issue](https://github.com/reefbarman/iPlayPC/issues).

## Features

<div class="feature-grid">
  <a class="feature-card" href="{{ '/pcs-and-setup.html' | relative_url }}">
    <span class="feature-title">Easy setup</span>
    <p>Finds PCs running Steam on your network, pairs with a PIN once, wakes a sleeping PC and lets each PC have its own video settings.</p>
  </a>
  <a class="feature-card" href="{{ '/picture.html' | relative_url }}">
    <span class="feature-title">Sharp, low-latency picture</span>
    <p>Hardware H.265/H.264 decoding drawn with Metal, HDR10 from supported PCs, MetalFX upscaling and frame generation.</p>
  </a>
  <a class="feature-card" href="{{ '/controllers.html' | relative_url }}">
    <span class="feature-title">Controllers and gyro aiming</span>
    <p>Your controller shows up on the PC as an Xbox controller or DualSense, with rumble, lightbar and touchpad, plus aiming by turning the controller or phone.</p>
  </a>
  <a class="feature-card" href="{{ '/touch-and-virtual-controls.html' | relative_url }}">
    <span class="feature-title">Virtual controls and touch</span>
    <p>On-screen sticks and buttons when you don't have a controller, touch as a mouse for the desktop, and the iPhone keyboard for typing.</p>
  </a>
  <a class="feature-card" href="{{ '/connection.html' | relative_url }}">
    <span class="feature-title">A connection that looks after itself</span>
    <p>Auto bitrate per PC and Wi-Fi network, a one-tap connection check and reconnecting after a dropout.</p>
  </a>
  <a class="feature-card" href="{{ '/audio.html' | relative_url }}">
    <span class="feature-title">Voice chat</span>
    <p>Your phone's mic shows up as the PC's microphone, for games, Discord and Steam, with a mute button on the stream.</p>
  </a>
  <a class="feature-card" href="{{ '/stream-screen.html' | relative_url }}">
    <span class="feature-title">Handy extras</span>
    <p>Quit a game straight back to Big Picture, see battery and temperature, and turn on stats.</p>
  </a>
  <a class="feature-card" href="{{ '/iphone-duo.html' | relative_url }}">
    <span class="feature-title">Made for the iPhone Duo</span>
    <p>Plays on the inner screen, waits on the outer one, and folding pauses the stream.</p>
  </a>
</div>

## Install

iPlayPC isn't on the App Store. You sideload it with your own Apple ID, and a free Apple ID is enough.

**SideStore or AltStore (recommended, gets updates):** add this source, then install iPlayPC from it:

```
https://raw.githubusercontent.com/reefbarman/iPlayPC/main/altstore-source.json
```

**Sideloadly or another signer:** download `iPlayPC.ipa` from the [latest release](https://github.com/reefbarman/iPlayPC/releases/latest) and install it as you would any other IPA.

Then follow [PCs and setup](pcs-and-setup.md) to get started. Every feature and setting is covered in the guides in the sidebar.

## Help

Found a bug? [Open an issue](https://github.com/reefbarman/iPlayPC/issues/new), and see [Help and troubleshooting](troubleshooting.md) for tips. The [changelog](https://github.com/reefbarman/iPlayPC/blob/main/CHANGELOG.md) lists what changed in each release.

iPlayPC is not affiliated with or endorsed by Valve.
