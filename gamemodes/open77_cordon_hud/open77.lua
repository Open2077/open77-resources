resource "open77_cordon_hud"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- The HUD is a separate resource from the gamemode and stays on "reconnect".
--
-- It is not a style choice: this resource owns four WebUI surfaces, and a
-- WebUI page cannot be re-created under a live session without the client
-- transitioning. Editing a string, a stylesheet or the tac-map's drawing code
-- must never be able to reset a match in progress, so the policy that forces a
-- clean reconnect is the correct one -- exactly as open77_deathmatch_hud found.
reload_policy "reconnect"

-- The gamemode is the only thing that talks to this resource. Declared without
-- a version constraint on purpose: the two ship together from one branch, and
-- pinning a version here would refuse the HUD every time the mode's version
-- moves first.
-- The version constraint is NOT optional. `dependency "open77_cordon"` with no
-- constraint made the resource host throw an unhandled NullReferenceException
-- and stop this resource with reason=runtime_error, so the HUD never reached
-- any client and the player saw a bare world with no interface at all. Every
-- shipped resource carries one; measured 2026-09-02.
dependency "open77_cordon >=0.1.0"

-- SCRIPTS ARE LISTED EXPLICITLY, ONE PER LINE, AND MUST STAY THAT WAY.
--
-- `client/**/*.lua` requires at least one intermediate directory, so it matches
-- NOTHING against a flat client/ folder. An empty glob does not merely skip a
-- file: it refuses the whole session resource set with
-- `script_pattern_empty:client/**/*.lua`, and no player can connect. `**` is
-- only safe under `files` / `web_files`, where the nesting genuinely exists.
--
-- Load order is the dependency order of the globals: strings first, then the
-- three surface modules, then main.lua which creates the pages and wires them.
shared_script "shared/strings.lua"
client_script "client/inventory.lua"
client_script "client/combat.lua"
client_script "client/match.lua"
client_script "client/tacmap.lua"
-- THE PROJECTED CORDON BOUNDARY. Fed by `cordon:edge:wall`, a LOCAL client
-- event raised by open77_cordon/client/edge.lua -- so it needs no permission of
-- its own: `Open77.camera.view` and `Open77.camera.project` are ungated
-- (docs/lua-resources.md lists Open77.camera with permission "None", which is
-- also why open77_groundcircle declares none at all), and this file talks to
-- nothing else.
--
-- Listed before main.lua with the other three, because main.lua calls
-- `CordonWall.attach` and the global has to exist by then.
client_script "client/wall.lua"
client_script "client/main.lua"

-- Four surfaces, all created explicitly by client/main.lua so their fps,
-- z-order and focus policy are stated in one place. The manifest page is
-- declared only because a resource that owns WebUI must name an entry; nothing
-- auto-creates -- `web/combat.html`, `web/tacmap.html` and `web/wall.html` are
-- reachable because `web_files` covers them, not because they are named here.
web_ui_page "web/match.html"
web_ui_auto_create false
web_files { "web/**" }

-- PERMISSIONS -- deliberately the smallest set that makes the HUD work.
--
--   network.events   the one state push (`cordon:state`), the notices, and the
--                    three client actions the player can take (join the next
--                    match, drop pin, ping). Everything a player reads on this
--                    HUD arrives through it, shaped on the server.
--   input.actions    RegisterKeyMapping. `docs/research/keymapping-api.md`
--                    states the gate plainly: "Every entry point requires the
--                    `input.actions` permission". Without it the tac-map has no
--                    key and the join toggle has no key -- both silently, since
--                    the call just returns `false, reason`. client/tacmap.lua
--                    logs that reason and falls back to the local events
--                    `cordon:tacmap:toggle` / `cordon:queue:toggle`, so a
--                    deployment that strips this permission degrades to a HUD
--                    the gamemode's own client can still drive.
--
-- What is NOT here, and why it matters to read the code correctly:
--   players.life.read   -- so health and armor are NOT sampled from the client
--                          mirror of the server ledger the way the deathmatch
--                          HUD does. They come from `self` in the state push.
--   player.weapons.read samples the active slot, magazine and reserve locally.
permissions {
    "network.events",
    "input.actions",
    "player.weapons.read",
    "ui.vanilla.hud"
}
