resource "open77_nameplates"
version "0.2.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

-- TWO CLIENT SCRIPTS, IN THIS ORDER, EACH LISTED EXPLICITLY.
--
--   main.lua    lifecycle: turn the native drawer on, or fall back to the page.
--               Owns nothing about WHO is labelled.
--   policy.lua  who gets a plate and what it says. Independent of main.lua --
--               it shares no state with it and touches only
--               `Open77.nameplates.set/remove`, never `clear()`, because
--               `clear` is `Api::Nameplates::Release` and would switch off the
--               native drawer main.lua just enabled.
--
-- `client/**/*.lua` would match NOTHING here (`**` requires an intermediate
-- directory) and the client then refuses the WHOLE session resource set with
-- `script_pattern_empty` -- nobody connects. Never glob a script entry.
client_script "client/main.lua"
client_script "client/policy.lua"

-- The operator's switch. Declares the policy tunables and pushes them to each
-- client; a host without tunable support degrades to the declared defaults.
server_script "server/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
    "ui.nameplates",

    -- policy.lua listens for the gamemode state pushes it uses to learn who is
    -- on your side (`cordon:state`, `deathmatch:state`) and asks the server
    -- half for the policy; server/main.lua answers and broadcasts retunes.
    -- Without this `RegisterNetEvent` returns permission_denied:network.events.
    "network.events",

    -- `Open77.players.allHealthStates()` on the CLIENT, gated by CanReadLife in
    -- scripting/src/ResourceHost.cpp. It is read-only there by construction --
    -- damage, heals and god mode are server Lua -- and it reads a ledger this
    -- client was already sent: SessionManager seeds a joining player with every
    -- other player's PlayerHealthState and ServerApplication broadcasts every
    -- change to the whole bucket. This permission grants no new information; it
    -- grants Lua access to information the client already holds.
    "players.life.read",
}
