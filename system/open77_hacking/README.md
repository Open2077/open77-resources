# open77_hacking

This resource is the player side of server-owned hacking: a player aims at another player and holds a key to upload a quickhack, and both players see, hear and feel the result. It covers Short Circuit, Overheat, Cyberware Malfunction, Cripple Movement, Reboot Optics and Weapon Glitch, plus the self and ally purge keys and the victim's warnings, while the server decides every outcome.

- **Docs:** [Hacking and counterplay](https://open2077.net/docs/hacking)
- **Starts:** on its own
- **Needs:** `open77_cyberware`, `open77_effects`, `open77_notifications`
- **Runs on:** server and client

Core client support for server-owned Short Circuit, Overheat, Cyberware Malfunction,
Cripple Movement, Reboot Optics, Weapon Glitch, Self-ICE and purge. This resource does not install implants or enable
a combat policy. Without an authoritative ready state it cannot submit a hack or purge
intent. The input path is kind-agnostic: the installed deck's `kind` only changes the
words (aim hint, incoming warning, impact line, outcome lines, toast titles, the native
bar headers) and the victim cue colour and sound.

It registers a rebindable **hold** mapping for the attack (F8), INSERT self purge, DELETE
aimed ally purge and END cancel. Aiming at a player draws nothing on the HUD: at most one
throttled chat line names the target and the keys. Pressing and holding the hack key while
aiming opens the hacking interface and submits the start intent; the upload runs while the
key is held, and releasing it before completion cancels the upload through the same cancel
path END uses (a release that lands before the server has opened the upload cancels it on
arrival). Selection uses actual streamed player bodies, the current camera and native
physics; it never opens the vanilla scanner or changes time scale. Incoming/upload progress
uses the native HUD adapter, scaled to 1.5x while it carries a hacking header and carrying
a twelve-cell ASCII fill bar next to the stock percentage; chat supplies target and outcome
text. The header names the kind (`<KIND> UPLOAD` while armed/uploading, `INCOMING <KIND>`
on the target, `<KIND> IMPACT` on a hit, with `SHORT CIRCUIT`, `OVERHEAT`, `CYBERWARE
MALFUNCTION`, `CRIPPLE MOVEMENT`, `REBOOT OPTICS` and `WEAPON GLITCH`) through the
`kind` field of `Open77.hacking.present`
(the fourth field of the `hacking.hud:` bridge command; a DLL without it keeps the Short
Circuit headers).

A connected Short Circuit is presented on both sides. The server projects three bounded
layers on the victim's body (the cooked electrocuted status effect on RightHand with the
authored `status_electrocuted` event in the victim's own view, the same effect on Chest,
and the catalog `electric.arc` on RightHand; 1.5 s, at most 24 live handles) plus one
deduplicated `quickhack_shortcircuit`. The victim's client adds the same hit sound
on its own body with `unique`, gated by
`HackingInput.feedback.sound` in `client/config.lua`. Impact cues use body effects,
HUD and audio. They never invoke a quest fade, because a fade can interrupt the
victim's native knockdown and cause `native_refused`.

An Overheat plays `quickhack_overheat` on the victim at impact,
then the server keeps a small flame and pouring steam on the victim's chest for the whole
burn (the authored `hacks_overheat_lvl1` event in the victim's own view); a Cyberware
Malfunction plays `quickhack_cyberware_malfunction`, then the EMP
status effect on the chest, the electrocuted status effect on the chest and the right
hand, and cable sparks on the right hand for the whole suppression
(`hacks_cyberware_malfunction` in the victim's view). Burn ticks (`status_tick`) print
nothing; the victim's toast countdown shows the remaining time.

A Cripple Movement plays `quickhack_locomotion_malfunction` on the
victim, then the victim's **own client** slows itself for the status through the platform
movement lock (`Open77.movement.lock`, permission `player.movement.lock`): `cripple` is the
vanilla netrunner Cripple Movement on V (MaxSpeed x0.75, no dodge, the `hacking_glitch_low`
glitch and the crippled HUD icon), `cripple_heavy` its Tier 3 (x0.4). The server refuses
the victim's Dash and Ground Slam with `crippled` for the same deadline; that gate is the
authority, the lock is presentation a modified client can drop but not dash out of. The
same lock serves `effects.freezeMs` beyond the native knockdown: a `freeze` row is applied
`HackingInput.freezeAfterKnockdownMs` (3 s) after the knockdown that always accompanies it,
for whatever remains of the server deadline, so the knockdown and the lock's stunned state
are never applied in the same tick. Freeze outranks cripple; a cripple resumes when the
freeze ends. `status_purged` / `status_expired` of the cripple, body loss and resource stop
release the lock at once; a fresh authoritative roster (reconnect, reload) re-locks from
`activity.frozenMs` / `crippledMs`. A refusal (`not_alive`, `in_vehicle`, `menu_open`,
`lock_busy` …) is logged once and never retried. Observers see no body effect for a
cripple.

A Reboot Optics plays `quickhack_optics_malfunction` on the victim,
a Weapon Glitch `quickhack_weapon_malfunction`; then the victim's **own
client** applies the kind's native status through the platform status primitive
(`Open77.hacking.nativeStatus(kind, remaining)`, permission `player.hacking.status`, one
independent slot per kind, clamped at 15 s): `blind` is an Open77 clone of the vanilla
netrunner Reboot Optics on V (`AIQuickHackStatusEffect.HackBlind`: `status_blinded`
VFX/SFX, `hacking_glitch_low`, scanner off, accuracy x0.01, the blinded HUD icon, no
movement stat), `weapon_jam` a clone of `BaseStatusEffect.WeaponMalfunction` (type `Jam`:
the held weapon reads not-ready and cannot fire, `hacks_weapon_malfunction`, the jammed
icon, movement untouched). The server gates nothing for a blind and refuses Gorilla Arms
arming with `weapon_glitched` for a glitch; those gates and deadlines are the authority,
the statuses are presentation a modified client can drop but not punch through.
`status_purged` / `status_expired` of the kind, body loss and resource stop clear the
status at once; a fresh roster re-applies from `activity.blindedMs` / `weaponGlitchedMs`;
a refusal (`not_alive`, `in_vehicle`, `menu_open`, `status_busy` …) is logged once and
never retried. Without the primitive (an older DLL) a Reboot Optics falls back to a
bounded screen-flash burst (`HackingInput.opticsFallback`, three tinted flashes at onset
and one at recovery through the native fade), a placeholder documented as such; a Weapon
Glitch has no substitute there, the server-side Gorilla gate is all that remains.
Observers see an `electric.arc` on the chest for a blind, the electrocuted status effect
and cable sparks on the right hand for a jam.

Each incoming action also raises an immediate chat warning, an independent bounded
native audio cue and an owned notification toast. The toast remains usable when a
foreign native progress bar owns the stock HUD. Defender evidence stays pending until
the notification WebUI has reported readiness and accepted the warning; unavailable
or rejected warnings fail closed.
Challenge refreshes reuse one warning and do not replay the cue. Terminal events,
lifecycle cleanup and resource teardown remove owned warnings.

The server sends challenge endpoints and a nonce to both participants. Each answers
with a current Static/Dynamic raycast on those exact endpoints. Missing physics is a
negative answer. The server owns freshness, ranges, body identities and all outcomes.
This bilateral evidence detects ordinary cover loss but is not trusted server physics:
colluding modified clients can lie. No client chooses damage or duration.

See [Hacking and counterplay](https://open2077.net/docs/hacking) for the creator API, and the
optional [open77_hacking_lab](../../gamemodes/open77_hacking_lab/) game mode.
