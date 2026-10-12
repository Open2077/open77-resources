resource 'open77_gizmos_editor'
version '0.1.0'
open77_version '*'
auto_start true
reload_policy 'reconnect'
server_scripts { 'authority.lua', 'server.lua' }
client_script 'client.lua'
permissions { 'gizmos.edit', 'world.props', 'network.events', 'acl.read', 'players.life.read' }
