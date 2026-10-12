resource "open77_sound"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true

-- The surface holds decoded audio and a live AudioContext. Replacing it in
-- place would cut every sound mid-sample, so a server generation change takes
-- the clean reconnect, exactly as open77_notifications does.
reload_policy "reconnect"

client_script "client/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
    -- The server twin (`Open77.sound.*` in the server prelude) reaches this
    -- resource over `open77:sound:*`, a prefix TriggerClientEvent reserves so
    -- only the prelude can emit it.
    "network.events",

    -- The supply line. A sound belongs to the resource that asked for it, and
    -- that resource ships the file; this surface is the only one in the session
    -- and lives under open77_sound's own root and allowlist. Without this
    -- permission there is no way to hand it another resource's clip, and the
    -- alternative is one CEF browser per resource that plays a sound.
    --
    -- It reads DECLARED files only -- the `files` manifest entry -- of a named
    -- resource, capped at 1 MiB. Scripts and undeclared assets are unreachable.
    -- See the note on LuaReadPackedFile in scripting/src/ResourceHost.cpp.
    "resources.files.read",
}
