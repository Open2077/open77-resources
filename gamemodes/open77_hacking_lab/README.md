# open77_hacking_lab

A test arena for hacking: ACL-restricted `/hacklab` commands install hacking decks, Self-ICE and purge implants on chosen players, open scoped PvP between them, place them and apply statuses, so you can try every hack kind and its counterplay. Run it on an isolated test server; it is not a public game mode.

- **Docs:** [Hacking and counterplay](https://open2077.net/docs/hacking)
- **Starts:** with `ensure open77_hacking_lab` (it declares `auto_start false`)
- **Needs:** `open77_hacking`
- **Runs on:** server

## Use it

Disabled by default. Start `open77_hacking_lab` explicitly on an isolated server.
Grant test operators `command.hacklab`; every command below is ACL restricted.
Other resources and game modes are not modified.
Run the existing `open77_appearance` character identity adapter (or a compatible
creator replacement) so players have a ready bound cyberware character. This lab
does not create a competing character/health ledger or identity binding.

Use real connected, alive, ready player IDs in place of 1 and 2. Operations are
explicit idempotency labels; use a new label for a new installation/removal.

```text
/hacklab attacker 1 training hacking-a-01
/hacklab protected 2 training hacking-b-ice-01
/hacklab ally 2 training hacking-b-purge-01
/hacklab state 1
/hacklab state 2
/hacklab scope 0 1 2
```

Replace `0` with both players' current routing bucket. `scope` returns an ID and
enables canonical PvP only among the listed 2–32 players in that bucket, subject to
teams, life and existing vetoes. It does not change global friendly fire. Retain the
returned ID and run `/hacklab unscope ID` to remove it; lab stop also releases owned
combat scopes. A scope does not move players between buckets.

Face the other player within 20 metres, then **press and hold F8**. The 1.5x bar
names the installed kind (`SHORT CIRCUIT UPLOAD`, `OVERHEAT UPLOAD`, `CYBERWARE
MALFUNCTION UPLOAD`, `CRIPPLE MOVEMENT UPLOAD`) on the attacker and `INCOMING <KIND>` on
the target, then `<KIND> IMPACT` on a connected hit. Aiming alone shows
nothing beyond a chat hint; the hacking interface opens on the press and the two-second
upload runs only while the key stays held. Let go early and the upload is cancelled,
exactly as END would. An unprotected target receives the upload warning and can move
behind cover, leave range, interrupt the hacker, or press INSERT when purge is installed.
DELETE purges the aimed ally; END still cancels the actor's own upload. Pause → Settings →
KEY BINDINGS changes these keys. On a connected hit expect sparks and an arc on the
target's body from any viewpoint, a short electric-blue flash and a hit sound on the
target's own screen, and the 1.5x `SHORT CIRCUIT IMPACT` bar on the attacker's.

For scene setup, `/hacklab place PLAYER X Y Z HEADING` uses heading in degrees
(0 faces +Y). Coordinates must be finite and within ±1,000,000; heading within
±360,000 is normalized. This is a canonical kill/respawn transaction for a ready,
alive player, preserving the current health fraction and bucket, with zero added
grace. It cancels transient work and requires the normal native recovery acknowledgement.
Wait for alive/readiness again before testing. It is not seamless movement or an
interruption test, does not bypass cooldowns, and cannot place a dead player.
An accepted request is not settlement proof: also check actual `char.state` at the
intended grounded point. Prefer already streamed nearby ground. Cross-district
placement can hit recovery/settlement limitations; do not infer success
from canonical acknowledgement alone or compensate with an arbitrary Lua delay.
There is no public `Open77.players.teleport` API; the lab composes the existing
permission-controlled life and stats APIs, without requiring Freeroam.

Use `/hacklab protection 2 on 0` for an owned safe-area guard, or
`/hacklab protection 2 off 0.5` for 50% electrical resistance with no lab safe-area
flag. `/hacklab clearprotection 2` removes only the lab's contribution. These tests
use public incarnation/bucket-owned policy APIs, separate from Self-ICE charges.

The `stun` grade demonstrates the server-owner outcome catalogue: `/hacklab attacker 1
stun hacking-a-stun-01` installs a deck whose connected upload deals 10 damage, holds
the target's movement for 2 s, puts them on the floor, and suspends their Open77
abilities (Dash, Ground Slam, arms, hacking, purge) for 5 s. See `effects` in
`server/config.lua` and the `effect_applied` transitions in the lab log. Both players
see the outcomes in chat; the victim also gets a toast per outcome.

## Overheat and Cyberware Malfunction

The two other hack kinds ride the same deck slot, keys and upload; only the grade
changes. Install one of them on the attacker instead of `training`:

```text
/hacklab attacker 1 overheat hacking-a-heat-01
/hacklab attacker 1 malfunction hacking-a-glitch-01
/hacklab attacker 1 malfunction_motion hacking-a-glitch-motion-01
/hacklab ally 2 training hacking-b-purge-01
/hacklab scope 0 1 2
```

`overheat`: a 5-point direct hit, then **40 more damage over 5 s in 500 ms ticks**
(`burn={totalDamage=40,durationMs=5000,tickMs=500}`), server-ticked through the same
non-bleeding ledger, nonlethal here. On every window expect a small flame and pouring
steam on the target's chest for the whole burn (the closest audited substitutes; no
cooked burn character effect exists by name), a heat-orange flash and the
`quickhack_overheat` sound on the target's own screen, `Overheat connected.` in the
attacker's chat, `You: Overheating for 5.0 s. Press INSERT to purge if installed.` plus
an `OVERHEAT` toast with a countdown on the target, and the health bar stepping down
ten times. INSERT on the target (purge installed) or DELETE from an ally stops the
ticks at once; so do death, reconnect, a bucket change and stopping the lab. The lab
log shows `status_applied`, `effect_applied reason=burn amount=5000`, ten
`status_tick reason=burn amount=4` and `status_expired reason=expired` (or
`status_purged reason=self_purge` / `ally_purge`). One burn per target: a second
Overheat inside the first lands its direct hit and logs `effect_refused reason=burn`
with the running burn's `statusEndsAt`.

`malfunction`: no damage; Dash, Ground Slam, Gorilla arming and hacking/purge on the
target refuse `cyberware_suspended` for 8 s (`malfunction={durationMs=8000,blocks=
{"dash","ground_slam","gorilla","hacking"}}`), installed grants untouched. Expect the
EMP sparks status effect on the target's chest plus cable sparks on the right hand for
the whole suppression, a violet flash and `quickhack_cyberware_malfunction` on the
target's screen, and a `CYBERWARE MALFUNCTION` toast listing the suppressed abilities
with a countdown. Press the Dash key or hold F8 on the target during the window: the
Dash permit and the hacking result both read `cyberware_suspended` (the target's chat
prints `Your cyberware is malfunctioning.`), and `/hacklab state 2` shows
`malfunctionMs` / `malfunctionBlocks` next to the running status. Because `hacking` is
listed, the target's own INSERT is refused too. That is the point of the
`malfunction_motion` grade, which leaves hacking alone so INSERT still purges it; DELETE
from an ally purges either. Death, reconnect, bucket change and lab stop lift it.

With the kind-aware presentation in the client, the 1.5x bar names the kind on both
sides (`OVERHEAT UPLOAD` / `INCOMING OVERHEAT` / `OVERHEAT IMPACT`, `CYBERWARE
MALFUNCTION UPLOAD` / `INCOMING CYBERWARE MALFUNCTION` / `CYBERWARE MALFUNCTION IMPACT`),
exactly as the chat hint, the incoming warning, the impact line and the toasts do. An
older client keeps the Short Circuit headers. The Malfunction body look adds the
electrocuted status effect on the chest and the right hand to the EMP/cable pair.

## Reboot Optics and Weapon Glitch

```text
/hacklab attacker 1 reboot_optics hacking-a-optics-01
/hacklab attacker 1 weapon_glitch hacking-a-glitch-01
/hacklab ally 2 training hacking-b-purge-01
```

`reboot_optics`: no damage; for 8 s the target's **own client** applies the native blind
through the platform status primitive (`Open77.hacking.nativeStatus("blind")`, an Open77
clone of the vanilla netrunner Reboot Optics on V: `status_blinded` VFX/SFX, the
`hacking_glitch_low` glitch, scanner off, accuracy x0.01, the blinded HUD icon, no
movement stat). Nothing is gated server-side; purge lifts it. `weapon_glitch`: no damage;
for 8 s the target's own client jams its held weapon (`weapon_jam`, a clone of
`BaseStatusEffect.WeaponMalfunction`: the weapon reads not-ready and cannot fire, the
jammed icon, movement untouched) while the **server** refuses its Gorilla Arms arming
with `weapon_glitched` for the same deadline; hacking, purge, Dash, Ground Slam and
ordinary melee stay usable, so INSERT always purges a glitch.

Expected on the target: the kind's flash and daemon sound at impact, then the native
look (static / scanner off, or a weapon that will not fire and the jammed icon) with
`You: Optics rebooting - vision and scanner disrupted for 8.0 s. Press INSERT to purge if
installed.` or `You: Weapon glitched - weapon jammed, Gorilla Arms refused for 8.0 s. …`,
the toast titled `REBOOT OPTICS` / `WEAPON GLITCH` counting down. On the attacker:
`REBOOT OPTICS IMPACT` / `WEAPON GLITCH IMPACT` on the bar and `Reboot Optics connected.`
/ `Weapon Glitch connected.`; observers hear the sound and see an arc on the chest (blind)
or the electrocuted effect plus cable sparks on the right hand (jam). A Gorilla arm
attempt by the glitched target reads `weapon_glitched` in the server log
(`onCyberwareActionRejected`); `/hacklab state 2` shows `blindedMs` / `weaponGlitchedMs`.
The bridge read `hacking.status.state` on the target client reads `blind=applied
blind.owner=open77_hacking` (or `weapon_jam=applied …`), then `idle` with
`reason=clear` after a purge or `reason=deadline` at expiry. A second upload of the same
kind inside the first (the 8 s deadline outlasts the 6 s cooldown) is `effect_refused
reason=blind|weapon_jam` with the running deadline; a blind and a jam coexist.

## Cripple Movement and the long freeze

```text
/hacklab attacker 1 cripple hacking-a-limp-01
/hacklab attacker 1 cripple_heavy hacking-a-limp-heavy-01
/hacklab attacker 1 freeze_long hacking-a-freeze-01
/hacklab ally 2 training hacking-b-purge-01
/hacklab scope 0 1 2
```

`cripple` / `cripple_heavy`: no damage; for 12 s the target's **own client** slows
itself through the platform movement lock (`Open77.movement.lock("cripple")`, MaxSpeed
x0.75, or `cripple_heavy`, x0.4; no dodge, no double/charge jump, sprint still allowed at
the reduced ceiling) while the **server** refuses the target's Dash and Ground Slam with
`crippled` for the same deadline. Hacking, purge and Gorilla arms stay usable, so INSERT
always purges it; DELETE from an ally does too, and death, reconnect, bucket change and
lab stop lift it. Expect on the target: a violet-blue flash and
`quickhack_locomotion_malfunction`, the vanilla `hacking_glitch_low` glitch and the
crippled HUD icon (the cripple clone starts both on the local player), `You: Movement
crippled - speed x0.75, no dodge, Dash, Ground Slam refused for 12.0 s. Press INSERT to
purge if installed.` plus a `CRIPPLE MOVEMENT` toast with a countdown, and visibly slower
walking/sprinting (the heavy grade is unmistakable). On the attacker: `CRIPPLE MOVEMENT
IMPACT` on the bar and `Cripple Movement connected.`; observers hear the sound and see
the slow body, with no extra body layer. A Dash key press on the
target during the window is refused `crippled` (parkour log); `/hacklab state 2` shows
`crippledMs` and `crippleHeavy`. The bridge read `movement.lock.state` on the target
client reads `phase=locked kind=cripple owner=open77_hacking`, then `idle reason=unlock`
after a purge or `reason=deadline` at expiry. A second cripple inside the first (the
12 s deadline outlasts the 6 s cooldown) lands its (zero) hit and logs `effect_refused
reason=cripple` with the running deadline. A modified client can ignore its own slow; it
cannot dash out of it.

`freeze_long`: `effects={freezeMs=6000}` on a Short Circuit grade. The platform freeze
always rides the stationary knockdown, so the target goes to the floor first
(`effect_applied reason=freeze amount=6000` in the log, no `knockdown` row because the
grade does not list it); the target's client waits `HackingInput.freezeAfterKnockdownMs`
(3 s, the stand-up time) and then locks the body through
`Open77.movement.lock("freeze")` (the stunned stagger pose, weapon forced safe, no
movement input, camera free) until the server deadline, 3 s later. `movement.lock.state`
on the target reads `phase=locked kind=freeze` from ~3 s to ~6 s after impact. The
server's `frozen` gate covers the whole 6 s regardless of the client (hacking, purge,
Dash, Ground Slam). The lab `stun` grade (freeze 2 s) never locks: the knockdown covers
it. If the stagger pose does not hold for the 3 s, or the lock starts while the body is
still on the floor, lower or raise `freezeAfterKnockdownMs` in
`open77_hacking/client/config.lua`.

### Server-side purge trigger

When both test clients run on one desktop, the defender's INSERT/DELETE steals window
focus from the attacker, whose held F8 is released and the upload cancels
(`interrupted reason=cancelled` shortly after `upload_started`) before the purge key
lands. `/hacklab purge` triggers the purge from the server through the public
`Open77.hacking.purge` API, the same authority path as the key (purge implant installed
on the actor, cooldown, stamina, team/range policy, `cyberware_suspended` while a
malfunction lists hacking), so purge-during-upload and status purge can be tested for
every kind from one machine. It is also a usable RP hook (a ripperdoc console, a medic
ability).

```text
/hacklab purge 2        # player 2 purges itself (self purge, INSERT equivalent)
/hacklab purge 2 1      # player 2 purges its ally 1 (DELETE equivalent; same positive team, <=10 m)
```

Self-ICE blocks one eligible upload and recharges after 15 seconds. For an ordinary
defender, `/hacklab unprotected 2 hacking-b-ice-remove-01` removes only the ICE slot.
It does not remove arms, legs or purge. The training hit is nonlethal and preserves
movement/camera; the cosmetic hack grade commits no damage.

For ally assistance, install the `ally` preset on the assisting player and explicitly
give defender/helper the same positive combat team with `/hacklab team PLAYER TEAM`.
DELETE requires an eligible target within 10 metres; it consumes the helper's cost and
cooldown. Showing attacker, defender and helper at once needs three game clients.

For an **owned-status fixture**, install the zero-damage
`ally_status` attacker grade on A and the purge implant on A, then place A/B
within 10 metres and create the canonical combat scope:

```text
/hacklab attacker 1 ally_status fixture-deck-01
/hacklab ally 1 training fixture-purge-01
/hacklab scope 0 1 2
/hacklab allyfixture 1 2
```

Aim A at B and physically press DELETE before the two-second status expires.
The ACL-restricted `allyfixture` command explicitly changes both teams to neutral 0,
applies the status, then **only on success** changes both teams to 7. These setup
transitions are logged. It requires distinct ready players; public status application
still validates incarnation, life, range, bucket, entitlement and canonical combat
policy. Failure after neutralization can leave teams at 0; restore desired teams explicitly.
This allegiance change is synthetic fixture setup, not normal gameplay or a bypass
of the canonical same-team attack veto. `friendlyFire=true` on a grade cannot
override that veto. The generic `status ACTOR TARGET GRADE` command remains available
without changing teams and may be vetoed accordingly.

Both commands use `Open77.statuses.apply` and its explicit
`players.statuses.apply` capability, configured definitions and normal canonical
eligibility. No client supplies damage. The fixture grade deals zero damage,
preserves movement/camera, requests friendly fire subject to canonical vetoes, and has three-second
recovery protection. Inspect the returned action/status ID and `status_purged`
transition. This is a permission-controlled synthetic status, not a real incoming
upload. Restore the desired normal deck grade and team policy after the fixture.

```text
/hacklab remove 1 operating_system hacking-a-remove-01
/hacklab remove 2 self_ice hacking-b-ice-remove-02
/hacklab remove 2 purge hacking-b-purge-remove-01
```

These are durable installations through existing cyberware APIs. Stopping the lab
revokes its definitions and cancels transient work; it does not erase paid records.
Restart the provider to restore definition availability. Economy, doctor consent,
prices and progression remain replaceable. Check current state after every operation;
an accepted install is not proof of successful native or multiplayer presentation.
