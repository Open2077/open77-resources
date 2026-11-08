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

The UI follows the October 2026 website/launcher identity: a full-screen Night City backdrop,
the white/yellow wordmark, wide italic Druk headings, Nippo labels, Satoshi body text,
angled controls and pink recovery actions. Artwork and fonts are bundled under `web/brand/`;
rendering never needs the website. The current phase has its own real progress bar, followed
by five connection checkpoints. Indeterminate stages have no invented percentage, and 100%
does not dismiss the cover before the native world handoff. A server's optional accent colors
the progress rail; the platform identity remains consistent.
The default screen stays visible through the native menu unmount until the loading
handoff completes; a server-provided loadscreen can still cover it during streaming.

Lobby audio is an owned local MP3 at `web/audio/lobby.mp3`, looping at 12% by default.
The footer dock persists
pause/volume as one `lobby:music` JSON value in this trusted resource's device-local KVP.
It is paused whenever the shell is hidden or a custom loadscreen takes over.

`scripts/tests/connection-ui-browser.cjs` exercises the real CEF bridge in Chromium, including
720p, 768p, 1080p, 1440p, ultrawide and narrow layouts. Set `OP77_PLAYWRIGHT` to an installed
Playwright module and optionally `OP77_BROWSER_EXECUTABLE` to an installed Chromium browser.
Live CEF evidence and deployment checks are recorded in
`docs/research/main-menu-and-server-browser.md`.
