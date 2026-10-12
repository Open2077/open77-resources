# open77_rp_basics

This resource gives a server three player-to-player role-play verbs, cuff, escort and search,
published as server exports and wrapped in the bookkeeping that keeps a held player recoverable.
They are composed out of primitives that already shipped. **carry** is present and refuses; see
below.

- **Docs:** [The role-play kit](https://open2077.net/docs/rp-kit)
- **Starts:** with `ensure open77_rp_basics` (it declares `auto_start false`)
- **Needs:** `open77_animations`
- **Runs on:** server and client

Nothing here is new engine work. It is the answer to "the primitives exist, now show me that they
compose", and to the question that only shows up once they do: *what happens when the officer
disconnects?*

Full guide: [The role-play kit](https://open2077.net/docs/rp-kit).

## Install

```
dependency open77_animations >=1.0.0
```

The resource is `auto_start false`. Add `"open77_rp_basics"` to the server's `resources.load` (or
`start open77_rp_basics` from the console), and grant the ACL permissions below. Without them
every verb answers `not_authorised`, which is the intended out-of-the-box state for a resource
that can hold one player still on another player's say-so.

| Permission | Who should hold it |
|---|---|
| `rp.cuff` | police, medics, anyone allowed to restrain |
| `rp.escort` | the same roles |
| `rp.search` | the same roles |
| `rp.admin` | staff: may free anybody, regardless of who is holding them |

`rp.*` grants all four. The server console (`source = 0`) is local administration and is not
subject to the ACL, exactly as it is for restricted commands.

A server profile with an explicit `resources.load` list is a silent allowlist -- a resource missing
from it is never started and never logged. Add `"open77_rp_basics"` there, not only to the
template.

## Exports (server)

```lua
local ok, reason = exports.open77_rp_basics:cuff(officerId, targetId, options?)
local ok, reason = exports.open77_rp_basics:escort(officerId, targetId, options?)
local ticket     = exports.open77_rp_basics:search(officerId, targetId, options?)
local ok, reason = exports.open77_rp_basics:carry(officerId, targetId)   -- false, "carry_unsupported"
local ok, reason = exports.open77_rp_basics:release(targetId, byPlayerId, reason?)
local record     = exports.open77_rp_basics:state(targetId)
local records    = exports.open77_rp_basics:held()
local verbs      = exports.open77_rp_basics:capabilities()
```

`officerId` is a **validated** player id the caller supplies: an export carries no player identity,
so the kit re-derives authority from the ACL rather than trusting the argument. `options.holdMs`
shortens a hold; it can never lengthen one past the ceiling.

Read `capabilities()` instead of hard-coding what this build can do: it reports `carry` as
`supported = false` with its reason, the same way `Open77.input.blockableActions()` reports an
action this engine cannot refuse.

## Events (host-wide)

| Event | Arguments |
|---|---|
| `open77_rp_basics:held` | `(targetId, officerId, verb)` |
| `open77_rp_basics:released` | `(targetId, officerId, verb, reason)` |
| `open77_rp_basics:searched` | `(officerId, targetId, ticket, result)` |

`reason` is always one of `shared/rules.lua`'s `endReasons`.

## Console

```
rp.free <playerId>      # release whatever this kit holds on a player
rp.held                 # who is held, by whom, and for how much longer
```

These exist so an operator is never dependent on the gamemode that cuffed somebody still being
willing to un-cuff him.

## Why carry is refused

Carrying a player means parenting one body to another. On game version 2.31:

- **`Open77.props.attach` attaches a prop, not a player.** Its `kind` is the *target* (`player`,
  `npc`, `vehicle`), and the thing that follows is always a prop. There is no player-to-player
  attachment anywhere in the surface.
- **Even for props it is a follow, not a parenting.** The server recomputes the transform ten
  times a second; a carried prop hovers at an offset and does not swing with an animation, because
  nothing binds it to a bone. `entHardTransformBinding` on a root component is not exposed.
- **`Open77.players.teleport` is a placement, not a follow.** It fades, waits for the client to
  report the body settled, and refuses a second placement for the same player with
  `settle_superseded`. At carry cadence every call would supersede the one before it.
- **No RP animation survives being moved.** The profiles are stationary and walking cancels
  playback, so there is no carry pose to hold while the carrier walks.

So `carry` would have to be a lie: a prompt that appears and a body that stays where it was. It
refuses by name instead. `escort` is the verb that does work, and it is honest about being a
leash.

## Tests

- `tests/rules_test.lua`: the pure decisions in `shared/rules.lua`.
- `tests/server_test.lua`: the real `server/main.lua` driven against `tests/fakes.lua`, one case
  per row of `endReasons`, each asserting that the kit gave back exactly the claims it took.

Both Lua suites run standalone from this directory with a Lua 5.4 interpreter. The platform's own
server test suite also checks that every declared end reason is produced by the server half *and*
exercised by the suite (an enumeration nobody implements is worse than no enumeration), and that
the manifest asks for what the kit uses and nothing wider.
