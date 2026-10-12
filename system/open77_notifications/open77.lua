resource "open77_notifications"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true

-- The surface is never replaced in-place. A server generation change uses a
-- clean reconnect, matching the other shared CEF services.
reload_policy "reconnect"

client_script "client/main.lua"
server_script "server/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permission "network.events"
