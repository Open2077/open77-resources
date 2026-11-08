resource "open77_chimera"
version "1.0.0"
auto_start true
server_script "server.lua"
client_script "client.lua"
permissions { "world.npcs", "npcs.read", "world.query", "players.life.read", "players.damage.apply", "network.events" }
