# open77_vehiclepicker

This resource gives any gamemode a vehicle picker panel that players use before a match: one curated roster per list, and one remembered choice per player.

- **Docs:** [Network vehicles](https://open2077.net/docs/vehicles)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

It is deliberately **not** Pursuit-specific. Pursuit is the first consumer and
the worked integration below, but the resource knows nothing about cops,
runners, matches or bounds: it knows *lists of cars* and *which one this player
last clicked*.

```text
open77.lua                      manifest
shared/roster.lua               THE ROSTER AND ITS RATIONALE: read this one
client/main.lua                 surface, focus discipline, exports
web/index.html                  the panel
web/app.js                      renders what it is sent, invents nothing
web/app.css                     tokens only
web/open77-ui.css               mirrored, byte-identical shared UI styles
integration/pursuit_loadout.lua drop-in server module: copy, do not require
```

---

## 1. The balance question, answered

The question was: can every car on offer be made roughly as fast as the others,
or can a technical speed limit be put on them when they are not?

Two routes were named. The technical cap was investigated first, because it
would have been strictly better: a cap turns the roster into a free choice
instead of a curated one.

### A speed cap does not exist, and it is not a Lua change to add

Four independent checks, all negative:

| Route | Verdict | Evidence |
|---|---|---|
| Write a performance field on a vehicle | **No such field** | `Open77.vehicles.update` accepts `health`, `flags`, the two colours, `doors`, `windows`, `tires`, `bodyDamage`, `brokenGlass`, `brokenLights`, `detachedParts`. The ten `flags` bits are `engineOn`, `locked`, `destroyed`, `exploded`, `invulnerable`, `immortal`, `lightsOn`, `highBeams`, `sirenOn`, `paintApplied`. |
| A setter the docs forgot to list | **Explicitly ruled out** | The [Network vehicles](https://open2077.net/docs/vehicles) guide: there is "no `setHorn`, `setRpm`, `setSteering`, `setWheelRotation`" because those values "describe native driver input, physics, or the validated occupancy ledger and **cannot be authored as durable script state**". |
| A soft governor: read speed, cut throttle | **Half of it exists** | The client *can* read `speed`, `rpm`, `rpmMax`, `throttle`, `brake`, `gear` off a vehicle snapshot. The loop cannot be closed: no Lua binding on either host applies throttle, brake, force or velocity. `Open77.input` is `isDown`/`isCaptured`, both reads. The only positional write, `setTransform`, revokes the physics lease and teleports: it fights the driver, it does not limit him. The **server** cannot even read speed: its vehicle snapshot carries no velocity and no orientation. |
| Retune the record in TweakDB | **Gated shut** | There is no TweakDB Lua namespace at all. The native `SetFlat` path refuses any record not named `<Type>.Open77*`, so `tweak.setflat Vehicle.v_standard2_…` answers `ERR record_must_be_open77_owned`. |

One theoretical route survives and is recorded so nobody re-derives it:
`tweak.clone` a vanilla vehicle record into a `Vehicle.Open77*` name and
`SetFlat` its existing flats. **It has never been done for a vehicle, it is
client-side only (every client would have to apply it identically), and the
server has no TweakDB and no way to command one.** It is a C++ and protocol
project, not a resource.

**So the only lever that exists is which record is spawned.** That is what this
resource is.

### The curation, and what it actually rests on

State the weakness first: **the platform ships no vehicle performance data.**
The 2.31 vehicle catalogue (1,376 records, see the
[Game data reference](https://open2077.net/docs/data-reference)) has exactly
three columns: record name, TweakDBID, `entityTemplatePath`. No speed, no
acceleration, no mass, no drive type, no class rating.

The roster therefore rests on the one performance signal that is a **fact
rather than an opinion**: REDengine's own chassis-class prefix, which is part of
the record name and so is data, not inference.

```text
v_standard2_*     everyday saloons        <- the band this roster uses
v_standard25_*    pickups, larger saloons
v_standard3_*     SUVs and heavies
v_sport1_*        hypercars (Caliburn, Aerondight, Turbo, Outlaw)
v_sport2_*        sports cars (Type66, Shion, 911, Alvarado, Deleon)
v_sportbike*_*    motorcycles
```

**Every entry in both lists is a `standard2` chassis.** One class, no mixing.
It is conservative on purpose, and it happens to match what Pursuit already
ships (the Archer Hella and the NCPD Villefort Cortes are both `standard2`), so
adopting this roster does not change the performance of the default match at
all.

Being honest about the strength of that: sharing a class prefix is strong
evidence of a similar envelope and it is the best evidence obtainable without
launching the game. **It is not a measurement.** §4 below is the procedure that
would turn it into one, and `shared/roster.lua` carries the per-entry
provenance so the next person edits data rather than re-deriving the argument.

### The gap that matters more than any of this

Two hand-timed launches exist for Pursuit: distance covered in five seconds
from a standstill, hand-held throttle, one run each:

| Record | Tier | 5 s launch |
|---|---|---:|
| `Vehicle.v_standard2_archer_hella_player` | `*_player` | **86.4 m** |
| `Vehicle.ncpd_villefort_cortes_heat_1` | NCPD | **59.7 m** |

Same chassis class, **45% apart**. This is the most important unresolved balance
fact in Pursuit and the picker does not fix it, because it does not sit between
two civilian cars: it sits between the `*_player` tier and the NCPD tier.
Three explanations are open and only measurement separates them:

1. `*_player` records really are tuned quicker than their traffic and police
   siblings;
2. the two runs differed in road, gradient, or how hard the throttle was held;
3. both.

The picker is built so either answer is a **data edit**. If (1) holds, point the
police list at the `*_police`-liveried `standard2` records
(`Vehicle.v_standard2_villefort_cortes_police`,
`Vehicle.v_standard2_archer_hella_police`) or at the plain `*_player` chassis:
one `record` string per row, no structural change.

---

## 2. The roster

### Civilian: the runner's list (8)

All `v_standard2_*_player`; all in the "Player and garage variants" table of the
vehicle catalogue; all already in the validated `/car` alias map of the
[freeroam](../../gamemodes/freeroam/) gamemode (`shared/config.lua`).

| Key | Record | Name |
|---|---|---|
| `hella` **(default)** | `Vehicle.v_standard2_archer_hella_player` | Archer Hella |
| `bandit` | `Vehicle.v_standard2_archer_bandit_player` | Archer Bandit |
| `quartz` | `Vehicle.v_standard2_archer_quartz_player` | Archer Quartz |
| `cortes` | `Vehicle.v_standard2_villefort_cortes_player` | Villefort Cortes |
| `colby` | `Vehicle.v_standard2_thorton_colby_player` | Thorton Colby |
| `galena` | `Vehicle.v_standard2_thorton_galena_player` | Thorton Galena |
| `thrax` | `Vehicle.v_standard2_chevalier_thrax_player` | Chevalier Thrax |
| `hozuki` | `Vehicle.v_standard2_mizutani_hozuki_player` | Mizutani Hozuki |

`cortes` is offered on purpose: a runner who picks it races an identical chassis
with no livery, which is the cleanest available read on whether the two tiers
really differ.

Left out, and the only `standard2` `*_player` saloon excluded:
`Vehicle.v_standard2_makigai_maimai_player`. The MaiMai is a city micro-car and
very unlikely to hold the band, but **that exclusion is a judgement about the
car, not a measurement.** Measure it; if it holds, it belongs in the list.
Sub-trims (`_gt`, `_base`, `_nomad`, `_delamain`, `_bobas`) are excluded as a
rule: they multiply the list without adding a choice a player can see at a
glance, and each would need its own verification.

### Police: the cop's list (4), and how many really exist

Should the police have several vehicles to choose from too? **Nine NCPD records
exist, and four of them are in this band.**

| Record | Chassis | Offered |
|---|---|---|
| `Vehicle.ncpd_villefort_cortes_heat_1` | standard2 saloon | **yes, default** |
| `Vehicle.ncpd_villefort_cortes_heat_2` | standard2 saloon | yes, untested |
| `Vehicle.ncpd_archer_hella_heat_2` | standard2 saloon | yes, untested |
| `Vehicle.ncpd_archer_hella_heat_3` | standard2 saloon | yes, untested |
| `Vehicle.ncpd_thorton_merrimac_police_heat_4` | standard25 | no, out of band |
| `Vehicle.ncpd_suv_chevalier_emperor_heat_4` | standard3 SUV | no, out of band |
| `Vehicle.ncpd_hellhound_heat_5` | standard3 heavy | no, out of band |
| `Vehicle.ncpd_suv_thorton_merrimac_maxtac` | standard25 MaxTac | no, out of band |
| `Vehicle.ncpd_brennan_apollo_bike` | motorcycle | no, out of band |

The five excluded records are excluded because they leave the saloon class the
civilian list is pinned to, **not because they are believed broken**. They are
exactly the raw material for a future asymmetric mode (a MaxTac roadblock, a
bike phase), and moving one into the roster is a one-line change plus the
measurement that justifies it.

Three facts worth carrying forward:

- **No NCPD `*_player` record exists.** The catalogue's nine `Vehicle.ncpd_*`
  records contain none, and the [Pursuit](../../gamemodes/pursuit/) gamemode
  records the same finding in its `shared/config.lua` and `server/vehicles.lua`.
- **Only `heat_1` is known to spawn.** It is the record Pursuit spawns by
  default. The other three carry a non-zero `entityTemplatePath` and are
  otherwise untested; the picker labels them `UNTESTED` and each carries a
  `fallback` to the same chassis's `*_player` variant, so a refused record
  still yields a playable match.
- **What `heat_N` means is not established.** It is presumed to be the NCPD
  heat-level livery, and the two Cortes rows are offered as visually distinct on
  that presumption. If `heat_1` and `heat_2` turn out to look identical in game,
  drop one row: do not keep a choice that is not one.

### Keys are the wire format, and that is the security boundary

The client sends an opaque **key**, never a record. A key is not a spawnable
thing, so the worst a tampered client achieves is naming a key that does not
resolve, and an unresolved key falls through to the list default. Accepting a
`Vehicle.*` string would hand a client the whole 1,376-record catalogue, quest
props and trains included. The
[Game data reference](https://open2077.net/docs/data-reference) gives the same
advice in general terms.

**Keys are stable.** A key is written into the player's client KVP store, so
renaming one silently resets everybody who had chosen it. Add and deprecate; do
not rename.

---

## 3. Using it

### From a gamemode's client

```lua
Open77.exports.call("open77_vehiclepicker", "open", { list = "civilian" })
Open77.exports.call("open77_vehiclepicker", "selection", "civilian")  -- current key
Open77.exports.call("open77_vehiclepicker", "roster", "police")       -- the list as data
Open77.exports.call("open77_vehiclepicker", "close")
Open77.exports.call("open77_vehiclepicker", "isOpen")
```

### From a gamemode's server

```lua
TriggerClientEvent("open77_vehiclepicker:open",  playerId, { list = "police", deadlineMs = 45000 })
TriggerClientEvent("open77_vehiclepicker:lock",  playerId, { locked = true })
TriggerClientEvent("open77_vehiclepicker:close", playerId)

RegisterNetEvent("open77_vehiclepicker:selected", function(payload)
    -- payload = { list = "police", key = "cortes_h1" }; source is the player.
    -- VALIDATE IT. The client's roster is advisory; yours is authoritative.
end)
```

**`:selected` arrives unprompted too.** A client reports its remembered picks
once per session, at `open77:worldReady` (and on a hot reload into a live
world), without the panel ever being opened. That is what makes remembering
work end to end: without it, a player who chose a car last week and never opens
the panel again would silently get the default while his own picker still showed
his pick selected, the UI and the car disagreeing with nothing to explain why.
A handler must therefore be idempotent and must not assume it opened anything.

### The server half is a file you copy

This resource ships no server script. The server half is
`integration/pursuit_loadout.lua`, a file a gamemode copies into its own
server code: it validates each reported pick against the gamemode's own copy of
the roster, remembers it per player, and hands the gamemode a vehicle spec. The
install steps are at the top of that file. The client side is a shared service
in the same way as [open77_zones](../open77_zones/) and
[open77_worldui](../open77_worldui/): client resources call its exports.

### Interaction rules

- **It opens only when asked**: a net event or an export. It never opens itself,
  never on connect, never on a hotkey. Nothing is armed while it is closed.
- **Selecting is instant-confirm.** There is no separate CONFIRM button, so
  there is no way to close the panel having lost a pick. "What if he never
  chooses" and "what if he closes without confirming" collapse into one answer:
  the last thing he clicked is what he has, and if he clicked nothing he has the
  roster default, which is the car Pursuit spawns by default.
- **After the match starts** the panel does not vanish: a player mid-decision
  would have it yanked away with no explanation. It goes read-only with a banner
  saying the pick applies to the next match, and the pick is kept.
- **The choice is remembered** in `Open77.kvp`, namespaced by connection address
  and resource, so it survives a reconnect and never leaks between servers. Every
  read is re-validated against the roster, so a stored key whose entry was later
  removed degrades to the default rather than dangling.

### It cannot trap input

A modal that owns the keyboard and cannot be dismissed is a known hazard here,
so the close paths are **redundant by construction**. Five of them release
focus, and none depends on another working:

1. the page's ESC key and its close button, and a click on the scrim;
2. `open77:pauseKey`: the plugin **swallows** Escape in the window procedure
   while the pause menu is armed, so (1) can never fire in a live session and
   this is the path that actually runs;
3. `onClientResourceStop`, so a reload cannot leave focus behind;
4. the gamemode's `open77_vehiclepicker:close` net event;
5. a **watchdog** that force-closes after 60 s. This one is not there for the
   player: it is there for the bug nobody has found yet.

All five call one idempotent `releaseFocus()`, which drops focus **before** it
touches any other state, so an error later in a close path cannot strand the
cursor. The body is `pointer-events: none` while closed, so a closed picker
cannot eat a click even if focus were left on by mistake.

---

## 4. Turning the class argument into a measurement

The roster's claim is "same chassis class, therefore close". Settling it needs
one number per row, and the method is simple: the two figures in §1 were
produced this way.

For each candidate record, in a private routing bucket on a straight, level
road, from a standstill:

1. `vehicle.create.player <playerId> <record>` from [open77_vehicles](../open77_vehicles/)
   (or spawn it through the gamemode), mount it;
2. hold full throttle for a fixed 5 s;
3. read the distance travelled between the start and end positions.

Then either replace `measured.launch5s` in `shared/roster.lua` with the figure,
or drop the row.

Two cautions, both from the existing measurements:

- **Hold the throttle the same way every time.** The two figures on record are
  hand-held, and two runs of the *same* car under the same conditions gave
  86.4 m and 82.9 m, so roughly 4% is this method's noise floor, and a
  difference smaller than that means nothing.
- **`Open77.vehicles.get(id).speed` is readable on the client** and is a better
  instrument than distance if someone wants to automate this, but it is a
  *client* read, so the measuring harness has to run there.

The picker draws a launch figure only where one exists, and a dash where none
does. **It never estimates a bar.** If you add a number, it must be a number you
measured.

---

## 5. Limits

- The class-band balance claim is a naming-derived inference, not a measurement
  (§4).
- Most roster records have no launch figure, and three of the four NCPD records
  are marked untested.
- The `heat_N` livery presumption is unverified.
