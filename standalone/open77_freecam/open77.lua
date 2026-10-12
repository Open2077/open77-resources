resource 'open77_freecam'
version '1.0.0'
open77_version '>=0.0.1'
auto_start false
reload_policy 'local'
client_scripts { 'config.lua', 'client/main.lua' }
server_script 'server/main.lua'
web_ui_page 'web/index.html'
web_ui_auto_create false
web_files { 'web/**' }
permissions { 'camera.script', 'players.read', 'players.controls', 'input.actions', 'local.events', 'network.events' }
