-- =============================================================================
-- open77_avdrive -- shared/config.lua
-- =============================================================================
-- The AV autopilot: where it flies, how fast, and the one key that starts it.
-- This file is downloaded by clients, so it holds no secret. Edit it and
-- `ensure open77_avdrive`.
--
-- WHAT THIS IS. Whoever flies an AV presses one key and the aircraft takes
-- them to their own map waypoint; the same key hands the controls back at any
-- moment. It is the Delamain-ride shape of the base game -- a vehicle that
-- carries you to the pin you dropped -- rebuilt for aircraft: it ends in a
-- hover over the pin instead of at a kerb, and the pilot lands.
--
-- WHOEVER FLIES IT (1.1.0). The Open77 client flies an AV from whichever seat
-- its crew boarded through, so the key belongs to whoever flies it: the one in
-- the pilot seat, else the one whose game simulates the aircraft, else the
-- only one aboard. A passenger behind somebody who flies is refused by name.
--
-- WHY IT IS A RESOURCE AND NOT THE ENGINE'S. `Open77.vehicles.ai` is the
-- platform's native auto-drive and it drives ground cars through traffic tasks
-- -- AVs are explicitly unsupported by it, and a `driveTo` route is snapped to
-- road lanes anyway. The honest primitive for an aircraft is
-- `Open77.vehicles.setTransform` per tick, server-authoritative, which revokes
-- the physics lease and republishes the canonical pose to every viewer.
--
-- HOW IT GETS THERE (1.1.0): `TRAVEL`, below. By default it ARRIVES: the
-- screens of everybody aboard fade to black, the aircraft is flown to the pin
-- under the black (1.2.0) at the pace the pilot's game keeps, the pilot's game
-- measures the ground there, the controls come back and so do the screens. `TRAVEL = 'fly'` flies it
-- there in three legs instead -- climb, cruise, descend -- with the aircraft
-- FROZEN for the whole flight: a seated pilot's client claims an AV and
-- reports its own poses, and a frozen hull has those reports discarded, so the
-- flight the server publishes is the only flight there is. Every one of its
-- poses makes the pilot's view flicker (`TRAVEL` says why).
--
-- Ported from the XyberRP servers (opx_infinity `config/avdrive.lua`).
-- =============================================================================

Open77AvDriveConfig = {
    -- THE ONE KEY. `ID` is what a player's rebind is stored under and must not
    -- change between versions; `DEFAULT` is the key it comes up on (Pause ->
    -- Settings -> Key bindings rebinds it), or `false` for no key at all.
    KEY = { ID = 'open77_avdrive_toggle', DEFAULT = 'F10' },

    -- WHICH RECORDS THE AUTOPILOT FLIES: the ones the Open77 client flies as
    -- AVs (`VehicleFlight::IsAvRecord`: `Vehicle.av_*` and
    -- `Vehicle.max_tac_av`), lower-cased Lua patterns. The run ends in a HOVER
    -- handed to the pilot, so it is only for aircraft a pilot can fly on from
    -- there: a record the client does not fly would fall out of the hover.
    RECORDS = { '^vehicle%.av_', '^vehicle%.max_tac_av$' },

    -- HOW IT GETS THERE (1.1.0): 'arrive' (the default) or 'fly'.
    --
    -- 'arrive': the screens of everybody aboard fade to black, the aircraft is
    -- flown to `HOVER_HEIGHT` over the pin under the black (1.2.0: fast, in
    -- small steps, at the pace the pilot's game keeps -- `ARRIVE`), the pilot's
    -- game measures the ground there once the world has streamed in (the
    -- hover is RAISED over a roof if it has to be, never lowered), the freeze
    -- comes off, and the screens come back. Nobody aboard sees a move.
    --
    -- 'fly': the three legs below, posed by the server every `TICK_MS`. EVERY
    -- pose takes the flight from the pilot's game -- `setTransform` revokes the
    -- physics lease, and the platform counts every occupant of an AV as its
    -- controller, so that game claims it straight back -- and its chase camera
    -- lets go and first person comes back each time: the pilot's view flickers
    -- between the two for the whole flight. Measured on open77_avdoor's pad
    -- snap, which flew an occupied AV the same way: 129 poses in 9.8 s, the
    -- hull changing hands 252 times in 10 s, the pilot's chase camera let go
    -- 116 times (Staging, 2026-10-30). No platform call moves an AV without
    -- that, and a resource cannot hold the view of a player in a vehicle.
    TRAVEL = 'arrive',

    -- THE ARRIVAL (`TRAVEL = 'arrive'`): milliseconds, metres and metres per
    -- second.
    --
    -- WHY IT IS FLOWN UNDER THE BLACK AND NOT PLACED (1.2.0). 1.1.0 placed the
    -- aircraft over the pin in one move. On Staging (2026-10-30) that was a
    -- 1 080 m move of an aircraft with its pilot in it, and the pilot's game
    -- drew it over the pin -- then never took it back: "stuck on a loadscreen
    -- forever". The platform's own teleport refuses a player in a vehicle for
    -- this reason (it cannot carry the car along), and a game that is not
    -- ready may not take its aircraft back. So the aircraft is FLOWN there,
    -- fast and in steps of a few metres, the way the game sees aircraft move,
    -- and the pilot's game says four times a second where it has the aircraft
    -- and whether a loading screen is up. The flight HOLDS while that game is
    -- behind or loading, and is given up -- the aircraft put where that game
    -- has it, the controls and the screens back -- when it does not follow.
    ARRIVE = {
        -- How long the screens take to go black.
        FADE_OUT_MS = 600,
        -- The longest the server waits for the pilot's game to say its screen
        -- is black; past it, the flight begins all the same (and the log says
        -- so).
        FADE_WAIT_MS = 2000,
        -- The flight under the black: across at `SPEED`, up and down at
        -- `CLIMB_SPEED`, `CRUISE_ABOVE` over the higher of where it starts and
        -- the pin. A long way is flown faster, so the black never lasts more
        -- than `MAX_FLIGHT_MS` of flying (holds come on top).
        SPEED = 150.0,
        CLIMB_SPEED = 60.0,
        CRUISE_ABOVE = 60.0,
        MAX_FLIGHT_MS = 30000,
        -- How often the pilot's game says where it has the aircraft, and how
        -- long without a word before the flight holds for it.
        PACE_MS = 250,
        PACE_STALE_MS = 1500,
        -- The flight holds while the pilot's body is farther than this behind
        -- the aircraft the server flies. Its game sees the flight a quarter of
        -- a second late or so -- under 100 m at 150 m/s -- so this is a game
        -- that is NOT following, not one that is merely late.
        LEASH_METRES = 200.0,
        -- How long the flight holds before it is given up: for a game that is
        -- behind, or never said a word ...
        STALL_MS = 8000,
        -- ... and for one that is loading, or went silent after it had been
        -- talking (what a game in a loading screen looks like from here).
        LOADING_WAIT_MS = 30000,
        -- Once the aircraft is over the pin, how long the pilot's game lets
        -- the world there stream in before it looks for the ground ...
        SETTLE_MS = 1200,
        -- ... and the longest it looks: a ray straight down every 250 ms until
        -- two agree. With no answer, the hover stays `HOVER_HEIGHT` over the
        -- pin's own height.
        MEASURE_MS = 6000,
        -- The freeze off, then this long before the screens come back: the
        -- pilot's game has the aircraft -- and its chase camera -- back by then.
        HAND_BACK_MS = 400,
        -- How long the screens take to come back.
        FADE_IN_MS = 800,
        -- Once the image is back, how long the pilot's game watches for the
        -- controls -- its game simulating the aircraft again -- before it says
        -- it did not get them; the server then asks the platform to hand the
        -- aircraft to the pilot (`Open77.vehicles.requestAuthority`), and says
        -- so in its log.
        OWN_WAIT_MS = 5000,
    },

    -- How long one press may follow another, in milliseconds. The key is a
    -- toggle, and a key mashed five times a second would be five engage and
    -- cancel pairs a second, each a freeze flip. 0 for no window at all.
    COOLDOWN_MS = 400,

    -- ── the flight (`TRAVEL = 'fly'`), in metres and metres per second ─────

    -- How high the cruise leg flies, ABOVE THE HIGHER of the take-off point and
    -- the destination. Measuring from the higher end is what keeps a cruise leg
    -- between two low points from being under the hill between them; a server
    -- with real mountains under the route raises this number.
    CRUISE_ALTITUDE = 120.0,

    -- The cruise leg's speed. 22 m/s is the platform's own flight model's
    -- cruise ceiling: an autopilot that outran the manual flight would be an
    -- aircraft that leaves its pilot behind when they take over.
    CRUISE_SPEED = 22.0,

    -- Up and down, at the platform's own flight model rates: 5 m/s climb and
    -- 3.5 m/s descent, the same ceilings a manual pilot has.
    CLIMB_SPEED = 5.0,
    DESCEND_SPEED = 3.5,

    -- How far above the destination the run ENDS and the pilot gets the
    -- controls back. A hover, not a landing: the ground under a map pin is not
    -- something the server can see, and setting an airframe down on a height it
    -- cannot measure is how a hull ends up inside a roof. The pilot lands.
    -- (Arriving, 1.1.0, the pilot's game measures the ground under the pin --
    -- the first roof or terrain straight down -- and the hover is raised to
    -- this far over it when the pin's own height is lower.)
    HOVER_HEIGHT = 8.0,

    -- ── the run itself ──────────────────────────────────────────────────────

    -- How often the hull is posed. Each pose is a `setTransform`, and the
    -- pilot's own screen shows each one as a step: measured in game on
    -- 2026-10-24 at 100 ms, the hull moved ten times a second, up to 1 m a
    -- step in the climb and 4 m at cruise speed (manual flight, posed by the
    -- pilot's client every frame, has no such steps). A shorter cadence makes
    -- smaller steps for more packets; the platform has no server-driven motion
    -- that viewers interpolate. XyberRP ran 100 ms.
    TICK_MS = 100,

    -- The farthest a waypoint may be, flat. Past this the request is refused BY
    -- NAME rather than accepted into a half-hour flight.
    MAX_RANGE = 4000.0,

    -- The longest one flight may take, in minutes. A run never outlives this.
    MAX_MINUTES = 20.0,
}
