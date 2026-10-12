# Freeroam PvP activity

Freeroam 0.7.0 integrates the existing Kabuki FFA and elimination-arena engine in the
same Lua VM as Race and the sandbox. The standalone Deathmatch resources are unchanged;
their scripts must not be started alongside this gamemode.

A separate melee-only **Blade FFA** is planned on the same map; see the
[follow-up scope](../../../../docs/blade-ffa-plan.md). It is not enabled yet.

## Players

- `/pvp`: menu; FFA or a 1v1/2v2/3v3 queue, loadout and sound preference.
- `/pvp.join`: immediate FFA entry, subject to readiness (no FFA player cap).
- `/pvp.leave`: cancel a queue, forfeit a match, or retry a delayed return.
- `/dm.queue <1v1|2v2|3v3> [bots|nobots]`: command equivalent of the arena cards.
- `Tab`: live standings, with bots and arena teammates/opponents labelled.

Queued players remain in the city. A match captures the player's server position at
formation, not queue entry. Entry requires a ready, alive, on-foot player in bucket 0.
Race, its queue and its editor exclude PvP, and conversely. Admission is rechecked when
an arena forms; changing buckets, dying or entering a vehicle cancels the affected queue entry.

An active match owns life, respawn, damage, team and equipment. Leaving removes the PvP
loadout and returns to the captured city position, restoring maximum health, armor, god-mode policy and
Freeroam regeneration. **The previous sandbox weapons are not restored automatically**;
the Weapons tab can re-equip them. Returning remains activity-owned until the authoritative
life/position transition settles. A Lua reload recovers captured return positions from the
resource state bag instead of adopting an orphaned arena.

## Presentation

Active PvP players have three times their pre-match maximum HP (normally 300).
The baseline is captured once, persisted with the return position, and reused on
every respawn; joining a queue or dying repeatedly cannot stack the multiplier.

Every credited PvP elimination instantly restores the living killer to their actual
maximum health. Armor is unchanged. Assists, suicides, environmental deaths,
cross-instance kills and duplicate death notifications do not grant this reward;
posthumous kills never revive the killer. This rule belongs to Freeroam PvP only.

The PvP menu and HUD use the existing Freeroam WebUI surface and offline design-system
tokens. Match objective/score/timer sit top-centre; personal statistics sit bottom-right.
Health, ammunition and hit feedback remain owned by the shared Freeroam HUD. Results,
respawn timers, spawn protection and feed are driven by server events.

Native SFX cover selection, joining, countdown, round start/result and eliminations.
The PvP sound checkbox stops only PvP-owned handles; it never clears Race audio.
Vanilla staged-interior restrictions are suppressed while playing PvP and released on
return/stop, through the owner-scoped `Open77.world.setSafeAreas` API. Server city safe
zones and authoritative PvP damage rules remain independent of this local presentation policy.

## Operators

Freeroam uses one shared FFA in bucket 4200, regardless of the number of players.
Only the server's overall connection limit applies; `ffaCapacity = 0` means
unlimited and cannot be overridden with an old capacity tunable. Large standings
are dictionary-encoded into UTF-8-safe fragments and delivered in bounded batches,
using latent transport with backpressure when needed. Above 16 participants,
round-reset placements/equipment are staggered by 200 ms per player to respect
the shipped weapon relay's pending-timeout budget.

The default arena is centred at `(2998.928223, -2414.493408, 118.472412)` with a
horizontal radius of **140.612430 m** and 17 spawn marks. The circular boundary
does not impose a height limit, so its different decks remain accessible. Client
clamping and the authoritative server backstop share the same geometry. The
built-in map retains the internal key `kabuki` for saved-map compatibility; its
display name is Freeroam Arena. Explicitly selected custom maps remain unchanged.

- `shared/config.lua`: rounds, kits, difficulty, surveyed zones and instance budgets.
- `shared/kabuki.lua`: shared box/cylinder geometry and legacy survey defaults.
- `shared/freeroam.lua`: arena coordinates, unlimited FFA, city bucket and integration overrides.
- `server/freeroam.lua`: admission, cross-activity guards and return transactions.
- `web/pvp/`: menu, combat HUD and responsive layout.

Existing `dm.*` administration and tunables remain available with their existing ACL.
The database bridge is optional: maps/careers are volatile when it is disabled. Enable a
configured bridge for persistence; never embed credentials in shared scripts. Existing
Deathmatch database tables are retained, not migrated or overwritten by this integration.

Arena training bots require **every queued human's consent** and are excluded from rating.
Bot navigation remains experimental on Kabuki's stacked floors: the local 2026-09-05 test
observed a bot projected onto another deck, followed by correction/report-jump rejection.
The PvP integration does not change the native NPC projection implementation.

The dependency set is the same as Freeroam Race. If the server uses an explicit
`resources.load`, all transitive dependencies must be discoverable. No standalone PvP
HUD or extra world-entry terminal is required: entry is through the shared menu or commands.
