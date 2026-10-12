resource "open77_weapons"
version "0.2.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
client_script "client/blasts.lua"
server_script "server/main.lua"
server_script "server/blasts.lua"

permissions {
    "network.events",
    "player.weapons.read",
    "player.weapons.edit",
    -- Blast relay (server/blasts.lua): find the cars a blast reaches and their
    -- physics owner, grant an ownerless one to the source, launch players the
    -- gamemode policy allows.
    "world.vehicles",
    "players.life.read",
    "players.motion.read",
    "players.motion.control"
}
