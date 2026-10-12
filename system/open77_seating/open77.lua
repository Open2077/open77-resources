-- open77_seating -- players sit (and lean) on the world's real furniture
-- (row B6 of docs/world-interaction-plan.md). Contract and lab script:
-- docs/world-interaction/b6-seating.md; author guide (experimental):
-- wiki/furniture.md.
--
-- Opt-in, `auto_start false`: add it, and its three dependencies, to the
-- server's `resources.load` (a profile with an explicit list is a silent
-- allowlist). open77_pedestrians is used when it runs (NPC coordination) and
-- is deliberately not a dependency: a server without the crowd has no NPC to
-- coordinate with.
--
-- A separate resource rather than a module of open77_furniture: the catalogue
-- stays a read-only, permission-free library (one 12.7 MiB copy, in its own
-- VM, for every resource that looks furniture up), and the gameplay half --
-- prompts, permissions, claims, a client script -- reloads without rebuilding
-- that index. The coupling is one direction, three exports (nearby/get/status).
resource "open77_seating"
version "0.1.0"
open77_version ">=0.0.1"
auto_start false

-- The client half creates prompts in open77_interactions; a live swap would
-- leave them owned by a VM that no longer exists. Clean stop removes them.
reload_policy "local"

-- open77_furniture is NOT a manifest dependency: it is server-only, and this resource ships a client
-- script, so the client would refuse activation (`missing_dependency:open77_furniture`) and end
-- the session (live, 2026-10-12). The server reaches the catalogue through exports and answers
-- `furniture_unavailable` until it runs; list it in `resources.load` next to this resource.
dependency "open77_actions >=0.1.0"
dependency "open77_interactions >=0.1.0"

shared_script "shared/model.lua"
server_script "server/core.lua"
server_script "server/main.lua"
client_script "client/main.lua"

-- Least privilege, line by line.
permissions {
    -- Both halves: the server sends seats / state / refused to one client; the
    -- client sends sit / stand / sync. `source` is the only identity trusted.
    "network.events",

    -- Server: Open77.animations.playAt / stopAt for the postures this resource
    -- starts (it stops only its own playbacks).
    "players.animations.control",

    -- Server: Open77.animations.current -- a player already in an animation
    -- (an emote, another resource's posture) is refused before being moved.
    "players.animations.read",

    -- Server: the life half of Open77.players.get (`alive`, `dead`). Acting on
    -- a player on the continue screen crashes his client.
    "players.life.read",

    -- Server: the seat half of Open77.players.get (`inVehicle`). Read only.
    "world.vehicles",

    -- Server: Open77.players.teleport to the approach point beside the
    -- furniture before the posture (never onto it), and back to it after a
    -- voluntary stand-up.
    "players.teleport",

    -- Client: Open77.input.registerKeyMapping for the stand-up key.
    "input.actions",

    -- Client: Open77.hud.notify for a refusal ("someone is already sitting there").
    "ui.vanilla.hud",
}
