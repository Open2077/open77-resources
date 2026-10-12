resource "open77_debug"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
server_script "server/main.lua"
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
files { "assets/blips/*.png" }
permissions {
    "webui.system", "network.client", "network.events", "world.doors",
    "ui.vanilla.map", "ui.vanilla.hud", "ui.nameplates", "voice.client", "debug.runtime",
    -- Privileged local diagnostics: verify resource perspective locks and F7.
    "perspective.policy",

    -- Body family, and it is a DIAGNOSTIC need rather than a gameplay one.
    --
    -- Open77 enters the world on a bundled pristine save, and which one decides
    -- what quest state the session has: `NCMP-Template-F` has never started
    -- Phantom Liberty, `NCMP-Template-M` has it completed (`ep1_active=1`,
    -- `q301_done=1`). That difference is the only clean A/B available for the
    -- Dogtown collision holes, and it is what let the 2026-09-02 test run:
    -- the gate opens only on the progressed save, and crossing it hangs the
    -- game thread in JobDispatcher::FlushCounter until RED4ext's watchdog
    -- fires. `Open77.appearance.switchBodyFamily` is the one supported runtime
    -- transition, and it refused this laboratory with
    -- `permission_denied:player.appearance.edit`.
    --
    -- This resource is already the privileged laboratory: it holds
    -- `debug.runtime`, which is arbitrary code evaluation, and its host-side
    -- capability switch is gated on the exact resource name so a downloaded
    -- resource can never acquire it. Adding an appearance grant next to that
    -- widens nothing a caller did not already have.
    "player.appearance.edit", "player.appearance.read",
    -- Compare client canonical life/health with native char.state during a
    -- diagnostic. Without this explicit read grant, these APIs return nil
    -- even when the client has received the state.
    "players.life.read",
    -- Read-only terrain/clearance queries for in-world map survey validation.
    "world.query"
}
