resource "open77_voice"
version "0.3.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "reconnect"

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"

-- Voice topology is server-authoritative. The client capability exposes only
-- device/preferences, PTT intent and read-only talker state; ui.nameplates is
-- used for the native speaker indicator and input.actions for the reference
-- PTT polling loop.
permissions {
    "voice.manage", "voice.client", "ui.nameplates", "input.actions",
    "network.events"
}
