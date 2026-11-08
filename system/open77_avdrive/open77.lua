-- open77_avdrive -- the AV autopilot: whoever flies an AV presses one key
-- (F10) and the aircraft takes them to their map waypoint -- by default under
-- a fade to black, flown there at the pace the pilot's game keeps (1.2.0), or
-- flown there in view in three legs (`TRAVEL = 'fly'`) -- and hands the
-- controls back in a hover over the pin. The same key takes the controls back
-- at any moment.
--
-- Ported from XyberRP's opx_infinity `avdrive` module, where it ran on the
-- XyberRP servers; README.md says what it does and why it is built this way.
resource "open77_avdrive"
version "1.2.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

shared_script "shared/config.lua"
shared_script "shared/core.lua"
server_script "server/main.lua"
client_script "client/main.lua"

-- Least privilege, line by line.
permissions {
    -- Both halves: the toggle (client to server) and the notice (server to
    -- client). `source` is the only identity the server trusts.
    "network.events",

    -- Server: Open77.vehicles.get / getPlayerSeat / owner to prove who flies
    -- the hull (and, for the log, who simulates it), isEngineOn for the log,
    -- setFrozen for the ride, setTransform for every pose of a flight, and
    -- requestAuthority to hand the aircraft back to a pilot whose game did not
    -- take it (1.2.0).
    "world.vehicles",

    -- Client: Open77.input.registerKeyMapping for the one key.
    "input.actions",

    -- Client: Open77.blips.waypoint, the pilot's own map pin.
    "ui.vanilla.map",

    -- Client: Open77.hud.notify for what the autopilot answers.
    "ui.vanilla.hud",

    -- Client: Open77.session.locale, the language of those words.
    "session.locale",

    -- Client: Open77.screen.fadeOut / fadeIn -- the arrival happens behind a
    -- fade to black (1.1.0).
    "screen.effects",

    -- Client: Open77.world.groundZ / raycast -- the pilot's game measures the
    -- ground under the pin once the aircraft is over it (1.1.0).
    "world.query",

    -- Client: Open77.vehicles.get / getPlayerSeat -- where this game draws the
    -- aircraft and the body in it, for the arrival's log lines (1.1.0) and the
    -- pace of the flight under the black (1.2.0).
    "vehicles.read",

    -- Client: Open77.screen.loadingState and the open77:loadingScreen:* events
    -- -- whether the game's own loading screen is up, so the flight under the
    -- black holds for it (1.2.0). A client without the read says "unknown",
    -- never "no loading screen".
    "screen.read",
}
