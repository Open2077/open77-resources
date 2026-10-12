resource "open77_props"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
-- persistence.lua first: it publishes the `PropsPersistence` global that
-- main.lua's command handlers call at every mutation point. Load order is
-- manifest order.
server_script "server/persistence.lua"
server_script "server/main.lua"

permissions {
    "network.events",
    "world.props",

    -- Optional persistence (the `persist` tunable, OFF by default). Declaring
    -- this on a server with no database is safe: the permission grants access
    -- to the binding, it does not require the bridge to be enabled, and the
    -- schema probe in server/persistence.lua degrades to a single logged line.
    "database.access",
}
