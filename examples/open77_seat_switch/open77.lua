resource 'open77_seat_switch'
version '1.0.0'
auto_start false
reload_policy 'local'
client_script 'client.lua'
server_script 'server.lua'
permissions { 'world.vehicles', 'vehicles.read', 'vehicles.control', 'network.events' }
