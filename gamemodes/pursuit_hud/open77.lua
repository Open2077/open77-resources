resource "pursuit_hud"
version "0.1.0"
open77_version ">=0.0.1"
-- TRUE, and the history is a production regression. The 2026-08-27 voice-chat
-- merge set `pursuit` AND this manifest to false for its local testing;
-- dc93bd2 (2026-08-28) re-enabled `pursuit` and missed this file, and that
-- day's release shipped the pair split: the server's StartAutomatic() honours
-- the MANIFEST flag for every resource on the config's load list, so prod
-- logged "pursuit_hud discovered" with no "started" and every 1v1 played with
-- no HUD (owner report; match 424875, 17:48 UTC). `pursuit` and `pursuit_hud`
-- are one gamemode in two manifests -- enable and disable them TOGETHER.
auto_start true

-- Its own resource, and this is the reason.
--
-- Swapping a live CEF surface while gameplay runs has historically been
-- unstable, so a WebUI resource must declare "reconnect". The rules engine
-- (`pursuit`) must stay "local" so a tuning change reloads in seconds without
-- ending live matches. One manifest can only declare one policy, so the HUD
-- cannot live inside the gamemode.
reload_policy "reconnect"

client_script "client/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

-- Presentation only. It receives state and draws it; it decides nothing and
-- therefore needs no gameplay capability.
permissions {
    "network.events"
}
