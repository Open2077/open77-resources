# open77_reticle

This resource draws an aiming reticle (a dot with four ticks) in the middle of the screen when a player aims a weapon in the Open77 third-person view (F7). It works on every server, with or without a gamemode, because the third-person view does too.

- **Docs:** [Third person](https://open2077.net/docs/perspective)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

There is nothing to configure and nothing to call: keep it running. It has no server half.

The reticle shows only while all of these are true:

- the player is in the Open77 third-person view and controls their own character;
- the player is aiming (the game's own aim state, so controllers, toggle-aim and rebound keys all work);
- the player is alive and armed;
- no interface has captured the input (an open menu or text box hides it).

It is pure presentation: it never asks for a camera change and never reads a mouse button. The page is a transparent HUD layer, so you can restyle it by editing `web/reticle.css`.
