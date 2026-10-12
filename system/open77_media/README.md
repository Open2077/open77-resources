# open77_media

This resource puts working televisions and screens in the world: an operator places a TV, monitor or panel prop and it shows a web page that every nearby player sees on its screen, with volume, mute, pause and a curtain. It also lets the operator push an ad blocklist to every client, so a page shown on a screen cannot load ads from the hosts you name.

- **Docs:** none yet
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Every command is restricted: the caller needs the matching `command.<name>` ACL right (for example `command.media.spawn`).

```text
media.records                              list the screen models (tv.16x9, monitor.a, panel.21x9, ...)
media.spawn tv.16x9 0 https://example.com  place a TV where you stand, showing a page
media.place <record> <x> <y> <z> [yaw] [url]
media.url <id> <url>       media.title <id> <text>     media.volume <id> <0-100>
media.mute <id> on|off     media.pause <id> on|off     media.curtain <id> open|closed|reveal
media.move <id> forward|back|left|right|up|down [metres]
media.rotate <id> left|right [degrees]     media.remove <id>     media.list
```

- Only `http` and `https` URLs are accepted, up to 512 characters. A screen starts at volume 75.
- A server holds up to 64 screens. Each client only builds the pages of the screens closest to the player (a resource can hold eight web surfaces at once).
- A screen lives in its prop's routing bucket: players in another bucket do not see it.
- There are no exports. Another resource drives screens with the same server events the console uses, `open77:media:spawn` and `open77:media:control`, which check the same ACL rights.

Ad blocklist: `media.adblock`, `media.adblock.add [token] <rule>`, `media.adblock.remove <rule>`, `media.adblock.clear`, `media.adblock.reload`, `media.adblock.status`. A host rule blocks that host and its subdomains; a `token` rule matches anywhere in a host name. The list is saved in the resource's `data/adblock.json`, and `server/config.lua` holds the starting list for a fresh install. These rules only add to the blocklist built into the client; they can never unblock anything.
