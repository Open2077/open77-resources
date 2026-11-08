-- open77_avdoor -- the door the game's aircraft never had: board a parked AV
-- you may fly (stepping up into its door), step out of it beside its door,
-- set down on the game's AV pads, and hear a MaxTac AV a player flies. Also: the watch over where each screen draws an aircraft, the
-- landing call ("Clear the area. MaxTac landing."), the landing pad under an
-- AV a resource flies, and where such an AV may come down.
--
-- Ported from XyberRP's opx_infinity `avdoor` module, where it ran on the
-- XyberRP servers; README.md says what each part does and what was measured.
resource "open77_avdoor"
version "1.9.0"
open77_version ">=0.0.1"
auto_start true

-- The client half hangs its card in open77_interactions; a live swap would
-- leave it owned by a VM that no longer exists. A clean stop takes it down.
reload_policy "local"

dependency "open77_interactions >=0.1.0"

-- Loaded in this order on purpose: the config, the core every file reads, the
-- parts, and the file that starts them last.
shared_script "shared/config.lua"
shared_script "shared/core.lua"
server_script "server/main.lua"
server_script "server/native.lua"
server_script "server/watch.lua"
server_script "server/pad.lua"
server_script "server/landing.lua"
server_script "server/callout.lua"
server_script "server/walkout.lua"
server_script "server/enter.lua"
server_script "server/land.lua"
server_script "server/sync.lua"
server_script "server/padlist.lua"
server_script "server/snap.lua"
server_script "server/leave.lua"
server_script "server/boot.lua"
client_script "client/pad.lua"
client_script "client/callout.lua"
client_script "client/walkout.lua"
client_script "client/enter.lua"
client_script "client/sync.lua"
client_script "client/shots.lua"
client_script "client/groundtest.lua"
client_script "client/snap.lua"
client_script "client/standin.lua"
client_script "client/leave.lua"
client_script "client/main.lua"

-- The landing call, in fourteen languages (README.md, "The landing call").
files { "audio/*.wav", "audio/*.mp3" }

-- The aircraft doors, swung by the platform's trunk and hood: the Rayfield
-- Excalibur's animation graph with the trunk's feature and events in place of
-- its one cabin door's, and (1.9.0) the Militech Manticore's with its left
-- door's events swapped with the trunk's and its right door's with the hood's
-- (scripts/avdoor/make_door_graph.py). Installed by the launcher in
-- archive/pc/mod before Cyberpunk starts, while the player is on this server
-- (the server serves it as a required mod: `requiredMods.enabled` must be
-- true); a running client keeps the graphs it booted with until it restarts.
preload_mod "dist/Open77AvDoor_b9ce8a61b828.zip"

-- Least privilege, line by line.
permissions {
    -- Both halves: the door, the key, the flight's moments, the sounds, the
    -- sight reports, the pads and the calls. `source` is the only identity
    -- the server trusts.
    "network.events",

    -- Server: Open77.vehicles.get / all / getPlayerSeat / seatFree / isLocked /
    -- isLockedForPlayer / isFrozen to judge a door; warpPlayerIntoVehicle to
    -- seat a body; openDoor / closeDoor / isDoorOpen for the doors everybody
    -- sees; setTransform for the watch's one heal of an EMPTY hull, and to set
    -- an EMPTY airframe down on its gear after the last body stepped out (a
    -- pose every 50 ms while one left hovering glides down, 1.7.9);
    -- setFrozen and setTransform to fly an AV coming down over a pad onto it
    -- (the pad snap, server/snap.lua).
    "world.vehicles",

    -- Server: Open77.players.isDead -- nobody boards while down.
    "players.life.read",

    -- Server: Open77.effects.sound, the platform's own fan-out for a listener
    -- whose client refused a flight sound. Client: Open77.sfx.play for the
    -- flight sounds and the Trauma AV's engine voice, Open77.vfx.play for the
    -- landing pad's beams and the dust under the hull.
    "world.effects",

    -- Server: Open77.world.groundZ for `landingSite`. Client:
    -- Open77.world.groundZ (the ground beside the door, under the pad, under
    -- the pilot) and Open77.world.entityGeometry (where this screen draws a
    -- hull).
    "world.query",

    -- Client: Open77.vehicles.get / getPlayerSeat / nearby / all.
    "vehicles.read",

    -- Client: Open77.vehicles.warpPlayerIntoVehicle -- another player's
    -- boarding step ends seated, and that body is presented in the seat the
    -- server assigned at once, rather than walked back in by the platform's
    -- live entry (1.7.8, client/sync.lua).
    "vehicles.presentation",

    -- Client: Open77.travel.teleport -- the exit guard stands the body beside
    -- the door, and the boarding step on the clip's first spot before it.
    "player.travel",

    -- Client: Open77.screen.fadeOut / fadeIn -- the exit happens behind a fade.
    "screen.effects",

    -- Client: Open77.audio.play3D -- the landing call, played by each game.
    "audio.play",

    -- Client: Open77.session.locale -- the card's words and the landing call's
    -- language.
    "session.locale",

    -- Client: Open77.hud.notify -- why a door refused.
    "ui.vanilla.hud",

    -- THE EXIT CLIP AND THE BOARDING STEP (server/walkout.lua, server/enter.lua,
    -- the client halves; optional, with open77_avexit running). Server:
    -- Open77.locomotion.set / get / playClip -- the package's style and clips.
    "locomotion.control",
    "locomotion.read",

    -- Server: Open77.players.setVisible -- the others do not see the
    -- platform's own exit (the drop in the cabin, the eject under the hull).
    "players.life.visibility",

    -- Client: Open77.players.freezePosition / freezeRotation -- the body is
    -- held still while its exit clip or its boarding step plays.
    "players.controls",

    -- Client: Open77.character.setFrozen -- the engine's NoMovement restriction,
    -- the hold tried when the platform's freeze takes the body off the ground
    -- (no clip is drawn on a body in the air).
    "player.freeze",

    -- Client: Open77.input.registerKeyMapping / unregisterKeyMapping -- the exit
    -- key (1.9.0, client/leave.lua): F, consumed, while the body sits in an
    -- airframe whose exit the game animates (the Militech Manticore), so the
    -- server steps it out through the forced exit; dropped when it is out.
    "input.actions",

    -- Client: Open77.perspective.setThirdPerson(true, true) -- the exit is seen
    -- in the platform's own third person (the stand-in body, with its head),
    -- not the legacy view of the first-person body.
    "perspective.policy",

    -- Client: Open77.camera.orbit / clearOrbit -- the exit clip is seen from
    -- in front: the third-person camera swung round the body while it plays
    -- (the platform's preview orbit), and back behind it as it ends.
    "camera.preview",

    -- Client: Open77.character.bonePosition / bones -- where this game draws
    -- the AV's door (its door slots, `AIRFRAMES` ... `DOOR_SLOTS`) and another
    -- player's hips during their exit step: the logger measures the step's
    -- first frame against the door as each screen draws both.
    "world.transform",

    -- Client: Open77.screen.capture -- a few small pictures of this game's own
    -- frame during each exit, kept on this machine (Open77.kvp) for the exit's
    -- tests and sent nowhere (`DIAG`, client/shots.lua).
    "screen.capture",

    -- Client: Open77.weapons.holster -- a weapon drawn as the key is pressed at
    -- a door is put away before the step up (1.7.2): the platform plays no clip
    -- on a body with a weapon drawn. The loadout is left as it was.
    "player.weapons.edit",
}
