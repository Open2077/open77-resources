-- open77_actions -- the thin action library (row B5) and the carry helper (row A5)
-- of the world-interaction campaign. Contract: docs/world-interaction/b5-actions.md;
-- author guide (experimental): wiki/actions.md.
--
-- Opt-in, `auto_start false`: it is a library a job resource depends on. List it in
-- `resources.load` (a profile with an explicit list is a silent allowlist: a resource
-- missing from it is never started and never logged) and start it with `ensure`: in the
-- 2026-10-12 lab an explicit load entry alone did not start it. Lab commands
-- (`actions.lab.*`) exist only with the `open77_actions_lab` convar set to 1.
resource "open77_actions"
version "0.1.0"
open77_version ">=0.0.1"
auto_start false

-- The client half holds control claims and a progress bar; a live swap would
-- leave them owned by a VM that no longer exists. Clean stop releases them.
reload_policy "local"

-- Every dependency is presentation this library composes rather than rebuilds:
--   open77_animations   client presentation of Open77.animations play/playAt/sequence
--   open77_props        client projection of the carried props and their attachment
--   open77_interactions the prompt service the client half creates its prompts in
--   open77_uikit        the progress bar and the "put down" hint
dependency "open77_animations >=1.0.0"
dependency "open77_props >=0.1.0"
dependency "open77_interactions >=0.1.0"
dependency "open77_uikit >=1.0.0"

shared_script "shared/model.lua"
server_script "server/claims.lua"
server_script "server/engine.lua"
server_script "server/carry.lua"
server_script "server/main.lua"
client_script "client/main.lua"

-- Least privilege, line by line.
permissions {
    -- Both halves: the server sends present / end / carry / targets / refused to
    -- one client; the client sends intent / putdown / cancel / sync. Ordinary
    -- authenticated net events; `source` is the only identity trusted.
    "network.events",

    -- Server: Open77.animations.play / playAt / sequence / stop / stopAt. The
    -- library starts and stops only the playbacks it owns; `get` (catalogue
    -- read, for clipDurationsMs) needs nothing.
    "players.animations.control",

    -- Server: the life half of Open77.players.get (`alive`, `dead`). Without it
    -- the fields are absent and a dead actor could not be told from a live one.
    -- Acting on a player on the continue screen crashes his client.
    "players.life.read",

    -- Server: the seat half of Open77.players.get (`inVehicle`) and
    -- Open77.vehicles.get for a vehicle put-down destination. Read only.
    "world.vehicles",

    -- Server: Open77.props.create / attach / detach / setTransform / remove for
    -- the carriable items this resource owns (a prop is mutable only by its owner).
    "world.props",

    -- Client: Open77.input.setActionBlocked (Movement, Attack, Melee, Sprint) for the running
    -- operation and Open77.input.registerKeyMapping for the put-down key.
    "input.actions",

    -- Client: Open77.players.allowJump and Open77.movement.setWalkMode -- the
    -- movement restrictions of a carry. Per-resource claims, released on stop.
    "players.controls",

    -- Client: Open77.hud.notify for a refusal ("someone is already using this").
    "ui.vanilla.hud",
}
