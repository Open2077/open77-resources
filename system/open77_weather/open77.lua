resource "open77_weather"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

-- Shared files are executed in this order on both sides. They contain only
-- immutable configuration and pure clock helpers: authority stays server-side.
shared_scripts {
    "shared/config.lua",
    "shared/clock.lua",
}

server_script "server/main.lua"
client_script "client/main.lua"

permissions { "network.events", "world.environment" }
