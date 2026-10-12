resource 'open77_pointing'
version '0.1.0'
open77_version '>=0.0.1'
auto_start false
reload_policy 'local'
dependency 'open77_animations >=1.0.0'
client_script 'client.lua'
server_script 'server.lua'
permissions { 'network.events', 'input.actions' }
