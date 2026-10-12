# open77_cyberarena_example

An optional Gorilla Arms practice arena: players who walk to a configured site get temporary cyberware arms and PvP that applies only inside the arena's own routing bucket, then leave with their own implants untouched. It is an example a server owner can keep, tune in `server/config.lua` or replace.

- **Docs:** [Gorilla Arms](https://open2077.net/docs/gorilla-arms)
- **Starts:** with `ensure open77_cyberarena_example` (it declares `auto_start false`)
- **Needs:** `open77_cyberware`
- **Runs on:** server

This example uses public temporary cyberware leases and scoped PvP grants.
It never installs/removes a paid implant, changes character identity, modifies
teams or enables global PvP. Native projection and restoration remain owned by
the backend when the example stops or a player disconnects.

## Use it

Add `open77_cyberarena_example` to the server's explicit `resources.load` list,
alongside the normal appearance/character adapter and `open77_cyberware` support.
The example has `auto_start false`; start it deliberately with the server's
`ensure open77_cyberarena_example` command. Its commands affect only their caller.
No doctor/admin permission is required to join. The manifest grants the resource
`combat.scope.control` and `players.cyberware.temporary`, not durable implant
management or identity-binding permissions.

Reserve `server/config.lua`'s bucket exclusively for this activity. Defaults:
bucket 11877; practice site `(2570, 113, 78.63)`, radius 20 m and vertical bound
6 m; eight participants; five-minute temporary loadouts. An occupied bucket with
nonparticipants refuses admission. Operators should validate the configured
site and any replacement coordinates before enabling the example.

## Play

1. Walk to the configured site while alive and outside a vehicle. Finish normal
   character loading and any pending implant restoration.
2. `/cyberarena join` selects `training`; an optional grade argument selects
   `industrial`, `cosmetic` or `lethal`. The command switches routing visibility
   at the same world position, then requests temporary arms. Wait for readiness.
   Routing clears the old position snapshot; admission waits for a fresh sample
   in the destination bucket and retries only transient character-readiness
   refusal within the configured preparation timeout.
3. With two ready participants, draw fists and use normal/charged punches.
   Training and industrial are nonlethal in this practice example; cosmetic
   arms deal no damage or knockback. Native/server validation and other
   resources' team/safe-area vetoes still apply.
4. `/cyberarena loadout <grade>` first restores the paid loadout, then requests
   the replacement temporary grade. Combat waits during both native stages.
   Explicitly selecting `/cyberarena join lethal` or `/cyberarena loadout lethal`
   enables punches that can kill other participants. The default remains
   `training`. Server makers can remove this grade or change its rules in the
   optional configuration.
5. `/cyberarena reset` fills health/stamina only while alive with an active
   loadout. It has a configurable 10-second cooldown, changes no maximum and
   never revives a dead body. This is an explicit practice-healing rule; pool
   changes persist on exit. Replace it if your RP economy forbids free healing.
6. `/cyberarena leave` removes arena combat permission, releases temporary arms
   and restores the original routing bucket. Returning while native restoration
   is pending does not allow another temporary lease until restoration finishes.

Default temporary balance (normal / charged):

| Grade | Damage | Stamina cost | Charged knockback | Minimum / maximum hold |
|---|---|---|---|---|
| `training` | 15 / 35 | 10 / 20 | 3.5 m | 650 / 3000 ms |
| `industrial` | 25 / 60 | 20 / 35 | 4.5 m | 800 / 4000 ms |
| `lethal` (explicit selection) | 25 / 60 | 20 / 35 | 4.5 m | 800 / 4000 ms |
| `cosmetic` | 0 / 0 | 0 / 0 | 0 m | 650 / 5000 ms |

A quick tap uses normal damage and, by default, 35% of the charged knockback
distance: 0.7 m for training and 1.05 m for industrial/lethal. Hold attack for about
one second, then release, to use the charged values. Contact and terrain can
reduce realized travel below the configured bound. Creators can independently
set `normalKnockbackMeters` on each grade (0–6 m).

A target with an active knockdown/recovery lease cannot start another throw.
Further accepted hits can still deal damage and produce impact feedback. The
public `onCyberwareMotionOutcome` event reports `rejected` / `motion_busy` for
that throw request; it does not mean the damage was refused. Wait until full
recovery before comparing isolated normal and charged throws.

These explicit stamina overrides charge the authoritative pool once per admitted
swing, including a miss; cancelling after admission does not refund the swing.
An overlong charged hold must be released before charging again. Native movement
costs remain separate. These settings are confined to the temporary arena
definition; paid doctor presets retain their native stamina pricing unless they
explicitly configure an override.

Leaving the area, entering a vehicle, death, a routing change, native failure or
lease expiry also exits the activity. A resource stop returns connected members
and relies on backend-owned implant/scope cleanup. An external routing change
is respected: the example does not move someone back from another activity.
Disconnect does not autojoin the next connection.

There is no forced transport: return uses the current physical position in the
original bucket, not a teleport to the exact entry coordinates. The example
does not kill/respawn a player as a placement shortcut or autoheal the dead.
Environment/fall damage remains active; nonlethal punches do not make cliffs safe.
An unexpected return-bucket refusal is logged and reported to that participant.

Configuration supplies definitions, grades, damage, knockback, charge/cooldown,
duration, capacity, area and reset policy. Server creators can replace this whole
resource. A stopped definition cannot erase paid implants owned by other presets.

Bounded server notices log transitions, refusal reasons and pending lease/ticket
IDs without account identities or per-frame position logging.
