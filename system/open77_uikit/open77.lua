resource "open77_uikit"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true

-- Replacing a live CEF surface while gameplay is running has historically
-- produced unstable transitions, so every resource that owns one declares
-- "reconnect" -- the same choice `open77_notifications`, `open77_interactions`
-- and `open77_admin` made. It matters more here than anywhere else: this
-- surface can hold KEYBOARD AND CURSOR FOCUS, and a surface swapped underneath
-- a focused dialog would leave the player with no input and nothing on screen.
-- A clean stop runs `onClientResourceStop`, which releases focus first.
reload_policy "reconnect"

client_script "client/main.lua"
server_script "server/main.lua"

-- ONE page for nine widgets. The per-resource surface budget is 8
-- (`kMaximumWebSurfaces`); spending one per widget would eat the whole budget
-- for a single resource and give every widget its own focus owner, which is
-- exactly the failure this kit is built to avoid. Routing is documented in
-- `client/main.lua` under "Message routing".
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
    -- Client + server: the server twins ask a client a question through
    -- `Open77.net.callClient` and the client half answers with
    -- `Open77.net.register`. Both ends of a callback need this and nothing
    -- more -- callbacks ride the ordinary net-event transport.
    "network.events",

    -- Client: a progress bar that disables movement and combat blocks through
    -- `Open77.input.setActionBlocked`, never by holding focus. Holding focus to
    -- stop the player moving takes the keyboard away from chat too, and a
    -- player who cannot act must still be able to say so.
    "input.actions",

    -- Client: `Open77.input.blockAll{ except = ... }`, for `disable = "all"`.
    -- A separate permission from `input.actions` on purpose -- it is a
    -- different blast radius and deserves its own line in a manifest audit.
    "input.blockAll",

    -- Client: the pause key (`open77:pauseKey`). The plugin SWALLOWS Escape in
    -- the window procedure, so a focused page's own Escape handler never fires
    -- in a live session. This event is the path that actually runs, and it is
    -- one of the ten release paths in the focus matrix.
    "local.events",

    -- Client: `Open77.players.getLifeState`. A player who dies with a dialog
    -- open must not come back to a respawn screen he cannot click through.
    "players.life.read",

    -- Client: `Open77.hud.setVisible("all", ...)` under `showCinematicBars`.
    -- The HUD hide is a per-owner loan the host releases with this resource,
    -- so a caller of the kit needs no HUD permission of its own -- the same
    -- presentation boundary as `input.actions` above. `drawText3D` needs
    -- nothing: `Open77.anchors` is ungated by design.
    "ui.vanilla.hud"
}
