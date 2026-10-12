resource "open-voice"
version "0.2.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "reconnect"

dependency "open77_voice >=0.2.0"

server_scripts {
    "server/config.lua",
    "server/main.lua",
}
client_script "client/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

-- open77_voice remains the sole PTT/VAD/audio driver. This companion owns
-- only server-authoritative reach presets, its F11 request edge, and HUD.
permissions { "voice.manage", "voice.client", "input.actions", "network.events" }
