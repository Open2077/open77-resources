# open77_uikit

This resource draws the on-screen dialogs most gamemodes need: progress bars, text hints, alerts, input forms, context and keyboard menus and a radial wheel.
The shared dialog and HUD-widget kit: `progress`, `textUI`, `alert`, `input`,
`context`, `menu` and `radial`, as client exports that resolve with a promise,
plus a server twin for each so a job step can drive a bar or ask a question.
Two more never wait: `drawText3D` (a string over a world point, one handle over
a native card anchor) and `showCinematicBars` (letterbox plus the vanilla HUD
hidden, one claim per owner).

- **Docs:** [The UI kit](https://open2077.net/docs/ui-kit)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

Toasts are not here -- `lib.notify`'s equivalent is
[`open77_notifications`](../open77_notifications/). `skillCheck` is deliberately
not implemented; [The UI kit](https://open2077.net/docs/ui-kit) page says why and where the extension point is.

Full API, definitions, failure reasons, styling tokens, the focus release matrix
and a worked example: **[The UI kit](https://open2077.net/docs/ui-kit)**.

## Two things to know before editing this package

**Focus is a ledger, not a flag.** `client/main.lua` calls `page:setFocus` from
exactly one function, `syncFocus`, which derives the real state from the set of
open widgets that asked for focus. Every exit -- confirm, cancel, Escape,
timeout, owner stop, owner reload, owner vanished, our own stop, death,
disconnect -- funnels through `settle()`, and a per-tick watchdog releases focus
whenever the ledger is empty and focus is still held. Do not add a `setFocus`
call anywhere else. A player left with a dead dialog cannot move, cannot shoot,
and cannot type to say so.

**3D text and the letterbox are budgets and claims, not widgets.** A
`drawText3D` is an anchor the host counts against *this* resource, so the kit
refuses 8 per owner and 24 in all before the host's own 32 is reached. The
letterbox is one claim per owner over the kit's own `ui.vanilla.hud` loan; it
shows while any claim stands and restores the HUD on the last release. Both
are released on every exit `settle()` already guards.

**Control blocking is not focus.** A progress bar that stops the player moving
claims `Movement` and `Attack` through `Open77.input.setActionBlocked`, which
leaves chat and voice working. Holding focus to achieve the same thing would
take the keyboard from chat too. Claims are refcounted inside this resource,
because the platform releases only the *calling* resource's claim.

## Layout

| File | What it is |
|---|---|
| `open77.lua` | manifest. One `web_ui_page`, five permissions, each with its reason. |
| `client/main.lua` | the widget ledger, the focus ledger, the block refcount, the 3D-text budget, the letterbox claims, and the 26 client exports. |
| `server/main.lua` | the 14 server twins over `Open77.net.callClient`, plus `/uikit.demo`. |
| `web/index.html` | one page, three regions. No inline script. |
| `web/app.js` | one component per widget, two message channels, pure ASCII. |
| `web/app.css` | the surface, on the mirrored design tokens. Header explains the choice. |
| `web/open77-ui.css` | **mirrored, byte-identical** across every shared platform resource. Do not edit one copy. |

## No native dropdowns

There is no native `<select>` anywhere in `web/`: the native dropdown popup does
not render reliably in the CEF compositor, and the platform's tests check that none ships. The input
dialog's `select` field type is a custom `role="listbox"`.
