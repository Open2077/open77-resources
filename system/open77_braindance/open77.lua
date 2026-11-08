-- open77_braindance -- the braindance launch (the game's white-out flash, the
-- dive to black, the BD overlay) as a scriptable sequence with events, for
-- braindance scenes and for any transition that needs a black screen to hide
-- a teleport, a bucket swap or a set change; and the braindance editor's
-- VISUAL / THERMAL / AUDIO layers (heatmap) on the live world.
-- Author guide: wiki/braindance.md.
--
-- Opt-in, `auto_start false`: add it to the server's `resources.load`, then
-- `ensure open77_braindance`. Other resources call its exports.
resource "open77_braindance"
version "1.1.0"
open77_version ">=0.0.1"
auto_start false

shared_script "shared/sequence.lua"
server_script "server/main.lua"
server_script "server/vision.lua"
client_script "client/main.lua"
-- The braindance editor's VISUAL / THERMAL / AUDIO layers on the live world.
client_script "client/vision.lua"

permissions {
    -- Both halves: start / resume / exit / cancel to a client, phase reports from it.
    "network.events",
    -- Client: Open77.vfx.playEntity for the authored player effects, Open77.sfx.play2d for phase sounds,
    -- Open77.braindance.setHeatmap / setHeat for the thermal and audio layers.
    "world.effects",
    -- Client: Open77.screen.fadeOut / fadeIn / cancel -- the native fade to black.
    "screen.effects",
    -- Client: Open77.input.setActionBlocked("Movement") while the screen is changing.
    "input.actions",
    -- Client: Open77.hud.setVisible("all") while the screen is changing.
    "ui.vanilla.hud",
    -- Client: Open77.screen.loadingState -- stay black while a far teleport loads.
    "screen.read",
    -- Client: Open77.perspective.setThirdPerson(false, true) -- first person while in a braindance.
    "perspective.policy",
    -- Server: Open77.players.teleport for options.teleport / exitTeleport.
    "players.teleport",
}
