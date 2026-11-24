# Connection

Steam adjusts the bitrate itself while you play, up to **Maximum bitrate** (Automatic by default, which lets the PC decide). The maximum is set when a stream starts, so connection changes apply from the next stream.

## Auto bitrate

Settings › Video › **Auto bitrate**. On by default.

It learns the maximum bitrate that works for each PC on each Wi-Fi network. After a stream that dropped video it asks for less next time, and after a long clean stream it tries a little more, never above your **Maximum bitrate**. Until a stream drops video (or you pick a bitrate with Check connection), your setting is used as is.

On mobile data the setting is always used as is.

**Forget learned bitrates** clears what it has learned.

## Check connection

In the stream menu, under **Connection**.

It watches the next 20 seconds of the stream for lost video, then tells you how the connection is doing and can suggest a maximum. Tap **Use … Mbps next time** to use it from your next stream. With Auto bitrate on it's remembered for that PC on that network, otherwise it becomes your **Maximum bitrate** (the PC's own, if it has custom video settings).

Play something busy while it checks, since the PC sends much less on menus and quiet scenes.

## Reconnecting after a dropout

If the connection drops mid-stream, including Wi-Fi just going quiet for 15 seconds, iPlayPC shows **Connection lost. Reconnecting…** and connects again on its own. It tries three times, a few seconds apart, then offers **Reconnect** on the screen that follows. Your game keeps running on the PC in the meantime.

When the PC ends the stream itself (you quit from Steam, or the PC goes to sleep), iPlayPC doesn't try to reconnect.

## Tips

- Turn on **Stats** (Settings › Display) to see bitrate, ping and loss.
- Use 5 GHz or 6 GHz Wi-Fi, and connect the PC to the router with a cable if you can.
- Lower the **Maximum bitrate**, or leave **Auto bitrate** on so it learns what works.
