# Privacy policy

iPlayPC doesn't collect or share any personal data. It has no accounts, no analytics, no ads and no tracking, and the developer never receives anything from the app.

iPlayPC only talks to PCs on your own network. It doesn't use any online service of its own, Valve's or anyone else's.

This policy covers iPlayPC however you installed it: by sideloading, from TestFlight or from an app store.

## What stays on your device

- **Your PCs:** the name, IP address and MAC address of each PC you've added, and any video settings you gave it.
- **Pairing keys:** the key Steam gives iPlayPC when you pair with a PIN, one per PC, kept in the iOS Keychain. **Forget** in a PC's settings removes it.
- **Device ID:** a random ID made when the app first runs, kept in the iOS Keychain. Steam uses it to tell paired devices apart. It isn't linked to your phone's hardware or Apple ID.
- **Settings:** your settings and the bitrates **Auto bitrate** has learned (each Wi-Fi network is remembered by its local address range, not its name).
- **Screenshots:** saved to your photo library, and only when you take them.

Deleting the app removes everything except screenshots you've saved to Photos and Keychain items, which can outlast the app on some iOS versions. Forgetting each PC first removes its pairing key.

## Who iPlayPC talks to

- **PCs on your network:** to find PCs running Steam, iPlayPC sends Steam's discovery message to the addresses on your network. Steam on a PC answers with its name and status.
- **Your PC:** pairing, the game stream, your controller, touch and keyboard input and (if you turn on **Microphone**) your voice go between your device and your PC. iPlayPC also tells Steam the device's name, which iOS gives as just "iPhone" or "iPad", and the device ID.
- **Waking a PC:** if you add a MAC address, **Wake** sends a wake packet to that PC's address.
- **GitHub:** only when you tap a link such as **Source code** or this policy, which open in your browser.

Nothing is sent anywhere else. What Steam on your PC does is covered by Valve's [privacy policy](https://store.steampowered.com/privacy_agreement/), not this one.

## Permissions

- **Local Network:** to find, pair with and stream from PCs on your network.
- **Microphone:** only used while **Microphone** is on in settings, to send your voice to the PC for voice chat.
- **Photos (add only):** to save screenshots you take from the stream menu. iPlayPC can't see your photo library.

## Diagnostics

**Settings › Share diagnostics** creates a plain-text report only when you tap it, and you choose where it goes (for example, attached to a GitHub issue). IP and MAC addresses, IDs, pairing keys and your PCs' names are removed before you see it. Nothing is sent automatically. See [Help and troubleshooting](troubleshooting.md).

## Children

iPlayPC doesn't knowingly collect data from anyone, including children, because it doesn't collect data at all.

## Changes and contact

If this policy changes, the updated version will be published on this page, and its history is in the [GitHub repository](https://github.com/reefbarman/iPlayPC/commits/main/docs/privacy.md). For questions, open an [issue on GitHub](https://github.com/reefbarman/iPlayPC/issues).

iPlayPC is not affiliated with or endorsed by Valve.
