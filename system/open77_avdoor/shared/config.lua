-- =============================================================================
-- open77_avdoor -- shared/config.lua
-- =============================================================================
-- Every number the aircraft door reads. This file is downloaded by clients, so
-- it holds no secret and no access list. Edit it and `ensure open77_avdoor`.
--
-- Ported from the XyberRP servers (opx_infinity `config/avdoor.lua`), where
-- each block below was measured in play before it was written down; the notes
-- keep what was measured, because a number nobody can explain gets "tidied"
-- back into the bug it fixed.
--
-- THE BASE GAME HAS NO WAY INTO AN AIRCRAFT. V boards an AV in a scene, never
-- through an interaction, so a hull standing on a pad or a rooftop offers no
-- "enter" at all: once a pilot stepped out, the aircraft was a statue. This
-- resource is that door, for every aircraft -- and the other things that
-- happen at an aircraft's door: the exit, the doors swinging for everybody,
-- the MaxTac AV's own voice, the landing call and the landing pad.
-- =============================================================================

Open77AvDoorConfig = {
    -- WHICH RECORDS ARE AIRCRAFT. Lua patterns, matched against the vehicle's
    -- TweakDB record (lower-cased). The client's flight code decides which
    -- records FLY (`Vehicle.av_*` and `Vehicle.max_tac_av`); this list only
    -- decides which hulls get a door.
    RECORDS = { '^vehicle%.av_', '_av$', '_av%d+$', '_av_', '_heli$', 'max_tac_av' },

    -- Metres from the hull's centre, measured by the SERVER against its own
    -- canonical transform. An AV is ten metres long and its door is beside the
    -- cockpit: nine metres from the centre is a walk to the door.
    REACH_METRES = 9.0,

    -- Metres per second above which a hull is "moving" and has no door. A
    -- parked aircraft reads zero (the motion facts are zeroed with the lease).
    REST_SPEED = 2.0,

    -- WHO MAY TAKE THE CONTROLS of an aircraft no resource registered a rule
    -- for (`exports.open77_avdoor:allow`):
    --   'anyone'     -- anybody, when the hull is not locked for them: the same
    --                   rule a ground car follows, the lock is the access list;
    --   'registered' -- only the pilots a resource named; everybody else may
    --                   only ride along (PASSENGERS).
    PILOTS = 'anyone',

    -- The seats a pilot fills, in order, and the ones a passenger may take.
    -- The flight controls are at `seat_front_left`, so it is first, and a
    -- passenger is never offered it.
    SEATS = { 'seat_front_left', 'seat_front_right', 'seat_back_left', 'seat_back_right' },

    -- Whether somebody who may not fly a hull may ride along in a free
    -- passenger seat of it, when it is not locked for them. A rule a resource
    -- registered can close its passenger seats with `passengers = false`.
    PASSENGERS = true,

    -- THE DOOR THE SEAT USES, by the platform's door names
    -- (`Open77.vehicles.openDoor`: frontLeft, frontRight, backLeft, backRight).
    -- The server opens it as a body boards and as one steps out, and every
    -- viewer sees it: the door state is canonical and replicated, unlike the
    -- client's own local actuation. A door the model does not animate is a bit
    -- that changes and nothing that moves, which is harmless.
    DOORS = {
        seat_front_left = 'frontLeft',
        seat_front_right = 'frontRight',
        seat_back_left = 'backLeft',
        seat_back_right = 'backRight',
    },

    -- BOARDING. The press opens the seat's door and the body is seated
    -- `DELAY_MS` later, judged again then -- a body stepping in through an open
    -- door rather than a pop. `HOLD_MS` is how long the door stays open after
    -- the body is in.
    BOARD = {
        DELAY_MS = 450,
        HOLD_MS = 1500,
        -- A HULL THAT HAS JUST APPEARED IS NOT BOARDED YET. Measured on
        -- XyberRP (2026-10-03): a pilot seated 0.3 s after the hull appeared
        -- flew the whole flight in an AV the engine still drew on the pad
        -- (`hullTrailM` 14-17 m, where a working flight trails by
        -- centimetres) -- the projection had not settled (the lift's drop
        -- onto the ground, the record's appearance swapped in, the observer
        -- physics handed over). Every aircraft created on this server is
        -- boarded through the door no sooner than this after it appeared.
        -- `exports.open77_avdoor:settleLeft(id)` tells a resource that seats
        -- pilots itself how long to wait. `0` boards at once.
        SETTLE_MS = 2500,
        -- THE DOOR SHUT IN FLIGHT (1.7.10). An aircraft with somebody aboard
        -- moving faster than `FLIGHT_SPEED` metres a second whose door the
        -- network still holds open has it closed, at the scan (`SCAN_MS`), and
        -- the log says so. The pilot's own game did not close a door the server
        -- closed after the seat (Staging, 2026-10-29, 17:25: closed 16 s after
        -- the seat, open on the pilot's screen the whole flight): a boarding
        -- step closes its door before the seat (`ENTER_ANIM.DOOR_CLOSE_*`), and
        -- this is the guard behind it. `CLOSE_IN_FLIGHT = false` leaves doors.
        CLOSE_IN_FLIGHT = true,
        FLIGHT_SPEED = 2.0,
        -- A BOARDING BEHIND A PILOT (1.8.4). The flight parks an AV its pilot
        -- sits in with its gear 0.4 m off the ground: the Excalibur's door's
        -- step is then 1.07 m up, past the boarding clips' reach, and Corpo V's
        -- climb sits down 0.4 m under the back seat -- a player boarding behind a
        -- pilot was seated plainly. For a boarding, a hull somebody is aboard
        -- that hangs at most `ABOARD_DROP_METRES` over its gear is set down on
        -- it in ONE move, frozen, and held there until every body boarding it
        -- is seated (`ABOARD_HOLD_MS` at most); then the freeze comes off and the
        -- pilot's flight has it again. The pilot's own game sees that one move
        -- as one hand-over of the flight (its chase camera may blink once).
        -- `0`: never -- a boarding behind a pilot on a hull over its gear is
        -- plain, as before 1.8.4.
        ABOARD_DROP_METRES = 1.0,
        ABOARD_HOLD_MS = 20000,
    },

    -- THE KEY on the door's card (open77_interactions). `F`, the gesture a
    -- player already knows for "get in".
    KEY = 'F',

    -- How often the SERVER measures the players on foot against the aircraft
    -- in their bucket. One pass is one `vehicles.all` and one position per
    -- player.
    SCAN_MS = 500,

    -- THE WATCH: WHERE EVERY SCREEN DRAWS AN AIRCRAFT, AND WHERE THE SERVER HAS
    -- IT. Measured on XyberRP (2026-09-30): an AV "driving away on other player
    -- screen going through buildings" and back "to the same spot" when the
    -- pilot moved -- a picture only the OTHER screen had, and no log anywhere
    -- held it. So:
    --   * every client, every `SIGHT_MS`, compares where its engine DRAWS each
    --     aircraft it does not simulate with where the server's last sample put
    --     it, for the nearest `MAX_HULLS` within `RANGE`. Drawn farther than
    --     `DRIFT_METRES` (+ `DRIFT_PER_SPEED` per m/s, because an observer draws
    --     a moving hull a jitter buffer behind its newest sample) opens an
    --     EPISODE: one line in that client's log and one report to the server,
    --     which writes it beside its own reads. Under `SETTLE_METRES` twice in a
    --     row closes it;
    --   * the server journals every change of an aircraft's physics owner and
    --     every canonical move bigger than `JUMP_METRES` between two scans;
    --   * `HEAL`: an EMPTY, unfrozen aircraft a client draws far from where the
    --     server has it is re-published where it stands (`setTransform` to its
    --     own canonical pose), which starts a new authority epoch and makes
    --     every viewer drop its buffered path. At most once per `HEAL_EVERY_MS`
    --     per hull, never with anybody aboard.
    --   * `DRAG_UNDO` (1.6.1): the exit's drag put right. An exit un-masks the
    --     hull on the exiting game, whose engine drags it back to where its
    --     flight began for a fifth of a second -- and that game, simulating the
    --     hull, may send the dragged pose as the hull's own: on Staging
    --     (2026-10-28, 18:20:46) the server took it ("Vehicle motion rejected
    --     ... canonical=(-38.377,1993.726,...) received=(-41.435,2007.588,...)":
    --     the hull's REAL pose refused against the pad) and the heal then
    --     re-published the pad to every game -- the AV jumped 14 m back. So the
    --     exiting game says what it saw (`DRAG`), and for `DRAG_WINDOW_MS`
    --     after the exit an EMPTY, unfrozen hull the server has where that
    --     game's engine dragged it (`DRAG_MATCH_METRES`), more than
    --     `DRAG_UNDO_METRES` from where it stood before the exit, is put back
    --     there (`setTransform`), once. The heal never re-publishes the drag.
    -- `WATCH = false` switches all of it off.
    WATCH = {
        SIGHT_MS = 500,
        RANGE = 350.0,
        MAX_HULLS = 3,
        DRIFT_METRES = 10.0,
        DRIFT_PER_SPEED = 0.4,
        SETTLE_METRES = 4.0,
        REPEAT_MS = 5000,
        JUMP_METRES = 45.0,
        HEAL = true,
        HEAL_EVERY_MS = 10000,
        DRAG_UNDO = true,
        DRAG_WINDOW_MS = 6000,
        DRAG_UNDO_METRES = 2.0,
        DRAG_MATCH_METRES = 3.0,
    },

    -- THE EXIT, ON THE SCREEN (1.6.0): THE CURTAIN. A native quest fade
    -- (`Open77.screen.fadeOut`) HOLDS THE BODY STILL WHERE IT IS: while it is
    -- out -- from the fade-out until its fade-in has run -- the engine moves
    -- nothing of the player's body, the platform's own notes say so of every
    -- vehicle (`WorldUpdateFlags`: the fade's byte is flag 0x8, part of the
    -- 0x1B physics block), and the laptop measured it of the player: a body put
    -- beside the door 3 cm over the ground under the exit's cut to black hung
    -- there, "off the ground (falling)", 0.00 m/s, for the whole 5.4 to 7.5 s
    -- of black, held or not, put 5 cm over the ground again or not, and fell
    -- the moment the image was back -- the client's "first move" rule
    -- (`vflt-exit-tpp-off`, the body faster than 0.4 m/s) fired exactly then,
    -- fade over + `IN_MS`, in all three exits (Staging, 2026-10-28, 01:54:23.2,
    -- 01:54:39.2, 10:33:02.7); the platform draws no clip on a body off the
    -- ground. ("Screen goes black then the player is falling outside the av
    -- door.") So the exit is never black at its first frame any more: the
    -- body is put beside the door with the image on -- the pilot's body is
    -- hidden by the client for 1.6 s and its chase camera holds the AV in view
    -- for 1.5 s -- it lands, and only once it stands there, facing the step's
    -- heading and held, does the screen go black (`OUT_MS`) for the cameras'
    -- change to third person; the step is asked under it, and the image comes
    -- back with the step's first frame (`IN_MS`). Nothing moves the body under
    -- it: a move that has to be made lifts it first (`LIFT_MS`, at once), the
    -- body lands, and it comes down again once the body stands (`TRIES` times
    -- an exit). `MAX_MS`: the most it stays down; the step then plays in view.
    -- A plain exit (no clip) is not faded. `EXIT_FADE = false`: no curtain.
    EXIT_FADE = {
        OUT_MS = 250,
        IN_MS = 550,
        LIFT_MS = 0,
        MAX_MS = 6000,
        TRIES = 2,
    },

    -- THE EXIT, ON THE GROUND. The client guard and the server's door.
    --
    -- THE GUARD (client): from the moment the mount drops it puts the body on
    -- the ground beside its seat's door -- `SIDE_METRES` out from the hull's
    -- centre on the door's side and `FORWARD_METRES` toward the nose, on the
    -- ground the static ray finds there -- and keeps it there for `GUARD_MS`:
    -- a jump of more than `JUMP_METRES` between two looks (50 ms) is the
    -- platform's own eject putting it back under the hull, and it is put back.
    -- A body still inside `DANGER_METRES` of the hull's centre when the guard
    -- ends is moved once more. Higher than `MAX_AIR_METRES` over the ground the
    -- exit is in flight: the body is put beside the door at the door's own
    -- height and falls from there. A seat lost more than `NEAR_METRES` from the
    -- hull is a teleport (a server move, a respawn) and is left alone.
    -- `PLACE = false`: the body is left where the platform puts it.
    --
    -- THE DOOR (server): the seat's door opens as the seat empties and closes
    -- `DOOR_HOLD_MS` later -- long enough for the wait, the curtain and the exit clip
    -- (about 3.5 s and 4.3 s), so the body walks out of an open door. The
    -- engine closes a pilot door a moment after an unmount, so for
    -- `DOOR_REASSERT_FOR_MS` the server looks every `DOOR_REASSERT_MS` and
    -- opens it again if it was shut.
    --
    -- ON ITS GEAR (server, `LAND`): the platform's flight sets an AV down on
    -- the lowest point of its collision hull, which for the Rayfield
    -- Excalibur is 1.46 m under its origin -- its gear feet then hang 0.4 m
    -- over the ground and its door's step 1.1 m up (Staging, 2026-10-27:
    -- `vhull ... belly=1.46`, "hull 1.5 m over it"). When the last body has
    -- stepped out of an airframe whose gear is known (`AIRFRAMES` ... `LAND`),
    -- the server lowers the hull onto its gear `LAND_DELAY_MS` after the exit
    -- (before the clip is asked), on the ground the exiting game measured under each
    -- foot within `LAND_WINDOW_MS` -- long enough for the measure a slow game
    -- makes again before its exit clip (it covers `EXIT_ANIM.VIEW_WAIT_MAX_MS`
    -- and `SETTLE_MS`). `LAND = false` leaves every hull where the flight put it.
    -- `EXIT = false` is neither.
    --
    -- THE GLIDE (1.7.9): a hull left hovering higher -- a pilot who steps out
    -- before the flight has set it down (Staging, 2026-10-29, 16:49:32: its gear
    -- 1.01 m over the ground, its door's step 1.68 m up) -- is brought down onto
    -- its gear, not dropped: a set-down of more than `LAND_GLIDE_FROM_METRES` is
    -- glided, one pose every `LAND_GLIDE_TICK_MS` (the platform's
    -- `setTransform`, the pad snap's way), at `LAND_GLIDE_SPEED` metres a second
    -- on average, leaving the hover gently and touching down gently. The exit
    -- clip waits for it (it is asked once the door's step is within its reach).
    -- A body that boards, a resource that freezes the hull or moves it across
    -- ends the glide where it is. A set-down of up to `LAND_GLIDE_FROM_METRES`
    -- (the 0.4 to 0.5 m the flight leaves an Excalibur at) is one move, as before.
    EXIT = {
        PLACE = true,
        SIDE_METRES = 6.0,
        FORWARD_METRES = 1.5,
        LIFT_METRES = 0.25,
        MAX_AIR_METRES = 4.0,
        NEAR_METRES = 14.0,
        GUARD_MS = 2800,
        JUMP_METRES = 2.5,
        DANGER_METRES = 3.2,
        SETTLE_MS = 350,
        DOOR_HOLD_MS = 9000,
        DOOR_REASSERT_MS = 400,
        DOOR_REASSERT_FOR_MS = 3200,
        LAND = true,
        LAND_DELAY_MS = 1200,
        LAND_WINDOW_MS = 20000,
        LAND_GLIDE_FROM_METRES = 0.5,
        LAND_GLIDE_SPEED = 1.5,
        LAND_GLIDE_TICK_MS = 50,
    },

    -- THE AIRFRAMES WHOSE DOORS ARE KNOWN, read from the game's own files
    -- (the rig's door, hinge and seat bones and the body mesh; 2.31/2.5
    -- archives, docs/research/av-door-and-autopilot.md "The airframes"). For
    -- these the exit -- plain or animated -- uses the real door: its side, how
    -- far its outer face is from the centre line (`OUT`), where it is along the
    -- hull (`FORWARD`, toward the nose), and the platform door that swings
    -- (`DOOR`). Any other aircraft uses the seat's side, `EXIT.FORWARD_METRES`,
    -- and for the clip the hull's mesh box (`EXIT_ANIM.DOOR_*`).
    --   * the Rayfield Excalibur has ONE door, on the left, between its hinges
    --     at +1.02 and -1.33 m (the cabin side at 1.1 to 1.2 m; the 1.84 m of
    --     the body mesh is the rear engine pods): every seat leaves through it,
    --     the right-hand seats included. Its animation (`door_front_left`, the
    --     only one its graph has) swings the upper wing up and folds the middle
    --     panel out into a step 0.6 m wide, its top 0.38 m under the origin and
    --     1.17 to 1.75 m out from the centre line, centred 0.13 m behind it
    --     (2.31/2.5 `av_rayfield_excalibur.anims`, the open pose). The
    --     platform's cabin-door path never swings it on the hulls the client
    --     projects (Staging, 2026-10-27: held open six seconds, never moved),
    --     so open77_avdoor's archive makes the TRUNK swing it -- the platform
    --     sends a trunk's feature and event itself -- and `DOOR` is `trunk`.
    --     The exit clip starts on the middle of that step (`OUT`, `FORWARD`).
    --     `LAND`: its gear feet (the rig's `landinggear_*_end`: the nose gear on
    --     the centre line 2.26 m ahead, the main gear 0.80 m either side 3.43 m
    --     behind) touch the ground with the origin 1.0 m over it; there the
    --     step is 0.62 m up -- the exit clip steps down 0.5 m. `STEP` is the
    --     step's top under the origin: an exit clip is played only from a step
    --     it can stand on (`M.StepBand`), never from one hanging over it.
    --     `MAX_DROP_METRES` is the most a hull is lowered: 3.0 (1.7.9; 0.8
    --     before) -- a pilot may step out while the AV still hovers (its gear
    --     1.01 m up, Staging, 2026-10-29), and the exit guard puts the body on
    --     ground up to `EXIT.MAX_AIR_METRES` (4.0) under the origin, the gear's
    --     1.0 m plus this. Higher, the hull stays where the flight left it.
    --     `DOOR_SLOTS`: the door's meshes hang on the entity's `vehicle_slots`
    --     slots `door_a_01`, `door_b_01`, `door_c_01` (and the hinges'), all at
    --     x -0.95 to -1.14 in the hull's frame: each game reads where IT draws
    --     the door (`Open77.character.bonePosition`), the exit is planned on the
    --     side it is drawn on, and every screen's report measures the step's
    --     first frame against it. `X` is the slots' place across the hull, `Y`
    --     along it (within `ALONG`), `TOLERANCE` how far off a slot may be;
    --   * the Militech Manticore (Myers' AV in q305) has a sliding door on
    --     each side, two panels each (rig bones `door_front_left_a` 0.45 m
    --     ahead of the centre and `door_back_left_a` 0.65 m behind it, 2.4 m
    --     out; `_right_a` on the right). Its one animation a side
    --     (`door_front_left`, `door_front_right`: 1.9 s, open at 1.07 s) slides
    --     both panels out 0.16 m and apart, 1.03 m each, so the doorway is about
    --     2 m wide, from 0.93 m ahead of the centre to 1.13 m behind it -- each
    --     seat's door point below stands in it. Its graph is the game's four-door
    --     car graph, every door entered by its own events only, and the platform's
    --     cabin-door path moves none of them on the hulls the client projects
    --     (the 1.8.4 test on Staging, 2026-10-30: the boarding step played
    --     against a shut door). So open77_avdoor's archive SWAPS the events (1.9.0,
    --     `scripts/avdoor/make_door_graph.py --airframe manticore`): the left
    --     door answers the TRUNK and the right door the HOOD -- the platform
    --     sends both itself -- and the Manticore has neither of its own.
    --     `EXIT_FORCED`: the game's own exit from its seats is a car's, ANIMATED
    --     -- the body held mounted, in the exit's workspot, 2.1 s while it climbs
    --     down beside the hull (Staging, 2026-10-30, 22:46:23: the exit's
    --     placements did not hold, eight of them, and the clip was given up) --
    --     so the exit key (`LEAVE`) steps the body out through the server's
    --     forced exit, which the client makes instant, and the exit clip plays
    --     as from the Excalibur. An exit the game animates all the same (another
    --     exit key, a game pad) is left to the game: no placement, no clip.
    --     `DOOR_CLOSE_LEAD_MS`: the door's clip ends with the body in the
    --     doorway, and the panels slide shut in 0.8 s: the boarding closes it
    --     as the clip ends, before the seat, not `DOOR_CLOSE_DOOR_CLIP_LEAD_MS`
    --     before.
    AIRFRAMES = {
        {
            NAME = 'Rayfield Excalibur',
            RECORDS = { 'av_rayfield_excalibur' },
            STEP = 0.38,
            DOOR_SLOTS = {
                NAMES = { 'door_b_01', 'door_a_01', 'door_c_01', 'door_hinge_a_01', 'door_hinge_b_01' },
                X = -1.05,
                Y = -0.15,
                ALONG = 1.4,
                TOLERANCE = 0.6,
            },
            SEATS = {
                -- `SIT` (1.7.7): the seat's slot in the hull's frame -- the rig's
                -- `seat_front_left` bone (0.82 m ahead, 0.40 left, 0.04 under the
                -- origin) turned 180 deg by the entity's `vehicle_slots` (the
                -- front seats face the tail) -- where the seat clip ends.
                -- 1.8.0: `seat_back_left` (the rig's bone 1.48 m behind the
                -- origin, 0.40 left, 0.04 under it; no turn: the back seats face
                -- ahead), boarded with its own clip, `CLIP = 'couch'`.
                seat_front_left = { SIDE = 'left', OUT = 1.45, FORWARD = -0.13, DOOR = 'trunk',
                    SIT = { X = -0.398, Y = 0.819, Z = -0.040, YAW = 180.0 } },
                seat_front_right = { SIDE = 'left', OUT = 1.45, FORWARD = -0.13, DOOR = 'trunk' },
                seat_back_left = { SIDE = 'left', OUT = 1.45, FORWARD = -0.13, DOOR = 'trunk',
                    SIT = { X = -0.398, Y = -1.482, Z = -0.040, YAW = 0.0, CLIP = 'couch' } },
                seat_back_right = { SIDE = 'left', OUT = 1.45, FORWARD = -0.13, DOOR = 'trunk' },
            },
            -- THE SEATS FILLED IN THIS ORDER (1.8.0): the pilot's, then the back
            -- seats -- the first rider takes the back-left one, the seat Corpo V
            -- climbs into -- and the one beside the pilot last (it faces the
            -- tail). A passenger is never offered the pilot's (`SEATS`).
            SEAT_ORDER = { 'seat_front_left', 'seat_back_left', 'seat_back_right', 'seat_front_right' },
            LAND = {
                HEIGHT = 1.0,
                GEAR = { { 0.0, 2.26 }, { -0.80, -3.43 }, { 0.80, -3.43 } },
                FLAT_METRES = 0.3,
                MAX_DROP_METRES = 3.0,
            },
        },
        {
            NAME = 'Militech Manticore',
            RECORDS = { 'av_militech_manticore' },
            EXIT_FORCED = true,
            DOOR_CLOSE_LEAD_MS = 0,
            SEATS = {
                seat_front_left = { SIDE = 'left', OUT = 2.45, FORWARD = 0.45, DOOR = 'trunk' },
                seat_front_right = { SIDE = 'right', OUT = 2.45, FORWARD = 0.45, DOOR = 'hood' },
                seat_back_left = { SIDE = 'left', OUT = 2.45, FORWARD = -0.65, DOOR = 'trunk' },
                seat_back_right = { SIDE = 'right', OUT = 2.45, FORWARD = -0.65, DOOR = 'hood' },
            },
        },
    },

    -- THE EXIT, ANIMATED: THE BODY STEPS OUT OF THE DOOR. Rosalind Myers'
    -- own exit from her AV in Phantom Liberty (q305, "border crossing": she
    -- stands up from the seat, walks to the door, steps down about half a metre,
    -- walks out and folds her arms), shipped as the custom locomotion package
    -- `avexit` by the resource open77_avexit (preload archive, installed by the
    -- launcher). The clips are cut so that each ENDS where the player entity
    -- stands, facing forward; where it STARTS is an offset of the clip, and the
    -- exit puts the entity so that the start lands on the door:
    --   * the guard puts the body `|offset|` metres out from the door, on the
    --     ground, turned so the clip's path points away from the hull;
    --   * when the screen would come back, this client asks the server for the
    --     clip; the server plays it (`Open77.locomotion.playClip`) for every
    --     viewer at once, and the screen comes back on the first step;
    --   * the body is held still for the clip (`FREEZE`), and every other
    --     game sees nothing of the platform's own exit (the drop in the cabin,
    --     the eject under the hull): the body is hidden from them from the
    --     moment the seat empties until the clip starts (`HIDE`).
    -- The clip: `CLIP` for a door on the left of the hull, `MIRROR_CLIP` on the
    -- right, or a record's own in `RECORDS` (`{ ['vehicle.av_x'] = 'step_m' }`).
    -- Exit clips of the package: `step` (from the door, 4.3 s) and `step_m`
    -- (mirrored); `enter`, `sit` and `couch` are the boarding's
    -- (`ENTER_ANIM`), never an exit's. 1.2.0 of the package gave the slot of
    -- `walk` (beside the door on the ground, 2.9 s) to `sit`, 1.3.0 the slot of
    -- `enter_m` (the step up mirrored, for a door on the right) to `couch`.
    --
    -- THE STYLE. A clip plays only on a player whose locomotion style is the
    -- package's (`STYLE`), and giving a player a style rebuilds the body every
    -- viewer draws for them. So the style is given when the player is ready
    -- (`ASSIGN = 'join'`, 1.7.0: the boarding's step plays on it, before any
    -- seat), or while the body sits in the aircraft, hidden in its seat
    -- (`'board'`: the first boarding of a session is then plain), and kept for
    -- the session: an exit or a boarding then costs only the clip. A player
    -- another resource gave a style to keeps it, and steps out and in
    -- unanimated. `EXIT_ANIM = false`, or no open77_avexit, is the exit above
    -- and the plain boarding.
    --
    -- THE HEAD. A second and a half after an exit the Open77 client shows the
    -- pilot from behind through the legacy camera path, which draws the game's
    -- first-person body -- the one with no head ("the head becomes
    -- invisible"). `HOLD_VIEW` holds the platform's own third person -- the
    -- stand-in body, dressed and with its head -- from the moment the seat
    -- empties until the player walks off (`RELEASE_SPEED` m/s for two looks),
    -- or `VIEW_MAX_MS`; the stand-in is also the body the clip plays on. After
    -- a clip the view goes back to the player's own the moment it ends
    -- (`RELEASE_AFTER_CLIP`): the client turns its own exit camera off on the
    -- first steps (`vflt-exit-tpp-off`), which a held third person fights for
    -- two seconds (Staging, 2026-10-27, 17:39:21: first person, then third
    -- person again).
    --
    -- THE GROUND UNDER THE CLIP. A clip ends standing on the ground where the
    -- player entity stands, so the body is put `LIFT_METRES` over the ground
    -- there -- not the plain exit's `EXIT.LIFT_METRES`, which a body falls
    -- from: under a clip it would end in the air and drop.
    --
    -- THE EXIT KEY (1.9.0, `LEAVE`, client/leave.lua, server/leave.lua). An
    -- airframe whose seats the game itself steps out of with an animation
    -- (`AIRFRAMES` ... `EXIT_FORCED`, the Militech Manticore's: a car's exit,
    -- the body held in its workspot for two seconds) gets this key while a body
    -- sits in it: `KEY` (F, the game's own exit key; rebindable under KEY
    -- BINDINGS as `NAME`), registered with `consume` so the game's exit never
    -- starts. The press asks the server, which checks the seat and steps the
    -- body out through the platform's forced exit -- instant on the leaving
    -- game -- and the exit is the Excalibur's: the door opens, the body is put
    -- beside it and the clip plays. A game that cannot consume the key keeps the
    -- game's own exit, and so does a body that leaves another way: the exit
    -- then places nothing and plays no clip. `ASK_GAP_MS`: one ask a press at
    -- most this often; an exit seen within `ASKED_MS` of the ask is the key's;
    -- the server answers one ask a player every `SERVER_GAP_MS`.
    LEAVE = {
        ON = true,
        KEY = 'F',
        ID = 'open77_avdoor_leave',
        NAME = 'Step out of an AV',
        ASK_GAP_MS = 1500,
        ASKED_MS = 4000,
        SERVER_GAP_MS = 750,
    },

    EXIT_ANIM = {
        STYLE = 'avexit',
        CLIP = 'step',
        MIRROR_CLIP = 'step_m',
        RECORDS = {},
        ASSIGN = 'join',
        -- 1.7.6: a style refused because the player is not ready yet (the
        -- platform gives one only to a ready, living player -- at join the
        -- hello comes first, and a player who joins dead is not ready until
        -- respawned) is asked for again every `STYLE_RETRY_MS`, for
        -- `STYLE_RETRY_MAX_MS` at most. Without it the style came with the
        -- first boarding's key, and giving a style rebuilds the body every game
        -- draws -- this player's own third-person stand-in included, so that
        -- first boarding had to wait for a new one (Staging, 2026-10-29: the
        -- stand-in made ahead at 18:41:59 UTC was thrown away at the key,
        -- 18:44:27, and the step waited 8.6 s).
        STYLE_RETRY_MS = 2000,
        STYLE_RETRY_MAX_MS = 300000,
        -- The door's distance from the hull's centre line: the hull's own mesh
        -- bounds plus `DOOR_MARGIN`, inside the band; `DOOR_METRES` when the
        -- bounds cannot be read.
        DOOR_METRES = 2.4,
        DOOR_MARGIN = 0.3,
        DOOR_MIN = 1.2,
        DOOR_MAX = 4.5,
        BLEND_IN_MS = 0,
        BLEND_OUT_MS = 450,
        -- How long this client waits for the server's answer before the curtain
        -- comes up without the clip. The ask comes once the body stands beside
        -- the door, so the seat is free by then; should the server still hold
        -- it when the ask arrives, the ask waits for it up to `PENDING_MS` (keep
        -- it under `ANSWER_MS`, with room for the round trip).
        ANSWER_MS = 1200,
        PENDING_MS = 700,
        -- How long after a seat was left the server still plays its clip.
        WINDOW_MS = 32000,
        FREEZE = true,
        HIDE = true,
        -- How long the others are kept from seeing the body before its clip
        -- starts (it covers VIEW_WAIT_MAX_MS, SETTLE_MS, moves to a new end
        -- point, the view drawn again after one and two answers -- the client's
        -- own ceiling for an exit never asked, client/walkout.lua `W.Ceiling`).
        HIDE_MAX_MS = 29000,
        -- THE PLAN AGAIN, BEFORE THE ASK. The exit plans the walk-out the moment
        -- the seat empties, when the engine may still draw the hull where its
        -- flight began (2.5 m off after a hop from the back seat, Staging,
        -- 2026-10-28, 01:10:52: the clip started on nothing, "floating in air ...
        -- while the av doors where open"). Before the clip is asked, it is
        -- planned again on the hull as it stands then -- where the network
        -- (the server) has it -- and the body is moved to the new end point
        -- when that is more than `REPLAN_METRES` away. A hull that still hangs
        -- over its gear (its door's step higher than the clip's first step can
        -- stand on) is measured again and waited for, up to `SETTLE_MS`; a step
        -- still out of reach is turned about the door, else played within the
        -- relaxed reach (1.6.2, shared/core.lua `STEP_TURNS`,
        -- `STEP_UNDER_RELAXED`); past that there is no clip: the body is shown
        -- standing where it is, never stepping out of the air.
        SETTLE_MS = 3500,
        REPLAN_METRES = 0.3,
        -- THE SERVER'S OWN CHECK: the clip's end point within `PLAN_METRES` of
        -- where the server's hull puts it (else the client plans once more on
        -- the server's pose), the body within `BODY_METRES` of it, the door's
        -- step within the clip's reach.
        PLAN_METRES = 0.75,
        BODY_METRES = 1.5,
        HOLD_VIEW = true,
        RELEASE_SPEED = 0.6,
        VIEW_MAX_MS = 120000,
        -- The clip plays on the stand-in body, which only the platform's third
        -- person draws: the clip is asked the moment that view draws it (under
        -- the curtain, which comes up with the clip's first step). The arbiter lets
        -- third person in twelve clean FRAMES after the client's exit camera is
        -- off and reveals the stand-in over a few more -- 0.3 s at 60 frames a
        -- second, about 4 s at 3 (Staging, 2026-10-27, 18:57:58: 5.0 s into the
        -- hold, as the old 5 s wait ran out). A view that does not come is
        -- given up once `VIEW_WAIT_MS` has passed AND `VIEW_WAIT_LOOKS` watch
        -- passes (100 ms each, never shorter than a frame) since that camera
        -- went off, or at `VIEW_WAIT_MAX_MS`: the clip then plays for the others
        -- and this screen shows its own view. `VIEW_WAIT_MS = 0`: never wait.
        VIEW_WAIT_MS = 5000,
        VIEW_WAIT_LOOKS = 30,
        VIEW_WAIT_MAX_MS = 12000,
        -- THE SHOT: as the stand-in is drawn the camera swings this far round
        -- the body (`Open77.camera.orbit`, the platform's preview orbit), so
        -- the clip is seen from in front -- the body stepping down out of the
        -- open door toward the lens -- and goes back behind it as the clip
        -- ends. 0 (or false): the clip seen from behind, as the rig has it.
        ORBIT_DEGREES = 160,
        -- The door stays open this long after the clip ends (the server holds
        -- it from the exit for `EXIT.DOOR_HOLD_MS`, and through the clip).
        DOOR_AFTER_CLIP_MS = 1500,
        -- The client's own exit camera (the legacy path, 1.5 s after the exit:
        -- the camera pulled behind the first-person body, the one without a
        -- head) keeps the platform's third person out: a camera detached under
        -- the perspective arbiter's first-person decision breaks its
        -- single-camera rule, and it answers with its fatal row (Staging,
        -- 2026-10-27: `fatal_state` the whole time that camera was on, third
        -- person 0.65 s after it went). While the exit holds third person it
        -- is turned off (`Open77.camera.thirdPerson(false)`, what the client
        -- itself does on the first steps). `false` leaves it alone. Only until
        -- third person has settled once: after that the camera is the
        -- platform's, and turning the client's off again throws it to first
        -- person (Staging, 2026-10-27, 17:39:21.966).
        LEGACY_VIEW_OFF = true,
        RELEASE_AFTER_CLIP = true,
        LIFT_METRES = 0.03,
        -- THE STEP'S HEADING. The clip's whole path turns with the body: a body
        -- facing the other way starts the step 4.9 m from the door, half a
        -- metre up, walking toward the AV (Staging, 2026-10-28, 03:15:44: the
        -- step planned facing 75 deg, the body facing 245.8 as it played --
        -- "walking out in the air nowhere near the av door"). Before the clip
        -- is asked the body's heading is read; one more than `FACING_DEGREES`
        -- off is turned back (`FACING_TRIES` times at most) and must hold for
        -- two looks; a body that will not stay turned plays no clip. While the
        -- clip starts it is read again and turned back once more; a camera
        -- swing that turns the body with it is let go (the clip seen from
        -- behind) for the rest of the session.
        FACING_DEGREES = 4.0,
        FACING_TRIES = 3,
        -- ON ITS FEET (1.6.0). The platform draws the clip only on a body its
        -- game says stands on the ground -- on every screen, from that one sample
        -- (client/src/puppet/MirrorGraph.cpp). The body is put beside the door
        -- with the image on (`EXIT_FADE`: the native fade holds a body still
        -- wherever it is, in the air too), and must stand there `STAND_LOOKS`
        -- looks in a row; it is then held (`HOLD`: 'position', the platform's
        -- freeze; 'restriction', the engine's NoMovement restriction; 'none'),
        -- never moved while held, and must stand, held, two looks more before
        -- the screen goes black and the clip is asked. A hold that takes a
        -- standing body off the ground is let go and the other one tried. A body
        -- that has not stood `GROUND_WAIT_MS` (and `GROUND_WAIT_LOOKS`) after it
        -- was put there is put 5 cm over the ground under it once and waited
        -- for as long again; then no clip -- the body is shown where it is.
        HOLD = 'position',
        GROUND_WAIT_MS = 1500,
        GROUND_WAIT_LOOKS = 6,
    },

    -- THE BOARDING, ANIMATED (1.7.0): THE BODY STEPS UP INTO THE DOOR. Rosalind
    -- Myers boarding her AV in Phantom Liberty (q305: she walks to the door,
    -- turns to it, steps up half a metre into the cabin and sits), cut into
    -- the clip `enter` of the exit's own package (`avexit`, open77_avexit
    -- 1.1.0): from 2.70 s, standing a metre before the door, to 5.30 s, both
    -- feet on the cabin floor in the door, 2.6 s. The clip STARTS where the
    -- player entity stands (its first frame is rooted there; the exit clips'
    -- last) and ends with the hips 1.17 m ahead, 0.15 m to the right and
    -- 0.53 m up: so the body is put that far out from the seat's door, turned
    -- so that the clip's path points straight into the hull, and the clip's
    -- last frame lands in the door -- the exit's own plan (`AvDoor.WalkOutPlan`,
    -- the door's step within the clip's reach, turned about the door on a
    -- slope: shared/core.lua `STEP_TURNS`).
    --   * the key on the door's card: the server opens the door and asks this
    --     client for the step (`ENTER`) instead of seating the body at once;
    --   * with the image on, the body is put on the clip's first spot facing
    --     the door, lands, stands `STAND_LOOKS` looks, is turned back when it
    --     faces more than `FACING_DEGREES` off, and is held (`HOLD`) -- never
    --     moved under the curtain: the native fade holds a body still where it
    --     is, in the air too (the exit's lesson, `EXIT_FADE`);
    --   * the view changes to third person (the stand-in body, the only one the
    --     clip plays on on this screen) -- a cut, in view (1.7.1; `CURTAIN =
    --     true` puts a short black over it, as 1.7.0 did). THE STAND-IN FIRST
    --     (1.7.3): third person is asked AT THE KEY (`VIEW_EARLY`), so the
    --     stand-in is made while the body is placed, held and the weapon put
    --     away; the step is asked only once this screen draws it, and draws
    --     it `VIEW_SETTLE_MS` (or settled): a clip that starts while the
    --     stand-in is still being made or dressed is never drawn on it. The
    --     owner's first boarding of a session on 1.7.2 (Staging, 2026-10-29,
    --     the laptop at 11 to 18 frames a second): the first third person of
    --     the session made the stand-in -- 2.4 s from its spawn to dressed,
    --     a 0.64 s hitch in it -- 1.7.2 gave up waiting at 2.5 s and asked the
    --     step anyway, and the diag pictures show the stand-in standing still
    --     at the door through the whole clip, then the cut into the seat ("i
    --     get blackscreen the teleport into the av"). `VIEW_WAIT_MS` counts
    --     from the key now; no third person by then (`VIEW_REQUIRED`): the
    --     plain boarding at once, said -- not a step this screen cannot show.
    --     The step is asked (`ENTER_READY`); the server checks
    --     it against its own hull -- the first spot within `PLAN_METRES` of
    --     where its hull puts it, the body within `BODY_METRES` of it, the
    --     door's step within reach -- and plays the clip for every viewer once
    --     the door has swung (`DOOR_OPEN_MS` after the key);
    --   * `SEAT_EARLY_MS` before the clip ends the server seats the body
    --     through the platform's own mount; this client lets go of the hold
    --     `SEAT_LEAD_MS` before that, and the view is the seat's own again the
    --     moment the seat is taken -- a cut (`SEAT_CURTAIN = true`: a short black
    --     over it, lifted `SEAT_SETTLE_MS` after the seat).
    -- 1.7.0 blacked the screen out twice in four seconds, before the step and
    -- at its end ("two black screens", the owner's first boarding, Staging,
    -- 2026-10-29): the change of view takes a fifth of a second here (no exit
    -- camera to let go of, unlike the exit's), so 1.7.1 cuts instead.
    --   * THE HULL OVER ITS GEAR (1.7.1). A hull the flight parked over its
    --     gear -- a fresh Excalibur hangs 0.4 m over it, its door's step 1.07 m
    --     up, past the clip's reach -- is set down on its gear first: this
    --     client measures the ground under its feet and asks (`SET_DOWN`), the
    --     server lowers the empty hull (server/land.lua, as after an exit) and
    --     asks for the step again `SET_DOWN_WAIT_MS` later; this client waits
    --     `SET_DOWN_LOOK_MS` at most for the hull to be drawn down there.
    --   * A WEAPON DRAWN (1.7.2) at the key is put away first
    --     (`Open77.weapons.holster`; `HOLSTER = false` leaves it): the platform
    --     plays no clip on a body with a weapon drawn -- the owner's first
    --     boarding of 1.7.1 stood still with one out (Staging, 2026-10-29). The
    --     step waits `HOLSTER_WAIT_MS` at most for the hands to be empty, then
    --     the boarding is plain.
    --   * A GAME WITHOUT THE CLIPS (1.7.2) -- open77_avexit's package not
    --     registered on it: the archive is not in the game it started with --
    --     boards plainly at once, says so to the player once, and the server's
    --     log names it (client/main.lua's hello, `AvDoor.AnimPackage`).
    -- Whatever fails -- no style, a client that does not know the step (an
    -- older one), no ground or a door's step out of reach, a body that will
    -- not stand or face the door, a hull that moved, no word from the client
    -- within `ASK_MS` -- the body is seated as it always was, and both logs say
    -- why. `ENTER_ANIM = false`: the plain boarding.
    ENTER_ANIM = {
        -- The door's clip; a door on the hull's right (the Manticore's) has
        -- none since open77_avexit 1.3.0 gave `enter_m`'s slot to `couch`, and
        -- is boarded plainly (`MIRROR_CLIP` may name a door's clip for it).
        CLIP = 'enter',
        RECORDS = {},
        KNOWN_DOORS_ONLY = false,
        -- The client's whole preparation, the key to the step asked for (the
        -- server waits a second more): `VIEW_WAIT_MS` and the placing in it.
        ASK_MS = 15000,
        ANSWER_MS = 1500,
        DOOR_OPEN_MS = 700,
        MOVE_MAX_METRES = 12.0,
        ARRIVE_METRES = 0.35,
        PLACE_WAIT_MS = 1500,
        PLACE_TRIES = 2,
        FACING_DEGREES = 6.0,
        FACING_TRIES = 2,
        STAND_LOOKS = 2,
        STAND_WAIT_MS = 2000,
        HOLD = true,
        HOLD_LOOKS = 2,
        -- Third person asked at the key (1.7.3; false: once the body is held,
        -- as 1.7.0 to 1.7.2 did).
        VIEW_EARLY = true,
        -- How long, from the key, the step waits for this screen to draw the
        -- stand-in. Made ahead (`STAND_IN`), it is drawn within a second or two;
        -- made at the key, it can take longer than the platform's own 3 s, which
        -- then restores first person and tries again 3 s later (1.7.5: Staging,
        -- 2026-10-29, the stand-in drawn 7.3 s after the key at 4 to 18 frames a
        -- second -- 1.7.4 had given up at 7.0 s and seated the body plainly).
        VIEW_WAIT_MS = 12000,
        -- The stand-in drawn this long (or settled) before the step is asked.
        VIEW_SETTLE_MS = 250,
        -- No third person within `VIEW_WAIT_MS`: the plain boarding (true), or
        -- the step asked all the same, for the others to see (false, 1.7.2).
        VIEW_REQUIRED = true,
        CURTAIN = false,
        SEAT_EARLY_MS = 200,
        SEAT_LEAD_MS = 350,
        -- THE VIEW BEFORE THE SEAT (1.7.8). With the seat taken while third
        -- person still drew the stand-in, the stand-in stood back up on the
        -- clip's first spot, beside the AV, and stayed there in the pilot's
        -- view until the AV flew off ("after the body sits down it gets moved
        -- back out until you take over the av", Staging, 2026-10-29; 1.7.6's
        -- "enters and doesn't sit down" was the same). Now, `VIEW_LEAD_MS`
        -- before the clip's end, the body is let go and first person is
        -- forced (the stand-in put away while the body is still on foot);
        -- once the platform shows first person, or after `PARK_WAIT_MS`, the
        -- client asks for the seat and the server seats the body at once --
        -- `SEAT_WAIT_MS` after the clip's end on its own if no word comes.
        -- `VIEW_LEAD_MS` is the seat clip's (the body is seated by then),
        -- `DOOR_VIEW_LEAD_MS` the door's clip's.
        -- The view is the pilot's the moment the seat is taken.
        SEAT_AFTER_VIEW = true,
        VIEW_LEAD_MS = 600,
        -- A door's clip steps up to its last frames: its view goes back later.
        DOOR_VIEW_LEAD_MS = 300,
        PARK_WAIT_MS = 700,
        SEAT_WAIT_MS = 1500,
        -- THE DOOR SHUT BEFORE THE SEAT (1.7.10). The door opened at the key
        -- closed 16 s after the seat, and the pilot's own game drew it open the
        -- whole flight (Staging, 2026-10-29, 17:25); the door that closed 4 s
        -- before a take-off was drawn shut (16:49). So a boarding step closes
        -- its door while the body is still on foot: `DOOR_CLOSE_SEAT_CLIP_MS`
        -- into a clip that ends in the seat (the body is inside, sitting down;
        -- at most `VIEW_LEAD_MS` before its end), `DOOR_CLOSE_DOOR_CLIP_LEAD_MS`
        -- before the end of a door's clip -- and the seat no longer opens it again.
        DOOR_CLOSE_SEAT_CLIP_MS = 3300,
        DOOR_CLOSE_DOOR_CLIP_LEAD_MS = 300,
        -- THE SEAT UNDER A SHORT FADE (1.8.2). Putting the stand-in away
        -- (above) shows first person from where the player entity stood all
        -- through the clip -- its first spot, outside the door -- for about half
        -- a second, and the seat comes after it: "when player enters there's a
        -- teleport outside the AV's door, then it goes to the pilot screen"
        -- (Staging, 2026-10-30). So the screen fades out (`SEAT_FADE_OUT_MS`)
        -- the moment first person is forced, stays black while the stand-in is
        -- put away and the body is seated, and comes back (`SEAT_FADE_IN_MS`)
        -- `SEAT_SETTLE_MS` after the seat, on the seat's own view.
        -- `SEAT_CURTAIN = false`: no fade (1.7.8 to 1.8.1).
        SEAT_CURTAIN = true,
        SEAT_CURTAIN_MS = 1500,
        SEAT_SETTLE_MS = 200,
        SEAT_FADE_OUT_MS = 150,
        SEAT_FADE_IN_MS = 350,
        SET_DOWN = true,
        SET_DOWN_WAIT_MS = 1000,
        SET_DOWN_LOOK_MS = 2000,
        HOLSTER = true,
        HOLSTER_WAIT_MS = 1500,
        BLEND_IN_MS = 0,
        BLEND_OUT_MS = 450,
        PLAN_METRES = 0.75,
        BODY_METRES = 1.5,
        BODY_WAIT_MS = 700,
        -- 0: the step seen from behind the body, the open door ahead of it.
        ORBIT_DEGREES = 0,
        -- INTO THE SEAT (1.7.7). The door's clip ends standing in the door and
        -- the seat is a cut: on Staging the body was seen stepping in and
        -- never sitting down. A seat whose slot is known (`AIRFRAMES` ...
        -- `SEATS` ... `SIT`: the Excalibur's pilot seat) is boarded with
        -- `SIT_CLIP` -- the game's own boarding of that AV (side quest sq012):
        -- the body walks up to the door, steps in, turns and sits down in the
        -- seat, 5.6 s -- planned from the seat's slot, so the clip ends where
        -- the seat holds the body; the seat comes `SEAT_EARLY_MS` before the
        -- clip's end, as for the door's clip. A first spot whose ground does
        -- not put the seat at the clip's height over it (`AvDoor.SEAT_UNDER`
        -- and `SEAT_OVER`, a slope beside the AV) is boarded with the door's
        -- clip. The camera swings `SIT_ORBIT_DEGREES` round the body toward
        -- its left, the door, so the sitting is seen through the open door.
        -- A seat may name its own clip (`SIT.CLIP`, 1.8.0): the Excalibur's
        -- back-left seat is boarded with `couch` -- Corpo V climbing into
        -- Jenkins' AV in the game's opening, made for this AV on its gear.
        -- `SIT = false`: the door's clip for every seat.
        SIT = true,
        SIT_CLIP = 'sit',
        SIT_ORBIT_DEGREES = 90,
    },

    -- THE GAME'S OWN ENTRY, SHUT (1.7.4). An aircraft has two entries on F: the
    -- door card (this resource: the step up, the seat it may take) and the
    -- game's own vehicle entry, which mounts the body in the seat whose door
    -- the eye is on, at once, with no step -- the owner's "enter animation
    -- isnt working everytime i enter av" (Staging, 2026-10-29: F at 01:08:17
    -- local seated him in `seat_back_left` with no line of this resource; F
    -- 25 s later, on the card, played the step). The platform takes every
    -- mount choice off a vehicle that is locked FOR THAT PLAYER; so while a
    -- player stands on foot within `METRES` of an aircraft, the server locks it
    -- for that one player (`Open77.vehicles.setLockedForPlayer`) -- the
    -- canonical lock, the one keys turn, is never touched -- and puts back what
    -- that player had once they are past `RELEASE_METRES`, seated, gone, or
    -- just before the card seats them (`warpPlayerIntoVehicle`, which a lock
    -- never stops). Who may board is still decided on the owner's lock, as
    -- before: the hold is this resource's own, not a lock. While it holds, a
    -- player's game reads the aircraft as locked (a keys row shows it so); the
    -- key still turns the real lock. Each hold, each release and every boarding
    -- that still came through the game's own entry are lines in the server log.
    -- `SHUT = false`: the game's own entry stays open, as before 1.7.4.
    NATIVE_ENTRY = {
        SHUT = true,
        METRES = 12.0,
        RELEASE_METRES = 16.0,
        -- Every this many scans each hold is read back (another resource's
        -- `setLockedForAll` takes every player's exception away) and set again.
        CHECK_EVERY = 4,
    },

    -- THE STAND-IN, MADE AHEAD (1.7.5). The step up plays on the platform's
    -- third-person stand-in, and the first third person of a game session has
    -- to make that body: spawned, dressed, its equipment worn. At 4 to 18
    -- frames a second that took longer than the platform's 3 s, so the first
    -- boarding of a session stood still at the door, then was seated plainly
    -- (Staging, 2026-10-29: the platform restored first person 3.6 s after the
    -- key, `prepare_timeout`, and showed third person at 7.3 s, just after 1.7.4
    -- gave up). Once made, the stand-in stays for the session, parked and
    -- hidden, and every later third person is drawn within a second or two.
    --
    -- So it is made ahead, out of sight: `AFTER_MS` after this client is up
    -- (and, with `NEAR_CARD`, as soon as a door card first comes up if that has
    -- not been done yet), on foot and in first person, this client asks for
    -- third person and lets it go again the moment the platform says it is
    -- building the body behind the first-person view (`holding_current`). The
    -- platform keeps first person on screen while it builds, and a request let
    -- go before the body is ready changes nothing on screen; the body is kept,
    -- parked, for the next third person. Never when the stand-in has already
    -- been drawn this session, nor while another resource holds the view. At
    -- most `TRIES` times a session, `RETRY_MS` apart; no `holding_current`
    -- within `LET_GO_BY_MS`: let go and tried later. If a client ever shows
    -- third person after the request was let go (an older client that plays
    -- every switch out), it is said once and not tried again. Every step is a
    -- line in the client log. `WARM = false`: made at the first boarding.
    STAND_IN = {
        WARM = true,
        AFTER_MS = 5000,
        NEAR_CARD = true,
        LET_GO_BY_MS = 2500,
        TRIES = 2,
        RETRY_MS = 15000,
        -- After letting go, the view is watched this long for first person.
        CONFIRM_MS = 1500,
    },

    -- WHAT THE SCREEN SHOWED (1.5.1), for the exit's tests: during each exit
    -- this game plays or draws, a few small pictures of its own frame
    -- (`Open77.screen.capture`: the game's back buffer alone -- never the
    -- desktop, never Open77's overlays), kept on this machine in this
    -- resource's client store (`Open77.kvp`, under the game's
    -- red4ext/plugins/Open77/storage/kvp) for the last `KEEP` exits, and sent
    -- nowhere. scripts/avdoor/read_avdoor_shots.py reads them out. `SCALE` of
    -- the frame, JPEG at `QUALITY`. `SHOTS = false`: no pictures.
    DIAG = {
        SHOTS = true,
        SCALE = 0.25,
        QUALITY = 55,
        KEEP = 2,
    },

    -- THE EXIT, ONE SCENE FOR EVERY SCREEN. Each game draws an exit on its own:
    -- the exiting player's game plays the step on its stand-in body, and every
    -- other game near it runs the platform's own dismount for that body first
    -- -- it holds the body in its seat for up to 2.5 s ("Remote seat dismount
    -- released: player=2 afterMs=2811", the laptop, Staging, 2026-10-28) -- and
    -- then plays the step on its copy of it. A fast game asked for its step
    -- 2.2 s after the exit: the slower screen still had the body in the seat as
    -- the step began, and saw it pop out half a second into it. So the server
    -- runs the exit as one scene: every other player within `RANGE_METRES` of
    -- the hull whose game runs this resource's client is told of it, and the
    -- step starts once each of those screens has the body out of its seat
    -- (`SCENE_READY`) -- held under the exiting player's curtain, `HOLD_MAX_MS` at
    -- most after the ask and never past `WAIT_MAX_MS` after the exit. A screen
    -- still holding the body after `READY_MAX_MS` says so, and is not waited
    -- for any longer; one that does not draw the body says so at once. A
    -- screen that draws the AV more than
    -- `HULL_METRES` from the server's pose gets the server's pose again
    -- (`REPUBLISH`, an empty hull only, once an exit).
    --
    -- THE LOGGER: every screen that drew the exit, the exiting player's own
    -- included, says what it drew `SAMPLE_MS` into the step and as it ended --
    -- the body against the step's end point (`BODY_METRES`), in its seat or
    -- not, the AV against the server's pose, the view, its frame rate -- and
    -- the server writes one line a screen, a warning for anything wrong, and a
    -- verdict for the exit. `SYNC = false`: no scene, no reports.
    --
    -- AND THE STEP AGAINST THE DOOR, as each screen draws both (1.5.0): the
    -- body's heading against the step's (`FACING_DEGREES`), the step's first
    -- frame -- worked out from where the body stands and the way it faces --
    -- against the door's step on that screen's own AV and its door slot
    -- (`STEP_METRES`), on the ground or not, a weapon drawn or not, the age of
    -- the movement the platform draws a remote body with (`STALE_MS`; the
    -- platform plays no clip on stale movement, a body in the air or a drawn
    -- weapon), and on a screen that draws another player's body, its hips:
    -- standing on its feet's point a moment into the step is a step that was
    -- not drawn there. Every screen is told of an exit; one whose client never
    -- said hello is not waited for, but its word is taken as its hello.
    SYNC = {
        RANGE_METRES = 150.0,
        READY_MAX_MS = 4500,
        WAIT_MAX_MS = 5000,
        HOLD_MAX_MS = 3500,
        HULL_METRES = 0.3,
        BODY_METRES = 0.75,
        SAMPLE_MS = 200,
        REPUBLISH = true,
        FACING_DEGREES = 15.0,
        STEP_METRES = 0.6,
        STALE_MS = 600,
        -- 1.7.8: another player's boarding step ends seated, and the platform
        -- answers a seat added live with the vanilla approach, door and
        -- workspot for that body -- from the step's first spot, outside the
        -- AV. Each screen presents the body in its seat at once instead, as
        -- soon as the ledger names the seat (the client's
        -- `Open77.vehicles.warpPlayerIntoVehicle`).
        PRESENT_SEAT = true,
    },

    -- THE MAXTAC AV'S OWN VOICE WHEN A PLAYER FLIES ONE. The base game's
    -- events (2.31 scripts: `AvStartAscentSFXBehaviour`,
    -- `AvStartDescentSFXBehaviour`, `MaxTacFearEvent`), played on the airframe
    -- for every player within `RANGE`. The pilot's own client reads the flight
    -- -- its seated body's height over the ground (`Open77.world.groundZ`) and
    -- the climb rate; the platform's AV flight publishes `onGround = false` on
    -- every frame, so the ground is measured, never read off the snapshot --
    -- and the server relays it after checking the asker really is seated in
    -- that hull. Every listener's client answers what it did with the sound,
    -- and a listener the host refused is given it through the platform's own
    -- fan-out instead (`RESCUE`). `''` switches one event off; `SOUNDS = false`
    -- switches all of them off.
    SOUNDS = {
        RECORDS = { 'max_tac' },
        RESCUE = true,
        TAKEOFF = 'av_maxtac_start_ascent',
        DESCENT = 'av_maxtac_start_descent',
        TOUCHDOWN = 'av_maxtac_descent_horn',
        -- THE GROUND BAND: a hull whose pilot sits at most this high over the
        -- ground and has stopped sinking for `SETTLE_MS` is down. The pilot sits
        -- two to four metres over the belly, and the platform eases any AV
        -- hovering inside five metres of a surface down onto it.
        GROUND_METRES = 7.0,
        REST_CLIMB = 0.5,
        SETTLE_MS = 750,
        -- The descent call: under this height, sinking faster than this.
        DESCENT_METRES = 30.0,
        DESCENT_SPEED = 1.5,
        -- The take-off call: off the ground and climbing faster than this.
        CLIMB_SPEED = 0.8,
        -- One event of a kind per hull at most this often, and how far it carries.
        FLOOR_MS = 6000,
        RANGE = 220.0,
        DURATION_S = 8.0,
    },

    -- THE LANDING CALL. A voice on the aircraft's loudspeaker -- "Warning.
    -- Clear the area. MaxTac landing." or "... Trauma Team landing." -- said
    -- over and over while one of those AVs comes down, and faded out over
    -- `FADE_MS` when it is down:
    --   * a player-flown AV: from its pilot's reported descent until the
    --     touchdown, or until it climbs back out of the descent band;
    --   * an AV a resource flies itself: `exports.open77_avdoor:callout` and
    --     `:hush`.
    -- Each game plays the line itself, in the language its voice-over is set
    -- to (`Open77.session.locale`), from where it draws the hull: full volume
    -- within `MIN_METRES`, fading out to `MAX_METRES`. The server tells every
    -- player in the hull's bucket within `MAX_METRES`, and anybody who comes
    -- near every `TELL_MS`, at the point the loop has reached. `MAX_SECONDS`
    -- ends a call that never heard its touchdown.
    --
    -- KINDS: which hulls say which line. `RECORDS` are patterns over the
    -- record. `ASSET` is the English line (a file in `audio/`, declared in
    -- open77.lua) and `SECONDS` its exact length -- a loop needs it, and the
    -- suite checks it against the file. `VOICES` are the same line in other
    -- languages, by two-letter code. `CALLOUTS = false` switches the call off.
    CALLOUTS = {
        KINDS = {
            maxtac = { RECORDS = { 'max_tac', 'maxtac' },
                ASSET = 'audio/av-callout-maxtac.wav', SECONDS = 4.4517,
                VOICES = {
                    fr = { ASSET = 'audio/av-callout-maxtac-fr.mp3', SECONDS = 4.9371 },
                    de = { ASSET = 'audio/av-callout-maxtac-de.mp3', SECONDS = 5.2767 },
                    es = { ASSET = 'audio/av-callout-maxtac-es.mp3', SECONDS = 4.3886 },
                    it = { ASSET = 'audio/av-callout-maxtac-it.mp3', SECONDS = 4.9371 },
                    pl = { ASSET = 'audio/av-callout-maxtac-pl.mp3', SECONDS = 4.8849 },
                    pt = { ASSET = 'audio/av-callout-maxtac-pt.mp3', SECONDS = 6.2433 },
                    ru = { ASSET = 'audio/av-callout-maxtac-ru.mp3', SECONDS = 6.5045 },
                    uk = { ASSET = 'audio/av-callout-maxtac-uk.mp3', SECONDS = 5.1461 },
                    cs = { ASSET = 'audio/av-callout-maxtac-cs.mp3', SECONDS = 4.4408 },
                    hu = { ASSET = 'audio/av-callout-maxtac-hu.mp3', SECONDS = 4.3102 },
                    zh = { ASSET = 'audio/av-callout-maxtac-zh.mp3', SECONDS = 5.6424 },
                    ko = { ASSET = 'audio/av-callout-maxtac-ko.mp3', SECONDS = 5.9559 },
                    ja = { ASSET = 'audio/av-callout-maxtac-ja.mp3', SECONDS = 6.9224 },
                },
            },
            trauma = { RECORDS = { 'trauma' },
                ASSET = 'audio/av-callout-trauma.wav', SECONDS = 4.1392,
                VOICES = {
                    fr = { ASSET = 'audio/av-callout-trauma-fr.mp3', SECONDS = 5.3029 },
                    de = { ASSET = 'audio/av-callout-trauma-de.mp3', SECONDS = 4.9110 },
                    es = { ASSET = 'audio/av-callout-trauma-es.mp3', SECONDS = 4.5192 },
                    it = { ASSET = 'audio/av-callout-trauma-it.mp3', SECONDS = 4.8327 },
                    pl = { ASSET = 'audio/av-callout-trauma-pl.mp3', SECONDS = 5.1461 },
                    pt = { ASSET = 'audio/av-callout-trauma-pt.mp3', SECONDS = 6.3478 },
                    ru = { ASSET = 'audio/av-callout-trauma-ru.mp3', SECONDS = 6.5567 },
                    uk = { ASSET = 'audio/av-callout-trauma-uk.mp3', SECONDS = 6.1127 },
                    cs = { ASSET = 'audio/av-callout-trauma-cs.mp3', SECONDS = 4.8588 },
                    hu = { ASSET = 'audio/av-callout-trauma-hu.mp3', SECONDS = 4.4147 },
                    zh = { ASSET = 'audio/av-callout-trauma-zh.mp3', SECONDS = 5.3290 },
                    ko = { ASSET = 'audio/av-callout-trauma-ko.mp3', SECONDS = 6.2955 },
                    ja = { ASSET = 'audio/av-callout-trauma-ja.mp3', SECONDS = 7.1837 },
                },
            },
        },
        TELL_MS = 1000,
        VOLUME = 1.0,
        MIN_METRES = 30.0,
        MAX_METRES = 300.0,
        MAX_SECONDS = 90,
        FADE_MS = 400,
        FOLLOW_MS = 150,
    },

    -- WHERE AN AV A RESOURCE FLIES ITSELF MAY COME DOWN
    -- (`exports.open77_avdoor:landingSite`). Measured on XyberRP (2026-10-07):
    -- AVs set down a fixed distance from a body on a fixed bearing, at the
    -- body's height, landed on water and the crew walked on air. A dedicated
    -- server has no physics world, so the games are asked
    -- (`Open77.world.groundZ`): the first point that is ground (open water
    -- answers nothing), open to the sky (a roof answers its own height), within
    -- `LEVEL_METRES` of the target's level, and flat under the hull
    -- (`FOOTPRINT_METRES` either side, both ways, within `FLAT_METRES`). Rings
    -- out to `FAR_METRES`, every 45 degrees from the caller's bearing.
    -- `BUDGET_SECONDS` bounds the asking. Only a game can measure, and a
    -- headless client never answers: the first point is asked of several
    -- players near it at once (`PROBE_MS` each), the first that answers
    -- measures the rest. `LANDING = false` switches the survey off.
    LANDING = {
        LEVEL_METRES = 2.5,
        FOOTPRINT_METRES = 4.5,
        FLAT_METRES = 0.8,
        FAR_METRES = 40.0,
        BUDGET_SECONDS = 4.0,
        OBSERVER_METRES = 250.0,
        PROBE_MS = 1500,
    },

    -- THE LANDING PAD UNDER AN AV A RESOURCE FLIES (`exports.open77_avdoor:pad`).
    -- The red ring the Open77 client draws under an AV it flies itself
    -- (twelve `laser.mine` beams on a 3.5 m ring, one orbiting inside it, the
    -- OPEN77 sign in dots), drawn by this resource under hulls of records the
    -- client does not fly as AVs (a Trauma Team airframe, say): shown while the
    -- hull is within `SHOW_METRES` of the ground and coming down faster than
    -- `DESCEND_SPEED`, or resting within `REST_METRES`. `PLATFORM` are the
    -- records the client pads itself, which are only measured. `DUST` is the
    -- effect under the hull within `DUST_METRES` of the ground, `VOICE` the
    -- engine's while it runs (`false` for none). `PADS = false`: no pads.
    -- `SIGN` is the OPEN77 dot matrix: off, because sixty beams in a 4x5 dot
    -- font never read as letters -- the sign under every aircraft is now the
    -- cursive "Open77" of open77_avlanding. `RING` is the twelve beams and the
    -- one orbiting inside them: off too, asked on XyberRP 2026-10-27 ("i want
    -- the old one removed"): the landing sign's ring and flashing word mark the
    -- spot; the dust and the engine's voice stay. (open77_avlanding's archive
    -- also draws the client's own `laser.mine` as nothing.)
    PADS = {
        METRES = 300.0,
        TELL_MS = 1000,
        PLATFORM = { '^vehicle%.av_', '^vehicle%.max_tac_av$' },
        RADIUS_METRES = 3.5,
        BEAMS = 12,
        RING = false,
        SIGN = false,
        SHOW_METRES = 6.0,
        REST_METRES = 2.2,
        DESCEND_SPEED = 0.4,
        DUST = 'base\\fx\\quest\\q001\\00c_rescuing_girl\\q001_av_dust_loop.effect',
        DUST_METRES = 11.0,
        VOICE = { START = 'v_av_trauma_big_engine_start', STOP = 'v_av_trauma_big_engine_stop' },
    },

    -- THE PAD SNAP (1.7.0, server/snap.lua, server/padlist.lua): an AV coming
    -- down over one of the game's own AV pads -- every one the world sectors
    -- hold, 208 of them (`M.PAD_ROWS`) -- is taken over, glided to the pad's
    -- centre, turned to the pad's heading and set down on it. The pilot has it
    -- back once it stands there.
    --   * CAUGHT: within `HEIGHT_METRES` over the pad's deck and within the
    --     deck's half width plus `MARGIN_METRES` of its centre, slower than
    --     `MAX_SPEED` across and not climbing faster than `CLIMB_MAX`, at
    --     `LOOKS` scans in a row (`SCAN_MS` apart): coming down or hovering. An
    --     AV that flies across a pad, or takes off from it, is left alone; one
    --     that was set down on a pad is not taken by it again until it has
    --     left it by `REARM_METRES`.
    --   * MEASURED: the pilot's own game reads the static ground under the
    --     pad's centre and under each gear foot of the hull as it will stand
    --     (`AIRFRAMES` ... `LAND`), straight down from where the hull flies --
    --     within `MEASURE_MS`. The deck must be where the pad list says it is
    --     (`SURFACE_METRES`, by the list's confidence: the marking on the deck
    --     is `high`, a module's or a stand-in's deck `medium`, a pad found by
    --     its lights or a quest scene `low`) and flat under the gear
    --     (`FLAT_METRES`); otherwise the AV is left alone and the log says why.
    --   * FLOWN: the hull is frozen (`Open77.vehicles.setFrozen`: the pilot's
    --     own reports are discarded) and posed every `TICK_MS`
    --     (`setTransform`): to the centre at `GLIDE_SPEED` while it turns to
    --     the pad's heading at `TURN_RATE` (the one of the pad's equal
    --     headings nearest its own) and comes down at `DESCENT` to
    --     `APPROACH_METRES` over its gear, then straight down at `TOUCHDOWN`.
    --     An airframe whose gear is known stands on it (its feet's highest
    --     ground plus `LAND.HEIGHT`); any other is brought to `HOVER_METRES`
    --     over the deck, centred and turned, and the pilot sets it down.
    --   * GIVEN BACK: after `HOLD_MS` on its gear the freeze comes off; a snap
    --     that has not landed in `MAX_MS`, a pilot who leaves the seat, a hull
    --     that goes or a pose the host refuses ends it at once, frozen no
    --     longer. A hull another resource froze is never taken.
    -- `PAD_SNAP = false` switches it off; `RECORDS` are the records it flies.
    PAD_SNAP = {
        -- WITH SOMEBODY ABOARD: DOCKED UNDER A DIP (1.8.3). Every
        -- `setTransform` takes the flight away from the game of whoever flies
        -- the AV, and that game claims it straight back: its chase camera lets
        -- go and first person comes back each time, so a glide flown by the
        -- server flickers their view from start to end ("when I land at an AV
        -- pad the screen is glitching repeatedly, I can't even see the AV
        -- landing", Staging, 2026-10-30: 129 poses in the 9.8 s the pad snap
        -- flew one AV down, the hull changing hands 252 times in 10 s, and the
        -- pilot's game logging `vchase-release-on-owner-loss` and `cam-veh-tpp
        -- fpp-reactivated` 116 times in one glide, 122 in the next). The
        -- platform has no move that does not do this, and a resource cannot
        -- hold the view of a player in a vehicle. 1.8.2 left such an AV to its
        -- pilot, and the pad no longer snapped it ("the AV pad isn't snapping
        -- the AV to the pad"). Now it is DOCKED: the screens of everybody
        -- aboard dip to black (`DOCK.FADE_OUT_MS`), the hull is set down on its
        -- gear on the deck -- centred, turned to the pad's heading -- in ONE
        -- move under the black, held `DOCK.HOLD_MS`, and the image comes back
        -- (`DOCK.FADE_IN_MS`) with the AV standing on the pad: one change of
        -- hands, hidden, instead of 129 in view. `DOCK.WAIT_MS`: the longest
        -- the server waits for the pilot's game to say its screen is black
        -- (then it moves all the same, and says so).
        -- `ABOARD = true`: glided down in view (the flicker); `false`: an AV
        -- somebody flies is left to them.
        ABOARD = 'dock',
        DOCK = {
            FADE_OUT_MS = 200,
            WAIT_MS = 1000,
            HOLD_MS = 500,
            FADE_IN_MS = 350,
        },
        RECORDS = { '^vehicle%.av_', '^vehicle%.max_tac_av$' },
        HEIGHT_METRES = 30.0,
        MARGIN_METRES = 6.0,
        MAX_SPEED = 10.0,
        CLIMB_MAX = 0.5,
        LOOKS = 2,
        REARM_METRES = 15.0,
        MEASURE_MS = 2000,
        SURFACE_METRES = { high = 2.0, medium = 4.0, low = 12.0 },
        FLAT_METRES = 0.4,
        TICK_MS = 50,
        GLIDE_SPEED = 4.0,
        TURN_RATE = 45.0,
        DESCENT = 4.0,
        APPROACH_METRES = 3.0,
        TOUCHDOWN = 1.0,
        HOVER_METRES = 2.5,
        HOLD_MS = 1200,
        MAX_MS = 30000,
    },
}
