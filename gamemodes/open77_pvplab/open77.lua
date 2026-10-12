resource "open77_pvplab"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

-- DEVELOPMENT LABORATORY. Phase 0 of docs/gamemode-pvp-arena-plan.md.
--
-- This resource exists to answer eight questions about props, NPCs and teams
-- that the documentation answers inconsistently or not at all. It registers
-- UNRESTRICTED commands on purpose, because it runs only on a loopback dev
-- server driven by an agent. It must never appear in templates/, in
-- server.jsonc, or on any server a player can reach.

client_script "client/main.lua"
server_script "server/main.lua"

permissions {
    "network.events",

    -- E1-E4: the wall.
    "world.props",

    -- E6-E8: the bots.
    "world.npcs",

    -- E9-E12: the client half reads the streamed projection so the debug
    -- bridge can be pointed at the right body. Read-only by construction.
    "npcs.read",

    -- E5, E7: teams and scripted damage against a player.
    "combat.config",
    "players.damage.read",
    "players.damage.apply",
    "players.life.read",
    "players.life.kill",
    "players.life.respawn",

    -- E6: the player needs a gun to shoot the bot with.
    "player.weapons.edit",
}
