resource 'open77_animations'
version '1.0.0'
open77_version '>=0.0.1'
auto_start true
reload_policy 'local'

client_scripts { 'shared/catalog.lua', 'client/controller.lua', 'client/main.lua' }
server_script 'server/main.lua'
permissions { 'network.events', 'animations.presentation', 'players.animations.control' }
