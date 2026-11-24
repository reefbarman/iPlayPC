# PCs and setup

iPlayPC streams from any Windows, Mac or Linux PC running Steam on your home network. It uses Steam's own Remote Play, so there's nothing else to install on the PC.

## Getting started

1. On the PC, open Steam and turn on **Settings › Remote Play**.
2. Open iPlayPC. PCs on your network show up by themselves. If yours doesn't, tap **+** and enter its IP address.
3. Tap **Pair** and type the PIN into Steam on the PC. You only do this once per PC.
4. Tap **Play**. Steam opens Big Picture.

Steam lists your phone as "iPhone" (or "iPad") under its paired devices, because iOS doesn't share the device's own name with apps.

## The PC list

Your saved PCs come first, then any other PCs **On your network**, each with **Play** or **Pair**. A saved PC with a MAC address that isn't answering shows **Asleep or off** and **Wake**.

With a controller, the d-pad moves through the list, A plays (or pairs), Y opens PC settings and Menu opens Settings.

## PC settings

Swipe left on a PC or long-press it for **PC settings**.

- **Name:** what iPlayPC calls it.
- **IP address:** follows the PC automatically when it's found on your network.
- **MAC address:** lets iPlayPC wake the PC from sleep (see below).
- **Custom video settings:** give this PC its own resolution, frame rate, bitrate, codec and HDR. Display and controller settings are always shared.
- **Forget:** removes the PC and its pairing. To play it again you'll pair with a new PIN.

## Waking a sleeping PC

Add the PC's MAC address in its PC settings, and a sleeping PC shows **Wake** instead of Play. iPlayPC keeps trying for a minute and starts playing as soon as the PC answers.

- **Finding the MAC address:** on Windows, run `ipconfig /all` and use the Physical Address of the network adapter it's connected with. On a Mac, it's under **System Settings › Network › Details › Hardware**.
- **Turning on Wake on LAN:** on Windows, in the network adapter's power management settings and often the BIOS. On a Mac, turn on **Wake for network access**.

iPhones can't send network-wide wake packets, so iPlayPC sends the wake packet straight to the PC's last IP address. That works on most home networks, ideally with the PC wired and given a reserved IP on the router.

## Streaming from a Mac

Steam on macOS needs two things before it can stream:

- **Screen recording:** allow Steam in **System Settings › Privacy & Security › Screen & System Audio Recording**. Without it, the stream connects but the picture never arrives, and iPlayPC shows "No picture from your PC yet". Look for a prompt on the Mac, which can hide behind Steam.
- **Steam's streaming audio driver:** Steam offers to install it the first time you stream. Until it's installed, the stream won't start.

Steam on a Mac streams at the display's scaled ("looks like") size, whatever iPlayPC asks for. A 4K display at default scaling streams 1080p, and an ultrawide gives a wide, letterboxed picture.

## Picture size

Steam captures the PC's own desktop and scales it to fit. If the PC's display isn't 16:9, you get black bars. On Windows, Steam's **Remote Play › Advanced host options › Change desktop resolution to match streaming client** makes the PC switch its resolution while you stream.
