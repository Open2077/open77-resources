resource "open77_freeroam"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

server_script "server/persistence.lua"

-- database.access injects the MySQL bridge; players.disconnect powers kick/ban.
permissions { "database.access", "players.disconnect" }
