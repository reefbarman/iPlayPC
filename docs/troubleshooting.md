# Help and troubleshooting

## Reporting a problem

Right after the problem happens, without closing the app, open **Settings › Share diagnostics** and attach the file to a [GitHub issue](https://github.com/reefbarman/iPlayPC/issues/new). It's also at the bottom of the stream menu, so you can share it mid-game. **Report a problem on GitHub** in the same section opens a new issue. Say what happened, and the PC's operating system and graphics card.

The report is plain text, so you can check it before sending. It has the app version, your iPhone or iPad model, screen details, settings and the app's logs since it was opened. IP and MAC addresses, IDs, pairing keys and your PCs' names are removed.

## The PC doesn't show up

- Check Steam is running on the PC and **Settings › Remote Play** is on.
- Make sure the phone and the PC are on the same network, and the phone isn't on a guest Wi-Fi network.
- iPlayPC needs **Local Network** access. If you said no, turn it on in the iOS Settings app under **Apps › iPlayPC**.
- Tap **+** and enter the PC's IP address.
- A firewall on the PC has to let Steam through. Steam uses UDP ports 27031 to 27036 and TCP ports 27036 and 27037.

## No picture or no sound from a Mac

Steam needs **Screen & System Audio Recording** permission and its streaming audio driver. See [Streaming from a Mac](pcs-and-setup.md#streaming-from-a-mac).

## Controller problems

Open **Settings › Controller › Controller Test** to see exactly what the game gets from your controller and to try its rumble. For PlayStation extras (touchpad, lightbar, gyro in Steam Input), turn on **PlayStation Controller Support** in Steam's controller settings on the PC. See [Controllers](controllers.md).

## The controller stops responding during heavy rumble

A wireless controller's vibration and your button presses share one Bluetooth connection. If the controls freeze for a moment while the controller rumbles hard, lower **Settings › Controller › Vibration › Rumble updates**.

## Stutter or lost video

- Turn on **Stats** (Settings › Display) to see bitrate, ping and loss.
- Run **Check connection** from the stream menu while playing something busy.
- Lower the **Maximum bitrate**, or leave **Auto bitrate** on so it learns what works.
- Use 5 GHz or 6 GHz Wi-Fi, and connect the PC to the router with a cable if you can.

See [Connection](connection.md) for details.

## Known limitations

- **Early preview.** Most testing so far has been against Steam on a Mac. Windows PCs, controllers, HDR and voice chat haven't had much testing yet.
- **Home network only.** iPlayPC finds and connects to PCs on your local network. Playing away from home isn't supported yet.
- **The PC decides the picture size.** Steam streams the PC's desktop, so a display that isn't 16:9 gives black bars, and a Mac streams at its scaled size. See [Picture size](pcs-and-setup.md#picture-size).
- **Video settings are fixed per stream.** Change them before you play.
- **One controller.** Local co-op with several controllers isn't supported.
- **Quitting a game on a Mac** may not bring Big Picture back to the front. Press the Xbox button to bring up Steam.
- **Not on the App Store.** Free Apple ID installs need refreshing every 7 days, which SideStore and AltStore do in the background.
