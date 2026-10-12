# open77_pause

This resource is the Escape menu players see on an Open77 server: it opens without pausing the world and offers Resume, City Map, Settings, Quit Session and Quit Game. A session card shows your ping, the player count, the tick rate and the server version, with IP addresses hidden unless the player chooses to show them.

- **Docs:** [Pause menu customization](https://open2077.net/docs/pause-menu)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

Keep it running: while it runs, Escape opens this menu instead of the vanilla pause screen, and the world keeps going. If the resource stops, Escape goes back to the game.

- **Settings** has Video, Graphics, Audio, Voice, Controls, Key bindings and Gameplay tabs. Labels and options come from the game itself, already translated, and a "Full game settings" button opens the vanilla settings screen (the world pauses while it is open).
- **Key bindings** lists every key mapping any resource declared with `RegisterKeyMapping`, so your own keys appear there.
- **Quit Session** and **Quit Game** ask for confirmation first.

You do not edit this resource to brand it. From your own client resource, give the menu your accent color and a logo shown beside the Open77 logo:

```lua
-- your resource's open77.lua: permissions { "pause_menu.customize" }
--                              pause_menu_logo "assets/server-logo.png"
assert(Open77.pauseMenu.setAccentColor("#FFCC00"))
```

Every player-facing word lives in `shared/strings.lua`, the one file to edit for a translation.
