# open77_cyberware_lab

A test arena for cyberware: a `/cyberlab` panel and command set that installs and removes Gorilla Arms and double-jump legs, grants Dash, Ground Slam and Reflex Overdrive, and probes effects, stamina, life state and routing. Every player may use it on themselves; acting on another player, or on the whole server, needs the server console or the `command.cyberlab.others` ACL right.

- **Docs:** [Cyberware](https://open2077.net/docs/cyberware)
- **Starts:** with `ensure open77_cyberware_lab` (it declares `auto_start false`)
- **Needs:** `open77_equipment`, `open77_dash`, `open77_reflex`
- **Runs on:** server and client

## Use it

It is disabled by default, including on servers that discover resources with a
wildcard. Add it to `resources.load` and explicitly run
`ensure open77_cyberware_lab` from the server console to enable it. Then enter
`/cyberlab` in game.

Freeroam depends on this resource and gives every ready player Athlete double
jump, Advanced Combined Dash (Ctrl), and Street Overdrive (X). The lab depends
on `open77_reflex`: that resource installs the X mapping and native boost;
the lab UI alone cannot activate Overdrive. Existing Overdrive grants/presets
are retained, and missing session grants are restored after lifecycle changes.

This resource defines test grades and provides a `/cyberlab` interface using
public server APIs. Once the optional resource is started, every connected player
can manage cyberware and run the probes on themselves. The separate
[ripperdoc example](../open77_ripperdoc_example/) provides the consent/payment
workflow between two players.

## Who may act on whom

`server/authority.lua` holds one rule, applied to every entry point:

- **Yourself:** open to every player (the panel, `/cyberlab ui`, every text
  command whose player is your own id, the `dash`, `slam` and `reflex`
  subcommands without a player or with your id).
- **Another player:** the server console (source 0) or a player holding the ACL
  right `command.cyberlab.others`. This covers changes (install, remove, kill,
  revive, bucket, health, stamina, knockdown, effects, grants) and reads (state,
  stats, activity, the panel's view of that player).
- **The whole server:** `pvp on|off` (friendly fire for everyone) and the `load`
  fixture need the same authority.

The `/cyberlab` command, its subcommands and the panel's request and action
events all apply the rule, so a client cannot bypass it by sending an event
itself. Refusals answer `operator_required: acting on another player needs the
server console or the command.cyberlab.others right`. A player without the
right sees only themselves in the panel's player list. The right is read live:
granting or revoking it takes effect on the next request.

Grant it in `acl.jsonc` (a principal or role holding `command.*` already has it):

```json
"permissions": [ "command.cyberlab.others" ]
```

The resource declares `acl.read` for this check. After updating an existing
server, run `refresh` before `ensure open77_cyberware_lab` so the new
permission is loaded.

## In-game interface

Enter `/cyberlab` to open the panel with **your own character selected**. An
operator may choose another named player; everyone else sees only themselves.
Then choose Gorilla Arms or Double Jump, a grade, and Install or Remove.
The panel shows the recipient and their current implants, keeps a staged
operation pending until backend completion, and displays failures. Refresh reads
the current roster and equipment. Escape or Close returns control to the game.
`/cyberlab ui <player-id>` opens directly on a recipient (operators, or your own
id). Existing text commands remain available under the same rule; the explicit
number is always the recipient, not the player sending the command.

Implant choices and grades come from `server/config.lua`; the UI does not carry
its own grade definitions or accept arbitrary native item records. Both slots
use the same public installation/removal APIs as the doctor. The server creates
operation IDs and checks the current revision, so players do not need to type
transaction names. Native readiness, supported grades, life state and concurrent
operation checks remain enforced by the cyberware backend.

The panel uses `client/panel.lua`, `server/panel.lua` and `web/`. Its request and
action handlers apply the same authority rule as the text command (see
[Who may act on whom](#who-may-act-on-whom)); a server owner who wants a stricter
policy changes `server/authority.lua` once. This resource stays optional and does
not change `/admin` or the doctor's permissions.

For a throw test, distinguish a quick tap from a held-and-released charged
punch. The training grade requests 3.5 m for a charged hit; industrial requests
4.5 m. Normal hits default to 35% of those distances (1.225 m / 1.575 m). Grade `normalKnockbackMeters`
overrides the normal distance independently. These are bounds, not guaranteed
travel through obstacles. Wait for the preceding knockdown/recovery to finish.
The lab logs public `onCyberwareMotionOutcome` events alongside damage contacts:
`motion_busy` explains accepted damage without a renewed throw.

Freeroam declares the lab as a dependency and starts it automatically.
While Freeroam runs, `server/freeroam.lua` installs Athlete double-jump legs
for ready, living players, then grants Advanced Combined Dash. It waits for
pending installation tickets, retains arms, and preserves foreign Dash grants.
Other gamemodes receive no automatic loadout from this script.

After changing the resource manifest (including permissions), run `refresh`
before `ensure open77_cyberware_lab`. `ensure` alone restarts Lua using the
previously discovered manifest. A new command can therefore run while its
new permission is still absent from the active VM.

For recovery after an explicitly lethal test:

```text
cyberlab health <player>
cyberlab revive <player>
```

`revive` uses the public authoritative `Open77.players.revive` API with full
health (`1.0`) and a 3000 ms grace period. The resource declares
`players.life.revive`; only a canonical
`Dead` player is eligible. Run it from the server console or a living operator
client, not by sending gameplay input to the dead client. An alive or
already recovering target is refused by the life service. There is no local
native resurrection fallback or forced placement.

An accepted result means recovery was requested, not completed. Verify the
server life transition and native `life.state`, positive health, attached/grounded
body, restored paid implant and observer appearance before testing physical
movement again. The arena's `reset` command still cannot revive a dead player.

For an explicit death-interruption test of surgery or active motion:

```text
cyberlab kill <player>
```

This optional command calls `Open77.players.kill(player,{cause="script"})`
with the declared `players.life.kill` capability. It fabricates no attacker,
impulse or melee contact and has no native fallback. Use the server console or
an operator client (a player may also run it on themselves). The authoritative life service owns the death
transition and forwards refusals such as `transition_in_progress`; an already
Dead target is an idempotent success, not a new death event. Verify canonical
Dead, cancellation/cleanup and observer state before requesting public revival.
This tests lifecycle interruption, not lethal melee damage, and runs only when
explicitly invoked. No default arena or RP death rule changes.

After adding a manifest capability, run `refresh` before
`ensure open77_cyberware_lab`; ensure alone may retain cached manifest permissions.

For authoritative hold/release timing:

```text
cyberlab activity <player>
cyberlab activitywatch <player> 5000
```

`activity` returns the public `Open77.cyberware.activity` snapshot as JSON, or
`null` when no fresh usable sample exists. `activitywatch` logs that same snapshot
with server `sampledAt` milliseconds on a 100 ms requested interval (actual tick
scheduling can be slower). Compare `incarnation`,
`sequence`, `holdAt`, `holding`, `charged`, `chargeExpired` and `remainingMs` to
correlate server decisions with captured input and effect timing. Sampling is
not a guarantee of observing transitions shorter than 100 ms.

Watch duration must be 100–10000 integer milliseconds; at most four watches run,
with one per target. Target/requester disconnect or resource stop cancels the
watch. No activity polling runs without an active watch. Both controls remain
inside the lab command and use its existing `players.cyberware.read`
capability; they do not invoke native debug APIs.

For a durable attached-effect comparison:

```text
cyberlab attachplayer <player> electric.industrial_arm 8000
cyberlab effectremove <effect-id>
```

`attachplayer` returns `effect_id=<decimal string>` in the command result and
server log. The TTL defaults to 5000 ms and accepts integers from 1 to 600000.
The command calls `Open77.effects.attach` with a typed player target, observer
body slot `RightHand`, and local `weaponRight`/`right_hand_start` attachment. Draw the
Gorilla weapon before testing the self view. The effect argument is not
a native entity-effect name: pass a world-effect alias or installed depot path.

Compare the industrial alias with an installed Strong Arms depot effect through
the same command. Observe both clients at creation and several seconds later,
move the hands, holster/redraw, stream out/in, then explicitly remove the returned
ID. A returned ID or a native handle does not prove visible particles. Capture
both body families' FPP and observer results.

Only IDs created by this lab's attachment command can be removed by
`effectremove`. Expired IDs are pruned on subsequent creation; resource stop
releases all tracked IDs, and backend ownership independently releases them.
Existing `fxplayer` remains the five-second one-shot body-slot comparison;
`fxoff` clears local probe effects, not durable server-owned attachments.

For an isolated owner-only attachment probe (also usable from the server console):

```text
cyberlab fxself <player> electric.industrial_arm right_hand weaponRight 8
cyberlab fxself <player> fire.small right_hand weaponRight 8
cyberlab fxself <player> electric.industrial_arm RightHand body 8
cyberlab action <player>
```

`fxself` targets only the selected client's own body handle `1`; `fxplayer`
instead broadcasts a typed player effect to eligible observers with a body slot.
The owner probe accepts a world-effect alias or installed depot path, an explicit
slot and `body` or `weaponRight` anchor. Duration defaults to eight seconds and
is bounded to five through ten seconds. The selected client's log records the
created handle, actual attachment result/reason, anchor and slot. A successful
attachment still needs screenshot evidence. Draw Gorilla Arms before the weapon
probe; compare a known visible control effect before blaming the asset.
`action` also logs the complete public native attack-state snapshot on that client.

For native entity-authored placement instead of a standalone world effect:

```text
cyberlab fxevent <player> temp_loaded
cyberlab fxevent <player> spy_perk_charge weaponRight
```

This command calls `Open77.vfx.playEntity` on that client's own body
handle `1`, with an eight-second lifetime. Supply an authored event name, not a
depot path. `temp_loaded` is present in the installed unholstered Strong Arms
appearance. The client logs the returned handle and reason; this confirms event
submission only. Capture the FPP result while the effect is alive.

The optional anchor is `body` (default) or `weaponRight`. `spy_perk_charge`
enables native persistence for this bounded eight-second probe, matching the
installed weapon-script lead. Holstering still triggers native ownership cleanup.
The script lead and submitted event do not establish visible charge effects.

For exact authoritative stamina-cost measurements:

```text
cyberlab staminaRegen <player> off
cyberlab stamina <player> 100
cyberlab stats <player>
```

Perform one accepted normal or charged punch, then repeat `stats` and compare
the stamina debit with that grade's configured cost. Inspect server damage/action
logs alongside the pool; a rejected punch must not produce accepted damage.
Restore regeneration after testing:

```text
cyberlab staminaRegen <player> on
```

These controls use `Open77.stats.get`, `Open77.stats.set(player,'stamina',value)`
and `Open77.stats.setRegenEnabled(player,'stamina',enabled)` with the resource's
`players.stats.read/apply` capabilities. They remain inside the existing
`cyberlab` command and do not invoke native debug APIs.

### Covered-sleeve check

The lab command uses the public asynchronous clothing API:

```text
cyberlab jacket <player> [Items.Jacket_01_basic_01]
cyberlab jacketrestore <player>
```

The first command reserves the player, requests a correlated snapshot, then
changes only `outer_chest` after its original record or explicit empty state is
known. Repeated changes are refused until restoration. The native catalog lists
the default jacket for both body families; inspect actual sleeves and mechanical
hands in owner/observer views. `open77_equipment` supplies the clothing relay;
its normal presentation authority persists and replicates the equipment change.
No direct body customization or wardrobe override is performed.

Inspect `Open77.wardrobe.active()` before testing: active transmog can conceal
this equipment. Preserve and restore any wardrobe change separately through its
public API. Restore the jacket **before disconnecting or stopping this resource**.
This small test utility keeps backups in memory. Disconnect/stop invalidates
pending callbacks and logs the original record (`<empty>` means false) for manual
restoration; it does not write to a recycled player ID or claim automatic rollback.
A failed or timed-out apply retains the backup so `jacketrestore` can be retried.
Logs show correlated completion and acceptance; verify native and observer state
instead of treating a request ID as visual proof. Maximum eight concurrent backups.

### Load fixture

The load fixture, for operators only (the resource itself remains `auto_start false`):

```text
cyberlab load start 60000 1,2,3 visual fire.small
cyberlab load start 60000 1,2,3 audio fire.small w_cyb_strongarms_spy_perk_charge
cyberlab load status
cyberlab load cancel
```

Use explicit ready player IDs, at most 32 unique targets. TTL is 1000–60000 ms;
only one batch runs. Audio mode adds one sound to each visual lease. The fixture
uses public `effects.attach/get/remove`, body RightHand attachment and normal
quotas. It records accepted/rejected counts, failure reasons, authoritative IDs,
expiry and `registryLive`; these are server records, not native handle or visual
proof. Sample native `Open77.vfx.list()` and `Open77.sfx.list()` separately.
A partial allocation failure preserves and reports successful entries. Cancel,
expiry, issuer/target disconnect and resource stop remove owned entries; idle
fixture has no polling thread. Native expiry independently bounds remaining
work if cleanup delivery fails. Synthetic player IDs remain synthetic sessions;
this fixture does not create real clients, bypass readiness or install implants.

`cyberlab capabilities <player>` uses the selected client’s server-bundle resource host to await the public `open77_cyberware` capabilities export. Read the bounded `[cyberware lab] capabilities` line in that client log; the server command result only confirms dispatch. Console use requires an explicit positive player. Missing exports report a failure and can be retried; one export request may be pending per client. Projection readiness is equipment readback, not visual proof, and actual build/DLC verification may remain `unknown`. This does not query a separate bootstrap debug host.

## Double-jump parkour control

Keep this resource optional. It registers `lab.double_jump` with training and
athlete grades through `Open77.cyberware.define`; it does not modify global
movement or install implants automatically. Commands use the same
public install/remove APIs as the doctor:

```text
cyberlab installlegs <player> training <unique-operation-id>
cyberlab state <player>
cyberlab jumpstate <player>
cyberlab removelegs <player> <unique-operation-id>
```

`jumpstate` dispatches a read-only client activity query. The server command
result is dispatch confirmation; inspect the client's log for sequence, phase, grounded state, airborne time and
vertical speed. It asynchronously reads the support resource's `legsActivity`
export because the native request belongs to that VM. This does not jump,
grant approval or count as rendered proof. `state` retains both arms and legs.
Retry an install/remove with its original operation ID; a new action needs a new
ID. The lab definition is distinct from the doctor's paid definition.

For the complete public workflow, use the doctor to install `example.double_jump`,
then use ordinary jump input on surveyed flat ground, an unobstructed gap, a low
ceiling, a wall, a slope, stairs and a safe fall. Record both wearer and observer
views at takeoff, second jump, air loop and landing. Repeat presses before
landing must not create extra boosts. Check stamina, measured position and
native locomotion in addition to images. Remove only legs through the doctor,
repeat the identical input and retain the exact Gorilla Arms record and combat.

Repeat with the other body family and after native knockdown recovery,
death/revival, reconnect, observer stream-out/in and core-resource restart.
Resource restart may also stop definition providers: ensure this lab/doctor
again before interpreting a refused activation.

## Routing visibility control

`cyberlab bucket <player> <bucket>` uses public
`GetPlayerRoutingBucket` / `SetPlayerRoutingBucket` and reports the previous and
read-back current bucket. Player IDs must be positive integers; bucket IDs must
be integers 0..4294967295. These public server routing bindings require no extra
resource permission; moving another player needs an operator.

Record the reported previous bucket, move one test player into a separately
chosen test bucket, inspect actual observer proxy teardown, then return that
player to the recorded bucket and inspect new proxy creation and appearance.
The command does not teleport, restore a previous bucket automatically or grant
an implant. Preserve other sessions' bucket choices. A successful setter is not
proof that either client finished streaming. Large physical distance alone can
leave peers attached and is not stream-out evidence.

## Ground Slam / Quake controls

The optional `/cyberlab` panel includes a Ground Slam session-ability card
for the selected player: yourself, or any player for an operator. Grant, revoke or cancel through the
same public `Open77.abilities` API as ordinary creator resources. It does not
install/remove implants or provide a direct activation bypass.

```text
cyberlab slam grant <player> harmless
cyberlab slam grant <player> combat
cyberlab slam grant <player> gorilla
cyberlab slam grant <player> parkour
cyberlab slam state <player>
cyberlab slam cancel <player>
cyberlab slam revoke <player>
```

Omit the player for yourself; console calls need an explicit positive player.
Default preset is harmless: zero damage/knockback. Combat requests 35 nonlethal
damage and 1.5 m knockback. Gorilla adds an active-arms prerequisite; Parkour
adds active double-jump legs. The two base presets require no implant. Native
blunt-weapon eligibility still applies to all presets.

All presets cost 20 stamina, have a five-second cooldown, allow ground/air and
use a four-meter radius. Edit `server/ground-slam.lua` to configure the normal
binding (`inputKey`, example default `l`) and example policy. Definitions use public
`players.abilities.define`; grant/revoke/cancel use `.manage`; inspection uses
`.read`. Other-player controls need an operator.

Wait for ready projection, equip a blunt weapon, close the panel, then release
and press L. Holding L through a grant or captured UI cannot activate it; an
ordinary landing does not trigger a slam. A pending panel grant is not visual
or combat proof. The panel retains the last observed implant record during
projection and labels it as such instead of momentarily claiming both slots are
empty.

See [Ground Slam / Quake](https://open2077.net/docs/ground-slam) for the complete
copyable public API example, bounds, lifecycle and geometry trust contract.

## Dash / Air Dash controls

Enable the optional lab and its `open77_dash` dependency, open `/cyberlab`, select
yourself (or, as an operator, another player), and use the toolbar's **Dash** shortcut. Choose a
**Basic** or **Advanced** preset and **Ground**, **Air**, or **Combined** loadout.
**Grant** requests a resource-owned session capability. It does not purchase,
replace, or remove an implant. Combined requires installed, active double-jump
legs; standalone Ground and Air loadouts do not install legs automatically.

**Inspect** refreshes server state. The card shows projection status, stamina,
charges, air-dash usage, landing rearm, cooldown and charge regeneration settings.
Native readiness is explicitly unknown when no live native report is available;
a ready projection alone does not establish current movement eligibility.
Grants owned by another resource cannot be replaced or removed through this lab.

**Test instructions** displays guidance only. Close the panel, release the
configured binding, hold a movement direction and tap the binding (default
**Ctrl**). For Air Dash, jump first. With active double-jump legs, jump twice,
then dash. There is one air dash per airtime; land and wait for rearm, charges
and cooldown before repeating. Test forward and lateral movement, a wall and
landing recovery. Remove the session grant with **Remove**, then verify ordinary
movement and jumping. Existing Gorilla Arms and paid legs remain installed.

Creator policy, preset costs, input and allowed zones live in
`server/config.lua`; `server/dash.lua` uses the same public `Open77.dash` and
cyberware APIs as other resources. Freeroam's automatic movement defaults are
described above. See [Native Dash and Air Dash](https://open2077.net/docs/dash).
