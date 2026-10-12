resource "open77_doors"
version "1.2.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"
dependency "open77_elevators >=1.0.0"
server_scripts { "server/authority.lua", "server/main.lua" }
client_script "client/main.lua"
-- world.npcs + npcs.foreign: read-only `Open77.npcs.presence` of the NPC an
-- NPC door intent is for (I7). The service owns no NPC and writes none.
permissions { "network.events", "local.events", "world.doors", "world.elevators", "acl.read", "world.npcs", "npcs.foreign" }
