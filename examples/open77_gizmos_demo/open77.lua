resource 'open77_gizmos_demo'
version '0.1.0'
open77_version '*'
auto_start true
reload_policy 'local'
client_script 'client.lua'
server_script 'server.lua'
-- world.vehicles serves independent state reads and the restricted placement
-- laboratory, which only mutates cars created by this resource for that admin.
permissions { 'gizmos.edit', 'world.props', 'network.events', 'world.vehicles', 'world.npcs' }
