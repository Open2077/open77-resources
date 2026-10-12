# open77_shell

This resource is the connection screen players see while they join a server: it shows the
connection, download and loading progress, lets the player cancel, and offers Retry
connection, Return to launcher and Quit game when something goes wrong. A failed connection also shows a support
code and a report the player can copy.

- **Docs:** [The OPEN//77 launcher](https://open2077.net/docs/launcher), [Custom loading screens](https://open2077.net/docs/loading-screens)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

It is the trusted client bootstrap, not a downloadable gamemode menu. The launcher owns server
selection, history, direct connect and mod consent. This resource displays connection progress
and recovery without maintaining another directory.

The UI uses local Open77 tokens/fonts and a responsive Bento/Metro grid. Lobby audio is an owned
local MP3 at `web/audio/lobby.mp3`, looping at 12% by default. The bottom-right dock persists
pause/volume as one `lobby:music` JSON value in this trusted resource's device-local KVP.
It is paused whenever the shell is hidden or a custom loadscreen takes over.
