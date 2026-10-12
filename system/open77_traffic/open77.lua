resource "open77_traffic"
version "0.2.0"
-- Server-owned population policy, plus one operator panel in front of it.
--
-- The span catalog, the population catalog and the controller itself
-- stay server-side: they never enter the signed client package. What the
-- client receives is three small Lua files that hold no settings and can change
-- nothing on their own: the panel owns a WebUI surface whose every control is
-- routed back through the restricted `traffic` command on the same
-- `open77:command:execute` path the chat box uses, the hit forwarder hands
-- the server the engine's own reports of this player's hits on NPCs, which the
-- server validates before any ambient driver takes damage, and the
-- `/traffic.esp` overlay only reads replicated cars.
auto_start true

-- Replacing a live CEF surface while the game is running has historically
-- caused unstable transitions, so every resource that owns one declares
-- "reconnect" (same rule as /admin and the cyberware lab).
reload_policy "reconnect"

-- The generator settings are declared here and read by both halves: the server
-- half declares them as tunables, and the client half builds the panel's
-- controls from these declarations, receiving only the values in a snapshot.
shared_scripts {
    "shared/config.lua",
}

server_scripts {
    "server/population-data.lua",
    "server/spans-generated.lua",
    "server.lua",
}

client_scripts {
    "client/panel.lua",
    "client/driver-hits.lua",
    "client/esp.lua",
}

-- The panel. `web_ui_auto_create false` because the surface is created lazily
-- on the first `/traffic`; a page nobody opened must not cost a CEF surface.
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions { "world.vehicles", "world.npcs", "world.query", "players.life.read", "player.weapons.read",
    -- Both halves: the panel's event channel to the client, the
    -- `open77:command:execute` transport on the way back, and the forwarded
    -- driver hit reports.
    "network.events", "network.client",
    -- Client: `open77:pauseKey`, so Escape closes the panel with everything
    -- else rather than leaving a focused surface holding the mouse.
    "local.events",
    -- Client: `/traffic.esp` reads replicated cars with `Open77.vehicles.nearby/all`.
    "vehicles.read" }
