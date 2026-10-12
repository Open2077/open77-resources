# open77_admin

This resource gives server operators an in-game admin menu (`/admin`) and a full admin console (`/adminfull`) to manage players, vehicles, weapons, props, doors and the weather, with every action checked against the server's ACL.
It is the gamemode-agnostic admin package: two operator surfaces (a compact
keyboard menu on `/admin` and the full console on `/adminfull`) and the
commands behind them. It introduces no join behaviour, no death behaviour and no combat
policy, so it can sit inside **any** resource set, including a server running
Pursuit, Freeroam, or a custom roleplay server.

- **Docs:** [Public identity, server commands, and ACL](https://open2077.net/docs/server-acl)
- **Starts:** on its own
- **Needs:** `open77_contextmenu`
- **Runs on:** server and client

## Install on any server

1. Deploy this **whole folder** as `resources/system/open77_admin` (or another
   scanned resource directory). No Freeroam, Race, PvP, debug, database, or master
   service is required by the menu.
2. Add `open77_admin` to `resources.load` if the server uses an explicit allowlist.
   Leave the other load entries and gamemode unchanged. With wildcard discovery,
   the resource already declares `auto_start true`.
3. Use a server build containing the `acl.read` bindings, not just new Lua files.
   Older hosts fail closed for admin actions. Connect/reconnect after installation
   because this resource owns WebUI surfaces (`reload_policy "reconnect"`).
4. Merge the desired roles from `acl-roles.example.jsonc` into the server's ACL,
   bind your own authenticated principals, and run `acl.reload`. No real identity
   is bundled, and ordinary players never receive an admin role automatically.

`command.admin` opens the menu; grant the individual `command.admin.*` actions
that role should use. Weather and weapon adapters are optional and their actions
are disabled when the corresponding resource is absent. Announcements render
through this resource even without chat or notifications.

`/pos` and `/rot` are intentionally **public**, self-only read commands. They
show and copy the local character position or quaternion plus yaw in degrees.
They have moved out of `open77_debug`; deploy its matching update if it is used.

Kick/ban and announcement text is entered in a form, then explicitly confirmed
with Cancel selected by default. Bans persist through `Open77.access` in the
server's own access file and block the authenticated identity on reconnect,
including after a server restart. They do not impose a network-wide master ban.
Use Warden Access or the server's `unban <identity>` console command to lift one.
Durations are positive and bounded to 3650 days; `perm` is explicit in the menu.
If persistence fails, the ban reports failure and does not kick the player.

---

## Server-wide actions (TpAll / DVAll)

When Freeroam is running, `/admin` also offers **Freeroam playtest**:
**Everyone → Foot Race queue**, **Everyone → Vehicle Race queue**,
**Everyone → Free-for-all**, and **Everyone → Blade FFA**. These run the restricted Freeroam commands
`admin.playtest.foot`, `admin.playtest.race`, `admin.playtest.ffa`, `admin.playtest.blade`; the cancel
action runs `admin.playtest.cancel`. Grant `command.admin.playtest.*` or the
individual commands. The existing operator role's `command.admin.*` covers
them. Freeroam owns the transitions and reports enrolled/skipped/failed counts;
this optional menu adapter does not start Freeroam on other gamemodes.

In `/admin`, open **Server actions**. There are also shortcuts at the bottom of
Players and Vehicles. Both actions require a confirmation, with Cancel selected
by default. The full console can run the same commands:

```text
admin.bulk.tpall confirm     /tpall confirm
admin.bulk.dvall confirm     /dvall confirm
admin.bulk.cancel
```

TpAll snapshots all other **gameplay-ready, alive** players across all routing
buckets. It gathers them in the operator's bucket around the position captured
when the action starts. Players arrive one at a time, **750 ms apart**, on
concentric rings with **at least 3 m spacing**; the operator is not moved.
Readiness/life/session and the operator's permission are checked again before
each move. Loading, dead, disconnected or replaced sessions are never moved.
Stand on **open, level ground** and leave your vehicle first: offsets are not a
terrain/navigation query and cannot detect a cliff or nearby wall. Teleports
use the same life/streaming transaction as Bring (full health and spawn grace).

DVAll snapshots **all canonical network vehicles**, regardless of creator,
owner, distance or routing bucket; it is not limited to the admin spawn ledger.
Occupants receive a forced exit (including exit-locked seats), and removal waits
for the live occupancy ledger to clear, up to 5 seconds. A refused/timed-out exit
leaves that vehicle intact and reports the failure. Processing is spaced by
150 ms per vehicle. Vehicles spawned after the snapshot are not swept. This does
not delete parked decorative map objects or disable subsequent traffic/spawners.

Only one bulk action runs at once. Cancel stops pending work, not completed
teleports/removals or exits already requested. Disconnecting the operator or
revoking the invoked command's ACL also stops the worker. Results include
completed, skipped, failed and unprocessed counts, with an audit entry. A 10 s
cooldown follows completion/cancellation. All timings live in `Config.bulk`.

Permissions: `command.admin.bulk.tpall`, `command.admin.bulk.dvall`, and
`command.admin.bulk.cancel`. Aliases separately require `command.tpall` and
`command.dvall`; they do not bypass the registry. Built-in admin/owner and the
example operator role already cover canonical commands. Do not grant these
server-wide permissions to ordinary players. Older hosts that still enforce
vehicle creator ownership must be upgraded for cross-resource DVAll.

Regression checks: `tests/bulk_test.lua` (Lua 5.4 from this resource directory).
DVAll removes vehicles created by any resource, including an exit-locked
occupied vehicle, whose driver is left alive on foot.

## The one thing to understand before changing anything

### Noclip controls (0.4)

`/admin.self.noclip` and `/admin.self.fly` use the same resource-owned native
flight controller. Movement follows the camera with the user's configured
locomotion keys. Space/Ctrl ascend/descend, Shift boosts 4x, Alt slows to 0.25x,
and the mouse wheel adjusts speed by 20% per notch (base range 0.1–500 m/s).
The configured default is applied only on the first activation of a connection.
`/admin.self.speed <m/s>` still works. The compact HUD and full panel read back
the actual wheel-adjusted speed through `Open77.travel.getNoclipSpeed()`.

Focused WebUIs and menus suspend flight input. Vehicle/workspot activation is
refused with a visible explanation; death, body changes and resource stop
release flight. The client `noclipState` event reports transitions only: it
cannot enable flight or grant ACL. Deploy the matching client build to get the
new controller; an older client retains its existing controller and has no
wheel-speed readback.

### Authority

**The host ACL is the sole authority.** Server-only `Open77.acl.isAllowed`
and `Open77.acl.roles` are read-only bindings behind manifest capability
`acl.read`. They resolve the authenticated session, never a client-supplied
user ID or nickname. The transport still checks the command before scheduling:
```csharp
var permission = $"command.{command}";
var allowed    = _accessControl.IsAllowed(userId, publicKey, permission);
_resources.ExecutePlayerCommand(source, tokens, allowed);
```

and the Lua sandbox refuses before the handler is even scheduled:

```lua
if entry.restricted and not allowRestricted then return 2 end
```

The corollary is the whole architecture of this resource: **a
`RegisterNetEvent` handler carries no authorisation whatsoever.** Any net event
a resource exposes is open to every authenticated player on the server.

So **every privileged action here is a restricted `RegisterCommand`, and nothing
else.** The panel is a command front-end: a click becomes a command line, sent
through `open77:command:execute`, the same path the chat box uses, meeting the
same gate. A hostile client that hand-crafts the packet gets exactly the same
answer.

If you find yourself adding an action to `open77_admin:*`, you are adding a
hole. Add a command.

The unprivileged `hello` and `rated` events report client capabilities and
bounded catalogue measurements only; neither grants an action.

---

## Rights

One source: `acl.jsonc`, compiled by the server host. This resource implements
no rights system of its own: doing so would be a rights system enforced by the
very resource it grants rights to. What varies is only who writes the file:

| Writer | How a grant reaches the game |
|---|---|
| **Warden** (Players → Rights, Access tab) | Warden is *in-process*: it is the game server. A grant validates, writes `acl.jsonc` atomically, and swaps the compiled set in memory. It takes effect on the very next command: no reload, no reconnect, and the player need not be online. |
| **A text editor** | Edit `acl.jsonc`, then `acl.reload` at the console. The document is fully re-validated before the swap, so a malformed edit throws and the previous set stays live. |
| **This resource** | Reads the compiled ACL. It never writes roles or permissions; grants remain in Warden or the server console. |

`acl-roles.example.jsonc` in this folder is a paste-ready `roles` block with
`helper`, `moderator` and `operator`, and explains the two wildcard footguns
that catch everybody:

* `command.admin.*` does **not** match `command.admin`, so a role needs both.
* `command.*` **does** match `command.client.exec`, so the built-in `admin`
  role hands out arbitrary Lua execution in another player's privileged VM on
  any server that also runs `open77_debug`.

---

## Two surfaces, one authority

| | `/admin`: the menu | `/adminfull`: the console |
|---|---|---|
| Shape | A responsive 380px strip on the right edge | Full screen, modal |
| Input | Arrow keys and Enter, **polled** | Mouse and keyboard, **captured** |
| While it is open | You are still playing: mouse-look, movement, aiming | You are not playing |
| For | Spawn it, then look at it | Rosters, the 1,372-record catalogue, audit, arbitrary commands |
| Permission | `command.admin` | `command.adminfull` |

**Both are restricted**, so a player without the grant gets one line and no
surface. On success the *server* tells that one client to raise it. A patched
client can force either UI up and gains nothing: they render only what the
server pushed, and every control is a command that will be refused.

**The console is `/adminfull`, not `/admin`.** It has its own permission,
`command.adminfull`; a role that lists only `command.admin` opens the
menu and not the console, silently. `acl-roles.example.jsonc` lists
both where they belong, and note that `command.admin.*` covers *neither*: the
matcher keeps the dot and neither name has one.

### The compact menu (`/admin`)

FiveM's shape: a title, a breadcrumb, a vertical list with one highlighted row,
`>` on rows that open a submenu, and a key-hint footer.

```text
UP / DOWN     move the selection (wraps)
ENTER         activate
LEFT / RIGHT  change a value, where the row has one
RIGHT         otherwise, open the submenu (the rows marked `>`)
LEFT          otherwise, go back one screen
BACKSPACE     go back one screen; at the root, close
ESC           close (the plugin swallows Escape and raises open77:pauseKey)
/admin        run it again to close
```

Keys fire on the **down-transition**, then auto-repeat after 350 ms at 8/sec,
which is what makes a 28-family prop list usable. A key that is already held
when the menu opens is inert until released; otherwise the ENTER that
submitted `/admin` in chat would activate the first row.

The tree:

```text
Players ▸ <roster> ▸  Teleport to / Bring here / Observe / Heal / Revive /
                      God mode / Weapons ▸ / Kill* / Kick* / Ban ▸ 30m 2h 12h 7d perm*
Vehicles ▸ standard | sport | sportbike ▸ <alias> → spawn beside you
Weapons ▸  Slot ↔ / Refill ammo / Holster / Clear slots /
                      <12 classes> ▸ Slot ↔ / <weapon> → give it LOADED
Props ▸    Aim distance ↔ / Effects ▸ / Clear my props / <28 families> ▸
                      <alias> → spawn AT AIM
Self ▸     Noclip / Fly / Noclip speed ↔ / God mode / Heal / Revive / Copy position
World ▸    Teleport ▸ <saved destinations> / Time ▸ / Weather ▸ / Cleanup vehicles
Developer ▸ Doors ▸ Door Inspector ON/OFF / Nearby doors / Inspector radius
Close
```

`*` routes through a one-keypress Confirm screen. Nothing else does: a
confirmation on a heal only teaches the operator to press ENTER twice by
reflex.

**Door Inspector (0.3.0).** `/admin → Developer → Doors` toggles local native
3D cards above the nearest eight streamed doors within 25 m. The first row
shows the opaque door ID and LOCAL open/closed/locked/sealed flags. The second
shows the SERVER target, routing bucket, revision, automatic mode and elevator
ID/floor when known. Amber means a local/server mismatch (which can be transient);
red means locked/sealed, green open, cyan closed and grey no server snapshot.
Distance is rendered natively. Labels use the native occlusion/off-screen culling.
`open77_doors` is optional: without it the inspector reports native-only state.

Grant `command.admin` to open the menu and
`command.admin.dev.doors.inspect` to use this tool; the existing operator
`command.admin.*` grant covers the latter. Direct command:
`/admin.dev.doors.inspect [on|off|toggle]`. Every toggle passes the restricted
server command registry. The overlay is visible only to its operator, never
changes a door, and needs the client door/anchor APIs (release `.58` recommended).
Closing the menu keeps it active; OFF, ACL revocation, world change, resource
stop or an expired 3.5-second server lease clear its anchors. It starts OFF.
Native state is sampled twice per second while enabled; unchanged cards are not
updated. Projection/drawing runs natively every frame, without another CEF page.

**Layout and input.** The menu sits below the minimap at 32vh, 32px from the
right, reserving 128px at the bottom. The page reports how many rows fit;
Lua windows the list, so neither the current selection nor the footer clips.
Normal arrow navigation keeps gameplay input. Only entering a kick/ban reason
or announcement captures keyboard and cursor. Escape cancels the form, and
submission releases focus before a separate confirmation screen opens.

**Spawn at aim** comes from `Open77.camera.view()`: there is no raycast
binding on this platform, and the debug bridge's `world.lookat` is not one
either (it calls `gametargetingTargetingSystem::GetLookAtObject`, which answers
with an *entity* under the crosshair or nothing). Looking down, the forward ray
is intersected with the horizontal plane through the operator's own feet, which
puts the prop on the floor they are standing on; level or upward, it is a fixed
distance along the ray, tuned with LEFT/RIGHT on `Aim distance`.

### The console (`/adminfull`)

Eight screens, in the order an operator reaches for them:

| Screen | For |
|---|---|
| **Overview** | The first ten seconds. Players, vehicles, buckets, uptime, resource health, last six actions. |
| **Players** | A report names somebody. Find them, get to them, act. |
| **Vehicles** | Browse and spawn from all 1,372 records; tune the performance governor. |
| **World** | Time and weather (delegated to `open77_weather`), saved destinations, announce, cleanup. |
| **Props** | Set dressing: props, lights and effects, spawned into your own routing bucket. |
| **Self** | Noclip, fly, speed, god, heal, revive, copy position, teleport to coordinates. |
| **Console** | Any command, with a palette harvested live from every resource's chat suggestions. |
| **Audit** | What this resource did this uptime. |

Both surfaces receive a concrete command map derived from the real ACL.
Unavailable actions are disabled before use. The server republishes changed
rights every second and rechecks each scheduled action; losing access closes
the affected menu/form and disables admin-owned noclip/map travel.

---

## Commands

Every privileged command is `RegisterCommand(name, fn, true)`; the permission is always
`command.<name>`.

```text
admin                                        open the compact keyboard menu
adminfull                                    open the full console

admin.read.players                           roster: position, bucket, life, health
admin.read.vehicles                          live vehicles, the ledger, the caps in force
admin.read.world                             destinations, buckets, resource states
admin.read.props [radius]                    props and looping effects near you (what the panel polls)
admin.read.audit                             this uptime's actions

admin.self.noclip [on|off]                   Shift x4 // Alt x0.25 // Space up // Ctrl down
admin.self.fly [on|off]
admin.self.speed <0.1..500>
admin.self.god [on|off]
admin.self.heal
admin.self.revive
admin.self.pos                               copy your transform as Lua
admin.self.maptravel [on|off]                arm the map: double-click a spot to go there
admin.self.maptravel <x> <y> <z>             what the double click sends; same permission

admin.player.goto <id>                       move YOURSELF to them
admin.player.bring <id>                      move them to you
admin.player.tp <id|me> <x> <y> <z> [yaw]
admin.player.at [id] <location>              saved destination
admin.player.observe <id>                    goto + noclip
admin.player.heal|revive|kill <id>
admin.player.god <id> [on|off]
admin.player.health <id> <0..1>
admin.player.armor <id> <armor>

admin.moderate.kick <id> [reason]
admin.moderate.ban <id> [30m|12h|7d|perm] [reason]   persistent server-local identity ban

admin.veh.spawn <record|alias> [x y z yaw]
admin.veh.give <id> <record|alias>
admin.veh.remove <vehicleId|mine|all>
admin.veh.repair <vehicleId> [scope]
admin.veh.flag <vehicleId> <flag> [on|off]
admin.veh.speed <vehicleId|record> <kph> [taper] [throttle]
admin.veh.speed.here <kph> [taper] [throttle]        the car you are in, or the nearest
admin.veh.speed.global <kph> [taper] [throttle]      every spawned vehicle, weakest tier
admin.veh.speed.clear <vehicleId|record|here|global|all>

admin.weap.give <id|me> <record|alias> [slot|auto] [reserve]   LOADED, see The Weapons tab
admin.weap.ammo <id|me> [slot|all] [reserve]         refill to a full load
admin.weap.remove <id|me> [slot|all]                 clears the slot, keeps the item
admin.weap.holster <id|me>
admin.weap.catalog                                   the 12 classes and their full loads
admin.read.weapons [id|me]                           a player's three slots, as their client verified them

admin.props.spawn <model> <x> <y> <z> [yaw]
admin.props.here <model> [yaw]               at your feet; z is the ground
admin.props.list [radius]                    id, model, kind, distance, bucket
admin.props.move <id> <x> <y> <z> [yaw]
admin.props.remove <id>
admin.props.clear                            everything THIS package created
admin.props.catalog                          curated model and effect aliases
admin.props.light <x> <y> <z> [intensity] [radius] [r] [g] [b]
admin.props.light.here [intensity] [radius] [r] [g] [b]
admin.props.light.toggle <id> <on|off>

admin.fx.play <effect> [x y z]               one-shot; no coordinates means at you
admin.fx.loop <effect> [x y z]               registers a looping record, ttlMs = 0
admin.fx.list
admin.fx.stop <id>
admin.fx.fireworks [rounds] [x y z]          volleys of shells, synchronized for everyone in range
admin.fx.show <preset> [x y z]               scripted show: opening, celebration, finale, storm
admin.fx.show.stop                           ends the running show (alias: admin.fx.fireworks.stop)
admin.fx.stage [x y z]                       dress a venue: holo floor, beacons, columns
admin.fx.stage.clear                         take the venue down

admin.world.announce <text>
admin.world.loc.add <name> [label]
admin.world.loc.remove <name>
admin.world.cleanup
admin.server.status
```

**A ban duration carries a unit** (`30m`, `12h`, `7d`, `3600s`, or `perm`),
and a bare number is reason text. The obvious alternative, "slot 2 is the
duration if it parses as a number", is ambiguous against free text and fails
invisibly: `/ban 7 3 strikes` would be a three-second ban, and `/ban 7 0
tolerance` would refuse the whole command with a complaint about durations to
somebody who typed a sentence.

**Short aliases** (`noclip`, `fly`, `goto`, `bring`, `tp`, `kick`, `ban`, `car`,
`dv`, `players`, `weapons`, `gun`, `god`, `heal`, `announce`, `noclip.speed`, `prop`,
`props`, `fx`)
are registered too,
because an operator under pressure types `/noclip`. Each carries its own
`command.<alias>` permission, so an alias never widens what anybody may do; set
`aliases.enabled = false` in `shared/config.lua` to drop them.

**No `admin.exec`, on purpose.** A command that runs another command would
collapse every permission above into one grant. The Console tab types a real
command line and each line meets its own gate.

**No time or weather commands, on purpose.** `open77_weather` owns those and is
already ACL-gated; the World tab issues `weather.set` and `weather.time.set`
through the same channel. Duplicating an authority to own a tab is the wrong
trade.

---

## Living alongside freeroam

Nothing is deleted from `freeroam`, and this resource declares no dependency on
it: a declared dependency is *hard*, and would stop a server running one
without the other.

Command dispatch walks running resources in **ordinal name order** and takes the
first match, so:

* `freeroam` (f) beats `open77_admin` (o). Every bare name freeroam owns
  (`car`, `dv`, `goto`, `noclip`, `players`) stays freeroam's, and the alias
  here is simply never reached. No error, no ambiguity.
* `open77_admin` (a) beats `open77_freeroam` (f), so this resource's `kick` and
  `ban` shadow that one's. Deliberate: its `makeadmin` writes an
  `admin_groups` table the ACL knows nothing about, and its `ban` is an
  `INSERT` that never reaches the master.

The `admin.*` namespace can never collide with anything.

---

## The Vehicles tab

**Browse.** The `shared/catalog*.lua` set is generated from the platform's 2.31 vehicle catalogue by
`tools/build-catalog.py`: 1,372 spawnable records in four groups (player &
garage 89, general ground 474, AV 23, quest & special 786). That catalogue
has three columns and no display name, manufacturer or class, so every
facet is derived from the record string. The panel offers group, chassis class
and manufacturer (149 of them, in a picker sorted by how many records each
has), plus toggles for player variants and police, and a search over both the
record and the display name. The chassis prefix (`sport1` =
hypercar, `standard3` = SUV, …) is genuine data, the display name is
title-cased and then overridden by a hand table for the ones an operator
actually types. Re-run the generator whenever the doc is regenerated:

```bash
python resources/system/open77_admin/tools/build-catalog.py
```

The catalogue is a set of `shared_script`s, so it is downloaded by every
connecting player: 148 KB of the resource's 264 KB client payload, once, cached
in the signed resource set. It is stored as six parallel arrays rather than
1,372 tables of six string keys, because building that many tables in every
client's Lua state at load is a measurable cost and six arrays is not.

It is split across seven files, and that is not cosmetic. The host loads each
script under an instruction hook that fires every 10,000 VM instructions and
aborts the load if the wall clock is past a 2 ms deadline when it does, and
both counters reset per file. As one file the catalogue executed about 13,700
instructions, crossed the stride once, and cost the whole 25-resource candidate
set a rollback whenever that single check landed on a stalled frame. Split, the
heaviest part executes 2,854, the hook never fires, and the deadline is never
read. The generator refuses to emit a part over its budget. **Do not merge them
back**, and do not hand-edit them.

**Speed column.** `Open77.vehicles.ratedTopSpeed(id)` reads the record's TweakDB
gearing, so the figure is effectively per-record, but it is only readable from
a *live instance*, on the client. There is no record-level query anywhere. So
the catalogue ships the three figures that were actually measured and fills in
as records appear in the world. A record with no reading shows a dash and sorts
last. **Nothing here ever estimates a number.**

**Tune.** Precedence is **instance → record → global**, and each tier *shadows*
every weaker one outright; clearing the instance entry is what lets the record
(or global) profile apply again. The tiers are visually separate on purpose: the
instance card is cyan and applies on click; the record card is coral, carries
its blast radius in its own copy, and requires a hold-to-confirm; the global
card is amber and holds to apply for the same reason. "I changed this car" and
"I changed every car on the server" must never be one gesture apart.

**"My car"** (`admin.veh.speed.here`, and the pair of buttons on the instance
card) resolves the target *server-side* from the live snapshot: the vehicle the
operator is aboard always wins, else the nearest spawned vehicle in his routing
bucket within `Config.vehicles.nearRadius` (40 m). Past that radius the command
refuses: capping a car the operator cannot see is the surprise it exists to
avoid. The compact `/admin` menu reaches the same commands under
`Vehicles → Speed caps`.

**The global tier is synthesised on the client.** The native has a default tier
but no Lua binding for it, so `client/main.lua` applies the global profile as a
record-class profile per record as records appear in the world (a 1 s sweep;
the native's own discovery sweep behind it is 16 frames). An explicit record
profile always beats the global on that record, and clearing it re-applies the
global underneath rather than going to stock.

| Control | Range | Note |
|---|---|---|
| `topSpeedKph` | 0–300 (native allows 1000) | 0 leaves the top end alone. |
| `taperKph` | 3–60 (native 3–200) | Roll-off width. Behind an "advanced" disclosure. |
| `accelerationScale` | 0.1–1.0 | **Cannot exceed 1.** The native only ever multiplies throttle *downward*, by construction, so the governor cannot be a cheat. There is no boost to offer and the UI must not imply one. |

Three things the panel says out loud:

* **It needs a governor-capable client.** `VehicleGovernor.{cpp,hpp}` shipped
  after `2.31.0+op77.7` (they are in the current release client); on an older
  build the bindings are simply absent. The client probes *both*
  `setPerformanceClass` and `clearPerformanceClass` (a half-present API would
  leave the undo path unable to reverse the do path), and the tuning block
  renders disabled with the reason on it. A control that appears to work and
  does not is worse than one that is greyed out.
* **It is client-local, not server-authoritative physics.** A cap is broadcast
  to every governor-capable client and replayed to joiners; `server/vehicles.lua`
  holds the authoritative mirror because Lua has no read-back. It is balance,
  not anti-cheat: a modified client can decline and the server cannot
  corroborate: its vehicle snapshot carries no velocity.
* **A record cap does *not* reach city traffic**, contrary to the note in
  `pursuit/client/performance.lua`, which says capping an `ncpd_*` record also
  caps AI patrols of it. Traced in the client: `RediscoverGoverned` sweeps
  `DynamicEntityService::SnapshotAll()`, whose registry has exactly **one**
  insertion site, inside `DynamicEntityService::Spawn`, i.e. an Open77-created
  stub. Ambient traffic comes from the game's own population system and never
  enters it. So a record profile governs every Open77 spawn of that model,
  present and future, server-wide, and nothing else.

  This follows from the client code (`RediscoverGoverned`), not from an
  in-game check, and it would change the moment that sweep widened. The panel says
  "every Open77 spawn of this model" rather than the older, vaguer warning.

### What is unsafe on an occupied vehicle

`setTransform` is a teleport *plus* a physics-lease revoke *plus* an
authority-epoch bump; on a car with a driver the solver resolves the
interpenetration by throwing the car. That cost Pursuit every match for weeks.

| Action | Occupied | Panel |
|---|---|---|
| `setPerformance` / `setPerformanceClass` | safe | allowed: it scales a float the drive update was about to read |
| `update` (flags, colours, health, doors) | safe | allowed |
| `repair` glass / body / lights / tires / visual | safe | allowed |
| `repair` full / mechanical | **unsafe** | refused; offers `visual` |
| `setTransform` | **unsafe** | not exposed at all |
| `remove` | **unsafe** | refused, naming the occupant |

The gate reads `#Open77.vehicles.get(id).occupants` **at the moment of the
call**, never from the list the panel is displaying: the case that matters is
the one where somebody boarded in the seconds nobody was looking.

---

## The Weapons tab

Hands an online player a **working** weapon: in a slot, drawn, magazine full,
spare pool loaded. A weapon that arrives empty is not the feature.

### The catalogue is the allowlist

189 records in twelve classes, in `shared/weapons.lua`, generated by
`tools/build-weapons.py` from a 1,925-record TweakDB extraction of the 2.31
weapon records. Three predicates do the filtering,
and each is a flat of the record rather than taste: `canonical` (one row per
weapon, not per quality tier), not `deprecated`, and
`equipArea == EquipmentArea.Weapon`.

That last one matters. The Lua weapons API supports the three ordinary slots and
nothing else, and answers `unsupported_weapon_area` for the rest -- so the
generator drops 12 grenades (`QuickSlot`), the portable HMG (`WeaponHeavy`) and
17 arm cyberware records (`ArmsCW`) at build time. A button that always fails is
worse than no button.

`server/weapons.lua` refuses any record that is not in
`Open77AdminWeapons.index`, which is what the Lua API's own authority note asks
for: *"Server code must validate the record against its own allowlist ... Never
forward a client-chosen arbitrary record."* Twenty-four one-word aliases
(`lexington`, `katana`, `defender`, ...) are taken verbatim from
the [freeroam](../../gamemodes/freeroam/) gamemode's `shared/config.lua`, so the two packages call the same gun
the same thing.

Unlike the vehicle catalogue this is **one file**, and that is measured, not
careless: the generator prints ~1,350 VM instructions against the host's
10,000-instruction load stride, where the 1,372-record vehicle catalogue cost
~13,700 and had to be split into seven.

### How ammunition is granted

**The ammo type is never chosen -- it is a foreign key on the weapon record.**
`Open77WeaponAmmoValues` in `client/redscript/Open77ScriptBridge.reds` resolves
`WeaponItem_Record.Ammo()`, and `Open77.weapons.setAmmo` has no parameter for
it. So this package says *how many* and the engine says *of what*; there is no
class -> ammo-type table to maintain or to get wrong.

Getting it wrong would be easy, incidentally. Reading back the `ammoTweakDbId`
the engine reports gives four buckets -- and **precision rifles draw rifle ammo,
not sniper ammo**: an M-179e Achilles reports `0x0000000E5BEC7BB0`, the same id
as an M2067 Defender, where an SPT32 Grad reports `0x00000014089D1CBC`. A
hand-written table would almost certainly have filed them under sniper.

A give is therefore up to four round trips, and each one is unavoidable because
the answer is only knowable on the client:

1. **snapshot** -- `assign` takes an *exact* slot and there is no "first free"
   primitive anywhere in the API. Only for `auto`.
2. **assign** -- `{ active = true, addToInventory = true }`.
3. **setAmmo(reserve)** -- always `activate = true`, because `setAmmo` needs
   `GetItemInSlotByItemID` to return a live `WeaponObject`, which only exists
   once the slot is drawn. Magazine omitted: capacity is not known yet.
4. **setAmmo(reserve, magazine = capacity)** -- issued once, from the capacity
   the engine just reported. Never guessed: `magazine > capacity` is refused
   with `magazine_exceeds_capacity`.

Step 4 is the load-bearing one. A full spare pool over an empty magazine is a
weapon that cannot fire until the player reloads.

### There is a carried-ammo ceiling, and over-asking reports a failure

Found in game on 2.31 by asking for more than the engine would
give and reading the loadout back: the pool is capped **per ammo type**, on the
**total**, which is reserve + magazine.

| Ammo type | Ceiling observed | Shipped full load |
|---|---:|---|
| Handgun | at least 520 (500 spare over a 21-round magazine, unclipped) | 500 |
| Rifle | just under 1000 | 800 SMG/assault/LMG, 400 precision |
| Sniper | 175 | 120 |
| Shotgun | exactly 200 | 150 |

The clip is not silent. `Open77WeaponAmmoStep` verifies
`total == reserve + magazine` in its last phase, so a request the ceiling clips
answers `ammo_update_rejected` -- the weapon **is** equipped and **is** loaded to
the cap, but the raw code says "failed". 1500 spare for an LMG did exactly that,
and so did 200 for a shotgun (200 plus a 4-round magazine is 204, four over).
`server/weapons.lua` reports that case as what it is, and the shipped figures
all sit under their ceiling with a full magazine to spare.

**Melee is skipped rather than attempted.** The usual justification -- melee
records have no `Ammo()` -- turns out not to be quite true: a Katana reports a
real ammo id (`0x0000000DA4AED401`) with a total of 0. Its pool simply caps at
zero, so any reserve fails the same verification with `ammo_update_rejected`.
The catalogue's per-class `ammo` flag is the honest answer to that, and
`weap.ammo <id> all` skips melee slots and says how many it skipped.

### The slot policy

The three slots are a loadout, not a bag: `assign` **replaces** what is in the
slot it is given. The displaced weapon stays in inventory, but it leaves the
weapon wheel, which for the player is indistinguishable from losing it. A give
that always wrote slot 1 would take the operator's pistol away every time they
asked for a rifle.

`auto` (the default) reads a verified snapshot and

* takes the **first empty, unlocked slot** -- the give is purely additive;
* replaces the **active** slot when all three are full. Deliberately the active
  one and not slot 3: the operator is holding it, so it is the one weapon they
  can watch change, and swapping what is in your hands is what "give me that
  gun" means. Rewriting a slot nobody was looking at is the surprise this branch
  avoids.

Naming `1`, `2` or `3` always wins and always replaces -- naming a slot *is*
asking for the replacement. A locked slot is skipped rather than fought:
`weapon_slot_locked` is REDengine state (a quest, a scene) this package has no
business overriding.

### What the server can and cannot corroborate

A loadout is further from this VM than a vehicle is. `Open77.weapons.*` on the
server is not a native at all: it is Lua in the host prelude that fires
`open77:weapons:request` at one authenticated session and waits ten seconds for
`open77:weapons:result`. The work happens inside `EquipmentSystemPlayerData`, on
the target's machine.

* The server **decides** -- the catalogue gate above.
* The server **corroborates, but only through the same client**. Every count in
  a reply came back after that client read `GetItemQuantity` and
  `GetMagazineAmmoCount` for itself. That verifies REDengine's answer, not the
  client: a modified client can decline outright (`request_timeout`), answer a
  plausible lie, or take the weapon and drop the ammo. There is no second
  channel -- `PlayerSnapshot` replicates a shot counter, not a loadout.
* The server **remembers** -- `granted` is the authority for what this package
  handed out, because `addToInventory` creates a local presentation item and
  persists nothing. It does not survive a resource reload, exactly like the
  vehicle ledger.

Balance, not anti-cheat -- the same trade the vehicle governor makes, and worth
saying because a refusing client looks exactly like a laggy one.

### No hard dependency on `open77_weapons`

Its **client** half owns the `open77:weapons:request` handler, so without that
resource running every request here times out. That is deliberately *not* a
manifest `dependency`: a declared dependency is hard, and removing
`open77_weapons` from a server's resource list would take the whole admin
package down with it -- no roster, no teleport, no kick, at exactly the moment
somebody wants them. `freeroam` can afford that trade and declares it; an
operator tool cannot. One screen degrades instead, and `request_timeout` is
translated into the sentence that names the cause.

The only manifest permission this tab needs is `network.events`, already
granted. `player.weapons.read` and `player.weapons.edit` gate the *client-side*
natives, which this package never touches.

---

## The Props tab

Set dressing: props, lights and one-shot or looping effects, through
`Open77.props` and `Open77.effects`, the same host registries `open77_props`
and `open77_effects` call. Nothing here mutates those resources; it calls the
same API and owns only what it creates.

Four properties of that API shape every command in `server/props.lua`, and
three of them are silent when you get them wrong:

* **A prop lives in a routing bucket, and the wrong bucket is invisible, not an
  error.** A prop created into a bucket nobody occupies is never projected to
  anyone while `create` reports success and hands back an id. So every command
  here takes the bucket from `Open77.players.position(source).bucket` and
  **refuses rather than default to 0**, which is why the coordinate forms
  still require an in-game caller, and why the panel has no bucket field.
  `open77_props` shipped exactly this bug in `prop.create`.
* **A prop origin sits at the model's base**, so `z` is the ground. The two
  "at my feet" forms pass the operator's own `z` straight through; adding
  clearance would leave the object hanging.
* **A light colour is `color = { x = r, y = g, z = b }`**, channels 0–1, because
  it is read through the shared vector reader. Spelling the keys `r`, `g`, `b`
  produces black with no error anywhere. Every channel is range-checked here, so
  an out-of-band value gets a usage line instead of a rejection code.
* **A light patch must carry the whole light table.** `Open77.props.update`
  fills an omitted field with its default, so `{ light = { enabled = false } }`
  silently resets colour, radius and intensity. `admin.props.light.toggle`
  therefore rebuilds the complete table on every call (from this file's own
  memo first, then from the record, then from the configured defaults), and it
  **says so in the reply** when it had to fall back. That last case is real: the
  registry hands the light back as the JSON *string* it stored, and indexing a
  string like a table yields nil for every field and no error at all.

**Mutations are owner-scoped by the host.** `setTransform`, `update`, `remove`
and `clear` act only on props this resource created; anything else answers
`owned_by_another_resource`. That is reported in plain English rather than
swallowed into "0 removed", the panel labels a foreign row instead of offering a
button that always fails, and `admin.props.clear` refuses a named resource that
is not this one instead of pretending a cross-resource clear exists. A light
placed by `/light.here` is `open77_props`' light, and `open77_props` is where it
gets switched off.

**A light-only action on a prop is refused**, not quietly ignored: an update
carrying a light table for a prop of kind `prop` is accepted by the registry and
does nothing visible, which reads to the operator as a broken command.

**A show is a cue list, and the venue is separate from it.** `admin.fx.show`
plays a preset from `props.shows`: a list of cues, each one `at` so many
milliseconds from the start, naming an effect (or none, which takes the next
firework shell), how many copies, how far apart and where they land. Absolute
offsets rather than sleeps make a preset readable as a score -- the confetti
visibly lands a beat before the first volley -- and let two cues share a beat.
Four ship: `opening` (flares, sparks, confetti, petals and volleys that build,
twenty seconds), `celebration` (confetti and petals only, nothing that explodes
or burns, for indoors), `finale` (half a minute, climbing, with a breath before
the last barrage) and `storm` (no pyrotechnics at all -- arcs, EMP and failing
hardware around the audience rather than in the sky, which is where the game
authors those and where they read).

**A cue with a `ttlMs` is a loop that retires itself, not a one-shot**, and that
distinction is what keeps a show from littering. A burst plays out and vanishes;
a flare burns, a smoke column pours and an arc crackles for as long as anything
lets them, so fired as one-shots they are still in the world when the show has
ended. The registry owns that lifetime -- a looping VFX has no duration of its
own -- so those cues go through `create` and are retired on the clock.

**What makes it read as fireworks is the spacing, not the count.** Shells fired
150 ms apart on one spot land as a single smear, which is the "everything is
stuck together" look; and independent random points clump on their own, because
that is what randomness does. So a group is a few shells a third of a second or
more apart, each group claims its own patch of sky and its own altitude band,
the gaps between groups are jittered so the ear does not hear the metronome, and
a point is redrawn until it clears the previous one by `minSeparation`. The last
group is the exception and fires as a wall, because a finale should be one. `admin.fx.stage` is the other
half: it dresses a place out of LOOPING effects -- a holographic floor, four
corner beacons, a smoke and a steam column -- which is a different lifecycle, so
the resource holds those ids and `admin.fx.stage.clear` is the way back. Stage
offsets are on world axes: a venue is a place, not a direction.

**The fireworks show runs on the server, and that is the whole point.**
`admin.fx.fireworks` fires a timed sequence (by default eight volleys of three
shells, spaced under a second), and every shell goes out through the same
broadcast `Open77.effects.play` as `admin.fx.play`. So all the players in range
see the same shell at the same world point at the same moment, which is what
makes it usable for a countdown, a race finish or a server event. The race start
plays its own burst from *client* Lua, and rightly: one effect, fired once, from
a start line every client already holds. A sequence run independently on each
client drifts apart within a round, so it belongs on the one clock the server
has. Four cooked shells are used in rotation (`race.firework.burst` plus the
three `q112_firework_0*` paths that have no alias), the launch boom plays once
per volley rather than once per shell, and the broadcast radius asks for the
500 m ceiling because a shell thirty metres up is meant to be seen from across a
district. One show runs at a time: the second operator would otherwise have no
way to stop the first, and `admin.fx.fireworks.stop` ends it within one shell.
Everything above (the shells, the volley plan, the spread, the heights, the
sound) is `props.fireworks` in `shared/config.lua`.

**Three reads, three grants.** `admin.read.props` is what the panel polls once a
second and answers in structured data only; `admin.props.list` and
`admin.fx.list` answer in prose as well, for somebody typing in chat. Polling a
prose command would print a sixty-row listing into the operator's chat every
second.

**No `prop.*`, `light.*` or `fx.*` aliases.** Command dispatch takes the first
resource in ordinal name order, and `open77_admin` (a) beats `open77_props` (p)
and `open77_effects` (e), so an alias spelled `prop.here` would shadow the
registry's own already-gated command. Shadowing `freeroam` was the point;
shadowing the props authority is not. The three bare aliases (`prop`, `props`,
`fx`) collide with nothing.

**The alias lists are configuration, not a whitelist.** `shared/config.lua`
mirrors the curated tables in `client/src/api/Props.cpp` and
`client/src/api/Effects.cpp`, because the server-side `Open77.props.catalog()`
deliberately answers an empty list: the depot paths live on the client, next to
the code that resolves them. A raw depot path is accepted by every command, and
**no alias is individually validated in game**: the client's own table records
`discoverable_not_individually_validated` for every row, so a spawn that answers
`entity_spawn_failed` is a real answer, not a bug in this package.

---

## Safety rules this resource enforces

* **Never act on a session with no life state.** That is the "continue" screen
  (an active session that is not an incarnation), and a server-side teleport
  received there crashes the client. Liveness is asked through
  `Open77.players.isDead`, resolved natively from the enum, because the phase
  *string* differs between hosts (`respawn_pending` vs `respawnpending`) and a
  guard written from the client spelling goes blind at exactly the wrong moment.
* **Never place a player before the readiness gate opens.** `Open77.ready` is
  consulted for every move. This resource never *holds* the gate: an admin tool
  has nothing to ask a joiner.
* **Move only through kill → respawn.** A direct transform write over any real
  distance drops the player into unstreamed world.
* **Announce every move to the target.** Nobody gets teleported silently.
* **Disclose the bucket.** A player in a non-zero routing bucket is in a match,
  and this resource does not ask that gamemode whether a move is safe. The roster flags it; the operator decides.

---

## Not built, and why

| Wanted | Blocked on |
|---|---|
| Grant/revoke admin from the panel | Intentionally not exposed. Use Warden or the server console, with its escalation checks. |
| Ping in the roster | **C#.** The session layer knows it; Lua has no reader. An absent column beats a fabricated one. |
| A unified audit trail | **C#.** Warden keeps a durable JSONL trail this resource cannot read, so in-game and panel history are two histories. `Open77.audit.append` would make them one. |
| True spectate | **C++.** `Open77.camera.detach(x,y,z)` is a *local offset*, not a free camera at a world point. `admin.player.observe` is honestly named: it teleports you and turns noclip on, and the target can see you standing there. |
| Freeze a player | **C++.** NPCs have `setAiMode("frozen")`; players have nothing. The command is not registered rather than faked. |
| The governor working for anybody | **C++.** `VehicleGovernor.{cpp,hpp}` are untracked and the bindings uncommitted. |
| Invisibility in the compact menu's Self screen | **Nothing implements it.** There is no `admin.self.invisible`, no player-visibility binding, and no way to fake one that another client would honour. The item is absent rather than dead. |

---

## Files

```text
open77.lua                    manifest -- reload_policy "reconnect" (it owns a CEF surface)
acl-roles.example.jsonc       paste-ready roles for acl.jsonc
shared/config.lua             limits, aliases, destinations, governor bounds
shared/catalog.lua            GENERATED -- head: facets, seeded speeds, position()/entry()
shared/catalog-records.lua    GENERATED -- the 1,372 record strings
shared/catalog-names.lua      GENERATED -- display names, parallel to records
shared/catalog-taxonomy.lua   GENERATED -- groupOf, classOf
shared/catalog-attributes.lua GENERATED -- makerOf, flags
shared/catalog-index-*.lua    GENERATED -- record -> position, in two slices
shared/weapons.lua            GENERATED -- 189 weapon records, classes, full loads (ONE file)
tools/build-catalog.py        the vehicle generator
tools/build-weapons.py        the weapon generator
server/main.lua               roster, audit, rate limits, the ONE command seam
server/players.lua            self, another player, moderation
server/vehicles.lua           ledger, occupancy gate, governor mirror
server/world.lua              destinations, announce, cleanup, server readout
server/props.lua              props, lights, effects -- bucket, ground and light-patch rules
server/weapons.lua            the give chain, the slot policy, the loadout ledger
server/public.lua             unrestricted self-only /pos and /rot
client/coordinates.lua        actual character transform display and clipboard
client/main.lua               the console: surface, focus discipline, travel + governor delegation
client/menu.lua               the compact menu: hud surface, key polling, the frame stack
web/index.html  app.css  app.js       the console's page
web/menu.html   menu.css  menu.js     the compact menu's page (renderer only, no state)
web/open77-ui.css             MIRRORED -- byte-identical in every consuming resource
```

`open77-ui.css` is copied, not shared, because each WebUI surface runs on its own
isolated origin and four separate checks refuse a cross-origin read. Verify the
mirror after touching it; one line of output means it is intact:

```powershell
Get-FileHash resources\*\web\open77-ui.css -Algorithm SHA256 |
  Select-Object -ExpandProperty Hash -Unique
```

---

## Status

The Weapons tab and the Door Inspector (Developer → Doors) have been exercised in
the game. The rest of this README describes the code and the Lua tests; where a
claim comes from reading the code rather than the game, the section says so.

## Context targeting integration

`open77_contextmenu >=1.1.0` is a required generic dependency. This package, not
the targeting framework, registers the admin actions. An operator needs
`command.admin` plus the specific existing player/vehicle/weather command.
Door writes additionally require `command.admin.dev.doors.control`; copying a
door ID uses `command.admin.dev.doors.inspect`. No rights are granted by default.

ALT-click a player/vehicle/door for targeted actions, or empty sky for time and
weather. Forms and confirmations reuse the compact admin menu; destructive
confirmations default to Cancel. Freeroam cooperates through its server export
for its own vehicles (20m, same bucket, live ACL, occupancy checked again).
Other vehicle resource owners must implement their own cooperation. Lift doors
remain governed by the elevator; administrative door writes keep resource ownership.

## Player morphs

`/admin` → **Self** → **Morph / original character** provides a searchable,
paged 6,582-record discovery catalogue, categories, direct `Character.*` input,
an optional appearance override and **Unmorph**. The server's model API owns and
replicates the override. Readiness/failure feedback is separate from acceptance.

Opening the menu requires `command.admin`. Action permissions are
`command.admin.self.morph`, `command.admin.self.unmorph` and
`command.admin.self.morph.search`; wildcard `command.admin.self.*` includes all
three. Commands are self-only, restricted, rechecked and audited. Another
resource's override is never stolen. Revocation releases admin-owned morphs;
death, disconnect and resource shutdown use native lease cleanup. The underlying
resource declares `players.model.control` and `players.model.read`.

Records are discovery candidates, not certified animations. Smasher's special
rig has known vehicle-pose limitations. Custom records remain accepted; the
catalogue is not an allowlist. Regenerate the server-only index with
`python resources/system/open77_admin/tools/build-models.py` from the repository
root; `--check` checks it without rewriting. Data parsing/search yields in batches
and at most 20 results are sent to an operator, not the whole catalogue.
