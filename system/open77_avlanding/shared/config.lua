-- =============================================================================
-- open77_avlanding -- shared/config.lua
-- =============================================================================
-- "WARNING", in bold block letters, flashing on the ground under an aircraft
-- that comes down to it, inside a ring of warning words that turns slowly:
-- the landing sign (1.4.0; 1.0 to 1.3 flashed a cursive "Open77" in a plain
-- ring, and the Open77 client's dot-matrix OPEN77 of red mine-laser beams
-- before that).
--
-- WHAT IS DRAWN. Two effects in this resource's preload archive, the game's
-- own AV landing-area hologram (`v_av_landing_area_hologram.effect`) reduced
-- to one flat sign of its each, in the landing lasers' red with a stronger
-- glow, one texture for both (scripts/avlanding/make_warning.py):
--   * THE WORD (`EFFECT`): "WARNING" in Inter Black (SIL OFL) on its "STAY
--     AWAY" quad at 3.8 times its size, about 4.2 m long and 0.6 m tall. It
--     FLASHES the way the game's own STAY AWAY does: half a second on, half a
--     second off. It turns with the hull so that the pilot behind it reads it;
--   * THE RING (`RING_EFFECT`), on its square stop-sign quad at 12.6 times its
--     size, lit the whole time: the ring of 1.3 (3.44 to 3.79 m), a thin line
--     inside it (2.40 to 2.46 m), and between them a band of words --
--     "WARNING * AV LANDING ZONE * KEEP CLEAR *" round the circle in Inter
--     ExtraBold, 0.5 m capitals, their tops outward. It TURNS under the word,
--     `RING_DEGREES_PER_SECOND` (counterclockwise seen from above: the words
--     run past like a ticker), turned by this client every `RING_MS`.
-- Both lie on the ground's plane (client/main.lua: on a slope, a camber, a
-- kerb they tilt and rise with the ground instead of sinking into it).
-- README.md has the provenance and the build recipe.
--
-- WHEN. The hull's lowest point (the bottom of its loaded mesh) over the
-- ground straight under its centre is its CLEARANCE. The sign comes on while
-- the hull comes down within `SHOW_METRES` of clearance (faster than
-- `DESCEND_SPEED`), or stands within `REST_METRES` while it is in use (an
-- occupant, its engine, or a physics owner); it stays while the clearance is
-- within `SHOW_METRES`, and goes after `RETIRE_LOOKS` looks in a row out of
-- that band, or `LINGER_MS` after a parked hull fell idle.
-- =============================================================================

Open77AvLandingConfig = {
    -- The effect. Change it only with a new archive: the path carries the
    -- archive's revision, and a game mounts archives as it starts.
    EFFECT = 'open77\\fx\\avlanding\\10c786843d78\\open77_warning.effect',
    -- THE RING under the word (same archive), and its turn: degrees a second
    -- (positive: counterclockwise seen from above; 0 holds it still), turned
    -- every `RING_MS`. `RING_EFFECT = false`: the word alone.
    RING_EFFECT = 'open77\\fx\\avlanding\\10c786843d78\\open77_warning_ring.effect',
    RING_DEGREES_PER_SECOND = 20.0,
    RING_MS = 33,
    -- A GAME WITHOUT THIS RESOURCE'S ARCHIVE (1.4.2) draws the game's own AV
    -- landing-area hologram instead -- the effect the sign was cut from, in
    -- every copy of the game -- so an aircraft coming down is never unmarked:
    -- the old lasers are drawn as nothing on this server, and a game started
    -- with another world's mods had no marker at all (Staging, 2026-10-29).
    -- `FALLBACK_EFFECT = false`: nothing then.
    FALLBACK_EFFECT = 'base\\fx\\vehicles\\av\\_landing_area\\v_av_landing_area_hologram.effect',

    -- WHICH HULLS. Lua patterns against the lower-cased TweakDB record: the
    -- records the Open77 client flies as AVs (`Vehicle.av_*`,
    -- `Vehicle.max_tac_av`) and the airframes open77_avdoor knows as aircraft
    -- (the Trauma Team's among them).
    RECORDS = { '^vehicle%.av_', 'max_tac_av', '_av$', '_av%d+$', '_av_' },

    -- How far from this player a hull is looked at, and how many at once (the
    -- nearest). Each sign is one effect; the game's own signs stop drawing at
    -- 100 m.
    RANGE_METRES = 120.0,
    MAX_HULLS = 6,

    -- The band, as the client's own landing pad keeps it, measured from the
    -- hull's lowest point.
    SHOW_METRES = 6.0,
    REST_METRES = 1.5,
    DESCEND_SPEED = 0.4,
    RETIRE_LOOKS = 10,
    LINGER_MS = 8000,

    -- Height of the effect over the ground's plane (its word floats another
    -- 6 cm, its ring 4 cm).
    LIFT_METRES = 0.15,

    -- THE GROUND'S PLANE (client/main.lua says how it is found). Rays go
    -- straight down at the sign's centre, at eight points `FIT_RADIUS_METRES`
    -- round it (just past the ring's edge, 3.8 m) and at four
    -- `FIT_INNER_METRES` round it (on the word's); 0 drops a circle, both 0
    -- lay the sign flat on the ground under its centre.
    FIT_RADIUS_METRES = 3.9,
    FIT_INNER_METRES = 2.0,
    -- The steepest the sign tilts. Steeper ground (stairs, a ramp's edge):
    -- held to this slope and raised until no sample is above it.
    MAX_TILT_DEGREES = 20.0,
    -- A sample is the ground the centre stands on when it is within this of
    -- the centre's height, plus what MAX_TILT_DEGREES allows at its distance:
    -- a kerb is, a wall, a roof's edge or the street under it is not.
    FIT_STEP_METRES = 0.6,
    -- A sample further than this off the plane of the others is dropped (a
    -- bench, a bollard, a drain), three at most.
    FIT_RESIDUAL_METRES = 0.35,
    -- The rays start this far over the ground under the centre (low enough
    -- not to meet an awning or a tree over the pad).
    FIT_REACH_METRES = 2.5,
    -- The plane is measured again this often, and when the sign moved half a
    -- metre (at most every GROUND_MS).
    REFIT_MS = 2000,
    -- What one plane may cost. The game runs this resource's Lua in slices
    -- with an instruction budget: of the planes through three samples at most
    -- `FIT_TRIPLES` are tried (the centre's first; a plane every sample lies on
    -- ends it at once), and one look over the hulls measures at most
    -- `FITS_PER_LOOK` planes -- a hull whose plane is due waits for the next
    -- look (LOOK_MS later). Every triple of thirteen samples ran out of the
    -- budget over a kerb (Staging, 2026-10-27, 17:40:21).
    FIT_TRIPLES = 96,
    FITS_PER_LOOK = 1,

    -- Where the sign lies along the hull's own axis, from the centre of its
    -- mesh box: 0 is straight under the hull; a positive number moves it
    -- ahead of the nose by that many metres (a pilot's camera behind a hull
    -- that is about to touch down sees past its nose, not under its belly).
    AHEAD_METRES = 0.0,

    -- `/avlanding.test` (a server command anybody may type in chat; the
    -- caller's game does the work): the sign on the ground
    -- `TEST_AHEAD_METRES` in front of the player for `TEST_SECONDS`, its top
    -- pointing away -- how it looks in this game, without an aircraft.
    TEST_AHEAD_METRES = 8.0,
    TEST_SECONDS = 20,
    -- The server sends the test to one player at most this often.
    TEST_COOLDOWN_MS = 3000,

    -- Looks a second at the hulls in the band (the sign follows the hull at
    -- this rate; the effect glides between two looks), how often the hulls in
    -- range are listed, and how often the ground under a hull is measured.
    LOOK_MS = 50,
    LIST_MS = 500,
    GROUND_MS = 400,
}
