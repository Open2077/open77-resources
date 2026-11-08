resource "open77_netdebug"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

-- /netdebug.npc (admin): live 3D labels over the nearest network NPCs -- id, record, who
-- simulates it (network owner + lease epoch), the gap between this client's body and the
-- canonical position, health, task, and the teleports this client saw.
dependency "open77_uikit >=1.0.0"

client_script "client/main.lua"
server_script "server/main.lua"

permissions { "network.events", "network.client", "npcs.read" }
