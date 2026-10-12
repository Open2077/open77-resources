# open77_watermark

A small, passive watermark centred at the top of the HUD that shows the OPEN//77 logo,
the **Open Stress Test** event label, and a quiet line with the player's name and ID, the
client build and a shortened session identifier. Players can match any screenshot to the
server logs with it, and it never takes input.

- **Docs:** [Vanilla HUD visibility](https://open2077.net/docs/hud-visibility)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Behaviour

- Remains inside `CHROME_STRIP` (top 7%); never enters the gamemode match band.
- Passive `hud` WebUI: no focus, no pointer events, transparent, 10 fps.
- Small translucent backing keeps text readable against sky and dark scenes.
  No blur, continuous animation, blinking or large full-width banner. Only a
  short entrance fade and status-colour transition; reduced motion is respected.
- Long names/builds truncate before displacing the session identifier. Short
  viewports use one row and omit the build; narrow ones omit redundant labels.
- The session status dot is cyan only after an authoritative server answer.
  Before that, or after a missed refresh, it is muted and displays `OFFLINE`.
- The page talks to the client over `watermark:ready` / `watermark:state`. Server
  replies contain the authenticated player ID, resolved name and persistent
  identifier; the full identifier is never inserted into the DOM.
- It refreshes every 60 seconds online and every 5 seconds offline. Session
  identifiers are shown abbreviated (`8…4`) for correlating screenshots with
  server logs.

## Editing

The event label lives in `web/index.html`; appearance in `web/app.css`; safe
text-only rendering in `web/app.js`. The logo is the packaged `web/open77.png`.
