resource "open77_deathmatch_hud"
version "0.2.0"
open77_version ">=0.0.1"
auto_start true

-- The HUD stays a separate resource from the gamemode and stays on
-- "reconnect": editing CSS or a string must never reset a live match.
reload_policy "reconnect"

dependency "open77_deathmatch >=0.1.0"

-- Scripts are listed explicitly, one per line. `client/**/*.lua` requires an
-- intermediate directory and therefore matches NOTHING against a flat
-- client/ folder -- and an empty glob refuses the whole session resource set
-- with script_pattern_empty, so no player can connect.
shared_script "shared/strings.lua"
client_script "client/combat.lua"
client_script "client/match.lua"
client_script "client/main.lua"

-- Two surfaces, split by update rate; both are created by client/main.lua.
web_ui_page "web/match.html"
web_ui_auto_create false
web_files { "web/**" }

-- network.events        the gamemode state push, notices, kill feed, callouts
-- players.life.read     Open77.players.getHealthState -- the client mirror of
--                       the SERVER health ledger, for health and armor
-- player.weapons.read   Open77.weapons.snapshot -- magazine, capacity, reserve
permissions {
    "network.events",
    "players.life.read",
    "player.weapons.read"
}
