-- Public configuration for Pursuit.
--
-- This file is downloaded by clients, so it must never carry secrets or ACL
-- data. Every tuning number lives here: the mode is a config file with code
-- attached, not code with constants buried in it.
--
-- SOME OF THESE NUMBERS ARE ALSO OPERATOR TUNABLES. The `tunables` block at
-- the BOTTOM of this file declares which ones a server owner may move from
-- Warden's Tuning tab, and for every key it names the declared default
-- SUPERSEDES the figure written here -- see the three notes above that block.
-- Changing a number that appears in both places means changing it in both.
--
-- Coordinates were captured in-game on build 2.31 with the debug bridge
-- `position` command. The lobby centre is PROVISIONAL: it sits on the open
-- terrace at the north edge of Corpo Plaza, City Center, and is expected to
-- move once the 60 m ring is visible on the ground and can be judged properly.

-- Build a STARTING-GRID spawn pair from one road anchor (owner request,
-- 2026-08-28: "place both cars in a better position, middle of the road (same
-- distance), or a nice starting spot where both cars are well placed").
--
-- Everything is DERIVED from the anchor so the symmetry survives every later
-- change of car or gap: both cars sit ON the surveyed centreline, facing the
-- road's own heading, `gapMetres` apart and equidistant from the anchor --
-- runner in front, cop behind, a chase already formed. Each player stands
-- `doorClearMetres` off his car's LEFT flank (the only driver door,
-- wiki/vehicles.md), facing it, so the first thing he sees is his own door --
-- the geometry the driver-side assertion in server/vehicles.lua checks.
--
-- The convention is the measured one from `match.spawns`: yaw y faces
-- (-sin y, cos y), right is (cos y, sin y); the player-facing algebra
-- (playerYaw = heading - 90) is the same identity read backwards.
--
-- z values are NOT derived -- they are the survey, passed in per station.
local function pursuitGridPair(spec)
    local radians = math.rad(spec.heading)
    local fx, fy = -math.sin(radians), math.cos(radians)
    local rx, ry = math.cos(radians), math.sin(radians)
    local door = spec.doorClearMetres or 2.8
    local function station(along, s)
        local carX = spec.anchor.x + fx * along
        local carY = spec.anchor.y + fy * along
        return {
            -- The PLAYER mark, on the car's driver (left) flank.
            position = { x = carX - rx * door, y = carY - ry * door, z = s.markZ },
            heading = spec.heading,
            -- Face the car, not the road: the door is the first decision.
            playerYaw = spec.heading - 90.0,
            vehicleOffset = { forward = 0.0, lateral = door },
            vehicleYaw = spec.heading,
            vehicleRestZ = s.restZ,
        }
    end
    return {
        name = spec.name,
        runner = station(spec.gapMetres / 2.0, spec.runner),
        cop = station(-spec.gapMetres / 2.0, spec.cop),
    }
end

PursuitConfig = {
    lobby = {
        -- Network dimension every lobby player sits in. Matches get their own.
        bucket = 1000,

        -- Captured 2026-08-25: Corpo Plaza terrace, City Center.
        -- z is the measured ground here (the player stands at 14.78), not the
        -- 19.35 first sampled from a raised terrace. Markers are drawn at the
        -- transform they are given and are NOT snapped to the ground, so a z
        -- that is metres off leaves the ring floating or buried.
        center = { x = -1460.2, y = 99.9, z = 14.8 },
        heading = 175.0,

        -- Players outside this radius are warned, then returned.
        -- 50, not 60, so the DRAWN ring is the line that is actually enforced.
        -- Both ring backends (Open77.markers and open77_groundcircle) clamp a
        -- radius to 50 m, so a 60 m leash drew its boundary 10 m inside itself:
        -- a player standing on the visible edge was still 10 m from being
        -- warned, and a player warned saw no reason for it. A boundary the
        -- player can see and the server enforces must be the same boundary.
        radius = 50.0,
        leashWarnSeconds = 4.0,
        leashReturnSeconds = 10.0,

        -- Draw the boundary as a visible ring on the ground?
        --
        -- FALSE since 2026-08-26, at the owner's request after playtesting:
        -- "laisse la limitation je veux dire mais on doit plus voir le contour,
        -- pas besoin, ça te prévient juste que tu sors du lobby". The ring was
        -- clutter; the warning already does the teaching.
        --
        -- THIS FLAG IS PRESENTATION ONLY. The leash is server-side and reads
        -- `radius`, `leashWarnSeconds` and `leashReturnSeconds` directly
        -- (server/main.lua, the leash tick): it neither knows nor cares whether
        -- anything is drawn. Setting this false hides a ring and changes no
        -- rule -- players are still warned at 4 s outside and returned at 10 s.
        --
        -- It does NOT touch the ready-up circle, which is a different marker
        -- built from a different definition and is how a player knows where to
        -- queue. That one always draws.
        --
        -- Kept as a flag rather than deleted because the drawing path behind it
        -- is hard-won: it is the native world-anchor path with occlusion and
        -- ground-following, fixed on 2026-08-26 after a long investigation.
        -- Flip this to true to get the ring back and to exercise that path.
        drawBoundary = false,

        -- How long after a placement the leash stops judging a player. Covers
        -- the fade, the streaming preload and the puppet attaching; below this
        -- the act of placing someone in the lobby trips the leash that sent
        -- them there.
        placementGraceMs = 15000,

        -- The join placement's own retry, used when the readiness gate opens a
        -- moment before the life authority has a record to act on.
        --
        -- This is a RETRY CADENCE, not a budget for the player: by the time it runs
        -- the platform has already confirmed the player is incarnated, so the wait
        -- being measured is the server's own bookkeeping catching up, not anything a
        -- human is doing. The timeout is there so a player the life authority never
        -- sees at all produces one log line naming the fact instead of a timer that
        -- runs until the server is restarted.
        placementRetryMs = 250,
        placementRetryTimeoutMs = 30000,

        -- The ready-up circle, offset from the lobby centre so players spawn
        -- beside it rather than inside it.
        readyUp = {
            id = "ready_up",
            offset = { x = 6.0, y = 0.0, z = 0.0 },
            radius = 2.0,
            style = "objective",
            label = "Queue for 1v1",
            description = "Wait here for an opponent.",
            key = "E",
            holdSeconds = 1.0,
            color = "#00E5FF",
            maxDistance = 90.0,
        },

        -- The vehicle station, PLACED rather than derived -- and this is the
        -- exception the derivation always allowed for.
        --
        -- client/main.lua puts the station on the same circle as the ready-up
        -- ring, one 60 degree arc step around the lobby centre. That is elegant
        -- and it was wrong HERE: the arc lands at (-1457.2, 105.1), which on
        -- this terrace is the kerb where the raised plaza ends. The ring is
        -- drawn by `open77_groundcircle`, which follows the true ground per
        -- vertex, so half of it climbed the step and the rest disappeared into
        -- the wall behind it -- the owner's screenshot of 2026-08-27, and
        -- reproduced in-game on the production server the same day. An arc step
        -- knows the distance to its neighbour; it knows nothing about what is
        -- standing there.
        --
        -- WHAT WAS MEASURED, on production, walking the ground and reading the
        -- debug bridge's `position` at each stop (2026-08-27):
        --
        --   lobby centre  (-1460.2,  99.9)   ground 14.77  -- the lower slab
        --   ready-up ring (-1454.2,  99.9)   ground 15.36  -- the raised plaza
        --   HERE          (-1454.2,  93.9)   ground 15.36
        --   and its four ring extremities at +-1.6 m, all four   ground 15.36
        --
        -- Identical to three decimals across the whole patch, and identical to
        -- the ready-up circle's own ground: the two stations now stand on one
        -- continuous slab with no relief between them, which is exactly what
        -- the drawn ring needs and what the arc could not promise.
        --
        -- The offset keeps the pair 6.0 m apart -- the same separation the
        -- derivation solved for, and well clear of MIN_VEHICLE_SEPARATION, so
        -- the dead band between the two prompts is unchanged. Direction is the
        -- owner's: standing on the spawn point facing the queue circle, this is
        -- immediately to its RIGHT, not behind it, so walking to one never
        -- crosses the other's activation.
        --
        -- `z` stays 0.0, i.e. the authored 14.8, deliberately: the ready-up
        -- circle does the same and the ~0.55 m the authored centre sits below
        -- the collision surface is absorbed by the ground-following ring, the
        -- floating prompt card and the zone's 6 m vertical tolerance. Matching
        -- the ready-up circle keeps that a measured property of this lobby
        -- rather than a fresh assumption -- see the note above
        -- `vehiclePickerPosition` in client/main.lua.
        --
        -- MOVING THE LOBBY INVALIDATES THIS NUMBER. It is a surveyed spot on
        -- one terrace, not a rule. If `center` changes, either survey again or
        -- delete this block and let the arc derivation take over.
        vehiclePicker = {
            offset = { x = 6.0, y = -6.0, z = 0.0 },
        },
    },

    -- Weather/time pin this gamemode WANTS. `open77_weather` is a shared
    -- platform resource whose own defaults are noon / sunny / random (see
    -- resources/system/open77_weather/shared/config.lua) -- correct for a generic
    -- server, wrong for a competitive 1v1 where visibility IS the mechanic:
    -- one match in fog and the next in clear noon sun are materially
    -- different games.
    --
    -- NOT AUTO-APPLIED. There is currently no delivery path from this
    -- resource's server VM to open77_weather's: the server Lua runtime gives
    -- every resource its own VM, `TriggerEvent` only walks that VM's own
    -- handler table (server/src/Open77.Server.Scripting/Runtime/
    -- LuaResourceRuntime.cs: `for _, entry in pairs(handlers)` is a local,
    -- per-VM table), there are no exports and no cross-resource event bus
    -- (docs/writing-a-gamemode.md #1 says so directly), and
    -- server/server.pursuit.jsonc's schema has no per-resource config
    -- override (server/config/server.schema.json: every object sets
    -- `"additionalProperties": false`, and `resources` only has
    -- enabled/root/autoStart/watchIntervalMilliseconds/download). An earlier
    -- attempt fired this through `TriggerEvent` anyway on the mistaken belief
    -- that it fans out host-wide the way it does on the CLIENT
    -- (scripting/src/ResourceHost.cpp) -- it does not on the server, so
    -- nothing happened and the lobby still opened at noon/sunny in-game.
    --
    -- Until the platform grows one of: a per-resource config override, a
    -- server-config startup-command list, or a real cross-resource Lua API,
    -- an operator must set this by hand each boot, over the admin
    -- console/Warden (confirmed working in-game 2026-08-26):
    --
    --   weather.time.set 20:30:00
    --   weather.set lightclouds
    --   weather.random off
    --
    -- See templates/pursuit/README.md #1.
    weather = {
        hour = 20, minute = 30, second = 0,
        preset = "lightclouds",
        randomWeather = false,
    },

    match = {
        size = 2,
        buckets = { from = 2000, to = 2099 },
        countdownSeconds = 10,

        -- Which distance column a NEW match runs on: "foot" or "vehicle".
        --
        -- "vehicle" is the v1 default because Pursuit is a car chase; "foot"
        -- stays because it is the column Phase C was proven against and it
        -- needs no vehicle spawn to be correct, which makes it the honest
        -- fallback when the cars misbehave.
        --
        -- A match CAPTURES this at creation (`match.mode`) and every rule reads
        -- the captured value, never this one. Flipping the switch -- from the
        -- config or from `pursuit.mode` -- must not move the finish line under
        -- two people who are already playing.
        --
        -- SUPERSEDED, AND KEPT ONLY FOR THE ARGUMENT ABOVE. The live value is
        -- the `matchMode` tunable at the foot of this file: `pursuit.mode`
        -- writes through it, the Tuning tab writes through it, and
        -- `server/match.lua nextMode()` is the one place that reads it. This
        -- field itself is no longer read by anything.
        mode = "vehicle",

        -- Where a match starts.
        --
        -- Explicit PAIRS, not a start point plus a bearing. A computed offset
        -- lands inside a wall, on a roof or below a road as often as it lands
        -- on the street, and nothing on the server can tell the difference --
        -- the respawn succeeds either way and the player falls through the
        -- world. Two authored points cost one measurement each and cannot do
        -- that.
        --
        -- MEASURED 2026-08-26 in-game, on foot, with pursuit.probe and
        -- pursuit.survey (both live in server/main.lua). Every z below is
        -- where the player's feet came to rest after the respawn settled, not
        -- where he was asked to appear, and every point was walked away from.
        --
        -- What the measurement caught, and why the warning above was right:
        --
        --   * The old cop point of pair A, -424.0 891.0 56.5, was OVER A VOID.
        --     The player fell 56.5 -> -81.2 in four seconds and the engine's
        --     own out-of-world recovery snatched him back. The respawn had
        --     reported success. This is exactly the failure a derived offset
        --     produces, and nothing on the server could see it.
        --   * The old runner heading of pair A, -68.0, faced a blank wall a
        --     metre away. Inherited from freeroam, where /goto northside only
        --     has to land you safely; a match start also has to let you see
        --     where to run.
        --   * The old cop point of pair B, -455.0 762.0 115.0, is solid ground
        --     but BOXED IN -- a covered rooftop service deck. Walking away
        --     from it covers 2.3 m before wedging against a column.
        --
        -- Headings follow the engine convention measured here: a yaw y faces
        -- the world direction (-sin y, cos y). The cop faces the runner; the
        -- runner faces his escape, which is the same compass bearing, with the
        -- cop behind him. Both are therefore the same number, which looks like
        -- a copy-paste error and is not.
        --
        -- Both pairs run along the North Watson promenade deck, in opposite
        -- directions. Pair B is deliberately pair A reversed rather than a
        -- second location: the Little China candidate could not be made to
        -- yield a walkable cop mark in the time available, and a mirrored pair
        -- on ground that has been walked end to end is worth more than a
        -- second postcode that has not. A genuinely distinct second location
        -- is still owed -- see the plan's Phase C notes.
        spawns = {
            {
                name = "northside_promenade",
                -- freeroam `northside`; ground confirmed at z 56.45.
                runner = { position = { x = -469.47, y = 930.99, z = 56.45 }, heading = 35.0 },
                -- Walked from the runner mark: 61.3 m along the deck, which
                -- ramps up ~7 m over that distance. grounded=yes on arrival.
                cop    = { position = { x = -434.30, y = 881.28, z = 63.60 }, heading = 35.0 },
            },
            {
                name = "northside_promenade_reverse",
                runner = { position = { x = -434.30, y = 881.28, z = 63.60 }, heading = -145.0 },
                cop    = { position = { x = -469.47, y = 930.99, z = 56.45 }, heading = -145.0 },
            },
        },

        spawnSettleMs = 8000,

        -- How far ABOVE the authored mark a player is actually put.
        --
        -- Playtest, 2026-08-26: "il m'est arrive une fois au spawn
        -- d'apparaitre dans l'escalier au lieu de par dessus donc j'ai du
        -- deco/reco" -- a player materialised inside a staircase and had to
        -- reconnect to get out. Same family as the car-spawn fix, and the same
        -- cause.
        --
        -- Every z in `spawns` above is a PLAYER POSITION READ, and a read sits
        -- about 0.55 m below the collision surface it was taken on (measured at
        -- the lobby: the player reads 14.78 where the surface is ~15.36).
        -- Respawn targets share that convention, so a mark placed from a read
        -- is correct FOR THE GROUND IT WAS READ ON -- which is exactly why the
        -- authored marks work and why the fix is not to re-measure them.
        --
        -- What it cannot survive is ground that is HIGHER than the mark by less
        -- than that bias: a step, a kerb, a ramp within a metre of the point.
        -- There the by-convention-correct z is inside geometry, and the engine
        -- resolves that by wedging the player rather than by ejecting him. The
        -- server cannot see it happen -- there is no ground query, Lua cannot
        -- raycast, and `Pursuit.placeAt` returns true as soon as the life
        -- authority accepts the transaction -- so this is not detectable, only
        -- avoidable.
        --
        -- 0.35 m, deliberately small. It is more than one stair riser (~0.18 m)
        -- and less than the 0.55 m read bias, so it cannot lift anyone clear of
        -- his own ground: on the flat he still starts below the surface and
        -- settles as before, and on a step he lands ON the step instead of
        -- inside it. Raising it much further starts dropping players from a
        -- height and, under a low ceiling, would trade one wedge for another.
        --
        -- Applies to MATCH placements only. The lobby has its own surveyed
        -- centre and its own furniture measured against it; lifting that would
        -- move the leash centre and the ready-up ring as a side effect, to fix
        -- a problem nobody has reported there.
        spawnLiftMetres = 0.35,

        -- Self-rescue for a player who was wedged anyway.
        --
        -- `pursuit.unstick` re-places the caller on his own mark, and is
        -- available only during the countdown and for this long into the round.
        -- The window is the whole safety of the mechanism: a placement grants a
        -- placement grace, during which separation is unreadable and the bust
        -- meter drains, so an unstick available mid-chase would be a way for a
        -- cornered runner to erase the cop's work. Inside the opening seconds
        -- there is no work to erase.
        --
        -- 20 s covers the 10 s countdown plus the settle, which is when a
        -- wedged spawn is discovered. Set to 0 to disable the command outright.
        unstickWindowSeconds = 20.0,

        -- An unreadable position freezes the accumulators rather than resetting
        -- them: one missing snapshot is not evidence that a runner stopped
        -- running. Past this, we have genuinely lost track of someone and the
        -- accumulators are cleared instead of being resumed on stale credit.
        positionStaleResetMs = 3000,

        -- Two players meeting again inside this window get their roles swapped
        -- (design §5.5 item 8) -- the natural best-of-two. The design's 30 s is
        -- the window for automatic RE-PAIRING, which is Phase E; this one only
        -- decides which side each player takes when the same two happen to be
        -- matched again, so it can afford to be generous.
        rematchWindowSeconds = 180,

        -- The other half of §5.5 item 8, and the one Phase E owes: two players
        -- who re-queue inside this window are pulled out of FIFO order and
        -- paired with EACH OTHER rather than with whoever waited longest.
        --
        -- Deliberately much shorter than the swap window above. Jumping the
        -- queue is a favour granted to a pair that is visibly still playing the
        -- same best-of-two; three minutes later they are just two players in a
        -- queue and the fair answer is FIFO. The design says 30 s and 30 s is
        -- what a scoreboard beat plus a walk back to the circle costs.
        rematchPairWindowSeconds = 30,

        -- ...but not forever. Without a cap, two players who keep re-queueing
        -- hold the front of the queue against a third player indefinitely,
        -- because every resolve refreshes their entry. After this many
        -- consecutive rematches the pair loses its priority and goes back to
        -- FIFO; the ROLE SWAP is unaffected, because swapping sides is fair
        -- whoever they end up playing.
        maxConsecutiveRematches = 2,

        -- During the head start the cop is asked to hold his ground. There is
        -- no server-side movement lock, so straying past this radius from his
        -- spawn earns a warning and nothing more -- the enforcement that
        -- matters is that no bust progress is counted before the release.
        copHoldRadius = 25.0,

        -- A dead cop cannot play out the clock, and leaving the runner to jog
        -- for four minutes against nobody is worse than ending it. Symmetric
        -- with "the runner dies -> the cop wins", and reversible from here if
        -- it turns out to reward suicide.
        copDeathEndsMatch = true,

        -- ------------------------------------------------------- THE MATCH --
        --
        -- Owner, 2026-08-26: "2 round, un cop/runner." A match is now a BEST OF
        -- TWO with the roles swapped between rounds, and that is a structural
        -- change rather than a number: hunting and being hunted are different
        -- games, and a result that only ever measured one of them measured half
        -- the player.
        --
        -- Set to 1 to get the old single-round match back; every other value is
        -- honoured too, though only an EVEN number gives both players the same
        -- number of turns in each role, and an odd one hands the extra cop
        -- round to whoever the rotation happens to favour.
        roundsPerMatch = 2,

        -- The beat between rounds: scoreboard, then the next placement.
        --
        -- Longer than the five seconds a resolution already holds, because
        -- more happens here than "you won": the roles swap, both cars are
        -- destroyed and recreated, and both players are respawned on the other
        -- end of the map. Eight seconds is the scoreboard plus that
        -- transaction, and the HUD counts it down so the beat is legible
        -- instead of feeling like a hang.
        intermissionSeconds = 8.0,

        -- What a 1-1 match is.
        --
        --   "draw"    -- a draw. One each is a real result in a two-round
        --               best-of-two, and the original default because every
        --               tie-break metric considered was worse than saying so:
        --               "who won faster" is meaningless across mixed outcomes
        --               (escaping in 20 s and surviving 180 s are both wins,
        --               and neither is comparable to the other), and a metric
        --               nobody can predict while playing is not a rule, it is
        --               a coin toss with extra steps.
        --   "decider" -- play one more round. THE DEFAULT since 2026-08-28,
        --               at the owner's request ("if there's a tie at 1-1
        --               after the two rounds, a third match would be good,
        --               no?"). Roles for it come from the same swap rotation,
        --               so round three replays round one's sides. That was
        --               kept over a fresh coin flip DELIBERATELY: the two are
        --               equally luck-neutral -- round one's sides were
        --               themselves chance, or the rematch alternation -- but
        --               rotation is legible in advance (both players know who
        --               will hunt from the moment the match is level, and the
        --               intermission card says so), where a flip at the
        --               decisive moment reads as the game taking sides. The
        --               performance-based rules considered ("faster cop keeps
        --               cop") reopen exactly the incomparable-outcomes
        --               problem above, and are recorded here so the next
        --               person weighs them against it before adding one.
        --               A decider cannot itself tie -- every round has a
        --               winner (the clock running out IS a runner win), and a
        --               mid-decider disconnect is the ordinary forfeit: the
        --               match goes to whoever stayed, whatever the scoreline.
        tieBreak = "decider",

        -- Phase C ships on foot; Phase E bolts vehicles onto the same state
        -- machine with the second column. Role logic and win conditions are
        -- identical either way -- only these numbers change.
        --
        -- ==================================================================
        -- BOTH COLUMNS ARE NOW OVERLAID BY THE `tunables` BLOCK AT THE FOOT
        -- OF THIS FILE
        -- ==================================================================
        --
        -- Every key that block declares -- the bust radius, the fill and drain
        -- rates, the escape distance and its delay, the round length, the head
        -- start -- is read from the match's captured tunables and NOT from the
        -- column below. What the columns still own is everything the panel
        -- does not name, and the argument for each number: the reasoning below
        -- is why the tunable defaults are what they are.
        --
        -- The visible consequence is that FOOT MODE RUNS ON THE VEHICLE
        -- FIGURES until an operator says otherwise. The foot column's own
        -- numbers are kept below, and they are what to type into the panel
        -- when switching `matchMode` to foot.
        --
        -- ------------------------------------------------- THE BUST METER --
        --
        -- Playtest, 2026-08-26, the project owner, in a car: "5 metres ca
        -- suffit pas, la voiture est trop longue... on reste juste derriere la
        -- voiture et ca fait rien jusqu'a la fin. Ca marche que si l'autre
        -- s'arrete completement pendant quelques secondes donc impossible de
        -- l'attraper."
        --
        -- That is not a tuning complaint. It is a rule that cannot be satisfied
        -- in motion, and it had two independent causes:
        --
        --   1. THE RADIUS WAS SHORTER THAN THE CAR. Separation is measured
        --      between two player origins; a Villefort Cortes is about 4.8 m
        --      long, so a cop whose bumper is touching the runner's boot is
        --      already 5-6 m of centre-to-centre separation before any driving
        --      error at all. 15 m -- the owner's number, kept below -- is the
        --      first radius that describes "on his tail" rather than "inside
        --      his car".
        --
        --   2. `bustSeconds` WAS A RESETTING TIMER. "Within X m for Y
        --      CONSECUTIVE seconds" throws away every second of a tail the
        --      moment one corner, one kerb or one truck breaks it. Widening the
        --      radius alone would have left that defect in place, just further
        --      out: a cop who holds 14 m for four and a half seconds and clips
        --      a bollard is back to zero, so in practice only a runner who
        --      STOPS is ever caught -- which is exactly what was reported.
        --
        -- So the hold timer is gone and a METER replaces it. It fills while the
        -- cop is inside `bustDistance` and drains, more slowly, while he is
        -- not. Three properties follow, and they are the reason for the shape:
        --
        --   * a sustained tail is rewarded even when it is imperfect, because
        --     incidental breaks cost a fraction rather than everything;
        --   * the runner keeps genuine counterplay -- break contact for long
        --     enough and the meter bleeds back down to nothing;
        --   * both players can WATCH it, which a hold timer never allowed. It
        --     is on the HUD for both sides (`pursuit_hud`), so closing in and
        --     being closed in on are the same readable event from two seats.
        --
        -- Filling is GRADED by distance rather than gated by relative speed.
        -- The graded term is `bustCoreDistance` / `bustCoreFactor`: on the
        -- bumper the meter fills `bustCoreFactor` times faster than it does out
        -- at the radius edge, so being genuinely on him is worth more than
        -- shadowing him at arm's length.
        --
        -- ------------------------------------------------------------------
        -- EVERY RATE BELOW ASSUMES THE TWO CARS ARE COMPARABLE, AND TODAY THEY
        -- ARE NOT. Read this before tuning any of them.
        --
        -- The only two vehicles this project has measured, over an identical
        -- five-second launch from a standing start:
        --
        --     runner  v_standard2_archer_hella_player   86.4 m
        --     cop     ncpd_villefort_cortes_heat_1      59.7 m
        --
        -- Same chassis class, and about 45% apart. Method noise is ~4%, so the
        -- gap is real: the cop loses roughly 27 m of ground every five seconds
        -- of open-road acceleration. The likely cause is that the `*_player`
        -- record tier is tuned quicker than the `ncpd_*` tier -- see
        -- `vehicles.cop` below.
        --
        -- What that does to these numbers: a cop who is behind cannot close, so
        -- the meter is nearly unfillable once the runner is clear, and the
        -- 100 m escape is won by driving in a straight line. NONE OF THAT IS A
        -- RATE PROBLEM, and it must NOT be compensated for here. Slowing the
        -- drain or shortening the fill to paper over a car-choice problem would
        -- hide it, and would break again the moment the cars change.
        --
        -- It is a DATA fix -- one record string in `vehicles.cop` -- and the
        -- measurement that settles it is cheap: a five-second launch on each
        -- candidate cop record against the runner's car, from the same mark.
        -- Four `Vehicle.ncpd_*` records are in the saloon class
        -- (`cortes_heat_1`, `cortes_heat_2`, `archer_hella_heat_2`,
        -- `archer_hella_heat_3`) and only `heat_1` has ever been spawned here.
        --
        -- A slower cop who compensates with roadblocks and information is a
        -- defensible mode. It is not the mode anyone chose -- it is an accident
        -- of a record id -- and it should be chosen or fixed, not inherited.
        -- ------------------------------------------------------------------
        --
        -- Relative speed was once REJECTED here, on the argument that "dwell
        -- time is the speed test -- you cannot stay inside 15 m of a moving car
        -- for five seconds without matching its pace". THE OWNER PLAYED IT AND
        -- REFUTED IT (2026-08-28): "what if the police car is just following
        -- closely the runner but they arent stopped?" Matching a car's pace is
        -- not hard, it is the whole skill of tailing, so the dwell test let a
        -- competent cop bust a runner who was never caught -- and its mirror
        -- ("what if they stop but not for long enough?") left a runner who WAS
        -- repeatedly pinned uncatchable under the old resetting timer.
        --
        -- So the meter is now an ARREST meter, not a proximity meter. It fills
        -- only while the runner is effectively CAUGHT: inside the radius, with
        -- the runner at or under `bustRunnerMaxSpeedKph`, and the cop himself
        -- under `bustCopMaxSpeedKph` -- a drive-by at 100 km/h through the
        -- radius is not an arrest, and the owner said as much of the reverse
        -- case. Tailing at speed fills NOTHING; what it does instead is keep
        -- the meter from bleeding: inside the radius it drains over
        -- `bustContactDrainSeconds` (slow -- the cop is still on him) and only
        -- outside it over `bustDrainSeconds` (fast -- he genuinely got away).
        -- Repeated short pins therefore RATCHET UP, which answers the second
        -- half of the owner's critique, and breaking contact remains the
        -- runner's real counterplay.
        --
        -- The speed itself is differenced from the same 5 Hz replicated
        -- positions the tick already reads -- `Open77.players.position` still
        -- has no velocity -- over a ~1 s window with a minimum baseline, the
        -- same discipline server/roadblock.lua applies to its heading. A speed
        -- the server cannot read fills nothing (freeze, never guess), exactly
        -- as an unreadable separation freezes the accumulators.
        --
        -- THE CRASH STALL is what creates the windows that make an arrest
        -- possible against a runner who never stops on purpose (owner: "quand
        -- il crash sur quelque chose le moteur s'arrete genre 3 sec? pareil
        -- pour la police"). A windowed speed collapse -- from at least
        -- `crashMinSpeedKph` down by at least `crashDropKph` -- is read as a
        -- hard crash, and the player is STALLED for `crashStallSeconds`, both
        -- roles alike:
        --   * a stalled RUNNER counts as pinned for the whole window, even as
        --     he pulls away again -- the fiction is a stalled engine, and the
        --     rule is that a crash near the cop is what loses you;
        --   * a stalled COP cannot arrest at all -- a crashed cop is not
        --     arresting anyone, which is the owner's own symmetry.
        -- The speed-drop test is an honest PROXY: the server has no collision
        -- events and Lua cannot raycast, so "was fast, instantly is not" is
        -- the only crash the server can see. Full braking measures well under
        -- the default threshold (~35 km/h lost per second against 40 inside
        -- the window); the thresholds are tunables precisely so a false
        -- positive found in play is a panel edit, not a code change. There is
        -- no server-side way to actually cut the engine -- the vehicle
        -- authority's durable owner-state would re-assert it within 500 ms
        -- (see the siren note below) -- so the stall is a RULES state with a
        -- HUD banner, not a physics act.
        foot = {
            -- 100 m and the same escape WINDOW as the vehicle column below,
            -- which carries the full reasoning. On foot 100 m is twenty seconds
            -- of running rather than three of driving, so opening the gap is a
            -- genuine sprint here -- and holding it for the window is a longer
            -- one, which is why the window matters even more on foot: a cop on
            -- foot has no engine to close 100 m in three seconds, and the
            -- window is the only comeback he has.
            escapeDistance = 100.0,
            escapeGraceSeconds = 18.0,
            escapeDrainSeconds = 6.0,
            -- Shorter than the vehicle column's: on foot there is no car to
            -- board, so the only thing this has to cover is the respawn fade.
            escapeArmSeconds = 8.0,

            bustDistance = 8.0,
            bustCoreDistance = 3.0,
            bustCoreFactor = 1.6,
            -- Faster than the vehicle column: on foot a cop who is within 8 m
            -- of you has already run you down, and there is no bodywork
            -- standing between the two numbers.
            bustFillSeconds = 3.0,
            bustDrainSeconds = 5.0,

            -- The arrest gate, in foot terms. A jog is ~9 km/h, so a runner
            -- who is walking or cornered is arrestable and one who is
            -- genuinely sprinting is not; the cop's own gate sits above any
            -- sprint this engine produces, because on foot "run him down" IS
            -- the arrest and there is no drive-by case to exclude.
            bustRunnerMaxSpeedKph = 9.0,
            bustCopMaxSpeedKph = 30.0,
            bustContactDrainSeconds = 20.0,
            -- No engine to stall on foot. 0 disables the crash rule outright;
            -- the two thresholds are kept only so the column stays complete.
            crashStallSeconds = 0.0,
            crashMinSpeedKph = 45.0,
            crashDropKph = 40.0,

            headStartSeconds = 5.0,
            durationSeconds = 180,
        },
        vehicle = {
            -- ------------------------------------------------- THE ESCAPE --
            --
            -- Owner, 2026-08-26, confirming this is the rule he wants: "si la
            -- voiture arrive a s'eloigner a x metre genre 100 il gagne
            -- automatiquement... si le runner arrive a le semer a cette
            -- distance il gagne automatiquement justement."
            --
            -- SHAKING THE COP OFF IS THE WIN -- but since 2026-08-29 it is a
            -- WINDOW, not an instant. The owner played the instant rule and
            -- refuted it the same way he refuted the resetting bust hold:
            -- "when the runner moves 100m away it shouldn't be instant --
            -- like 15-20 secs time for the cop to get closer; if he does not
            -- find a way to fall back below the limit then it's [the cop's]
            -- loss." The instant rule ended rounds on a single good corner,
            -- before the cop's comeback could exist at all.
            --
            -- So the escape is now the bust meter's mirror: crossing
            -- `escapeDistance` starts an ESCAPE METER that fills over
            -- `escapeGraceSeconds` while the gap holds, drains -- much faster,
            -- see below -- over `escapeDrainSeconds` when the cop pulls it
            -- back under the line, and wins the round for the runner when it
            -- fills. Both players watch it on the same HUD bar the bust
            -- meter uses; the two cannot run at once.
            --
            -- Together with the bust meter this keeps the mode one continuous
            -- opposition with no dead zone: every metre of separation is
            -- filling the cop's meter or carrying the runner towards his win,
            -- and never neither. THE GAP BETWEEN `bustDistance` AND
            -- `escapeDistance` IS STILL THE BALANCE DIAL OF THE WHOLE MODE --
            -- 15 m to 100 m today, an 85 m corridor in which the chase
            -- actually happens; the window adds a TIME dial on top of the
            -- distance one.
            --
            -- What moving each number does:
            --   escapeDistance      -- LOWER starts escape attempts sooner and
            --                          favours the runner; higher makes him
            --                          earn a longer break. 100 m is about
            --                          three seconds of clear road at chase
            --                          speed.
            --   escapeGraceSeconds  -- the window itself. 18 s is the middle
            --                          of the owner's 15-20 bracket. 0
            --                          restores the instant rule exactly.
            --   escapeDrainSeconds  -- the cop's comeback rate; the argument
            --                          for 6 s is on the tunable below.
            escapeDistance = 100.0,
            escapeGraceSeconds = 18.0,
            escapeDrainSeconds = 6.0,

            -- ...but not in the opening seconds of a round.
            --
            -- Measured from the cop's release, which with no head start is the
            -- moment the round goes live. Nobody is SEATED when a round begins
            -- -- both players have to find a door and get in, see
            -- `vehicles.mount` -- so without this the opening is decided by
            -- whoever boards first: a runner already rolling while the cop is
            -- still walking round his own bonnet banks a free head start. The
            -- escape window softens that -- the attempt can now be clawed back
            -- -- but a meter filling against a cop who is not yet in a car is
            -- still a rigged clock, so the arm delay stays.
            --
            -- 15 s, which is the boarding window's insurance rather than a
            -- balance number: the cars are created during the 10 s countdown
            -- and both players are meant to be aboard before the clock starts,
            -- so this covers the case where one of them was not. The cop can
            -- still BUST inside it, so it delays one rule rather than declaring
            -- a truce. Lower it if rounds feel like they start slowly; raise it
            -- if a runner keeps winning before the chase exists.
            escapeArmSeconds = 15.0,

            -- The owner's radius. See the long note above the columns: this is
            -- the number the whole bust rule was broken by, and it has to be
            -- comfortably longer than a car for "right behind him" to be a
            -- state the server can observe at all.
            bustDistance = 15.0,

            -- Inside this the meter fills at `bustCoreFactor` times the edge
            -- rate; between the two it interpolates linearly. 6 m is roughly
            -- one car length of gap -- bumper to bumper, no daylight -- and 1.6
            -- makes that worth 3.1 s instead of 5 s. A cop who is genuinely on
            -- him should not be paid the same as one shadowing at 14 m.
            bustCoreDistance = 6.0,
            bustCoreFactor = 1.6,

            -- Seconds to fill the meter from empty while sitting at the EDGE of
            -- `bustDistance`. Five, because that is about the length of a
            -- deliberate act in a car: long enough that it cannot happen by
            -- passing someone, short enough that a cop who has genuinely caught
            -- his man is not asked to babysit him through a whole block.
            bustFillSeconds = 5.0,

            -- Seconds to drain the meter from full while OUTSIDE the radius.
            --
            -- DELIBERATELY SLOWER THAN THE FILL, 8 against 5. The asymmetry is
            -- the entire point of using a meter, and the two events are not
            -- equivalent: time spent inside the radius is EARNED -- the cop had
            -- to close and stay closed -- while time spent outside it is
            -- frequently accidental, a corner or a kerb or a truck. Draining at
            -- the fill rate would restore the old defect in slow motion, with
            -- four seconds of good work undone by four seconds of a bad line.
            --
            -- It must not be much slower than this either. At, say, 20 s the
            -- meter would become a ratchet: a cop who touched the radius once
            -- would keep most of it indefinitely and bust on a glancing contact
            -- a minute later, which takes the counterplay away from the runner
            -- entirely. 8 s means a genuine break -- eight seconds of the
            -- runner keeping more than 15 m -- wipes a full meter, and that is
            -- a fair price for having been caught once.
            bustDrainSeconds = 8.0,

            -- ---------------------------------------------- THE ARREST GATE --
            --
            -- The 2026-08-28 redesign; the full argument is in the long
            -- "Relative speed" note above the columns. The meter fills ONLY
            -- while all three hold: inside `bustDistance`, runner at or under
            -- his ceiling, cop at or under his.
            --
            -- 12 km/h for the runner: creeping in traffic, wedged, reversing
            -- off a wall -- caught, in every sense that matters -- while any
            -- honest attempt to drive away clears it within a second. 30 for
            -- the cop: rolling to a stop beside his man still counts, a
            -- fly-past does not.
            bustRunnerMaxSpeedKph = 12.0,
            bustCopMaxSpeedKph = 30.0,

            -- Drain while the cop is INSIDE the radius but the arrest
            -- conditions are not met -- the tailing-at-speed state. Slow on
            -- purpose, and this number is what makes repeated short pins
            -- accumulate: at 30 s a two-second pin (+40% of a 5 s fill)
            -- outlasts ten seconds of contested tailing (-33%). The runner's
            -- way to actually clear the meter is unchanged -- break the 15 m
            -- contact and it drains over `bustDrainSeconds`.
            bustContactDrainSeconds = 30.0,

            -- The crash stall. The owner's number ("genre 3 sec"), applied to
            -- both roles; 0 turns the whole crash rule off. `crashMinSpeedKph`
            -- is the speed you must have carried into the wall for it to count
            -- as a crash at all, and `crashDropKph` is how much of it must
            -- vanish inside the ~1 s speed window -- full braking loses ~35
            -- km/h per second, so 40 within the window is bodywork, not brake
            -- discs. Both are tunables because they were calibrated in play,
            -- not derived.
            crashStallSeconds = 3.0,
            crashMinSpeedKph = 45.0,
            crashDropKph = 40.0,

            -- NO HEAD START, and this is forced by the 100 m escape rather than
            -- chosen. Any head start at all is itself an escape: the runner
            -- cannot help but be more than 100 m clear after several seconds of
            -- driving nobody is contesting, so the round would be decided
            -- before the hunt began. Both cars leave together from marks ~60 m
            -- apart, which is a police chase already in progress -- the shape
            -- the owner's rules describe. `escapeArmSeconds` above is what
            -- protects the opening seconds instead.
            --
            -- Set this back above zero ONLY together with a bigger
            -- `escapeDistance`; the two are a pair, and the old 300 m/10 s
            -- combination is what they were.
            headStartSeconds = 0.0,

            -- Owner: "3m au lieu de 5" -- three minutes per ROUND, and there
            -- are two rounds (`match.roundsPerMatch`), so a sitting is about
            -- the length of one old six-minute match but contains two chases
            -- and both roles.
            durationSeconds = 180,
        },
    },

    -- ------------------------------------------------------------- vehicles --
    --
    -- The cars a MATCH owns, as opposed to `match.vehicle` above, which is the
    -- vehicle-mode tuning column. Two different things, and conflating them is
    -- how a distance ends up living next to a paint colour.
    --
    -- READ THIS BEFORE CHANGING ANYTHING HERE. The server creates both cars and
    -- removes them; it does NOT seat anybody, and it cannot. wiki/vehicles.md
    -- is explicit that the occupancy ledger "is produced by native mount
    -- detection and validated by the server" and that scripts "cannot write
    -- this ledger directly". The only warp helper, `warpPlayerIntoVehicle`, is
    -- a CLIENT function that "operate[s] only on remote player proxies",
    -- refuses with `occupancy_mismatch` unless the server ledger already holds
    -- the tuple, and explicitly "cannot ... move the local player". There is no
    -- server-side seat API at all.
    --
    -- So the contract this section implements is "your car is on your mark, get
    -- in": the server spawns it beside the player, tells him it is there,
    -- watches the ledger, and confirms when he is aboard. Anything stronger
    -- would be a lie.
    vehicles = {
        runner = {
            -- A `*_player` record, per docs/vehicle-models.md: those are the
            -- variants validated as ordinary drivable player vehicles.
            record = "Vehicle.v_standard2_archer_hella_player",
            -- Unmarked and dark. The runner is not supposed to be findable.
            primaryColor = { r = 28, g = 30, b = 34 },
            secondaryColor = { r = 16, g = 17, b = 20 },
            lightsOn = true,
            sirenOn = false,
        },
        cop = {
            -- There is NO `*_player` NCPD record. Checked against every
            -- `police` and `ncpd` row of docs/vehicle-models.md: the 89 entries
            -- in "Player and garage variants" contain none of them.
            -- `ncpd_villefort_cortes_heat_1` is the ordinary NCPD patrol
            -- Cortes, and the catalogue's own usage example spawns a sibling
            -- record (`Vehicle.ncpd_archer_hella_heat_2`), which is the best
            -- evidence available that this family spawns.
            --
            -- It is NOT covered by the "prefer *_player" guarantee, so it is
            -- the one model id in this file that could plausibly fail to
            -- create or fail to drive. `fallbackRecord` is the `*_player`
            -- Cortes -- same chassis, no livery -- and server/vehicles.lua
            -- retries with it automatically and says so in the log.
            record = "Vehicle.ncpd_villefort_cortes_heat_1",
            fallbackRecord = "Vehicle.v_standard2_villefort_cortes_player",
            primaryColor = { r = 24, g = 36, b = 72 },
            secondaryColor = { r = 205, g = 210, b = 220 },
            lightsOn = true,
            -- ===============================================================
            -- THE LIGHT BAR IS THE SIREN, AND THE SIREN BIT CANNOT SURVIVE ON
            -- THIS BUILD. THIS IS ALREADY `true` AND IT IS NOT ENOUGH.
            -- ===============================================================
            --
            -- Asked for on 2026-08-26: "tu peux m'activer les giros dans les
            -- voitures polices par défaut ?". The answer is that it was already
            -- asked for here, and that the platform throws it away five seconds
            -- later. Traced 2026-08-26, and every step is in the source rather
            -- than inferred:
            --
            --   1. `sirenOn` becomes `Open77.vehicles.flags.sirenOn` (256) on
            --      `create`, so the canonical vehicle really does carry the bit.
            --   2. A client streaming the car in applies it:
            --      VehicleReplication.cpp ApplyState -> Api::Vehicles::SetSiren
            --      -> native `ToggleSiren` on `vehicleBaseObject`. The bar
            --      lights.
            --   3. The server grants a SIMULATION STEWARD to every vehicle the
            --      moment it exists (VehicleAuthorityService.ReconcileInterest),
            --      and that client starts publishing durable owner state 5 s
            --      after the entity attaches, every 500 ms.
            --   4. `DurableState()` in VehicleReplication.cpp builds that report
            --      from `Api::Vehicles::Snapshot`, and THAT STRUCT HAS NO SIREN
            --      FIELD. Engine, locks, lights, high beams, doors, glass,
            --      tyres -- all present; siren, nothing. So the report can never
            --      contain `VehicleSirenOn`.
            --   5. `AcceptOwnerState` merges the electrical flags by
            --      REPLACEMENT: `(StateFlags & ~electrical) | (observed &
            --      electrical)`. A bit the owner cannot report is a bit the
            --      owner is understood to be reporting as off.
            --
            -- Net effect: the bar runs for about five seconds, inside the 5.7 s
            -- respawn fade, and goes dark at almost exactly the moment the cop
            -- can first see his car. Which is indistinguishable, from the
            -- driver's seat, from a flag that was never set.
            --
            -- The same mechanism explains the `engineOnAtSpawn` reading above
            -- (`engine=off` on a car created with the bit set) and the fact
            -- that `lightsOn` DOES stick: headlights are the one electrical bit
            -- the snapshot can read back, so the owner keeps re-affirming them.
            --
            -- WHAT WOULD ACTUALLY FIX IT is outside this resource -- one line,
            -- in `DurableState()`, echoing the canonical bit for a field the
            -- client cannot observe, exactly as that function already does for
            -- an unregistered health pool:
            --      if (replica.state.stateFlags & Protocol::VehicleSirenOn)
            --          state.stateFlags |= Protocol::VehicleSirenOn;
            -- Reported rather than done: client/ is not this gamemode's to
            -- edit. `server/vehicles.lua reassertElectrical` is already wired
            -- and will make the bar stick the day that lands.
            --
            -- Left `true` on purpose. It costs nothing, it is the correct
            -- authored intent, and it is what the fix above turns on.
            sirenOn = true,
        },

        -- Where the car appears relative to its driver's mark, in the MARK's
        -- own frame -- lateral rather than forward, so the player does not
        -- spawn inside the car and does not have to walk around it. He turns
        -- and it is beside him.
        --
        -- Heading convention, measured and recorded on `match.spawns` above: a
        -- yaw y faces (-sin y, cos y). "right" is therefore (cos y, sin y).
        --
        -- ===================================================================
        -- THE SIGN OF `lateral` IS NOT COSMETIC -- IT DECIDES WHICH SIDE OF
        -- THE CAR THE PLAYER LANDS ON
        -- ===================================================================
        --
        -- The engine's entry prompt ("F Monter") appears within roughly one
        -- metre of the DRIVER DOOR specifically. The bonnet, the boot and the
        -- passenger flank offer nothing at all -- not a refusal, not a
        -- greyed-out prompt, nothing -- so a player standing on the wrong side
        -- of his own car concludes the car is broken. Two full match cycles
        -- were lost to exactly that on 2026-08-26.
        --
        -- Night City cars are left-hand drive: `seat_front_left` is the only
        -- driver seat (wiki/vehicles.md), so the driver door is the car's LEFT
        -- flank. The player therefore has to end up on the car's left.
        --
        -- Whether he does is decided by two numbers that live in different
        -- places and were never checked against each other:
        --
        --   C - P = forward(markHeading)*forward + right(markHeading)*lateral
        --   driver side  <=>  (C - P) . right(carYaw) > 0
        --
        -- which collapses, for a purely lateral offset, to:
        --
        --   carYaw == markHeading        -> need lateral > 0
        --   carYaw == markHeading + 180  -> need lateral < 0
        --
        -- Both C1 marks satisfy it TODAY, and one of them does so by accident:
        -- the runner's `vehicleYaw = 75.5` was added to get its nose off a
        -- pillar, and flipping the car 180 degrees happened to move its driver
        -- door from the far flank to the near one. Before that flip the runner
        -- spawned on the PASSENGER side, 4.5 m from a door that only answers
        -- within 1 m -- which is the reported bug, exactly.
        --
        -- `server/vehicles.lua` now asserts this at start for every configured
        -- mark and logs a WARNING naming the mark and the role when it fails.
        -- Nothing enforces it at spawn time, because the honest response to a
        -- badly authored mark is a loud log line and a playable match, not a
        -- refusal to create the car.
        -- ===================================================================
        -- `up` IS CLEARANCE OVER THE GROUND, AND THE AUTHORED z IS NOT THE
        -- GROUND
        -- ===================================================================
        --
        -- Raised from 0.5 to 0.85 on 2026-08-26, after the owner reported
        -- "des fois la voiture spawn dans le sol et se retourne quand ça
        -- commence".
        --
        -- A car created interpenetrating the road is not left there: the
        -- physics solver resolves the overlap by pushing it out, and pushing a
        -- two-tonne body out of a road surface in one step is an ejection. It
        -- comes back down on a corner and lands on its roof. "Se retourne" is
        -- the solver working correctly on a bad input.
        --
        -- The bad input is that every z in `spawns` below is a PLAYER or NPC
        -- POSITION READ, and a position read is not the collision surface. The
        -- one place this repository has measured both at the same spot is the
        -- lobby centre: the player standing there reads 14.78, and the ring
        -- authored at 14.8 drew HALF A METRE UNDER the tarmac -- so the surface
        -- is about 15.3 and the read sits ~0.55 m below it. Applied here, the
        -- old `up = 0.5` bought no clearance at all: it cancelled the bias and
        -- put the car exactly on the surface, where a kerb, a drain cover, a
        -- 1.5% gradient or late-streaming collision decides the outcome. Hence
        -- "des fois".
        --
        -- 0.85 = the ~0.55 m measured bias, plus ~0.3 m of real clearance --
        -- which is roughly what freeroam's proven `/car` asks for (its
        -- `Config.vehicles.spawnOffset.z` is 0.25, measured from the same kind
        -- of read).
        --
        -- WHY ERR UPWARD. The two failures are not symmetric. Too low is a
        -- guaranteed ejection and a ruined round. Too high is a drop, and a car
        -- absorbs a kerb-height drop on its suspension without leaving its
        -- wheels; the drop also happens during the countdown, ~10 s before
        -- anybody can drive. So the cost of a metre too high is nothing you can
        -- see, and the cost of a centimetre too low is the match.
        --
        -- DO NOT GUESS THE NEXT VALUE -- MEASURE IT. `server/vehicles.lua`
        -- probes the settle a few seconds after the re-plant and logs
        -- `settle +/-x.xx m (commanded z ..., resting z ...)` for every car of
        -- every match. Negative is the car falling, which is the safe
        -- direction; POSITIVE means it was pushed up, which is this bug still
        -- happening on that mark.
        spawnOffset = { forward = 0.0, lateral = 3.5, up = 0.85 },

        -- =================================================================
        -- WHY CARS USED TO HOVER, AND WHAT `vehicleRestZ` DOES ABOUT IT
        -- =================================================================
        --
        -- Owner, 2026-08-28: "the car when we start a run are a bit higher
        -- than the floor... it's not going back to the floor properly, only
        -- when you get in."
        --
        -- Measured the same evening, on the dev server, three matches in a
        -- row: an unoccupied fresh vehicle is PHYSICS-ASLEEP. It hangs at the
        -- exact transform `create` gave it -- `read z + up` = roughly 0.30 m
        -- of daylight under the wheels -- and the settle probe read back
        -- `resting z == commanded z` to the centimetre every time, which its
        -- old wording mislabelled "on the ground". Nothing moves it until a
        -- client's physics wakes it, which in practice is the driver getting
        -- in: production's settle lines (-0.29 m, -0.34 m) all landed one
        -- tick AFTER "player is aboard". There is no server-side wake: the
        -- Lua API has no impulse or velocity call (wiki/vehicles.md lists
        -- the complete surface), and `setTransform` just moves the sleeping
        -- body to a different hover.
        --
        -- So the fix is to SPAWN AT THE REST HEIGHT: a mark that carries
        -- `vehicleRestZ` -- the z a SETTLED car of this class measured at
        -- this exact spot, engine awake, driver aboard -- gets its car at
        -- `vehicleRestZ + restClearanceMetres` instead of `read z + up`. The
        -- car still spawns asleep, but asleep ON ITS WHEELS, a hair above
        -- where physics would put it; when boarding wakes it, it drops the
        -- clearance and nothing visible happens.
        --
        -- THE ANTI-CLIP REASON FOR `up = 0.85` STILL STANDS and this does
        -- not repeal it: 0.85 exists because a POSITION-READ z is ~0.55 m
        -- below the surface and guessing lower ejects the car ("se
        -- retourne"). `vehicleRestZ` is not a guess -- it is a measurement
        -- of a settled car -- so it may sit lower safely. A mark WITHOUT the
        -- measurement keeps the 0.85 lift and the hover, which is the honest
        -- fallback: floating beats flipping.
        --
        -- 0.10 m: enough that survey error to the centimetre cannot put the
        -- axles inside the road (the ejection direction), small enough that
        -- the stance reads as parked, not floating. Measure, then lower --
        -- never the reverse order.
        restClearanceMetres = 0.10,

        -- Refuse to re-plant a car that is already this far from its mark.
        --
        -- Past this it is not a badly settled car, it is a car somebody drove,
        -- pushed or wrecked, and putting it back is a rewind rather than a
        -- repair. 6 m is comfortably outside the settle of a car that merely
        -- rolled or was nudged off a kerb, and well inside the first corner.
        replantMaxDriftMetres = 6.0,

        -- How long after the re-plant to read the car's resting position back.
        --
        -- It has to be long enough for the car to have fallen, stopped, and
        -- been simulated by a real client -- the canonical position only moves
        -- when a physics owner reports it, and the client that owns a freshly
        -- streamed car withholds durable reports for its first 5 s. 4 s after
        -- the re-plant is 8 s after creation, which is inside the countdown and
        -- past the mean 5.7 s respawn fade.
        settleProbeAfterMs = 4000,

        -- What counts as "it was pushed up" and "that was a long drop" in the
        -- settle log. Only wording; neither number changes a car's behaviour.
        settleRiseWarnMetres = 0.25,
        settleDropWarnMetres = 1.5,

        -- Where the driver door sits in the CAR's own frame, and how close the
        -- engine wants the player before it offers to let him in.
        --
        -- These are not measured from the game's collision data -- there is no
        -- server-side way to read a vehicle's bounding box, and the server
        -- snapshot does not even expose orientation (wiki/vehicles.md, "Server
        -- snapshot fields"). They are the dimensions of a mid-size Night City
        -- sedan: ~1.9 m wide, so a flank at ~0.95 m, and a front-seat door
        -- centred a little ahead of the wheelbase midpoint.
        --
        -- They are used for TWO things and neither of them moves a car:
        --   * the start-up assertion above, which reports the door's distance
        --     from the player's mark so a bad pair is visible without playing;
        --   * the HUD boarding readout, which tells the player how far he is
        --     from the door he needs -- the feedback whose complete absence is
        --     what made the original bug unreadable.
        --
        -- `promptRadius` is the engine's own reach as OBSERVED, not as read
        -- from the binary. It only decides when the HUD readout switches from
        -- "walk to it" to "press F", so being wrong by 30 cm costs a slightly
        -- early or slightly late change of wording and nothing else.
        door = {
            lateral = 0.95,
            forward = 0.35,
            promptRadius = 1.2,
        },

        -- Set `Open77.vehicles.flags.engineOn` on a match car at creation.
        --
        -- KEPT, but do not expect it to do anything you can feel. It exists as
        -- a switch only because it was once believed to be the reason match
        -- cars would not drive, and A/B-ing that belief in game needed a way to
        -- turn it off without editing code. The measurement, 2026-08-26, one
        -- session, same mark, same car, same 5 s throttle:
        --
        --   engineOnAtSpawn = true   -> 86.4 m
        --   engineOnAtSpawn = false  -> 82.9 m
        --
        -- 4% apart on a hand-held throttle, i.e. the same number.
        --
        -- The mechanism is that REDengine does not keep the engine running on
        -- an UNOCCUPIED vehicle: `vehicle.status` read `engine=off` on a car
        -- created with the bit set, and `engine=on` on the same car the moment
        -- a player mounted it -- the mount sequence starts it by itself. So the
        -- bit never survives to the entity while it would matter, and driving
        -- never depended on it.
        --
        -- It stays true because the canonical flag is what an OBSERVER's client
        -- reads for remote engine audio, and a match car is meant to be running.
        engineOnAtSpawn = true,

        -- Re-publish the canonical transform this long after creation.
        --
        -- `create` already positions the car, but the world around a fresh
        -- match spawn is still streaming and a car that lands before its road
        -- does can settle badly. `setTransform` is documented to revoke any
        -- physics lease, advance the authority epoch and republish the complete
        -- transform to every current viewer, which is precisely the repair a
        -- badly settled car needs.
        --
        -- IT NOW HAPPENS INSIDE THE COUNTDOWN. IT DID NOT USED TO, AND THAT
        -- WAS A BUG THIS COMMENT HID.
        --
        -- The sentence that used to end this note -- "it happens inside the
        -- countdown, so nobody is driving when the ground is pulled back under
        -- the wheels" -- was the intent, never the behaviour. The re-plant was
        -- gated on the `tick` hook, and `server/match.lua` fires `tick` only
        -- for a match in state `active`; its countdown branch pushes the HUD
        -- and nothing else. So the 4 s deadline could not be met until the
        -- countdown was already over, and the re-plant landed on the first
        -- active tick -- at t+10 s, at the instant the match starts, with the
        -- driver most likely already aboard. A teleport plus an authority
        -- revoke, delivered to a car with a player in it, at the moment he
        -- takes the throttle: "la voiture se retourne quand ça commence".
        --
        -- `server/vehicles.lua` now schedules it with `SetTimeout` from the
        -- countdown hook, which is the only way to get work done during a
        -- countdown from that file, and `replant` refuses outright to move a
        -- car that is occupied or has already left its mark. Both halves
        -- matter: the schedule makes the normal case right, the guard makes
        -- every other path -- reload, fallback, a slow machine -- safe.
        --
        -- 4 s is ahead of the 5.7 s mean respawn fade, so in the normal case
        -- the car is put back before its driver can even see it.
        replantAfterMs = 4000,

        mount = {
            -- The server polls the occupancy ledger and nags. It cannot seat
            -- anyone (see the note at the top of this section), so every number
            -- here buys information and a reminder, never enforcement.
            checkIntervalMs = 1000,
            remindAfterMs = 5000,
            remindEveryMs = 10000,

            -- HOW LONG "GET IN YOUR CAR" IS ALLOWED TO EXIST.
            --
            -- The boarding affordance -- the HUD strip and the repeat toasts --
            -- is useful for the opening of a match and pure noise for the
            -- remaining five minutes. Left uncapped, the old reminder fired
            -- every 10 s for the whole match at a player who had already
            -- decided to run on foot.
            --
            -- ===================================================================
            -- THIS IS THE PLAYER'S USABLE TIME, NOT WALL CLOCK FROM CAR CREATION
            -- ===================================================================
            --
            -- It used to be counted from the moment the car was CREATED, which
            -- is the start of the countdown -- and that was wrong in a way that
            -- destroyed the feature it was protecting. Measured with two
            -- clients on 2026-08-26: roughly 25-30 s of a 45 s window was
            -- consumed by the respawn fade, before the player could act, or
            -- even see, at all. The strip EXPIRED MID-APPROACH in three of four
            -- attempts -- it vanished while the player was still walking to the
            -- door, which is precisely the moment it exists for.
            --
            -- The fade is not a constant, and that is the whole argument.
            -- Measured 2026-08-26 off this feature's own log line, eight
            -- samples across four matches: 5.2 5.3 5.3 5.3 5.4 6.0 6.0 7.1 s,
            -- mean 5.7 s. An earlier loaded-machine session read 25-30 s.
            --
            -- So the fade spans roughly 5 s to 30 s, and this repository's two
            -- estimates of it -- `match.spawnSettleMs` at 8000 and
            -- `lobby.placementGraceMs` at 15000 -- sit INSIDE that spread:
            -- comfortable against a typical fade, hopeless against a bad one.
            -- Neither direction is available to a constant, which is why this
            -- window uses an ANCHOR: it tracks a length that depends on
            -- streaming, on the machine, and on how many clients are running.
            --
            -- So the clock starts when `server/vehicles.lua usableSince` first
            -- observes the driver as genuinely present -- life phase `alive`
            -- AND a replicated position inside the match bucket -- which is the
            -- closest thing the server has to "the fade has lifted and he can
            -- move". Before that the window has not started and the affordance
            -- simply waits.
            --
            -- 45 s of USABLE time is generous on purpose and costs nothing:
            -- getting in removes the strip instantly, so this number is only
            -- ever spent by a player who is not getting in. Past it the
            -- affordance stops of its own accord -- a player still on foot then
            -- is playing a vehicle-tuned match on foot, which is a choice, not
            -- a mistake to keep nagging about.
            affordanceSeconds = 45,

            -- The unconditional backstop, counted from car creation the way the
            -- old window was.
            --
            -- An anchored window has one failure mode a wall-clock one does not:
            -- if the anchor never resolves -- a client that never finishes
            -- incarnating, a position that never replicates into the match
            -- bucket -- the window never starts and the hint never leaves. This
            -- is the ceiling that makes that impossible, and it is the reason
            -- the "a hint cannot outlive the opening of a match" guarantee
            -- still holds absolutely rather than conditionally.
            --
            -- 120 s: comfortably past any fade yet observed (25-30 s) plus the
            -- full 45 s window, and a third of a 360 s vehicle match. It is
            -- expected never to fire; when it does, it means the anchor is
            -- broken and the log line from `usableSince` will be missing.
            affordanceCeilingSeconds = 120,
        },

        -- Vehicle-mode spawn pairs. `nil` means "reuse Config.match.spawns".
        --
        -- THE FOOT MARKS ARE NOT ROADS, and this is the single largest
        -- unverified assumption in Phase E. Read the long note on
        -- `match.spawns`: both marks were surveyed for a player standing on the
        -- North Watson promenade DECK -- pedestrian ground, reached by walking
        -- 61 m along a ramp. That is exactly the sort of place a car can be
        -- created and then cannot leave.
        --
        -- A vehicle match needs its own surveyed pair on tarmac, measured the
        -- same way the foot pair was: `pursuit.probe` to land, `pursuit.survey`
        -- to drive away from it. Until that survey exists this stays nil, the
        -- foot marks are reused, and everything else in the mode can still be
        -- exercised.
        --
        -- ===================================================================
        -- HOW THIS TABLE IS READ (fixed 2026-08-26 -- history below)
        -- ===================================================================
        --
        -- Filling this in now moves the PLAYERS AND THE CARS TOGETHER. There is
        -- ONE selector: `server/match.lua pickSpawnPair(matchId, mode)` prefers
        -- this table whenever the match was created in vehicle mode and it is a
        -- non-empty array, and falls back to `Config.match.spawns` otherwise.
        -- It writes the chosen pair to `match.spawn` and the table it came from
        -- to `match.spawnSource`; `server/vehicles.lua markFor` reads
        -- `match.spawn` and no longer selects a pair of its own. A match
        -- therefore has exactly one set of marks and the cars cannot end up
        -- anywhere but beside their drivers.
        --
        -- It did not always work that way, and the failure is worth keeping
        -- because it was invisible: `placeForMatch` read `Config.match.spawns`
        -- unconditionally with no knowledge of `match.mode`, while `markFor`
        -- read `match.vehicleSpawn` off THIS table. Measured offline on
        -- 2026-08-26 with a probe pair offset 500 m from the foot marks: both
        -- players were still placed on the promenade deck and their cars
        -- appeared 470 m and 540 m away. Because the field was nil the bug was
        -- latent, and pursuit-v1-duo.md E3 tells the next person to fill this
        -- in -- which would have armed it, with a symptom ("cars spawned
        -- somewhere else") that looks like a bad coordinate rather than a code
        -- path. The offline harness now asserts the coupling directly.
        --
        -- Second gap, same measurement, also fixed: bounds.lua's startup "arena
        -- WARNING" sweep iterated `Config.match.spawns` only, so a pair added
        -- HERE was never checked against the arena. It now sweeps both tables
        -- and names which one each mark came from.
        --
        -- ===================================================================
        -- UNSURVEYED CANDIDATES -- coordinates only, no ground truth
        -- ===================================================================
        --
        -- These are NOT surveyed spawns and must not be enabled as they stand.
        -- They exist to save the next person the search, not the survey.
        --
        -- Provenance: every coordinate below is a REAL in-game position read,
        -- captured with `grounded=yes` during the NPC locomotion reference
        -- sessions of 2026-08-06 and filed under
        -- docs/progress/samples/npc-locomotion/. They are places an ambient NPC
        -- was standing or walking, which is decent evidence of solid, level,
        -- reachable ground -- and NO evidence at all that a car can be spawned
        -- there or driven off it. NPC crowds walk on pavements as happily as on
        -- roads. Not one coordinate anywhere in this repository is described as
        -- a road, street, tarmac, parking or garage in Watson.
        --
        -- Each pair was chosen for three properties the foot marks lack:
        -- both endpoints independently captured, near-zero gradient between
        -- them (the promenade pair runs at 11.7%), and a separation in the same
        -- band as the current 61 m pair. Distances below are planar from the
        -- arena centre (-452, 906), radius 600 m.
        --
        -- TO VERIFY ONE, in game, on the dev server, as a single player:
        --
        --   1. pursuit.probe <x> <y> <z> <heading> cand
        --      Watch the log for 11 s. It reports z once a second: a stable z
        --      means ground, a falling z means the void that ate the original
        --      pair-A cop mark (56.5 -> -81.2 in four seconds).
        --   2. pursuit.survey 60
        --      then WALK away from the mark for a minute. The log prints the
        --      distance from origin every second. Wedged against a column reads
        --      as a few metres and then nothing.
        --   3. /car hella   (freeroam) or spawn the match car, GET IN, and
        --      DRIVE OFF THE MARK. This is the step the foot pair fails and the
        --      only one that actually settles the question. A car that spawns
        --      and cannot leave is exactly the E3 failure.
        --   4. Repeat for the other end of the pair, then re-measure the real
        --      resting position of both and REPLACE the numbers below with what
        --      you measured. Do not enable a coordinate you have not stood on.
        --
        -- Headings follow the same convention as `match.spawns`: a yaw y faces
        -- (-sin y, cos y), the cop faces the runner, and the runner faces his
        -- escape, so both ends of a pair carry the same number.
        --
        -- ===================================================================
        -- C1 IS NOW SURVEYED AND ENABLED -- 2026-08-26
        -- ===================================================================
        --
        -- Probed in game on the dev server, both ends, `pursuit.probe` for 11 s
        -- each: z held to the centimetre with zero drift on both marks
        -- (-644.91,1019.37,36.56 and -701.49,1033.97,35.71). That is solid,
        -- level, settled ground, not the void that ate the original pair-A cop
        -- mark. The step the foot pair fails -- getting into a car and driving
        -- off the mark -- was then run as a real match; see the session notes.
        --
        -- The coordinates below are the CAPTURED ones and the resting positions
        -- measured on them agree exactly, so there was nothing to correct.
        --
        -- The foot pair stays in `match.spawns` and is still what foot mode
        -- uses; `pickSpawnPair` prefers this table only in vehicle mode. The
        -- promenade deck is a fine place to run and a hopeless place to drive.
        --
        -- ===============================================================
        -- THE STARTING GRID -- surveyed 2026-08-28, and the active pair
        -- ===============================================================
        --
        -- The same Lower Watson street as the retired pair below, kept
        -- because both of its ends were PROVEN drivable there -- but the
        -- start now sits on the street's straight WESTERN half, both cars on
        -- the centreline, symmetric about one anchor, facing the open road
        -- together. What the retired pair could never offer: its two marks
        -- sat on opposite kerbs of a street that bends, its runner's car had
        -- to be flipped 180 degrees off a pillar and so faced its own
        -- pursuer, and its cars were authored as player-position reads plus
        -- a safety lift, which is the hover the owner reported.
        --
        -- THE SURVEY (dev server, 2026-08-28, `pursuit.probe`, 11 s of z per
        -- point, every point stable to the centimetre with zero drift):
        --
        --   anchor       (-680.0, 1027.3)  ground read 35.91
        --   runner car   (-699.4, 1032.3)  ground read 35.74
        --   cop car      (-660.6, 1022.3)  ground read 36.27
        --   runner mark  (-700.1, 1029.6)  ground read 35.52
        --   cop mark     (-661.3, 1019.6)  ground read 36.26
        --
        -- One slab: 0.53 m of z over the 40 m gap is the street's own 1.3%
        -- grade, agreeing with the 1.4% the retired pair's settled cars
        -- measured. The centreline was fitted from two full-length in-lane
        -- drives recorded during real matches (the 2026-08-28 proof runs),
        -- one per direction, and then every derived point was probed --
        -- fitted geometry is a candidate, only standing on it is a survey.
        --
        -- Heading 75.5: the road's own direction, WEST, the way the street
        -- is measured open (38.3 m driven at the east end, 57 m at the
        -- west). East is the walled corner that ate a proof-run cop car at
        -- 59 km/h. Both cars face west; the runner's 20 m ahead of the
        -- anchor, the cop's 20 m behind.
        --
        -- gapMetres 40: comfortably outside the 15 m bust radius, well
        -- inside the 100 m escape, and entirely on ground that was probed --
        -- the retired pair's 58 m could only be kept by bending the grid
        -- around the street's curve. The chase corridor the tunables define
        -- is untouched.
        --
        -- restZ: what a SETTLED car of that class measured on this street --
        -- rest sits 0.51-0.56 m above a ground READ (three settled cars
        -- agree: 36.27, 37.07 prod, 37.08 local) -- so these two are the
        -- read + 0.53, TO BE RE-MEASURED by boarding on the grid itself;
        -- see `restClearanceMetres` above for what they buy: cars that
        -- stand on their wheels during the countdown instead of hovering.
        --
        -- MOVING THE ANCHOR INVALIDATES EVERY NUMBER HERE. It is one
        -- surveyed spot on one street: re-probe all five points, re-measure
        -- both restZ, or fall back to the retired pair while you do.
        spawns = {
            pursuitGridPair({
                name = "watson_grid_west",
                anchor = { x = -680.0, y = 1027.3 },
                heading = 75.5,
                gapMetres = 40.0,
                doorClearMetres = 2.8,
                -- restZ, MEASURED on the grid itself (2026-08-28, dev):
                --   cop slot: the NCPD Cortes wakes and settles on its own --
                --   two matches read resting 36.58 and 36.67 from a commanded
                --   36.90, so 36.62 is the mean and the car corrects the last
                --   decimetre itself.
                --   runner slot: the Hella STAYS ASLEEP at spawn (every
                --   observation), so it was measured THROUGH its driver --
                --   the in-seat player read tracks the settled car's canonical
                --   z to a centimetre (37.078 vs 37.07 on the retired pair) --
                --   and two boardings on this slot both read 36.18.
                runner = { markZ = 35.52, restZ = 36.18 },
                cop    = { markZ = 36.26, restZ = 36.62 },
            }),
        },

        -- The RETIRED pair, kept whole because its survey data and its
        -- lessons (the pillar, the sign of `lateral`, the walled corner) are
        -- the reference the grid was built against. Nothing reads this
        -- table.
        retiredSpawns = {
            -- 58.4 m apart (the foot pair is 60.9 m), 1.5% gradient, and a
            -- THIRD independent capture sits 4.7 m from the cop mark agreeing
            -- on z to 7 cm. Lower Watson, z ~36, street level rather than deck
            -- level.
            -- Sources: npc-crowd-flee-run-02.json (both ends),
            --          npc-injured-locomotion-01.json (the corroboration).
            {
                name = "watson_lower_36",
                -- 223.8 m from the arena centre.
                --
                -- The mark stands on the pavement between a covered arcade and
                -- an open junction, and the two marks of this pair share a
                -- heading and therefore a world "right" -- which is road at the
                -- cop end and arcade at this one. With the shared +3.5 m the
                -- car spawned into a pillar, nose-up with every window broken.
                -- Its LEFT is the junction: wide tarmac, crossings, no cover.
                -- Hence the sign flip, and hence `vehicleOffset` existing at
                -- all. Measured in game 2026-08-26.
                runner = {
                    position = { x = -644.91, y = 1019.37, z = 36.56 },
                    heading = -104.5,
                    vehicleOffset = { lateral = -3.5 },
                    -- The car faces 180 degrees away from its driver here, and
                    -- that is not a typo. MEASURED IN GAME 2026-08-26, in one
                    -- match, on this exact car:
                    --
                    --   throttle held 5 s on heading -104.5 -> 2.6 m, then a
                    --     dead stop with the nose against the traffic-light
                    --     pillar that stands 2.7 m off this mark's forward;
                    --   throttle held 3 s the other way          -> 38.3 m.
                    --
                    -- The same session drove the COP's car 59.7 m in 5 s off
                    -- its own mark, so this was never an engine, a handbrake or
                    -- a physics-authority problem: one of the two marks simply
                    -- points its car at a pillar. That 2.6 m is what earlier
                    -- sweeps recorded as "0.57 m of roll then stall" and read
                    -- as a car that had never been started.
                    --
                    -- 75.5 = -104.5 + 180. The position is untouched -- it is
                    -- surveyed, and the car spawns pristine on it.
                    --
                    -- THE COST, stated plainly because it is a real one: 75.5
                    -- faces -x, and -x is where the cop is. The runner's car
                    -- therefore points at his pursuer instead of at his escape,
                    -- which is backwards as design even though it is right as
                    -- geometry. He has a 10 s head start and one corner to turn,
                    -- so it costs him a second or two, not the match.
                    --
                    -- The obvious alternative -- keep the designed facing and
                    -- push the car forward past the pillar -- was measured and
                    -- refused: 12 m along +x from the car's mark
                    -- (-632.4, 1019.8, 37.1) is a walled corner, not road. The
                    -- runner end of this pair simply has no open road in the
                    -- direction the pair was authored to run.
                    --
                    -- So this mark is drivable, not good. The proper fix is a
                    -- better PAIR -- one whose two ends face the same open
                    -- street -- and the unsurveyed candidates below the pair are
                    -- where to start looking. Until then a car that drives the
                    -- wrong way beats a car that travels 2.6 m.
                    vehicleYaw = 75.5,
                    -- -104.5 + 90. `lateral = -3.5` puts this car to the
                    -- player's LEFT, so the way to face it is the mark's
                    -- heading turned 90 degrees anticlockwise.
                    --
                    -- See `playerYaw` on the cop mark below for why the player
                    -- is turned at all. It costs the runner nothing: his car
                    -- already points 180 degrees away from his escape (see the
                    -- long note above), so his opening move is a turn either
                    -- way.
                    playerYaw = -14.5,
                },
                -- 280.4 m from the arena centre. PROVEN END: the NCPD Cortes
                -- spawned here pristine (health 1.0, no broken glass) on the
                -- street, the engine offered "F Monter", the player boarded
                -- into seat_front_left -- the server's occupancy ledger
                -- confirmed it -- and drove 57 m off the mark under his own
                -- power. That is E3, closed, on this coordinate.
                --
                -- `playerYaw` is -104.5 - 90 = -194.5, written here as its
                -- in-range equivalent 165.5: `lateral = +3.5` puts this car to
                -- the player's RIGHT, so the way to face it is the mark's
                -- heading turned 90 degrees clockwise. Kept inside -180..180
                -- because every other heading in this file is, and nothing
                -- downstream is known to normalise.
                --
                -- WHY THE PLAYER IS TURNED AT ALL. `heading` was authored so
                -- that "the cop faces the runner", which is the right facing
                -- for a foot match and the wrong one for a car chase: it puts
                -- the car at a dead 90 degrees to the player's view, so a
                -- player who fades in sees empty street, no car and -- because
                -- the entry prompt only answers within a metre of the driver
                -- door -- no prompt either. He has to turn on the spot to
                -- discover that he has a car at all.
                --
                -- `playerYaw` overrides ONLY the facing the respawn is given.
                -- It deliberately does not touch `heading`, because `heading`
                -- is the frame the CAR's offset is measured in
                -- (`server/vehicles.lua markFor`): changing it would move the
                -- car off ground that has been surveyed and proven. Exactly
                -- the same separation of concerns as `vehicleYaw`, in the other
                -- direction.
                --
                -- The distance is unchanged and it is still a step: the door
                -- lands ~2.5 m from the mark, outside the engine's ~1 m reach.
                -- Closing that gap was considered and refused -- it means
                -- either moving the car 1.3 m toward a kerb it was surveyed
                -- clear of, or moving the player onto ground nobody has stood
                -- on -- so the remaining metre and a half is covered by
                -- feedback (the HUD boarding strip) rather than by geometry.
                cop    = { position = { x = -701.49, y = 1033.97, z = 35.71 }, heading = -104.5,
                           playerYaw = 165.5 },
            },
        },

        -- ===================================================================
        -- STILL UNSURVEYED -- coordinates only, no ground truth
        -- ===================================================================
        --
        -- unsurveyed = {
        --     -- C2: 40.6 m apart -- shorter than the foot pair, but the two
        --     -- captures agree on z to THREE MILLIMETRES over that distance,
        --     -- which is a paved surface and nothing else. It is the King
        --     -- Stoop forecourt, z 115, also reachable as freeroam `/goto
        --     -- stoop`. A forecourt is the most road-like thing captured in
        --     -- Watson, and 40 m is still far outside vehicle bustDistance
        --     -- (15 m) and far inside escapeDistance (300 m), so the shorter
        --     -- separation costs nothing the rules care about.
        --     -- Sources: king-stoop-reference-01.json,
        --     --          applyfeature-validation-01.json.
        --     {
        --         name = "watson_stoop_115",
        --         -- 188.0 m from the arena centre
        --         runner = { position = { x = -410.22, y = 722.73, z = 115.00 }, heading = -14.7 },
        --         -- 224.8 m from the arena centre
        --         cop    = { position = { x = -420.50, y = 683.46, z = 115.00 }, heading = -14.7 },
        --     },
        --     -- C3: two free-walk captures 104.6 m apart that agree on z to
        --     -- 30 cm -- a 0.3% grade over a hundred metres, the flattest run
        --     -- of ground captured anywhere in the district. 105 m is longer
        --     -- than the other two and still well inside escapeDistance.
        --     -- Sources: npc-free-natural-walk-03.json,
        --     --          npc-free-natural-walk-02.json.
        --     -- If 60 m is wanted instead, the point (-421.12, 705.47, 46.50)
        --     -- lies ON the segment between them at the same altitude -- but it
        --     -- is INTERPOLATED, not captured, and a segment between two solid
        --     -- points can still cross a gap. Probe it before believing it.
        --     {
        --         name = "watson_mid_46",
        --         -- 188.0 m from the arena centre
        --         runner = { position = { x = -479.34, y = 719.96, z = 46.67 }, heading = 76.0 },
        --         -- 223.9 m from the arena centre
        --         cop    = { position = { x = -377.87, y = 694.70, z = 46.37 }, heading = 76.0 },
        --     },
        -- },

        -- ---------------------------------------------------------- governor --
        --
        -- Shape numbers for the top-speed governor. THE CEILING ITSELF IS NOT
        -- HERE: it is the `topSpeedKph` tunable at the foot of this file, so a
        -- server owner can move it from Warden without a code change. What
        -- lives here is the one figure an owner has no reason to touch.
        --
        -- The governor is a CLIENT native reached through
        -- `Open77.vehicles.setPerformanceClass` (permission
        -- `vehicles.performance`). It scales driver throttle on the wheeled
        -- drive update, per TweakDB record, so every present and future spawn
        -- of a roster car inherits the ceiling. `server/performance.lua` pushes
        -- the figures out and `client/performance.lua` applies them.
        --
        -- IT DOES NOT EXIST ON EVERY CLIENT. 2.31.0+op77.7 has no such export
        -- and the applier degrades there to one logged line and no cap, which
        -- is the behaviour this mode had all along. `shared/roster.lua` section
        -- 1 still argues at length that a technical cap is impossible; that was
        -- true when it was written, and the correction belongs upstream in
        -- `open77_vehiclepicker` rather than in this byte-identical copy.
        performance = {
            -- Width of the proportional roll-off below the ceiling. The
            -- limiter eases throttle off across this band instead of chopping
            -- it at the line, which is what stops a car hunting audibly against
            -- its own limit. The native refuses anything below 3 km/h for
            -- exactly that reason, and anything above 200.
            taperKph = 12.0,
        },
    },

    -- -------------------------------------------------------------- scanner --
    --
    -- Design §5.5 items 1-3. This is the mechanic that makes Pursuit a game
    -- rather than a straight-line speed contest, so it gets the long comment.
    scanner = {
        enabled = true,

        -- Switch nameplates off for the duration of a match.
        --
        -- THIS IS NOT COSMETIC. It closes the hole that made everything else in
        -- this section pointless at exactly the range where it mattered most.
        --
        -- `open77_nameplates` ships in the Pursuit resource set
        -- (templates/pursuit/template.json) and is on by default. It draws a
        -- plate over every attached remote player at up to 35 m
        -- (`maximumDistance` in client/src/api/Nameplates.hpp), every frame, and
        -- with NO occlusion test -- the draw path culls on depth and viewport
        -- only, so the plate renders straight THROUGH walls and buildings.
        --
        -- So a cop within 35 m had the runner's exact live position, floating
        -- over the geometry, while this file carefully rationed him a snapshot.
        -- 35 m also sits inside the 45 m pressure band, meaning the leak was
        -- open precisely during the close-quarters phase the scanner is tuned
        -- for. Delaying the ping without this flag would have fixed nothing at
        -- the range where the owner felt the problem.
        --
        -- Match-only, and deliberately so: nameplates in the LOBBY are wanted,
        -- because seeing who you are queuing against is the point of standing
        -- in a lobby. client/main.lua drives it off the same two edges as the
        -- lobby furniture -- the first `matchState` of a match turns them off,
        -- `lobbyState` on the return turns them back on.
        --
        -- Best-effort. `open77_nameplates` is NOT a declared dependency of this
        -- resource, so the call goes through `callExport` and a server whose
        -- resource set omits it degrades to "no plates to hide", exactly like
        -- the open77_groundcircle fallback.
        hideOpponentNameplates = true,

        -- The cop never gets a live blip. Every interval the server pushes the
        -- runner's LAST KNOWN position and the blip jumps there; between pushes
        -- it is simply wrong, and being wrong is the point.
        --
        -- WHAT THIS NUMBER DOES TO THE CHASE: it is the runner's entire
        -- counterplay. The cop drives to a fix; everything the runner does
        -- before the next sweep is invisible. So this interval IS the size of
        -- the runner's window to change direction and break line of pursuit.
        -- Shorten it and the mode collapses into "drive at the dot".
        --
        -- Raised from 8.0 to 12.0 on 2026-08-26 after the owner's playtest read
        -- as live position. The measurement, from that session's own log
        -- (red4ext/logs/open77-2026-08-26-21-21-27.log), is what settled it:
        --
        --   SCAN #12 -> -859.4, 944.1   21:41:21
        --   SCAN #13 -> -858.1, 946.7   21:41:25
        --
        -- 2.9 m apart, 4.2 s apart. A fix that lands 3 m from the runner is a
        -- live fix, whatever the design comment says. Error is speed x
        -- interval, and city driving spends most of its time slow -- corners,
        -- traffic, junctions -- so a short interval degrades to live exactly
        -- when the chase is tightest and the runner needs the window most.
        --
        -- At 12 s a runner holding 15 m/s owns ~180 m of uncertainty: enough
        -- for a junction and a turn, which is the decision the mode is about.
        --
        -- Reads against the HUD's own 6 s staleness threshold (`STALE_MS` in
        -- resources/gamemodes/pursuit_hud/web/index.html): the readout now spends the
        -- back HALF of every free-running cycle marked stale, so the cop
        -- watches his information rot for six full seconds. Under pressure
        -- (7.2 s) only the last 1.2 s is stale -- that contrast IS the reward,
        -- so changing this number without looking at STALE_MS throws it away.
        pingIntervalSeconds = 12.0,

        -- Item 2: closing distance buys information, not just proximity. The
        -- pressure band is a MULTIPLE of the mode's own bustDistance so it
        -- scales with the column -- 45 m in cars, 24 m on foot -- rather than
        -- being a third absolute number to keep in sync.
        --
        -- The band stays at 3.0: rewarding a cop who has closed to 45 m is the
        -- good half of this mechanic and the playtest did not dispute it.
        --
        -- The FACTOR is what was wrong. At 0.5 the halved interval was 4 s, and
        -- the same session shows 11 of 13 sweeps firing PRESSURE -- pressure
        -- was not an occasional reward, it was the steady state. That is a
        -- self-reinforcing loop with no escape valve: close in, get better
        -- information, use it to stay close, keep the better information. The
        -- runner never gets a window back. 0.6 keeps the reward legible (a
        -- 12 s wait becomes 7.2 s, still nearly half) without ever handing out
        -- a fix fresh enough to drive straight at.
        pressureMultiplier = 3.0,
        pressureIntervalFactor = 0.6,

        -- The floor no combination of pressure may go below.
        --
        -- Nothing today reaches it -- 12.0 x 0.6 = 7.2 s clears it by 1.2 s --
        -- and that is the point of writing it down: it is a guard against
        -- someone (including a future us) lowering the base interval or the
        -- factor and silently recreating the 4 s tracker the playtest rejected.
        -- Below roughly 6 s a fix stops being a memory and becomes a position,
        -- because at city speeds the runner has not had time to leave it.
        minIntervalSeconds = 6.0,

        -- Fire one fix the moment the cop is released, so the hunt opens with
        -- information rather than with an empty map and a 12 s wait.
        pingOnRelease = true,

        blip = {
            -- Client-side, `Open77.blips`, POSITION-attached and never
            -- entity-attached: an entity-attached blip would track the runner
            -- live and delete the entire mechanic.
            --
            -- `objective` deliberately, and not the thematically obvious
            -- `ActionScanVariant`. wiki/blips.md warns that "HUD-only variants
            -- can still be absent from the fullscreen map" and names exactly
            -- five it vouches for -- `objective`, `quest`, `fast_travel`,
            -- `vehicle` and the service points. A scanner contact the cop
            -- cannot find on his map is not a mechanic, so visibility wins over
            -- flavour until visibility is PROVEN in game. Once it is, try
            -- `ActionScanVariant` (id 5) and check the minimap, the compass and
            -- the fullscreen map before keeping it.
            sprite = "objective",
            title = "Scanner contact",
            description = "Last known position of the runner.",
            visibleThroughWalls = true,

            -- Make the fix AGE VISIBLY, so the cop reads "this is old" from
            -- the marker itself rather than only from the HUD's number.
            --
            -- It has to be a sprite swap, and that is a limit of the engine,
            -- not a preference. wiki/blips.md is explicit: "gamemappinsMappinData
            -- carries neither colour nor scale... The API therefore offers no
            -- fake `color` or `scale` that would do nothing." So there is no
            -- alpha to fade and no size to shrink. The icon itself is the only
            -- channel that renders.
            --
            -- `quest` and not the thematically perfect `question`
            -- (QuestionMarkVariant): wiki/blips.md vouches for exactly five
            -- map-capable variants -- `objective`, `quest`, `fast_travel`,
            -- `vehicle`, service points -- and warns that HUD-only variants
            -- "can still be absent from the fullscreen map". A stale fix that
            -- vanishes from the map is a bug wearing a feature's clothes, so
            -- the stale stage stays inside the vouched five. Try `question`
            -- once it has been checked on the minimap, the compass AND the
            -- fullscreen map.
            staleSprite = "quest",

            -- 6.0 to the second, because `STALE_MS` in
            -- resources/gamemodes/pursuit_hud/web/index.html is 6000: the icon changes at
            -- the same instant the HUD's "x.xs ago" readout turns old. One
            -- event, two channels, no ambiguity about which to believe.
            staleAfterSeconds = 6.0,

            -- Put the age in the fullscreen-map tooltip too. `description` is
            -- resource-owned free text (128/1024 byte limits) and is the only
            -- place a precise number can live on the marker, since the HUD does
            -- not draw text beside the icon.
            staleDescription = "Runner was here %.0fs ago. He has moved.",
        },

        -- Item 3: the runner FEELS the scan. A one-sided mechanic would just be
        -- a handicap; this is what makes it a trade.
        runner = {
            notify = true,
            message = "Scanner sweep — you have been located.",
            notifyDurationMs = 2500,

            -- A curated alias from `Open77.vfx.catalog()`. wiki/effects.md
            -- lists exactly seven curated names and warns that a raw
            -- `base\...\name.effect` path is build-dependent and not
            -- necessarily safe or visible out of context, so the alias is the
            -- only defensible default. `electric.destruction` is the closest of
            -- the seven to a scanner pulse.
            vfx = "electric.destruction",
            vfxDurationSeconds = 1.2,

            -- A Wwise event name. The catalogue it comes from
            -- (docs/generated/sfx-events-wolvenkit-seed.csv) declares game
            -- version 1.6 and flags every row
            -- `seed_requires_2.31_runtime_validation`, so a silent ping means
            -- "unvalidated event name", NOT "broken pipeline". Failure is
            -- non-fatal by construction: `sfx.play` returns nil plus a reason.
            sfx = "ui_gmpl_stealth_detection",
            sfxDurationSeconds = 2.0,
        },
    },

    -- ---------------------------------------------------------------- arena --
    --
    -- Design §5.5 item 7. Without bounds the mode is "drive to the Badlands and
    -- idle out the clock", which is a winning strategy and a terrible game.
    arena = {
        -- OFF since 2026-08-26, on the owner's instruction after the first real
        -- playtest: "faut remove le out of bounds qu'on puisse aller ou on veut
        -- sur la map". Night City is the arena now.
        --
        -- Disabled rather than deleted, and everything below is left intact and
        -- accurate, because the argument the bounds were built on has not been
        -- refuted -- it has been OUTRANKED. The argument was that without them
        -- the mode has a dominant strategy: drive to the Badlands and idle out
        -- the clock. What has changed is that the two rules it was defending
        -- are not the same rules any more. The clock is three minutes rather
        -- than six, and the escape is 100 m rather than 300, so "drive far away
        -- and wait" is no longer a way to survive a long timer -- it is simply
        -- a win by escape, decided in the first thirty seconds, and the runner
        -- is welcome to it. The idling exploit died with the numbers that made
        -- it profitable.
        --
        -- Two things follow, and both are handled rather than assumed:
        --
        --   * `Pursuit.outsideArena` returns nil while this is false, which the
        --     win conditions in server/match.lua already read as "not outside".
        --     Escape and bust therefore accrue everywhere on the map.
        --   * server/roadblock.lua clips its throw to the arena circle. That
        --     whole branch is already guarded by this flag, so with bounds off
        --     the blockade is contained by the GRADIENT rule alone -- which is
        --     the rule that actually keeps it out of the void, and is
        --     independent of geography. See the containment note in that file.
        --
        -- Turning this back on is one word, and every number below still
        -- describes a working rule.
        enabled = false,

        -- Watson, bounded (plan §0). PROVISIONAL, and honestly so: this is the
        -- midpoint of the surveyed North Watson promenade pair, because that is
        -- the only ground in this district anyone has actually walked. It has
        -- NOT been surveyed as a district boundary, and the radius is sized to
        -- the plan's "~1.2 km across" rather than measured.
        --
        -- Both authored spawn marks sit ~30 m from this centre (worst case
        -- 30.5 m, `northside_promenade`/runner, measured offline 2026-08-26),
        -- so a match cannot start out of bounds -- which is the one property
        -- that must hold before this is tuned for feel. server/bounds.lua
        -- re-checks it on every start, for BOTH spawn tables.
        center = { x = -452.0, y = 906.0, z = 60.0 },
        radius = 600.0,

        -- PLANAR, like the lobby leash and unlike match separation. An arena is
        -- a district footprint and Night City is vertical: a runner on a
        -- rooftop 90 m up is still in Watson, and busting him for it would be
        -- absurd. Separation includes z because a bust is about reach; bounds
        -- exclude it because bounds are about geography.

        -- The lobby leash's shape, deliberately with the lobby leash's numbers:
        -- warn, then act, one mechanism to reason about.
        warnSeconds = 4.0,
        bustSeconds = 10.0,
        -- ...but repeated, unlike the lobby's single warning. Ten seconds is a
        -- long time at 100 km/h and a player who saw one toast four seconds ago
        -- deserves to be told how long he has left.
        warnRepeatSeconds = 3.0,

        -- There is deliberately NO placement grace of its own here. The bounds
        -- rule reuses the one `placeAt` already writes on every player it moves
        -- (`lobby.placementGraceMs`), so there is one window to reason about
        -- rather than two that can drift apart. Match spawns are additionally
        -- covered by `match.spawnSettleMs`, which the tick honours before any
        -- rule runs at all.
    },

    -- ------------------------------------------------------------ roadblock --
    --
    -- Design §5.5 item 5. The cop's one active ability, and the only thing in
    -- the mode that spends bankable resource rather than driving skill.
    roadblock = {
        enabled = true,

        chargeSeconds = 60.0,
        -- One in hand, never a stockpile. Banking three roadblocks and dropping
        -- them in a wall would end matches without a chase in them.
        maxCharges = 1,

        -- "roughly 200 m along the runner's current heading" (§5.5.5).
        distanceMeters = 200.0,

        -- Heading is DERIVED by differencing two position samples, because
        -- `Open77.players.position` returns `{ x, y, z, bucket }` and nothing
        -- else -- there is no server-side facing. Two rules keep that honest:
        -- samples must be this far apart in time, and the runner must have
        -- covered this much ground between them. A stationary runner yields no
        -- direction at all rather than a direction made of replication jitter.
        headingSampleMs = 1000,
        headingMinMeters = 4.0,

        -- How long a derived heading stays usable.
        --
        -- `state.headingAtMs` was recorded and never read. Measured offline on
        -- 2026-08-26: after 90 s of a runner standing perfectly still the
        -- direction was still reported `(measured)` and a blockade was thrown
        -- 200 m along a bearing from another part of the match. Past this age
        -- the heading is treated as ABSENT and `blockDirection` falls through
        -- to `away_from_cop`, which is a guess about the present rather than a
        -- fact about the past.
        --
        -- 6 s, for two reasons that agree. It is the staleness threshold the
        -- HUD already applies to a scanner fix (`STALE_MS` in
        -- resources/gamemodes/pursuit_hud/web/index.html), so the mode has one idea of
        -- "too old to act on" rather than two. And a heading only exists above
        -- `headingMinMeters / headingSampleMs` = 4 m/s, so 6 s is at least 24 m
        -- of travel -- far enough for a turn to have made the old bearing a
        -- lie. Shorter would discard good headings across ordinary replication
        -- gaps; much longer reopens the 90 s bug in slow motion.
        headingMaxAgeMs = 6000,

        -- Never drop a blockade on top of the runner, whatever the heading says.
        minDistanceMeters = 60.0,

        -- ------------------------------------------------------- containment --
        --
        -- Two limits on how far the throw may actually go. Both SHORTEN the
        -- throw where they can and REFUSE where they cannot, and a refusal
        -- never costs the cop his charge -- `spendCharge` debits only on
        -- success. A blockade nobody can legally reach is worse than no
        -- blockade, because the cop paid a minute for it.

        -- Keep the blockade inside the arena.
        --
        -- Measured offline 2026-08-26: a runner 640 m from the centre of a
        -- 600 m arena got a blockade 840 m out -- 240 m into ground neither
        -- player may legally drive to -- and it cost the cop his one charge.
        --
        -- 25 m of margin because the blockade is not a point: two cars abreast
        -- at 3.6 m spacing with NPCs 2.5 m behind puts the furthest entity
        -- about 4 m from the centre, and the rest is room for the runner to be
        -- pushed AT it without the whole encounter happening on the boundary
        -- line -- where he would be warned for leaving the zone by the very
        -- obstacle placed to stop him.
        arenaMarginMeters = 25.0,

        -- Bound the damage done by `centre.z = runner.z`.
        --
        -- There is no ground query on the server and Lua cannot raycast, so the
        -- blockade takes the runner's own altitude 200 m away. On the only
        -- slope ever surveyed in this mode -- the promenade deck, 11.7% -- that
        -- is a 23 m error over the throw, about seven storeys, and what lands
        -- is scenery in the sky.
        --
        -- The gradient of the runner's RECENT PATH is inferred from the same
        -- position samples the heading is derived from, and the throw is
        -- shortened until the implied vertical error fits in
        -- `maxVerticalErrorMeters`. This bounds the error; it does not remove
        -- it, and it can say nothing at all about ground the runner has not
        -- yet driven over.
        --
        -- 4.0 m because that is roughly one storey and comfortably more than
        -- the height of the Cortes the blockade is made of: at that error the
        -- blockade is embedded in the road or hovering just above it -- ugly,
        -- and still an obstacle in the right place.
        maxVerticalErrorMeters = 4.0,

        -- ...and above this gradient, refuse outright rather than shorten.
        --
        -- 6% is the standard maximum sustained grade for a motorway, so above
        -- it we are demonstrably not on the kind of road a 200 m straight-line
        -- extrapolation describes -- a ramp, a spiral, or the promenade.
        --
        -- The two numbers are deliberately consistent rather than independent:
        -- at exactly 6% the shortened throw is 4.0 / 0.06 = 66.7 m, which is
        -- still above `minDistanceMeters` (60 m). So every gradient this rule
        -- accepts yields a legal distance, and every gradient it refuses is one
        -- where shortening would have had to break the "never on top of the
        -- runner" rule to help. Changing either number without re-checking
        -- `maxVerticalErrorMeters / (maxGradePercent/100) > minDistanceMeters`
        -- breaks that property.
        maxGradePercent = 6.0,

        -- A gradient, like a heading, is only worth trusting while it is fresh,
        -- and for the same reason: it describes ground the runner was on, not
        -- ground he is on. Same 6 s, same argument as `headingMaxAgeMs`.
        gradeMaxAgeMs = 6000,

        -- ...and only once there is more than one differenced pair behind it.
        --
        -- "Never decide on a single position sample" is a house rule, and a
        -- gradient is more jitter-prone than a bearing: replication noise of a
        -- few centimetres in z over a 4 m step is already a 1% grade. Three
        -- pairs, folded into a moving average, is the cheapest thing that is
        -- not one reading. Below this the gradient is treated as UNKNOWN.
        --
        -- An unknown gradient is NOT treated as flat ground. Absence of
        -- evidence is not evidence of a slope, but it is not evidence of level
        -- ground either, and the throw is contained on the worst case this rule
        -- would still accept: `maxGradePercent`. See the long note in
        -- roadblock.lua -- a forced blockade that threw the full 200 m on
        -- `no_samples` landed in a void, which is what closed this hole.
        gradeMinSamples = 3,

        vehicles = {
            record = "Vehicle.ncpd_villefort_cortes_heat_1",
            fallbackRecord = "Vehicle.v_standard2_villefort_cortes_player",
            count = 2,
            spacingMeters = 3.6,
            -- Across the runner's path, not along it: a blockade is a wall.
            yawOffsetDegrees = 90.0,
            lightsOn = true,
            sirenOn = true,
        },

        npcs = {
            -- wiki/npcs.md puts exactly two templates on the server allowlist:
            -- `civilian_female_relaxed_01` and `hostile_female_ranged_lab`, and
            -- says of the hostile one that "native combat remains
            -- experimental". A roadblock does not have to shoot to be a
            -- roadblock -- it has to be IN THE WAY. So the blockade is staffed
            -- with the stable template, frozen and immortal: scenery with a
            -- silhouette, not an unvalidated combat path in the middle of a
            -- live match.
            template = "civilian_female_relaxed_01",
            count = 2,
            -- Behind the cars, from the runner's point of view.
            behindMeters = 2.5,
            spacingMeters = 2.0,
        },

        -- A blockade the runner has already driven past is dead weight the
        -- server keeps replicating. Clean it up rather than letting a six
        -- minute match accumulate six of them.
        lifetimeSeconds = 120.0,
    },

    -- ------------------------------------------------------------- RANKED --
    --
    -- Owner, 2026-08-26: "on fait un systeme de rank, on monte en pts quand on
    -- gagne et quand on perd ca descend ? une espece de ranked ?"
    --
    -- The maths is Elo, and server/ranked.lua opens with the argument for why
    -- it is Elo and not a counter. The short version: a counter measures how
    -- OFTEN you play, Elo measures how often you beat what you were expected
    -- to beat, and only the second one makes beating a strong player worth
    -- more than farming a weak one.
    --
    -- Every value below is read FRESH at the start of each match and clamped
    -- to the range in its comment, so any of them can be turned from a live
    -- config editor without a reload and without a typo putting the ladder
    -- into a state the arithmetic does not survive. A change never applies
    -- retroactively: ratings already banked stay where they are.
    ranked = {
        -- Off means no rating is computed, recorded or announced. Matches play
        -- exactly as before.
        enabled = true,

        -- Where a new player starts. 1000..1200 are the conventional choices;
        -- the number itself means nothing, only distances between numbers do.
        -- Moving it does NOT move anybody already rated, so a server that has
        -- played matches should leave it alone -- newcomers would be joining a
        -- different scale from everyone else.
        -- Range 100..5000.
        startRating = 1000,

        -- The Elo spread, the classic D = 400: a player 400 points ahead is
        -- expected to win 10 games out of 11. LOWER makes the ladder steeper
        -- (a smaller gap already implies a near-certain result, so upsets pay
        -- more and expected wins pay less); HIGHER flattens it. 400 unless
        -- there is evidence to move it.
        -- Range 50..2000.
        spread = 400.0,

        -- How far a settled player's rating can move in one match. A 50/50
        -- match at K=20 moves +-10, which is 1% of the starting rating: ten
        -- matches meaningfully relocate you, one match does not define you.
        -- Raise it for a livelier ladder on a small server, lower it for a
        -- steadier one.
        -- Range 1..100.
        baseK = 20.0,

        -- The provisional K, used for a player's first `provisionalMatches`
        -- rated matches, then dropped to `baseK`.
        --
        -- This is the one thing Glicko would otherwise be needed for. A new
        -- player's rating is a guess, so it should be cheap to move; a settled
        -- player's rating is evidence, so it should not be. At 40 over ten
        -- matches a newcomer can travel +-200 and land near his real level
        -- instead of grinding towards it for a month.
        -- Range 1..200.
        provisionalK = 40.0,

        -- How many rated matches count as provisional. 0 disables the whole
        -- idea and everyone always uses `baseK`.
        -- Range 0..100.
        provisionalMatches = 10,

        -- The rating nobody can fall below. A ladder with no floor sends the
        -- weakest player to an ever more meaningless negative number, and a
        -- floor is also the cheapest protection against a losing streak
        -- reading as a punishment. Clamped to `startRating` if set above it.
        --
        -- Note that the floor breaks the zero-sum property: a player at the
        -- floor loses less than his opponent gains. That is intended, and it
        -- is why the floor is well below the start rather than just under it.
        -- Range 0..5000.
        floorRating = 100,

        -- The smallest movement a DECISIVE result may produce. Without it, a
        -- large enough rating gap rounds the favourite's win to zero and the
        -- ladder looks broken -- and worse, becomes free to farm. Draws are
        -- exempt: a draw that computes to zero really is zero.
        -- Range 0..50.
        minDelta = 1,

        -- What a disconnect mid-match costs the leaver, as a multiplier on his
        -- LOSS only (the survivor's gain is never inflated -- that would make
        -- being left a way to farm points).
        --
        -- 1.0, i.e. an abandonment is rated exactly as a loss, and that is a
        -- deliberate choice rather than a placeholder: a rage-quit, a crash
        -- and an ISP blip all reach the gamemode as the same event with no
        -- reason attached, so the server genuinely cannot tell them apart.
        -- Punishing all three as rage-quits would be punishing crashes. The
        -- requirement -- a player losing must not escape the loss by leaving --
        -- is already met at 1.0, and match.lua awards the match to whoever
        -- stayed regardless of the scoreline.
        --
        -- CLAMPED AT 1.0 FROM BELOW in code: a leaver must never lose less by
        -- leaving than by playing it out. Raise it only once a disconnect
        -- reason exists to justify it.
        -- Range 1.0..3.0.
        abandonPenaltyScale = 1.0,

        -- Rate a match abandoned before a single round finished?
        --
        -- false: nobody played anything, so nobody is rated. The alternative
        -- turns a crash during the first countdown into a full loss, which is
        -- the one case where "he was losing and ran" cannot possibly be true.
        rateUnplayedForfeit = false,

        -- Send each player a notification with his new rating and the change
        -- after every rated match.
        announce = true,

        -- How many rows `pursuit.rank top` prints.
        -- Range 1..25.
        leaderboardSize = 10,

        -- Refuse to rate at all when the database bridge is off, rather than
        -- keeping a ladder in memory that dies with the server.
        --
        -- false by default because a visible, honestly-labelled volatile
        -- ladder is more useful during development than no ladder -- every
        -- surface that prints a rating also prints "VOLATILE, no database"
        -- when the bridge is down. Set it true on a server where a temporary
        -- database outage must not produce numbers players might trust.
        requireDatabase = false,

        -- NO INACTIVITY DECAY, deliberately, and there is no dial for one.
        --
        -- Decay exists to stop a dormant account squatting the top of a large
        -- ladder. This ladder has a handful of regulars, where the only thing
        -- decay achieves is charging people for not playing -- the exact
        -- volume-over-skill defect Elo was chosen to avoid, applied backwards.
        -- The `last_match_at` column is written anyway, so the day the
        -- playerbase justifies decay it is a rule to add and not a migration.
    },

    -- How often the server re-derives rules from replicated positions. The
    -- conditions above are all "held for N seconds", so a 5 Hz sample is ample
    -- and never decides anything on a single reading.
    tickHz = 5,

    debug = {
        -- Log every accepted and refused queue intent.
        verboseQueue = true,
        -- Log the separation and both accumulators on every match tick. Very
        -- noisy at 5 Hz -- read `pursuit.match` instead unless a win condition
        -- is actually misbehaving.
        verboseMatch = false,
        -- One line per scanner ping. Once per 4-8 s per match, so this one is
        -- cheap enough to leave on while the mechanic is being verified.
        verboseScanner = true,
        -- One line per bounds warning and bust, never per tick. Silent while
        -- everyone stays inside the arena.
        verboseArena = true,
    },

    -- ======================================================================
    -- TUNABLES -- the numbers a SERVER OWNER may move from the Warden panel
    -- ======================================================================
    --
    -- Everything in this table is rendered by Warden's Tuning tab as a
    -- labelled, bounded control, and written back through the same validation
    -- this file gets. Nothing parses or rewrites Lua: the panel can only ever
    -- set a key declared here, to a value inside the bounds declared here.
    -- docs/writing-a-gamemode.md #8 is the contract; docs/lua-resources.md
    -- "Operator-tunable settings" is the field reference.
    --
    -- THREE THINGS TO KNOW BEFORE ADDING A ROW.
    --
    -- 1. THE DECLARATION LIVES HERE, THE `declare` CALL DOES NOT.
    --    `Open77.tunables` exists on the SERVER only, and this file is a
    --    shared_script that every connecting client downloads. A `declare`
    --    call here would fail on every client and the whole resource set would
    --    be refused. `server/main.lua` makes the call; this table is data.
    --    Which also means every word below is PUBLISHED -- keep it publishable.
    --
    -- 2. A DEFAULT THAT BREAKS ITS OWN RULES REFUSES THE RESOURCE AT START.
    --    Not a warning, not a clamp: the host would rather Pursuit not run
    --    than run on a value its own panel could never restore. Check every
    --    `value` against its own `min`/`max` before saving this file.
    --
    -- 3. THESE VALUES SUPERSEDE THE NUMBERS ABOVE, IN BOTH COLUMNS.
    --    `server/match.lua tuning()` overlays a match's captured tunables onto
    --    `Config.match.foot` / `Config.match.vehicle`, so for every key named
    --    here the column's own figure is dead at runtime and the value below
    --    is what a match plays by. That is deliberate -- an operator who reads
    --    "15 m" in the panel must get 15 m, whichever mode he switched to --
    --    but it has a real cost, stated plainly: FOOT MODE NO LONGER HAS ITS
    --    OWN CHASE NUMBERS. The tuned foot figures (8 m bust, 3 m core, 3 s
    --    fill, 5 s drain, 8 s escape arm, 5 s head start) survive in
    --    `Config.match.foot` above, with the reasoning that produced them, and
    --    they are what an operator should type into the panel if he sets
    --    `matchMode` to foot.
    --
    -- APPLY TIMING. Everything that can decide a round is `next_match`, and
    -- `server/match.lua` promotes at match creation and immediately captures
    -- the whole set onto the new match (`match.tune`). So a change is stored
    -- and persisted the moment it is made, reaches the NEXT match to be
    -- created, and can never move the finish line under two people already
    -- chasing each other -- including a match running in another routing
    -- bucket at the same time, which is why this mode captures rather than
    -- relying on `promote()` alone.
    --
    -- WHAT IS DELIBERATELY NOT HERE, and why. Each of these is either a value
    -- where a wrong number breaks the mode rather than rebalancing it, or one
    -- read in a file this change does not own -- and a tunable that nothing
    -- reads is a panel that lies:
    --
    --   * `match.spawns`, `vehicles.spawns`, every coordinate and heading --
    --     surveyed ground. A number typed by feel here puts a player through
    --     the floor or a car into a pillar, and the server cannot detect it.
    --   * `match.spawnLiftMetres` -- 0.35 m sits between one stair riser and
    --     the 0.55 m read bias, for reasons measured in game; outside that
    --     band it wedges players inside geometry, which costs a reconnect.
    --     Its own note above says measure, do not guess. That is not a
    --     setting, it is a survey result.
    --   * `match.spawnSettleMs`, `lobby.placementGraceMs`,
    --     `match.positionStaleResetMs`, `tickHz` -- mechanism timing tied to
    --     the respawn fade and the replication rate. Wrong values make rules
    --     unreadable, or trip the leash on the act of placing someone.
    --   * `vehicles.*` records, colours and offsets -- a bad record id is a
    --     car that does not spawn, not a slower car; the offsets are geometry
    --     with a driver-door assertion behind them.
    --   * scanner, roadblock, arena and ranked -- all genuinely tunable, and
    --     all read in `server/scanner.lua`, `server/roadblock.lua`,
    --     `server/bounds.lua` and `server/ranked.lua`, which this change does
    --     not own. Declaring them without wiring the read would put controls
    --     in the panel that move nothing. They are the obvious next batch.
    --     The scanner's pressure band is the exception that already follows:
    --     it is a MULTIPLE of `bustDistance`, so tuning the bust radius moves
    --     the band with it.
    --   * `debug.*` -- developer switches, not balance.
    --   * `weather` -- there is no delivery path from this resource's VM to
    --     `open77_weather`; see the long note on that block above.
    tunables = {
        -- ---------------------------------------------------------- Chase --
        bustDistance = {
            value = 15.0, min = 5.0, max = 60.0, step = 0.5,
            unit = "m", apply = "next_match",
            label = "Bust radius", group = "Chase", order = 1,
            description = "How close the cop must be for the pursuit meter to fill. It is measured between the two cars' centres, so it has to be comfortably longer than a car: at 5 m a cop whose bumper is touching cannot fill the meter at all, and only a runner who stops completely is ever caught.",
        },
        bustCoreDistance = {
            value = 6.0, min = 0.0, max = 30.0, step = 0.5,
            unit = "m", apply = "next_match",
            label = "Bumper range", group = "Chase", order = 2,
            description = "Inside this range the meter fills at the full bonus rate, tapering back to normal out at the bust radius. About one car length, so a cop who is genuinely on his man is paid more than one shadowing him at arm's length. To switch the grading off entirely, set the bumper bonus below to 1.0 rather than setting this to 0 -- at 0 the bonus still tapers all the way out from the bumper.",
        },
        bustCoreFactor = {
            value = 1.6, min = 1.0, max = 3.0, step = 0.1,
            unit = "x", apply = "next_match",
            label = "Bumper bonus", group = "Chase", order = 3,
            description = "How much faster the meter fills at bumper range than out at the edge of the bust radius. 1.0 turns the bonus off and makes every distance inside the radius identical; 1.6 makes a bumper tail worth about three seconds where an edge tail costs five.",
        },
        bustFillSeconds = {
            value = 5.0, min = 1.0, max = 20.0, step = 0.5,
            unit = "s", apply = "next_match",
            label = "Bust time", group = "Chase", order = 4,
            description = "How long the arrest conditions must hold to win the round, measured at the edge of the bust radius: cop inside the radius, runner at or under his arrest speed, cop at or under his. Long enough that it cannot happen in passing; short enough that a cop who has genuinely pinned his man is not asked to babysit him for a whole block.",
        },
        bustDrainSeconds = {
            value = 8.0, min = 1.0, max = 30.0, step = 0.5,
            unit = "s", apply = "next_match",
            label = "Bust recovery", group = "Chase", order = 5,
            description = "How long the runner must stay outside the bust radius to wipe a full meter. Keep it SLOWER than the bust time: time spent close was earned, time spent apart is often just a corner or a truck. Much slower and the meter becomes a ratchet the runner can never clear.",
        },
        bustRunnerMaxSpeedKph = {
            value = 12.0, min = 0.0, max = 120.0, step = 1.0,
            unit = "km/h", apply = "next_match",
            label = "Arrest speed (runner)", group = "Chase", order = 10,
            description = "The meter only fills while the runner is at or under this speed: a cop glued to a moving car is tailing, not arresting. 12 km/h means a runner creeping in traffic or backing off a wall is caught, while any honest attempt to drive away stops the fill within a second. Set it very high to restore the old behaviour where proximity alone filled the meter.",
        },
        bustCopMaxSpeedKph = {
            value = 30.0, min = 0.0, max = 200.0, step = 1.0,
            unit = "km/h", apply = "next_match",
            label = "Arrest speed (cop)", group = "Chase", order = 11,
            description = "The cop must also be at or under this speed for the meter to fill -- driving through the radius at full tilt is not an arrest. 30 km/h lets him roll to a stop beside his man without losing the opening seconds. On foot, set it above sprint speed so running the runner down still counts.",
        },
        bustContactDrainSeconds = {
            value = 30.0, min = 1.0, max = 120.0, step = 1.0,
            unit = "s", apply = "next_match",
            label = "Contact drain", group = "Chase", order = 12,
            description = "How long a full meter takes to bleed away while the cop is INSIDE the bust radius but the arrest conditions are not met (the tailing-at-speed state). Keep it much slower than the recovery below: it is what lets repeated short stops add up instead of evaporating between pins. The runner clears the meter properly by breaking contact, which drains at the ordinary recovery rate.",
        },
        crashStallSeconds = {
            value = 3.0, min = 0.0, max = 15.0, step = 0.5,
            unit = "s", apply = "next_match",
            label = "Crash stall", group = "Chase", order = 13,
            description = "A hard crash stalls the engine for this long, both roles alike: a stalled runner counts as caught for the whole window even if he gets rolling again, and a stalled cop cannot arrest anyone. This is what turns a wall into a bust window. 0 switches the crash rule off entirely.",
        },
        crashMinSpeedKph = {
            value = 45.0, min = 10.0, max = 200.0, step = 5.0,
            unit = "km/h", apply = "next_match",
            label = "Crash speed floor", group = "Chase", order = 14,
            description = "How fast a car must have been going for its sudden stop to count as a crash. Below this a bump is just parking. Raise it if kerbs and traffic taps are stalling people; lower it if genuine wall hits at city speed go unpunished.",
        },
        crashDropKph = {
            value = 40.0, min = 5.0, max = 150.0, step = 5.0,
            unit = "km/h", apply = "next_match",
            label = "Crash speed drop", group = "Chase", order = 15,
            description = "How much speed must vanish, almost at once, for a stop to read as a crash rather than as braking. Full braking sheds about 35 km/h per second, so 40 inside the measuring window means bodywork. Lower it and hard braking starts to stall; raise it and only the most violent crashes count.",
        },
        escapeDistance = {
            value = 100.0, min = 40.0, max = 400.0, step = 5.0,
            unit = "m", apply = "next_match",
            label = "Escape distance", group = "Chase", order = 6,
            description = "Open this much of a gap and the runner wins the round on the spot. Lower ends rounds sooner and favours the runner; higher makes him earn a longer break. The gap between this and the bust radius is the corridor the whole chase happens in.",
        },
        escapeGraceSeconds = {
            value = 18.0, min = 0.0, max = 60.0, step = 0.5,
            unit = "s", apply = "next_match",
            label = "Escape window", group = "Chase", order = 7,
            description = "How long the runner must stay beyond the escape distance to win the round. Crossing the line starts a visible meter instead of ending the round on the spot, so the cop gets this long to pull the gap back under the limit and cancel the attempt; if he cannot, the runner has escaped. 18 is the middle of the owner's 15-20 second bracket. 0 restores the old instant escape. It replaces the retired 'Escape hold', whose progress reset the moment the gap dipped -- this one drains instead, at the recovery rate below.",
        },
        escapeDrainSeconds = {
            value = 6.0, min = 0.5, max = 60.0, step = 0.5,
            unit = "s", apply = "next_match",
            label = "Escape recovery", group = "Chase", order = 8,
            description = "How long the cop must hold the gap back under the escape distance to wipe a full escape attempt. Keep it well FASTER than the escape window -- the opposite asymmetry to the bust meter, because an escape ends the round: pulling the runner back under the line is the cop's whole comeback and has to pay at once, and a fast drain is what makes hovering on the line a losing strategy (at 6 against 18 the runner must spend over three quarters of his time beyond the line just to hold level). Raise it toward the window and boundary-flapping starts to pay.",
        },
        escapeArmSeconds = {
            value = 15.0, min = 0.0, max = 60.0, step = 1.0,
            unit = "s", apply = "next_match",
            label = "Escape delay", group = "Chase", order = 9,
            description = "How long after the start of a round the escape rule is switched on. Nobody is sitting in a car when a round begins, so without this the opening is decided by whoever gets in first. The cop can still bust inside it. Raise it if a runner keeps banking escape progress before the chase exists.",
        },

        -- ---------------------------------------------------------- Round --
        durationSeconds = {
            value = 180, type = "integer", min = 30, max = 900, step = 10,
            unit = "s", apply = "next_match",
            label = "Round length", group = "Round", order = 1,
            description = "How long one chase lasts. When it runs out with no completed escape, the round goes to whoever 'Clock favours' names -- the cop by default, so the clock is the cop's ally and the runner has to actually break away. Remember that a match is several rounds, so a sitting lasts this multiplied by the rounds per match.",
        },
        headStartSeconds = {
            value = 0, type = "integer", min = 0, max = 60, step = 1,
            unit = "s", apply = "next_match",
            label = "Head start", group = "Round", order = 2,
            description = "How long the cop is asked to hold his ground before the hunt begins. 0 in cars, because with a 100 m escape any head start at all IS an escape and the round would be decided before the chase began. Raise it only together with a much larger escape distance.",
        },
        countdownSeconds = {
            value = 10, type = "integer", min = 5, max = 60, step = 1,
            unit = "s", apply = "next_match",
            label = "Countdown", group = "Round", order = 3,
            description = "The beat between a round being set up and it going live. Both players are placed and both cars are created inside it, so it is the budget for the respawn fade -- shorten it much and players start a round still fading in.",
        },
        intermissionSeconds = {
            value = 8.0, min = 1.0, max = 60.0, step = 1.0,
            unit = "s", apply = "next_match",
            label = "Between rounds", group = "Round", order = 4,
            description = "How long the scoreboard sits between rounds. More happens here than 'you won': the roles swap, both cars are destroyed and rebuilt, and both players are moved to the other end of the map. Too short and the beat reads as a hang.",
        },
        copHoldRadius = {
            value = 25.0, min = 5.0, max = 200.0, step = 5.0,
            unit = "m", apply = "next_match",
            label = "Head start leash", group = "Round", order = 5,
            description = "How far the cop may stray from his mark during a head start before he is warned. It is a warning and nothing more -- what is actually enforced is that no progress towards a bust counts before he is released. Irrelevant while the head start is 0.",
        },

        -- ---------------------------------------------------------- Match --
        matchMode = {
            value = "vehicle", choices = { "foot", "vehicle" },
            apply = "next_match",
            label = "Chase on", group = "Match", order = 1,
            description = "Whether a new match is a car chase or a foot chase. Vehicle is what Pursuit is; foot needs no cars to be correct and is the honest fallback when they misbehave. Both run on the chase numbers above, so retune those if you switch.",
        },
        roundsPerMatch = {
            value = 2, type = "integer", min = 1, max = 9, step = 1,
            apply = "next_match",
            label = "Rounds per match", group = "Match", order = 2,
            description = "How many chases make up a match. The roles swap between rounds, so only an EVEN number gives both players the same number of turns as the cop; an odd one hands the extra cop round to whoever the rotation favours. 1 gives the old single-chase match.",
        },
        tieBreak = {
            value = "decider", choices = { "draw", "decider" },
            apply = "next_match",
            label = "If it is level", group = "Match", order = 3,
            description = "What a level match is. 'decider' (the default -- the owner's call, 2026-08-28: a level match plays a third, sudden-death round) settles it in one more round, with the roles following the same swap rotation: round three replays round one's sides, which both players can see coming from the moment it is level. 'draw' calls one-each a result and lets them run it back.",
        },
        deciderDurationSeconds = {
            value = 0, type = "integer", min = 0, max = 900, step = 10,
            unit = "s", apply = "next_match",
            label = "Decider length", group = "Match", order = 6,
            description = "How long the sudden-death round lasts. 0 -- the default -- means exactly as long as any other round: the decider already has a natural end (the clock expiring goes to whoever 'Clock favours' names, the cop by default), and a shorter clock now tilts the decider toward the COP rather than the runner. Set a shorter time only when you want faster sittings and accept that tilt.",
        },
        copDeathEndsMatch = {
            value = true, apply = "next_match",
            label = "A dead cop ends the round", group = "Match", order = 4,
            description = "On, a cop who dies hands the round to the runner, mirroring the runner dying handing it to the cop. Off, the runner has to see the clock out against nobody. Turn it off if players start dying on purpose to end a round they are losing.",
        },
        timeoutWinner = {
            value = "cop", choices = { "cop", "runner" },
            apply = "next_match",
            label = "Clock favours", group = "Match", order = 7,
            description = "Who takes the round when the clock runs out with no completed escape and no bust. 'cop' -- the default since 2026-08-30, the owner's call: the runner must actually shake the cop to win, and merely surviving the timer is not an escape -- makes the clock the cop's ally. 'runner' restores the survival rule, where outlasting the hunt is itself the win. Either way, an attempt already underway at the buzzer -- an escape meter filling, an arrest closing -- plays out as sudden-death overtime instead of being cut: it ends the moment the attempt completes or breaks.",
        },
        unstickWindowSeconds = {
            value = 20.0, min = 0.0, max = 120.0, step = 5.0,
            unit = "s", apply = "next_match",
            label = "Unstick window", group = "Match", order = 5,
            description = "How far into a round a player may ask to be put back on his own mark after spawning inside geometry. It must stay in the opening seconds: later on it becomes a way for a cornered runner to erase the work the cop has done. 0 disables the command outright.",
        },

        -- ------------------------------------------------------- Vehicles --
        --
        -- The one lever the roster never had. `shared/roster.lua` balances the
        -- cars by CURATION -- one chassis class, no mixing -- because when it
        -- was written nothing on the platform could cap a car. Something can
        -- now, and these two numbers drive it. Both are applied by
        -- `server/performance.lua` across every record in the roster, so they
        -- cover the picker's twelve cars and any car it grows, not a hardcoded
        -- pair.
        --
        -- WHAT THE MEASUREMENTS SAY, because the default only makes sense with
        -- them. Two roster cars have a rated top speed on record:
        -- `v_standard2_archer_hella_player` (the runner's) at 115 km/h and
        -- `ncpd_villefort_cortes_heat_1` (the cop's) at 140. A ceiling only
        -- equalises anything if it sits at or below the SLOWER of the two --
        -- anything above 115 clips the Cortes and leaves the Hella exactly as
        -- it was, which is a nerf to one car rather than a level field.
        --
        -- BOTH ARE `next_match`, and that is not caution for its own sake:
        -- moving a speed ceiling under two people already mid-chase is the
        -- precise class of change the capture mechanism exists to prevent.
        topSpeedKph = {
            value = 110.0, min = 0.0, max = 300.0, step = 5.0,
            unit = "km/h", apply = "next_match",
            label = "Top speed cap", group = "Vehicles", order = 1,
            description = "The ceiling every roster car is held to, cop and runner alike, so no round is decided by which record spawned. The two measured cars rate 115 and 140 km/h: a cap above 115 clips only the faster one and equalises nothing, so keep it under 115. 110 leaves a little margin so it binds on the slower car too. 0 switches the governor off and restores every stock top end.",
        },
        throttleAuthority = {
            value = 1.0, min = 0.2, max = 1.0, step = 0.05,
            unit = "x", apply = "next_match",
            label = "Throttle authority", group = "Vehicles", order = 2,
            description = "How much of the throttle a driver actually gets, at every speed. 1.0 is stock pickup, and the default. Lower it to make a chase about lines rather than about flooring it. The honest limit: it scales EVERY roster car by the same factor, so it does not close the LAUNCH gap between two of them -- the Hella still out-drags the Cortes, just more slowly.",
        },

        -- ---------------------------------------------------------- Lobby --
        lobbyRadius = {
            value = 50.0, min = 20.0, max = 50.0, step = 1.0,
            unit = "m", apply = "live",
            label = "Lobby radius", group = "Lobby", order = 1,
            description = "How far from the lobby centre a waiting player may wander before he is warned and then returned. It cannot exceed 50 m: both ways of drawing the boundary clamp there, so a wider leash would enforce a line nobody can see. Takes effect at once, since the leash judges nobody mid-chase.",
        },
        leashWarnSeconds = {
            value = 4.0, min = 1.0, max = 60.0, step = 1.0,
            unit = "s", apply = "live",
            label = "Lobby warning after", group = "Lobby", order = 2,
            description = "How long a player may stand outside the lobby before he is told to come back. Keep it below the return delay, or he is dragged back before he has been warned about anything.",
        },
        leashReturnSeconds = {
            value = 10.0, min = 2.0, max = 300.0, step = 1.0,
            unit = "s", apply = "live",
            label = "Lobby return after", group = "Lobby", order = 3,
            description = "How long a player may stay outside the lobby before he is put back in it. Counted from the moment he left rather than from the warning, so it should be comfortably more than the warning delay.",
        },
        lobbySpawnSpacing = {
            value = 2.0, min = 1.2, max = 5.0, step = 0.1,
            unit = "m", apply = "live",
            label = "Lobby spawn spacing", group = "Lobby", order = 4,
            description = "The minimum distance between the lobby spawn slots that placements scatter over, so two players placed together never share a point and get shoved apart by physics. It is the ring step and the gap between neighbours at once. Below about 1.2 m capsules touch again; much above 3 m the outer rings start reaching ground the lobby survey never measured. Live, because it only shapes FUTURE placements -- players already standing keep the spot they have.",
        },

        -- ---------------------------------------------------------- Queue --
        rematchWindowSeconds = {
            value = 180, type = "integer", min = 0, max = 3600, step = 10,
            unit = "s", apply = "live",
            label = "Role swap window", group = "Queue", order = 1,
            description = "How long two players who have just played each other keep their sides remembered, so that meeting again swaps cop and runner. Generous on purpose: it only decides which side each takes, never who is matched with whom. 0 turns the swap off.",
        },
        rematchPairWindowSeconds = {
            value = 30, type = "integer", min = 0, max = 600, step = 5,
            unit = "s", apply = "live",
            label = "Rematch queue jump", group = "Queue", order = 2,
            description = "How long after a match two players who both re-queue are paired with EACH OTHER instead of with whoever has waited longest. A favour to a pair visibly still playing the same best-of-two; minutes later the fair answer is first come, first served. 0 turns it off.",
        },
        maxConsecutiveRematches = {
            value = 2, type = "integer", min = 0, max = 20, step = 1,
            apply = "live",
            label = "Queue jumps in a row", group = "Queue", order = 3,
            description = "How many times in a row the same two players may jump the queue to reach each other before they go back to first come, first served. Without a cap, two who keep re-queueing hold the front of the queue against a third indefinitely.",
        },
    },
}
