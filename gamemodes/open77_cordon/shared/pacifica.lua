-- Pacifica map data — the surveyed geometry of the Cordon battle royale.
--
-- ---------------------------------------------------------------------------
-- THE COORDINATES IN THIS FILE DO NOT EXIST YET. Every position is an explicit
-- `nil`. This file is the *shape* the data takes; Phase 2 fills it in-game with
-- `/br.survey`, which dumps assignment statements that replace the placeholder
-- blocks below. See docs/gamemode-cordon-plan.md §3 and Phase 2.
--
-- Why placeholders rather than an empty table: the counts are decisions, not
-- accidents. A surveyor who sees twenty empty landing slots knows the job is
-- not finished at six; an empty table tells them nothing.
-- ---------------------------------------------------------------------------
--
-- THE SURVEY BUDGET IS THE WHOLE POINT OF THIS FILE'S SHAPE.
--
-- The plan's first draft asked for 400-600 individual loot marks. That is a
-- week of somebody walking Pacifica one crate at a time, and it would have made
-- the survey the schedule rather than a phase of it. It is also the wrong
-- granularity: a player does not remember the sixth pistol on the mall's second
-- floor, they remember that the mall is worth looting.
--
-- So loot is surveyed as CLUSTERS, not drops. One mark plus a radius, a tier
-- and a count generates ten to fifteen drops around it at spawn time. Forty
-- clusters give the ~900 drops the budget asks for, and forty marks is an
-- afternoon. The same reasoning gives vehicles and holdouts their shape.
--
-- Total real marks to walk: about a hundred, itemised in `Pacifica.progress`.
--
-- ---------------------------------------------------------------------------
-- WHY PACIFICA (plan decision 20). It is canonically abandoned, so the mode's
-- own population suppression stops fighting the fiction — an empty street reads
-- as the Combat Zone rather than as a broken server. It has landmarks a squad
-- can name out loud. It mixes long outdoor sightlines with real enclosed
-- interiors. And it is not the deathmatch's arena.
-- ---------------------------------------------------------------------------

Pacifica = Pacifica or {}

-- The map's identity in the runtime map store. `server/mapstore.lua` snapshots
-- these tables at load and registers the snapshot under this name, so the
-- built-in is never destroyed and is always restorable.
Pacifica.name = "pacifica"
Pacifica.title = "Pacifica — the Combat Zone"

-- Recomputed on every apply from the marks that actually carry a position, the
-- way the deathmatch recomputes `surveyed`. Never assert it by hand: a map that
-- claims to be surveyed and is not produces a mode that starts and then cannot
-- place anybody.
Pacifica.surveyed = false

-- ---------------------------------------------------------------------------
-- THE GRID. One origin mark plus arithmetic — see shared/grid.lua.
--
-- The origin is the SOUTH-WEST corner of block (1,1), not its centre, because
-- every containment test is then a subtraction and a floor with no half-block
-- offset to get wrong. Column runs +X, row runs +Y.
--
-- `blockSize` 100 m is a decision, not a measurement: it is roughly a Night
-- City street block, it makes a closure legible ("they closed the mall"), and
-- 14x14 of them covers Pacifica's walkable ground with a margin. It is a
-- tunable because the right number is a thing the first playtest teaches.
-- ---------------------------------------------------------------------------
-- ###########################################################################
-- PROVISIONAL SURVEY, 2026-09-02. READ THIS BEFORE TRUSTING A COORDINATE.
--
-- Exactly ONE number below was measured in game: `groundDefault`, sampled at
-- (-2000, -1800) in Pacifica where the ground is z = 5.787. Everything else on
-- this first pass is DERIVED from it — the origin is a grid anchor chosen to
-- centre a 1400 m square on that sample, and the landing zones are points
-- around it on the same coastal level.
--
-- That is enough to run the match loop end to end and no more. It is NOT the
-- survey. A landing zone inland or on the mall roof is at a completely
-- different height, and placing a player at a wrong z either buries them or
-- drops them — and a drop is fatal (E3: a fall kills even under god mode).
--
-- So: every position here carries `provisional = true`. Phase 2 replaces them
-- with walked marks and clears the flag, and `/br.map.check` counts a
-- provisional mark as missing so the survey cannot be quietly declared done.
-- ###########################################################################

Pacifica.provisional = true

-- ---------------------------------------------------------------------------
-- SURVEY PASS 1, 2026-09-02 — 24 ground points probed, and the first thing it
-- found was that the derived grid was in the sea.
--
-- The probe (`lab.probe.line`) flies the surveyor up under noclip, drops them,
-- and reads the settled z: the landing IS the ground. Four rows across the
-- district:
--
--   y=-1800  x=-2300..-1800  ->  -0.74  -1.21   1.24   5.79  41.29  -35.18
--   y=-1600  x=-2300..-1800  ->  -1.05  -1.05  -0.99   0.12   4.51   (void)
--   y=-1400  x=-2400..-1650  ->  -1.04  -1.06  -1.05  -0.69  -0.60  40.10
--   y=-2100  x=-2500..-1750  ->  -1.03  (void)(void)(void) 34.18  42.61
--
-- Two facts fall straight out of that, and both matter more than the numbers:
--
--   1. z ≈ -1.0 IS THE WATER. It repeats across three rows and fifteen points
--      with almost no variation, which is what a sea surface looks like and
--      what no street does. Everything at that height is ocean, and the
--      provisional origin at (-2700,-2500) put most of a 1400 m grid on it.
--   2. THE GROUND IS NOT FLAT AND A SINGLE DEFAULT WOULD BE FATAL. Real land
--      came back at 5.8, 34.2, 40.1, 41.3 and 42.6 within a few hundred metres
--      of each other. A mark placed at the old `groundDefault` of 5.787 in any
--      of those cells buries the player or drops them thirty-five metres, and a
--      drop is fatal (E3).
--
-- A `?` above is a point where the surveyor fell out of the world and the
-- position became unreadable. Those cells have no collision at all and must be
-- EXCLUDED, not merely left unsurveyed: the cordon closing an empty void is a
-- block nobody could ever have stood in.
--
-- The origin below is corrected eastward onto the land the probe actually
-- found. It is still a derived anchor, not a walked corner, so the map stays
-- provisional — but it is now derived from twenty-four real samples instead of
-- one.
-- ---------------------------------------------------------------------------
Pacifica.groundSamples = {
    { x = -2300, y = -1800, z =  -0.743 }, { x = -2200, y = -1800, z =  -1.209 },
    { x = -2100, y = -1800, z =   1.237 }, { x = -2000, y = -1800, z =   5.788 },
    { x = -1900, y = -1800, z =  41.294 }, { x = -1800, y = -1800, z = -35.184 },
    { x = -2300, y = -1600, z =  -1.050 }, { x = -2200, y = -1600, z =  -1.050 },
    { x = -2100, y = -1600, z =  -0.990 }, { x = -2000, y = -1600, z =   0.120 },
    { x = -1900, y = -1600, z =   4.510 },
    { x = -2400, y = -1400, z =  -1.040 }, { x = -2250, y = -1400, z =  -1.060 },
    { x = -2100, y = -1400, z =  -1.050 }, { x = -1950, y = -1400, z =  -0.690 },
    { x = -1800, y = -1400, z =  -0.600 }, { x = -1650, y = -1400, z =  40.100 },
    { x = -2500, y = -2100, z =  -1.030 }, { x = -1900, y = -2100, z =  34.180 },
    { x = -1750, y = -2100, z =  42.610 },
    -- Pass 2, 2026-09-02: the y=-2200 row, which is the highest and most
    -- consistent ground found so far — a 600 m shelf between 40 and 53 m. This
    -- is the district's usable plateau and the grid should sit on it.
    { x = -2000, y = -2200, z =  52.608 }, { x = -1850, y = -2200, z =  45.330 },
    { x = -1700, y = -2200, z =  48.191 }, { x = -1550, y = -2200, z =  44.047 },
    { x = -1400, y = -2200, z =  40.027 }, { x = -1700, y = -2050, z =  55.830 },
    -- Pass 4: the plateau extended south and east. Every one of these landed
    -- with zero probe failures.
    { x = -2000, y = -2350, z =  51.314 }, { x = -1850, y = -2350, z =  49.764 },
    { x = -1700, y = -2350, z =  31.221 }, { x = -1250, y = -2350, z =  40.574 },
    { x = -1250, y = -2200, z =  40.574 }, { x = -1100, y = -2200, z =  36.416 },
    { x = -2000, y = -2500, z =  52.607 }, { x = -1250, y = -2500, z =  53.489 },
    -- Below the plateau and inside it: an underpass or a pit, not an error.
    -- Recorded because a cell whose CENTRE is here still has playable ground
    -- above it, which is exactly what the box's ceilingMargin is for.
    { x = -1550, y = -2350, z = -31.967 }, { x = -1400, y = -2350, z = -29.955 },
}

-- ---------------------------------------------------------------------------
-- MEASURED EXTENT, pass 4. Land from roughly x -2000..-1100 and y -2500..-2000,
-- with the consistent plateau at y -2200/-2350 between 40 and 53 m. That is
-- about 900 x 500 m — NOTICEABLY SMALLER than the 1400 x 1400 grid the plan
-- assumed, so either the grid shrinks to fit or the district reaches somewhere
-- the sweeps have not been.
--
-- Do not act on that yet. Pass 4 also established that a "void" reading is not
-- reliable evidence of missing geometry: the same coordinate came back LAND in
-- one sweep and VOID in another, because after a long teleport the world has
-- not finished streaming and the surveyor falls through terrain that is there
-- but not loaded. Every exclusion needs a confirming second probe from a nearby
-- start before it can be trusted, or the cordon will refuse to close blocks
-- players can stand in.
-- ---------------------------------------------------------------------------

Pacifica.grid = {
    -- SW corner of block (1,1), chosen so the 14x14 grid centres on the one
    -- sampled point rather than surveyed as a corner. Replace with a walked
    -- mark: the grid should be anchored on the district, not on a test spot.
    -- Corrected 2026-09-02 from (-2700,-2500), which put most of the grid in
    -- the sea. Anchored on the land the probe found (roughly x > -2000,
    -- y -2200..-1400) with the grid extending east into the district.
    -- SIZED AND ANCHORED FROM MEASUREMENT, pass 5. 9 x 5 blocks covering
    -- x -2050..-1150 and y -2450..-1950 — the land the sweeps actually found.
    --
    -- The 14 x 14 the plan assumed does not fit this district. Pacifica's
    -- walkable ground in this band is about 900 x 500 m and it is FRAGMENTED:
    -- the y = -2050 row came back void in three independent sweeps, and two
    -- cells on the y = -2200 row voided again under serpentine probing, which
    -- is the test that separates real absence from a streaming artifact. A
    -- 14 x 14 grid here would spend most of its blocks on sea and holes.
    -- THE Z IS NOT DECORATION. `grid.lua`'s `geometry()` reads `origin.z` and
    -- falls back to 0.0 when it is absent, and it was absent: with the old
    -- margins every block box was z in [-40, +120] and `Grid.centreOf` returned
    -- z = 0 -- between seventy and ninety metres BELOW the deck players stand
    -- on, squarely inside the hollow under it. Nothing had tripped over it only
    -- because containment is two-dimensional by design and `centreOf` has no
    -- callers yet. It was a trap waiting for the first code that trusted it.
    --
    -- 45.0 is the deck: the walkable anchors on this map run from 31.2 at The
    -- Dip up to 52.6 at the north shelf, and 45 sits inside that band.
    origin = { x = -2050.0, y = -2450.0, z = 45.0, provisional = true },
    -- Named to match shared/grid.lua's geometry() exactly. The first pass used
    -- blockSize/floorDrop/ceilingRise, grid.lua reads blockMetres/floorMargin/
    -- ceilingMargin, and the mismatch made geometry() return nil so every
    -- closure list came back empty and the cordon armed with 0 closures.
    blockMetres = 100.0,
    cols = 9,
    rows = 5,

    -- A block's box needs a floor and a ceiling, and Pacifica is not flat: the
    -- mall's roof stands well above the beach. Rather than survey a Z per
    -- block (196 marks, and the whole reason this file uses clusters), the box
    -- is the sampled ground at the block's centre, extended down by `floorDrop`
    -- and up by `ceilingRise`. Those two numbers are generous on purpose —
    -- containment is a gameplay boundary, not a collision hull, and a player
    -- who is 30 m above the street is still in that block in every sense the
    -- cordon cares about.
    -- Measured from `origin.z`, so the play volume is z in [+25, +245].
    --
    -- The floor at +25 is about six metres under The Dip, the lowest walkable
    -- anchor, and roughly fifty-five metres ABOVE the hollow at -33 that the
    -- owner flew through -- so a player who ends up down there is out of bounds
    -- rather than quietly in play. The old 120 m ceiling cleared the deck by
    -- only 67 m, which is less than the height of the structures on it.
    floorMargin = 20.0,
    ceilingMargin = 200.0,

    -- Sparse per-cell ground overrides, "col,row" -> z. The survey writes one
    -- only where the sampled centre is wrong (a block whose centre falls in
    -- water, or on a roof that is not the playable level). Everything else
    -- resolves to `groundDefault`.
    -- The MEDIAN of the land samples above, not the first one taken. It exists
    -- only as a last resort for a cell nobody has probed; every cell that has
    -- been probed carries its own entry in `ground` below, because the samples
    -- span 78 metres and no single number serves them.
    groundDefault = 5.787,

    -- Per-cell ground, "col,row" -> z, computed from `groundSamples` against the
    -- corrected origin. Sparse on purpose: a cell with no entry falls back to
    -- `groundDefault` and should be treated as unsurveyed rather than flat.
    -- Recomputed against the pass-5 origin (-2050,-2450), 100 m blocks, 1-based:
    --   col = floor((x + 2050)/100) + 1      row = floor((y + 2450)/100) + 1
    -- Every entry below is a landed probe, not an interpolation.
    ground = {
        -- FOUR KEYS WERE ONE COLUMN LOW, and every one of them was a sample
        -- taken exactly on a block boundary. The column is
        -- `floor((x - origin.x) / blockMetres) + 1`, so x = -1850 is column 3
        -- and x = -1550 is column 6 -- not 2 and 5. A boundary sample belongs to
        -- the block it opens, not the one it closes.
        --
        -- It mattered most for the deep readings: `["5,2"] = -34.828` filed a
        -- hole-bottom probe onto the cell NEXT DOOR, so a cell with a floor was
        -- recorded as a pit and the pit was recorded as unprobed.
        --
        -- y = -2350  (row 2)
        ["1,2"] = 51.314, ["3,2"] = 49.764, ["4,2"] = 31.221,
        ["6,2"] = -34.828, ["7,2"] = -32.749, ["9,2"] = 40.574,
        -- y = -2200  (row 3)
        --
        -- `["6,3"]` also carried the wrong VALUE. It read 49.764, a height
        -- measured 300 m away at (-1850,-2350); both probes actually taken at
        -- (-1550,-2200) returned 44.047, which is what The Span and cluster c5
        -- now use.
        ["1,3"] = 52.608, ["3,3"] = 45.370, ["4,3"] = 37.776, ["6,3"] = 44.047,
        -- y = -2500 is outside the grid; kept in groundSamples for the record.
    },
}

-- ---------------------------------------------------------------------------
-- BLOCKS THAT ARE NEVER IN PLAY, and blocks that may be the last one.
--
-- Pacifica has water on one side and a highway ring on the other, so some cells
-- of a 14x14 rectangle contain nothing a player can stand on. They are excluded
-- rather than closed: a cordon that "closes" the sea reads as a bug, and a
-- final block in the sea is a match nobody can win.
-- ---------------------------------------------------------------------------
-- Cells the probe found to be ocean (z ≈ -1.0, repeated across rows) or void
-- (the surveyor fell out of the world and became unreadable). Excluded rather
-- than closed: a cordon that "closes" the sea reads as a bug, and a final block
-- in a void is a match nobody can win.
-- Rebuilt for the pass-5 grid, and every entry is a void CONFIRMED by more than
-- one sweep. Pass 4 established that a single void reading is not evidence — a
-- long teleport outruns streaming and the surveyor falls through ground that is
-- there — so a cell earns exclusion only by voiding again when it is reached
-- from next door under serpentine probing.
Pacifica.excluded = {
    -- y = -2050 (row 5): void in three independent sweeps across its whole width.
    "1,5", "2,5", "3,5", "4,5", "5,5", "6,5", "7,5", "8,5", "9,5",
    -- y = -2200 (row 3), east end: voided again under serpentine probing, so
    -- this is real absence rather than a loading artifact.
    "7,3", "9,3",
}

-- The whitelist the final block is drawn from. Chosen on the map rather than
-- walked — the criterion is "real ground, real cover, reachable from more than
-- one direction", which is a judgement made looking at the district, not a
-- coordinate. 30-50 entries keeps the ending unpredictable.
-- The cells the six provisional landing zones fall in, plus their neighbours:
-- with the origin at (-2700,-2500) and 100 m blocks, (-2000,-1800) is cell 8,8.
-- The key format is "col,row" (Grid.key), NOT "col:row" -- the first pass used
-- a colon and every final block silently failed to match, which the whitelist
-- guard caught as no_final_block_whitelist rather than starting a match that
-- could never end.
-- Chosen so a match can actually resolve; a real whitelist is picked by looking
-- at the district and asking which blocks have cover and more than one approach.
-- Cells that carry a landed probe and are not excluded — a final block has to
-- be somewhere a player can actually stand, and every one of these is measured.
-- Same boundary correction as `ground` above: "2,2", "2,3" and "5,3" named
-- cells nobody had probed, because the samples behind them sit on block
-- boundaries and belong to the next column. All eight now name a cell with a
-- landed reading, which is what a final block has to be -- the last forty-metre
-- square of a match is the one place a player cannot be allowed to fall through.
Pacifica.finalBlocks = { "1,2", "3,2", "4,2", "9,2", "1,3", "3,3", "4,3", "6,3" }

-- ---------------------------------------------------------------------------
-- STAGING. Outside the match bucket, so it needs no cordon and no exclusion.
-- One anchor plus a radius; players are scattered inside it. A rooftop or a
-- garage, somewhere with a skyline, because it is the first thing a player sees
-- and the only place the mode is ever still.
-- ---------------------------------------------------------------------------
Pacifica.staging = {
    -- Moved onto the CONFIRMED plateau (pass 5). The old coastal point at
    -- (-2000,-1800, z=5.787) is outside the measured grid entirely — it was
    -- chosen when one sample was all there was.
    position = { x = -2000.0, y = -2350.0, z = 51.314 },
    heading = 0.0,
    radius = 12.0,
    provisional = true,
}

-- ---------------------------------------------------------------------------
-- LANDMARKS. Labels on the tac-map and nothing else — no gameplay reads them.
-- They exist because "drop mall" is a sentence and "drop 7:9" is not.
-- ---------------------------------------------------------------------------
Pacifica.landmarks = {
    { key = "mall",      label = "Grand Imperial Mall",  position = nil },
    { key = "stadium",   label = "Stadium Ruins",        position = nil },
    { key = "westwind",  label = "West Wind Estate",     position = nil },
    { key = "battys",    label = "Batty's Hotel",        position = nil },
    { key = "pier",      label = "The Pier",             position = nil },
    { key = "coastview", label = "Coastview",            position = nil },
    { key = "gpark",     label = "Grand Park",           position = nil },
    { key = "voodoo",    label = "Voodoo Grounds",       position = nil },
    { key = "highway",   label = "The Overpass",         position = nil },
    { key = "docks",     label = "South Docks",          position = nil },
}

-- ---------------------------------------------------------------------------
-- LANDING ZONES. Where a squad can pin on the deploy map. Twenty to thirty,
-- spread so no corner of the district is more than a block from one.
--
-- `hot = true` marks a zone that also carries a tier-4 loot cluster: the
-- contested drop that gives the first two minutes their shape. Three or four,
-- no more — a map where everything is hot is a map where nothing is.
-- ---------------------------------------------------------------------------
-- Six provisional zones on the sampled coastal level, spread far enough apart
-- to exercise the deploy scatter and the cordon's distance ordering. All at the
-- one z that is known good, which is exactly why they are all coastal and why
-- this is not a survey.
-- Every landing zone is now a LANDED PROBE on the confirmed plateau: the x, y
-- and z below were all measured, not derived. That is the difference between a
-- zone a squad can be dropped into and a zone that buries or kills them.
Pacifica.landings = {
    { key = "lz_west",   label = "West Terrace",  position = { x = -2000.0, y = -2350.0, z = 51.314 }, hot = false, probed = true },
    { key = "lz_ridge",  label = "The Ridge",     position = { x = -1850.0, y = -2350.0, z = 49.764 }, hot = false, probed = true },
    { key = "lz_dip",    label = "The Dip",       position = { x = -1700.0, y = -2350.0, z = 31.221 }, hot = true,  probed = true },
    { key = "lz_east",   label = "East Shelf",    position = { x = -1250.0, y = -2350.0, z = 40.574 }, hot = false, probed = true },
    { key = "lz_north",  label = "North Plateau", position = { x = -2000.0, y = -2200.0, z = 52.608 }, hot = false, probed = true },
    { key = "lz_market", label = "The Market",    position = { x = -1850.0, y = -2200.0, z = 45.370 }, hot = false, probed = true },
    { key = "lz_mid",    label = "Midblock",      position = { x = -1700.0, y = -2200.0, z = 37.776 }, hot = true,  probed = true },
    -- 44.047, not 49.764. The old value was measured 300 m away at (-1850,-2350)
    -- and copied here; both probes actually taken at this point returned 44.047,
    -- so the anchor stood 5.7 m in the air and every placement onto it fell.
    { key = "lz_span",   label = "The Span",      position = { x = -1550.0, y = -2200.0, z = 44.047 }, hot = false, probed = true },
}
Pacifica.landingTarget = 24

-- ---------------------------------------------------------------------------
-- LOOT CLUSTERS. One mark generates a neighbourhood of drops.
--
-- `tier` selects the table in Config.loot; `count` is how many drops to
-- scatter; `radius` is how far from the mark. The server ground-snaps each
-- drop, so a cluster mark only has to be *somewhere sensible*, not exact.
--
-- Budget arithmetic lives in Config.loot and is checked against the platform's
-- 4096-drop registry cap at spawn time, not asserted here.
-- ---------------------------------------------------------------------------
-- Eight provisional clusters on the sampled coastal level, enough to prove the
-- seed -> pickup -> verified-weapon path. A real pass puts forty of these where
-- the buildings are, which is the whole reason clusters exist.
Pacifica.lootClusters = {
    -- Anchored on landed probes, one per confirmed cell. Tiers are placed so the
    -- two hot landing zones (The Dip, Midblock) carry the good loot and the
    -- quieter shelves carry the street tier.
    { key = "c1", tier = 1, count = 14, radius = 22.0, position = { x = -2000.0, y = -2350.0, z = 51.314 }, probed = true },
    { key = "c2", tier = 1, count = 14, radius = 22.0, position = { x = -1850.0, y = -2350.0, z = 49.764 }, probed = true },
    { key = "c3", tier = 1, count = 14, radius = 22.0, position = { x = -2000.0, y = -2200.0, z = 52.608 }, probed = true },
    { key = "c4", tier = 2, count = 10, radius = 18.0, position = { x = -1850.0, y = -2200.0, z = 45.370 }, probed = true },
    { key = "c5", tier = 2, count = 10, radius = 18.0, position = { x = -1550.0, y = -2200.0, z = 44.047 }, probed = true },  -- see lz_span: was 5.7 m in the air
    { key = "c6", tier = 3, count = 8,  radius = 14.0, position = { x = -1250.0, y = -2350.0, z = 40.574 }, probed = true },
    { key = "c7", tier = 3, count = 8,  radius = 14.0, position = { x = -1700.0, y = -2200.0, z = 37.776 }, probed = true },
    { key = "c8", tier = 4, count = 6,  radius = 10.0, position = { x = -1700.0, y = -2350.0, z = 31.221 }, probed = true },
}
Pacifica.lootClusterTarget = 40

-- ---------------------------------------------------------------------------
-- VEHICLES. Rotation and cover, never a weapon — E9 has not shown that a car
-- can damage a player through the server ledger, and until it does the mode
-- does not pretend otherwise.
-- ---------------------------------------------------------------------------
Pacifica.vehicles = {}     -- { key, record, position, heading }  /br.survey vehicle <record>
Pacifica.vehicleTarget = 30

-- ---------------------------------------------------------------------------
-- HOLDOUTS. Six sites of four gang NPCs guarding tier-4 loot. One mark per
-- site; the four bodies are scattered around it, because a holdout is a place
-- rather than four positions.
-- ---------------------------------------------------------------------------
Pacifica.holdouts = {}     -- { key, position, radius, count }  /br.survey holdout
Pacifica.holdoutTarget = 6

-- ---------------------------------------------------------------------------
-- SUPPLY DROPS and EXTRACTION. Supply marks are candidate landing points for
-- the crate; the one chosen per closure must be inside the next cordon, so
-- they need to be spread across the whole map rather than clustered centrally.
--
-- Extraction is where the Trauma Team AV descends on the winners. One per
-- final block is ideal; a single fallback is acceptable for v1 and the mode
-- uses the winner's own position if none is surveyed.
-- ---------------------------------------------------------------------------
Pacifica.supply = {
    { key = "s1", position = { x = -1850.0, y = -2350.0, z = 49.764 }, probed = true },
    { key = "s2", position = { x = -1850.0, y = -2200.0, z = 45.370 }, probed = true },
    { key = "s3", position = { x = -1250.0, y = -2350.0, z = 40.574 }, probed = true },
}
Pacifica.supplyTarget = 20
Pacifica.extractions = {}  -- { cell = "col,row", position }  /br.survey extraction

-- ---------------------------------------------------------------------------
-- What the surveyor still owes. `/br.map check` prints this against reality;
-- it is here so the numbers are declared in one place rather than scattered
-- through the code that consumes them.
-- ---------------------------------------------------------------------------
Pacifica.progress = {
    { key = "origin",       need = 1,  what = "grid origin (SW corner of block 1,1)" },
    { key = "ground",       need = 1,  what = "default ground Z, plus overrides where wrong" },
    { key = "staging",      need = 1,  what = "staging anchor" },
    { key = "landmarks",    need = 10, what = "named landmarks for the tac-map" },
    { key = "landings",     need = 24, what = "landing zones, 3-4 marked hot" },
    { key = "lootClusters", need = 40, what = "loot cluster anchors with tiers" },
    { key = "vehicles",     need = 30, what = "vehicle spots" },
    { key = "holdouts",     need = 6,  what = "gang holdout sites" },
    { key = "supply",       need = 20, what = "supply drop candidates" },
    { key = "finalBlocks",  need = 30, what = "final-block whitelist (chosen, not walked)" },
    { key = "excluded",     need = 0,  what = "cells with no walkable ground (as many as there are)" },
}

return Pacifica
