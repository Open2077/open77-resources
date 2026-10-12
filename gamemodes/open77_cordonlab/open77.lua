resource "open77_cordonlab"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

-- DEVELOPMENT LABORATORY. Phase 0 of docs/gamemode-cordon-plan.md.
--
-- One command per experiment E3-E12: the drop, ghost spectating, cordon damage,
-- the loot loop, revive at the body, the light edge, vehicle ramming, a server-
-- flown AV and team persistence. Every command prints what it asked for and what
-- it got back, refusal reason included, and the event log prints every life,
-- damage and weapon event with its context so a readout is a fact, not a guess.
--
-- It registers UNRESTRICTED commands on purpose: it runs only on a loopback
-- dev-local server driven by an agent. It must never appear in templates/, in
-- server.jsonc, or on any server a player can reach.

client_script "client/main.lua"
server_script "server/main.lua"

permissions {
    "network.events",

    -- E3 drop, E7 revive, E12 placement, E4 ghost.
    "players.life.read",
    "players.life.kill",
    "players.life.revive",
    "players.life.respawn",
    "players.life.ghost",

    -- E5 cordon damage, E3/E4 god mode.
    "players.damage.read",
    "players.damage.apply",

    -- E12 teams, and the arbiter log for E6.
    "combat.config",

    -- E6 loot -> assign.
    "world.loot",
    "player.weapons.edit",

    -- E8 the light edge.
    "world.props",

    -- E9 ramming, E10 the AV lane.
    "world.vehicles",

    -- Client half: noclip for the ghost spectator (E4).
    "player.travel",
}
