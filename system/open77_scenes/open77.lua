-- open77_scenes -- synchronized RP scenes on the world's furniture: the first
-- one lies a player down on a ripperdoc's surgical chair (sit down, seated
-- loops, get up), seen the same by every player in the bucket, late joiners
-- included. Author guide: wiki/scenes.md. Research: docs/research/rp-scenes.md.
--
-- Opt-in, `auto_start false`: add it with its two dependencies to the server's
-- `resources.load`, then `ensure` them (open77_animations is the platform's RP
-- presentation service and must run too).
resource "open77_scenes"
version "0.1.0"
open77_version ">=0.0.1"
auto_start false

-- The client half creates prompts in open77_interactions; a live swap would
-- leave them owned by a VM that no longer exists.
reload_policy "local"

dependency "open77_animations >=1.0.0"
dependency "open77_interactions >=0.1.0"

shared_script "shared/scenes.lua"
server_script "server/spots-generated.lua"
server_script "server/core.lua"
server_script "server/main.lua"
client_script "client/main.lua"

permissions {
    -- Both halves: spots / state / refused to one client; start / stand / idle / sync from it.
    "network.events",
    -- Server: Open77.animations.sequenceAt / stopAt for the scenes this resource starts.
    "players.animations.control",
    -- Server: Open77.animations.current -- a player already in an animation is refused.
    "players.animations.read",
    -- Server: the life half of Open77.players.get (alive, dead).
    "players.life.read",
    -- Server: the seat half of Open77.players.get (inVehicle).
    "world.vehicles",
    -- Server: Open77.players.setHeading -- the waiting body turns to where the get-up ends.
    "players.teleport",
    -- Client: Open77.input.registerKeyMapping for the get-up and change-pose keys.
    "input.actions",
    -- Client: Open77.hud.notify for hints and refusals.
    "ui.vanilla.hud",
}
