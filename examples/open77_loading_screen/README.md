# open77_loading_screen

Shows a branded overlay with a progress bar ("Loading your destination") over every native loading screen, and hides the game HUD until the load ends. Use it as the starting point for your own server loading screen.

- **Docs:** [Custom loading screens](https://open2077.net/docs/loading-screens)
- **Starts:** with `ensure open77_loading_screen` (it declares `auto_start false`)
- **Needs:** nothing
- **Runs on:** client

## Use it

Run `ensure open77_loading_screen`. The next time a player crosses a loading screen (joining, a long teleport), the overlay covers it and fills its bar as the load progresses. When the game does not report progress, the bar animates and the label reads "Loading...". It only observes loads: it never forces, skips or shortens one.

To brand it, edit `web/index.html`. The page receives each loading state as a `loading:state` message carrying `active`, `progressKnown` and `progress` (0 to 1).

The client creates the page once at start and keeps it empty and transparent between loads, so no browser has to start in the middle of a load. Its core is one event handler:

```lua
AddEventHandler('open77:loadingScreen:changed', function(state)
    Open77.hud.setVisible('all', not state.active)
    overlay:send('loading:state', state)
end)
```

On a client without `Open77.screen.loadingState`, it prints one line in the client log and does nothing. Stopping the resource removes the page and gives the HUD back. The manifest declares `screen.read`, `ui.vanilla.hud` and `webui.modal`.
