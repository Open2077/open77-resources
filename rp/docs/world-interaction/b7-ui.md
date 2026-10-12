# B7: minimal job / inventory / wallet UI over the existing kit (wave 1)

**Row:** B7 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 B:
"Minimal job/inventory/wallet UI over existing kit first; richer grid after contracts stabilize.
Avoid a separate surface per station."). **Date:** 2026-10-12.
**Branch:** `Open2077/open77-rp-examples` `wi/b7-ui`, from `wi/integration` (8109d7d: B1/B2, B3, B4, A9).
**Read against:** plan §4 B7 acceptance, §5.3 Authorization row, §8 "Financial/item durability";
`b1b2-inventory.md`, `b3-wallet.md`, `b4-jobs.md`, `a9-cargo.md`; `wiki/webui.md`,
`wiki/webui-input.md`, `wiki/ui-kit.md`, `wiki/input-blocking.md`.

**Status: built offline, not proven.** Nothing was deployed, launched or run against a database,
and no `open77_*` tool was used. Every behaviour below was executed only in the offline harness
(Lua 5.4 through KeraLua's `lua54.dll`) or, for the two pages, rendered in a headless Chrome with a
fake bridge (layout only). Nothing here claims in-game behaviour; §9 is the integrator's run.
**Fact** = seen in source or in an offline run cited here; **inference** = follows, unmeasured;
**open** = a decision.

---

## 0. Summary

1. **No new surface.** The two existing pages carry the row: the `rp_inventory` POCKETS panel
   (`/inv`, plus a stash column and now a read-only cargo column) and the `rp_hud` panel. No
   per-station page, no new resource.
2. **Inventory panel over the B2 facade:** private per-player pushes on every change, including
   the coordinator's `open77_transactions:committed`; B1 metadata (quality grades, durability,
   serial) per unit; refusals keep their token and the coordinator's own (`capacity_exceeded`);
   `in_doubt` actions shown **pending, in transit, not lost** and watched until settled; a
   read-only vehicle cargo view authorized by `rp_garage:canAccessVehicle(..., "cargo", "view")`.
3. **HUD over B3/B4:** cash and bank from B3 balances with what is still unsettled
   (`+300 incoming`, amber once in doubt), **unknown never drawn as 0**; job, grade and duty from
   B4's `summary`, `records offline` instead of "unemployed" when the file is unavailable.
4. **Focus:** the panel takes the **cursor only** while browsing (the keyboard stays with the game:
   chat, push-to-talk, movement) and the keyboard only while the count field is typed in; it never
   opens over a menu holding the keyboard and closes rather than fight for the focus; every exit
   releases it; a watchdog releases a stray hold.
5. **Tests:** 13 new offline tests (`tests/test_b7_ui.py`), all passing; the whole suite 92 tests,
   one pre-existing error (`lupa` import), with `OP77_TX_ROOT` pinned (§6, §7 F3).
6. **Findings:** a B2 facade bug fixed (wear updates never reached the view), a B2 drop/in_doubt
   gap, and the B2 suite's default prototype path now broken by the A13 wave-1 commit (§7).

## 1. Acceptance and where it is answered

| Plan B7 acceptance / §5.3 Authorization | Answer | Offline evidence |
|---|---|---|
| Only authorized data visible | Panel pushes go to one player (`TriggerClientEvent(..., playerId)`), never `-1`, never a state bag; content = own pockets, a stash opened for that player by its owner resource (`openStash`), a cargo view only after `canAccessVehicle(view)` (and `rp_cargo:contents` asks again). HUD pushes the player's own wallet and job only | `panel_private_refresh` (targets `7x1`, nothing but the public catalogue head broadcast), `cargo_view` (stranger refused before `rp_cargo` is asked), `hud_wallet_and_job` (no `-1`) |
| Chat / voice preserved | Browsing holds the cursor only; keyboard only while typing; the HUD and the kit's progress bar never take focus | `client_focus` (`-C` browsing, `KC` typing) — the keys themselves are §9 |
| Rejected / stale actions show the correct state | Every answer carries the current state; refusal tokens kept (`notice.reason`, `notice.code`); a refused click made on an older `seq` says "That changed meanwhile"; one intent at a time (`busy_intent`); `in_doubt` = pending with the units in transit, confirmed or refused when the store settles | `panel_refusals`, `panel_in_doubt` |
| Reconnect / overlapping menus release focus and controls | Client: release on page close, server close, pause key, focus taken by another surface, session end, resource stop, focus never arriving, stray-hold watchdog; refuses to open over a keyboard holder. Server: closes on death, disconnect, `blocked`, resource stop | `client_focus`, `panel_exits` |
| §8: never mirror private inventories into broadly visible state bags | No state bag anywhere in B7; the panel and HUD are per-player net events | `panel_private_refresh` (`broadcast=none`) |

## 2. Inventory panel (`rp_inventory`)

**Server (`server/main.lua`, panel section only; exports and B2 flows unchanged).**

- **Private refresh.** `refreshPanel` coalesces 50 ms and sends `rp_inventory:panel` to that
  player only. Triggers: every local mutation (as before), the facade's view change (a foreign
  `open77_transactions:committed`, a lost write-behind, a settled async operation), stash viewers,
  cargo events. Each state carries `seq` (monotonic per session) and `backend`.
- **Metadata.** In the transactions backend the entries come from `Facade:effective(view)`:
  `variants` (stack fields such as quality, decoded from the asset id), `units` (unique items:
  instance id and scalar metadata, most worn first; at most 24 per item and 64 per container,
  the rest counted in `moreUnits`, so a state stays far below the event envelope), `held` (units leaving
  in an unsettled async operation) and per-container `sync` (`saving` = write-behind not
  acknowledged, `incomingKg` = credits in flight). The legacy backend sends counts as before.
- **Refusals.** Intents answer `ok, text, reason, info`; the notice is
  `{ ok, kind = ok|refused|retry|pending, text, reason, code?, opId?, stale? }`.
  `capacity_exceeded` arrives as the facade's receiver token (`stash_full`, `too_heavy`,
  `target_too_heavy`) with `code = "capacity_exceeded"`; `store_unavailable`, `busy` and
  `busy_intent` are `retry`; `in_doubt` is `pending`.
- **In doubt.** The facade keeps its holds and settles in the background (B2 §3.2). The panel lists
  the action under *Pending* and reads `status(opId)` without `resolve` (2 s, doubling to 15 s,
  `panelPendingWatchS` = 15 min) until `committed` (`Confirmed: Stored Scrap x2.`) or a
  not-committed state (`Not done: ... Nothing was lost.`); a closed panel gets the line in chat.
  At most 8 watched per player.
- **One intent at a time** per player (`panelBusy`); a handler error is caught (`intent_error`)
  so the guard can never stick.
- **Cargo view** (`intent cargo`): the server picks the vehicle (seated, else nearest registered
  within `panelCargoReach` = 5 m), asks `rp_garage:canAccessVehicle(..., "cargo", "view")`, then
  `rp_cargo:contents`. Re-read on a commit touching its account, `rp_cargo:changed`,
  `rp_garage:changed` and `despawned`; closed on refusal or distance. Nothing in it moves cargo.
- **Exits.** `onPlayerLifeStateChanged` to anything but `alive`/`recovering` closes the panel;
  `blocked` (client refused to open) closes it with a chat line; disconnect clears the session,
  the watched operations and the busy guard; a stash column closes past `panelStashReach` = 6 m
  from where it opened (the player can walk now), a cargo view past reach + 1 m.

**Client (`client/main.lua`, `client/catalogue.lua`).** Surface created visible with an empty
document (the proven pattern of `wiki/webui.md`); focus as in §4; each entry enriched with
`def = { durabilityMax, quality, serial }` from the verified B1 catalogue (global
`RpInvClientCatalogue`, added to `catalogue.lua`).

**Page (`web/index.html`).** Tiles show `x2 +2 in transit` (dashed amber), `dur 15/20` (red under
25 %), `2 grades`; the detail lists units with durability bars and serials, and grades with counts;
a *Pending* strip; container chips `saving` / `+2.0 kg incoming`; toasts coloured by kind with the
token chip; a `Vehicle cargo` button and a read-only CARGO column; count steppers plus `all`; a
25 s client-side unlock if an answer is lost. Headless renders (fake bridge, not the game) checked
the layout with pockets + stash + cargo + pending, a selected unique item, and an idempotent
double close leaving an empty page.

**Manifest:** `input.actions` added (client `Open77.input.isCaptured`). **Config**
(`shared/items.lua`): `panelStashReach`, `panelCargoReach`, `panelUnitsShown`, `panelUnitsBudget`,
`panelPendingWatchS`, `panelFocusGraceMs`.

## 3. HUD (`rp_hud`) and the wallet read (`rp_economy`)

- **Wallet.** `readWallet` calls `rp_economy:walletStatus(playerId, { minAgeSeconds = 1.5 })`:
  balances plus `incoming` (atomic credits in flight, not in the balance), `outgoing` (debits in
  flight, already subtracted), `unconfirmed` (write-behind credits not acknowledged), `inDoubt`.
  Not loaded = `wallet.state` (`not_loaded`, `store_unavailable`, `migration_pending`...) and no
  number. Coordinator down with a loaded wallet = last known values plus `offline, last known`.
  Without the export (older `rp_economy`) the HUD falls back to `getBalance` / `getAccount`.
- **`rp_economy` gained two additive, read-only, synchronous exports** (`walletStatus`,
  `pendingPlayers`) in a separate block of `server/main.lua`; no existing export, event or
  behaviour changed. They read the cache (`Wallets.byPlayer`, `accounts[id].tracked`).
  **B3 owner: please review/adopt** (§8 item 1).
- **Pending watch.** One `pendingPlayers()` call per 2 s for the whole server; players whose
  fingerprint appeared, changed or vanished are re-pushed (an atomic credit raises no event until
  it settles). New events consumed: `rp_economy:walletChanged` (cash/bank), `rp_jobs:workEpoch`.
- **Job.** `rp_jobs:summary(playerId)`: job, label, grade, grade label, duty; a refusal becomes
  `jobState` (`store_unavailable` -> `records offline`, `not_loaded`/`player_not_found` ->
  `loading`). Fallback to `getJob`/`getGrade`/`onDuty` without the export.
- **Page.** Amber pending line under Cash/Account; `offline` / `loading` in place of a number;
  hidden state now also `visibility: hidden`, so a hidden or reloading page leaves no blurred
  rectangle (`backdrop-filter`).

## 4. Focus and controls

| Situation | Client behaviour | Evidence |
|---|---|---|
| Browsing | `setFocus(false, true)`: cursor only | `client_focus` `open_focus=-C` |
| Count field has the caret | `setFocus(true, true)`; back to cursor only on blur | `typing_focus=KC`, `typed_focus=-C` |
| Another WebUI owns the keyboard at open | poll `isCaptured` 10 x 100 ms, then `blocked`; never calls `setFocus` | `blocked=... focusCalls=0` |
| Another surface takes the focus while open | close, tell the server, never re-take | `taken`, `taken_no_regrab` |
| Focus never arrives (surface cannot present) | close after `panelFocusGraceMs` (3 s) | `never_focused` |
| Closed but still holding | watchdog `setFocus(false, false)` (releases only the holder) | `stray=none` |
| `x` / page Escape / pause key / server close / session end / resource stop | release, idempotent | `page_close`, `pause_close`, `server_close`, `session_end`, `stop` |
| Page document reloads | closed -> `close` sent again; open -> state and focus again | `reload_closed`, `reload_open` |
| Death (server) | `{ open = false }` | `panel_exits` `death_closes=1` |

Escape: `wiki/webui.md` says a keyboard-focused page receives Escape and `open77:pauseKey` is not
raised; `wiki/ui-kit.md` and `open77_admin` say the plugin swallows it and raises the pause key.
The panel handles both (page keydown and `open77:pauseKey`), each idempotent. While browsing
(cursor only) Escape reaches the game: **inference**, the pause menu may open as the panel closes.

## 5. Authorization and privacy

- The cargo view is the only new data source and is asked twice (panel, then `rp_cargo`); a
  stranger's refusal never reaches `rp_cargo` (test `contents_asked_for=7`). Access changes close
  an open view on the next event (`rp_garage:changed`), distance within a second.
- Stash moves keep B2's per-move re-authorization (registered stash authorizers); the panel adds
  the reach rule because a player can now walk with it open.
- Instance ids / serials are shown only for containers the viewer already sees.
- The B1 catalogue head stays the only broadcast (public definitions, B1 §1.4).

## 6. Offline tests

`python -m unittest discover -s tests -p "test_b7*.py"` — 13 tests, **OK** (2026-10-12). The
coordinator is the vendored A13 prototype (`tests/compat/vendor/open77_transactions`, pinned blob
ids) unless `OP77_TX_ROOT` / `OP77_TX_DIR` say otherwise.

| Test | Covers |
|---|---|
| `test_refresh_is_private_and_follows_foreign_commits` | foreign commit on A's pockets -> one push, to A only; B untouched; no broadcast but the catalogue head |
| `test_metadata_variants_and_units` | quality grades kept apart; durability most worn first and **following `wearAsync`** (15,20); serial = unit id |
| `test_unit_lists_are_bounded` | unit lists capped per container (budget 3 in the test), the rest counted |
| `test_refusals_keep_their_reason_and_the_state_is_current` | local `stash_full`; coordinator `capacity_exceeded` (stash filled by another writer a tick earlier) moving nothing; stale click; `store_unavailable` as retry; unknown action |
| `test_in_doubt_is_pending_then_confirmed` | lost answer + `status` in_doubt: second click `busy_intent`, units `2+2 in transit`, `+2.0 kg incoming`, pending notice and list, then `Confirmed: Stored Scrap x2.`, counts `2/2`; closed panel -> chat confirmation |
| `test_cargo_view_is_authorized_private_and_closes` | owner sees plate/slots/labels read-only; stranger `no_access` without `rp_cargo` being asked; re-read on commit; closes on revocation, on walking away; `garage_unavailable` as retry |
| `test_exits_close_the_panel` | death, `blocked`, stash reach |
| `test_every_exit_releases_focus` | the client against a fake one-slot focus model (§4 table) |
| `test_wallet_and_job_from_b3_b4` / `test_falls_back_to_the_1x_exports` | HUD snapshot fields, unknown != 0, pending watch pushes (appear, settle), events, privacy; 1.x fallback |
| `test_pending_is_reported_until_settled` | real `rp_economy` on the B3 world: in-flight credit `incoming=300` not in balance, write-behind debit `outgoing=100`, `inDoubt` after the caller's 20 s, `pendingPlayers`, settled -> clear, durable 700 |
| static | changed Lua compiles, no BOM; pages contain no network call |

Whole suite: `OP77_TX_ROOT=tests/compat/vendor/open77_transactions python -m unittest discover -s
tests -p "test_*.py"` -> 92 tests, 1 error (pre-existing `lupa` import in `test_held_actions.py`).
`test_compat_contracts.py`: `FROZEN_SURFACE` gained the consumed exports (`rp_economy`
`walletStatus`/`pendingPlayers`, `rp_jobs` `summary`, `rp_garage` `canAccessVehicle`), with the
note in `b8-compat-audit.md`.

**What these tests cannot show:** the pages in CEF, the focus slot and key routing of a real
client, chat/voice, real tick ordering, the coordinator's wave-1 wiring, MariaDB.

## 7. Findings

- **F1 (B2, fixed here, one line).** `Facade:transact` collected accounts with
  `ipairs({ l.from, l.to, l.at })`; a metadata update line has no `from`, so ipairs stopped and
  `wearAsync`'s container got no hold and no committed delta: the store said durability 15, the view
  (and every panel and `read`) 20 until a reload. Now `pairs` (accounts are sorted after).
  **Fact (offline):** before 20,20, after 15,20. B2 owner: keep or replace with your own fix.
- **F2 (B2, not changed).** `dropItemsTx` treats an `in_doubt` transact like a refusal: it removes
  the loot projection and releases the world view, although the goods may be committed in
  `world:<id>`. They are conserved (journaled) but have no projection until a projection owner
  re-creates it (B2 §3.5 already lists restarts). The panel shows such a drop as pending without an
  operation id to watch.
- **F3 (environment).** The B2 suite defaults to the live
  `wt-world-interaction/resources/system/open77_transactions`; since A13 wave-1 (697e9e2f,
  05:28) that path breaks it (players never load: the `txhost.lua` stand-in does not match the new
  coordinator). **Fact:** a clean `git archive HEAD` of this branch fails 14 of its 20 tests against
  it and passes them against the vendored prototype. Run with `OP77_TX_ROOT` pinned until the
  harness follows wave 1.
- **F4 (docs).** `wiki/webui.md` and `wiki/ui-kit.md` disagree on where Escape goes for a
  keyboard-focused page (§4). One of them is wrong for this build.

## 8. Needs (contracts not changed here)

1. **B3:** adopt or replace `walletStatus` / `pendingPlayers` (§3). A host event on in-doubt /
   settle (`rp_economy:pendingChanged(playerId)`) would replace the 2 s poll.
2. **B2:** a per-operation settle callback or event (`rp_inventory:settled(opId, state)`) so the
   panel need not read `status`; `meta` / `instances` selection in the panel intents once the grid
   grows (B2 already accepts them in `storeAsync` etc.); F1 and F2.
3. **A13:** a cheap non-yielding `status` for the watcher; `open77_transactions:committed` carrying
   the invoking resource (A9 N5) would let the cargo view skip its own reads.
4. **A9:** a `cargo:view` without the access check duplicated in the panel, or a documented promise
   that `contents` always checks (it does today).
5. **Platform:** a "focus released" edge (or `menuState().overlayResource` without the
   `session.menus` permission) would let a closed panel reopen after the chat instead of staying
   closed.

## 9. Integrator checklist (lab, two clients, transactions backend)

Load: `open77_transactions` (wave 1, store `sql`), `rp_inventory` with convar
`rp_inventory_backend transactions`, `rp_economy`, `rp_bank`, `rp_jobs`, `rp_hud`, `rp_garage`,
`rp_cargo`, `open77_uikit`, `open77_contextmenu`, `open77_loot`, the chat and voice packages.
Clients A (id 1) and B (id 2). Hash every artifact that runs. Expected screens below are what this
code is written to show; none has been observed.

1. **HUD baseline.** Both join: bottom-left panel; Cash/Account show `loading` (amber) until the
   wallet loads, then numbers — never `0` first. Job line `unemployed · no shift` or the job.
2. **Private refresh.** A and B both `/inv`. Console `giveitem 1 scrap 3`: A's panel gets a
   `Scrap x3` tile; B's panel does not change. Log: `player 1 +3 scrap`.
3. **Metadata.** From a lab resource:
   `exports.rp_inventory:define({ b7_tool = { label = "Lab crowbar", weight = 1.5, durability = 20, serial = true }, b7_ore = { label = "Lab ore", weight = 1.0, quality = { min = 1, max = 3 } } })`,
   then `add(1, "b7_ore", 2, { quality = 3 })`, `add(1, "b7_ore", 1)`, `add(1, "b7_tool", 2)` and
   `Open77.exports.call("rp_inventory", "wearAsync", 1, "b7_tool", 5):await()`. A's panel:
   `Lab ore x3 · 2 grades`, `Lab crowbar x2 · dur 15/20`; select the crowbar: two units
   `#<serial> · 15/20` (bar) and `· 20/20`, hint `The most worn unit moves first.`
4. **Refusal.** `exports.rp_inventory:openStash(1, "lab:b7", 1)`; store 2 scrap: red toast
   `The stash is full.` with chip `stash_full`; tile still `x3`.
5. **Outage.** Stop `open77_transactions`; A stores 1 scrap: grey toast
   `The inventory service is unavailable. Nothing moved...` chip `store_unavailable`. HUD Cash shows
   the last value and `offline, last known` (amber). Start it: storing works again.
6. **Focus, chat, voice (A).** `/inv`: cursor visible, WASD moves the character, no mouse-look.
   Hold push-to-talk: B hears A. Press the chat key: chat opens, the panel closes, no cursor left
   behind; send a line, B reads it. `/inv`, click the count field: WASD no longer moves; Escape
   leaves the field; Escape again closes the panel (note whether the pause menu also opens).
7. **Overlapping menus.** `/inv`, then ALT+click B > **Give item**: the dialog opens, the panel
   closes; finish or cancel the dialog: full control, no stuck cursor. With the dialog open again,
   push a panel to A from a lab resource (`exports.rp_inventory:openStash(1, "lab:b7", 1)`, since A
   cannot type): after about a second, chat `Another menu holds the keyboard...`, no panel, and the
   dialog keeps the keyboard.
8. **Reconnect and restarts.** With the panel open: A reconnects -> no panel, no cursor, chat and
   voice work, `/inv` works. `restart rp_inventory` with the panel open -> it vanishes, no scrim.
   Restart `rp_hud`, `rp_inventory` and `open77_uikit` together -> no stuck dark or blurred
   rectangle on either client.
9. **Death.** `/inv`, A is killed: the panel closes; after respawn control is normal.
10. **Stash reach.** Open the `lab:b7` stash panel, walk 7 m: the stash column disappears, red
    toast `You walked away from the stash: it is closed.`
11. **Cargo view.** A owns a garage Mackinaw with one crate loaded through `rp_cargo:load`. A next
    to it: **Vehicle cargo** -> a CARGO column `<plate>`, `read-only`, slot list with the crate.
    B (stranger) next to it: red toast `You have no access to this vehicle's cargo.` chip
    `no_access`, no column. A gives B a key, B retries: column. Revoke B's key with B's view open:
    B's column closes, toast `Cargo view closed: ...`. A walks 7 m: A's column closes.
12. **Job.** A `/service`: the duty dot turns green within a push. Stop the database and reconnect
    A: Job line `-- records offline`.
13. **Pending (optional, needs a slow store).** If the lab can delay the database (for example a
    firewall rule on its port for ~40 s) while A stores 2 scrap: second click `Still working on your
    last action.`; after ~30 s an amber *Pending* strip `store Scrap x2 · ... not lost, confirming`,
    tile `x1 +2 in transit`; when the database answers: `Confirmed: Stored Scrap x2.` and the strip
    empties. The same delay during a sale payout should show `pending: +N incoming` on the HUD.

Grep-able lines: `panel intent <action> of player <id> raised`, `player <id> panel <action> <item>
x<n> op <opId> settled: committed|not_committed|timeout`, `panel reach watch:`.

## 10. Research ledger entry (for the integrator to copy)

> **2026-10-12 — B7 minimal job/inventory/wallet UI (RP pack `wi/b7-ui`, offline).**
>
> **Built:** no new surface. `rp_inventory` panel: private per-player pushes (incl. foreign
> `open77_transactions:committed`), B1 metadata (grades, durability, serial), refusal tokens with
> the coordinator's code, `in_doubt` = pending/in transit watched by read-only `status`, one intent
> at a time, read-only cargo view behind `rp_garage:canAccessVehicle(..., "cargo", "view")`, cursor-
> only focus with keyboard only while typing, every exit releasing. `rp_hud`: wallet from B3
> (`walletStatus`, unknown never 0, pending incoming/unconfirmed) and job from B4 `summary`.
> `rp_economy`: additive read-only `walletStatus` / `pendingPlayers`.
>
> **Facts (offline, KeraLua lua54.dll; vendored A13 prototype):** 13 B7 tests OK; whole suite 92,
> 1 pre-existing lupa error. A foreign commit refreshes only its owner's panel; a stranger's cargo
> request is refused before `rp_cargo` is asked; a lost answer shows `2+2 in transit` then
> `Confirmed`; an in-flight sale credit reads `incoming=300` outside the balance. Facade bug: wear
> updates never reached the view (`ipairs` over `{ from, to, at }`), fixed. The B2 suite's default
> prototype path fails since A13 wave-1 697e9e2f.
>
> **Inferences (unmeasured):** chat, push-to-talk and movement keep working while the panel holds
> only the cursor; Escape while browsing may also open the pause menu.
>
> **Not done:** any live run (`docs/world-interaction/b7-ui.md` §9), the richer grid, unit
> selection in intents.
