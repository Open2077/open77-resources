resource "open77_pause"
version "0.5.1"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

-- The string table first: it declares the global `PauseStrings` that
-- client/main.lua reads and forwards to the page. Shared scripts are
-- prepended to the client list by the resource host, so the order is not a
-- convention here, it is the load order.
shared_script "shared/strings.lua"
client_script "client/main.lua"
files { "assets/**" }
-- Temporary CEF presentation while the native INK menu is investigated.
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
-- network.client is read-only here in practice: the pause menu polls the
-- session snapshot for its info card and calls disconnect() for Quit Session.
permissions {
    "webui.system", "network.client", "network.events",
    "voice.client", "input.actions", "map.read", "map.control"
}
