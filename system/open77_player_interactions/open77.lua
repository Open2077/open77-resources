resource 'open77_player_interactions'
version '1.0.0'
open77_version '>=0.0.1'
auto_start true
reload_policy 'local'
dependency 'open77_animations >=1.0.0'
client_scripts { 'client/controller.lua', 'client/main.lua' }
server_script 'server/main.lua'
permissions { 'network.events', 'animations.presentation', 'players.interactions.read' }
