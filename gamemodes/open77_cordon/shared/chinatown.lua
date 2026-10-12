-- Chinatown / Watson -- Little China. THE SECOND MAP, AND A SKELETON.
--
-- ---------------------------------------------------------------------------
-- READ THIS FIRST: NOTHING HERE WAS WALKED, PROBED, RUN OR SEEN IN GAME.
--
-- Not one coordinate below was captured by standing on it. No build was run, no
-- server started, no client connected, no resource reloaded while this file was
-- written. The grid is DERIVED from the engine's own streaming index; every
-- height is a CANDIDATE; and the point arrays are EMPTY because the survey
-- belongs to the owner and he walks it himself.
--
-- The map therefore ships DELIBERATELY UNPLAYABLE. `K.recomputeSurveyed()`
-- (server/main.lua:46-63) needs five things, and this file supplies four:
-- origin, groundDefault, staging and finalBlocks are here, `landings` is `{}`.
-- So `surveyed` computes false and `/br.start` answers
--
--     refused: the map is not surveyed (needs origin, ground, staging,
--              a landing zone and a final-block whitelist)
--
-- THAT EMPTY ARRAY IS THE MOST IMPORTANT LINE IN THE FILE. Every z below is a
-- guess with an argument attached. If the map could start, sixty-four players
-- would be placed at those heights, and battle-royale-and-scale.md:248-253 is
-- explicit about what a wrong ground plane does: it buries a player or drops
-- them thirty-five metres, and a drop kills. One empty array makes that
-- impossible until the landing zones have been walked -- by which point every
-- other number here has been checked too. Fill `landings` LAST, not first.
--
-- The full argument, the vehicle plan, the loot model and the walk list are in
-- docs/gamemode-cordon-chinatown.md.
--
-- ---------------------------------------------------------------------------
-- WHERE THIS IS, AND WHY IT IS NOT A GUESS.
--
-- The owner says "Chinatown". THE ENGINE DOES NOT USE THAT WORD. The world
-- hierarchy is `$/03_night_city/c_watson/little_china/`, three-letter code
-- `lch`, siblings `kabuki` (`kab`) and `northside` (`nid`) -- see
-- base/scripts/build-prologue-world-variant-overrides.ps1:86-106 and the crowd
-- entity `crowd__watson_littlechina_ma.ent`
-- (docs/generated/npc-records-2.31.csv:476). Japantown is a different district
-- entirely (`c_westbrook/japan_town`). So this map is Little China, in Watson,
-- one sub-district over from the Kabuki ground the deathmatch and shared/watson
-- already play on without a single collision complaint.
--
-- The extent comes from `all.streamingblock`, the compiled Night City streaming
-- index, deserialised on this workstation at
--     base/build/generated/prologue-world-variants/json/all.streamingblock.json
-- (38.5 MB, GameVersion 2310). It holds 23 689 sector descriptors with
-- world-space bounding boxes and 1 958 node refs under
-- `$/03_night_city/c_watson/little_china/`. LOD-0 sectors are named
-- `exterior_<i>_<j>_<k>_0` on a 64 m cell, so sector (i,j) is
-- x in [64i, 64i+64), y in [64j, 64j+64) -- confirmed against the one measured
-- point this repository already had: (-2092.2, 807.9, 53.1) is recorded as
-- being in `exterior_-33_12_0_0`, and -33*64 = -2112..-2048, 12*64 = 768..832
-- both contain it (docs/research/multiplayer-mode.md:1014).
--
-- Little China's footprint, by node-ref density:
--
--     >=1 ref    x -2176..-1088   y  448..2176   105 cells
--     >=3 ref    x -2112..-1216   y  896..2176    66 cells   (the core)
--     >=5 ref    x -2112..-1216   y  896..1792    28 cells   (the dense core)
--
-- THE GRID BELOW IS THE DENSE CORE, EXACTLY: origin (-2112, 896), seven blocks
-- of 128 m on each axis, x -2112..-1216 and y 896..1792. Nothing was rounded to
-- make that fit; it is what the index says.
--
-- Neighbours, same method, so the edges are known rather than assumed:
-- kabuki x -1280..-768 y 1088..2496 (so the east edge of this grid touches
-- Kabuki's west edge around x -1280..-1216); arasaka_waterfront x -2176..-1728
-- y 1920..2688, north of the top edge.
--
-- ---------------------------------------------------------------------------
-- WHY 7 x 7 OF 128 m, AND WHY SEVEN IS NOT NEGOTIABLE.
--
-- `Grid.subdivisionFor` (shared/grid.lua:496-516) grows the lattice factor only
-- while `shortest_side * factor < minCellsPerSide (8)`. So:
--
--     7 x 7 of 128 m  ->  factor 2  ->  lattice 14 x 14 of 64 m  ->  8 phases
--     8 x 8 of 100 m  ->  factor 1  ->  lattice  8 x  8 of 100 m ->  5 phases
--
-- AN EIGHT-WIDE MAP IS A WORSE BATTLE ROYALE THAN A SEVEN-WIDE ONE that is
-- smaller in metres: it gets four shrink phases instead of seven, and its last
-- fight happens in a 100 m box instead of a 64 m one. The moment the short side
-- reaches eight the lattice stops subdividing and everything downstream
-- degrades at once. Seven is the number to hold; `blockMetres` is the dial.
--
-- 128 m earns its place twice over. It makes the map 896 m square, which is the
-- dense core to the metre -- and because 128 / factor 2 = 64, EVERY LATTICE CELL
-- IS EXACTLY ONE STREAMING SECTOR, and the origin sits on a sector corner
-- (-2112 = -33*64, 896 = 14*64). Lattice cell (i,j) is sector (i-34, j+13).
-- A cell key and a sector name are the same statement about the same ground,
-- which is worth a great deal to a survey that has to cross-check itself.
--
-- WHAT THE SIZE BUYS, and it is not only the owner's reasons. The server's
-- `playerInterestRadius` is 500 m (server/server.cordon-local.jsonc:63) and
-- wiki/cordon.md:695 forbids lowering it, because 500 m is the longest ranged
-- damage the arbiter honours. Watson is 200 m across with a 283 m diagonal, so
-- every player on it is always inside every other player's interest radius and
-- Phase 1 CULLS NOTHING there (battle-royale-and-scale.md:4067-4071). This map
-- is 896 m across, diagonal 1267 m: 43.7 % of player pairs fall outside 500 m
-- in the early game (uniform-pair arithmetic, 400 000-sample Monte Carlo, mine,
-- never run against a client). The measured stake is 18 772 KiB/s of egress
-- clustered against 2 379 KiB/s spread (battle-royale-and-scale.md:4048).
--
-- The match length does not change: grace 45 + cordon 300 + final 25 = 370 s on
-- every map, because C.buildSchedule normalises the per-step durations. What
-- changes is the zone sequence -- 832 -> 704 -> 576 -> 448 -> 320 -> 192 -> 64 m
-- against Watson's 275 -> 25 -- and, pleasantly, the rotation stays walkable:
-- each step retires exactly one 64 m ring, so the worst move to safety is 64 m
-- in the shortest 23.8 s step. The case for cars is speed and reach, not
-- survival.
-- ---------------------------------------------------------------------------

Chinatown = Chinatown or {}

Chinatown.name = "chinatown"
Chinatown.title = "Chinatown — Little China"

-- Both false, and both honest. `surveyed` is recomputed by the server anyway
-- (server/main.lua:46-63) and will stay false while `landings` is empty.
Chinatown.surveyed = false
Chinatown.provisional = true

-- NOTHING HAS BEEN WALKED IN THIS DISTRICT. Watson's fourteen entries here are
-- literal deathmatch spawns players have fought over for weeks; Little China has
-- no equivalent and this array must stay empty until it does. `surveyedCells`
-- in server/cordon.lua:353-369 reads it to decide which lattice cells the final
-- zone may land in, so filling it with anything unwalked would quietly aim the
-- last fight at ground nobody has stood on.
-- SURVEYED 2026-09-03 with `lab.probe.line`, the noclip ground probe: fly the
-- surveyor up, drop noclip, and the settled z IS the ground. Seven rows of
-- seven, one per block centre, at the grid computed from `origin` and
-- `blockMetres` below -- 49 points, 44 of them walkable.
--
-- THE RESULT THAT DECIDES THE MAP: there is no single ground plane here.
-- Valid ground runs from 8.93 to 60.21 m, a spread of 51 m, and only SIX of
-- the 44 sit within 6 m of the median (31.17). Watson needed one override for
-- the whole district because Kabuki is flat; Little China needs one per cell,
-- and `ground` below carries all 44. A `groundDefault` alone would be wrong by
-- tens of metres nearly everywhere, which is precisely what this file's header
-- warns buries a player or drops him.
--
-- The five excluded cells are not opinion either. Two settled at -1.04, the
-- water plane -- the same signature the Watson survey recorded as "the grid
-- was in the sea" -- one at -2.97 beside them, and two fell clean through at
-- -93.23 and -52.67.
Chinatown.groundSamples = {
    { x = -2048.0, y = 960.0, z = 53.21 },
    { x = -1664.0, y = 960.0, z = 23.61 },
    { x = -1536.0, y = 960.0, z = 23.42 },
    { x = -1408.0, y = 960.0, z = 23.41 },
    { x = -1280.0, y = 960.0, z = 23.73 },
    { x = -1920.0, y = 1088.0, z = 11.94 },
    { x = -1792.0, y = 1088.0, z = 48.35 },
    { x = -1664.0, y = 1088.0, z = 32.58 },
    { x = -1536.0, y = 1088.0, z = 56.63 },
    { x = -1408.0, y = 1088.0, z = 24.83 },
    { x = -1280.0, y = 1088.0, z = 20.05 },
    { x = -2048.0, y = 1216.0, z = 11.45 },
    { x = -1920.0, y = 1216.0, z = 60.21 },
    { x = -1792.0, y = 1216.0, z = 42.00 },
    { x = -1664.0, y = 1216.0, z = 30.98 },
    { x = -1536.0, y = 1216.0, z = 37.73 },
    { x = -1408.0, y = 1216.0, z = 22.88 },
    { x = -1280.0, y = 1216.0, z = 16.81 },
    { x = -2048.0, y = 1344.0, z = 25.63 },
    { x = -1920.0, y = 1344.0, z = 40.45 },
    { x = -1664.0, y = 1344.0, z = 28.93 },
    { x = -1536.0, y = 1344.0, z = 53.94 },
    { x = -1408.0, y = 1344.0, z = 57.40 },
    { x = -2048.0, y = 1472.0, z = 8.95 },
    { x = -1920.0, y = 1472.0, z = 47.10 },
    { x = -1792.0, y = 1472.0, z = 13.70 },
    { x = -1664.0, y = 1472.0, z = 17.98 },
    { x = -1536.0, y = 1472.0, z = 24.30 },
    { x = -1408.0, y = 1472.0, z = 18.18 },
    { x = -1280.0, y = 1472.0, z = 21.22 },
    { x = -2048.0, y = 1600.0, z = 8.93 },
    { x = -1920.0, y = 1600.0, z = 38.44 },
    { x = -1792.0, y = 1600.0, z = 31.36 },
    { x = -1664.0, y = 1600.0, z = 18.19 },
    { x = -1536.0, y = 1600.0, z = 50.59 },
    { x = -1408.0, y = 1600.0, z = 53.03 },
    { x = -1280.0, y = 1600.0, z = 53.00 },
    { x = -2048.0, y = 1728.0, z = 35.21 },
    { x = -1920.0, y = 1728.0, z = 39.29 },
    { x = -1792.0, y = 1728.0, z = 43.21 },
    { x = -1664.0, y = 1728.0, z = 44.11 },
    { x = -1536.0, y = 1728.0, z = 42.12 },
    { x = -1408.0, y = 1728.0, z = 54.00 },
    { x = -1280.0, y = 1728.0, z = 18.33 },
}

-- ---------------------------------------------------------------------------
-- THE FOUR THINGS THIS WORKSTATION ACTUALLY KNOWS ABOUT LITTLE CHINA.
--
-- Read by nothing. Kept in the file because the next person to touch this map
-- deserves the provenance without having to re-derive it, and because two of
-- the four are the whole basis for `groundDefault`.
-- ---------------------------------------------------------------------------
Chinatown.evidence = {
    {
        what = "The Afterlife -- WALKED. Cordon's staging anchor. Streams, loads collision, holds a player; solid floor 1.3 m under the requested z; a real interior. Resolves to sector (-23,15), which the streaming index puts in c_watson/little_china with 54 node refs -- so this is the one place in the district a player is known to have stood.",
        position = { x = -1455.068, y = 1010.975, z = 17.824 },
        block = "6,1",
        source = "resources/gamemodes/open77_cordon/shared/watson.lua:135, tested 2026-09-03",
        measured = true,
    },
    {
        what = "Prologue roadblock on the ELEVATED FREEWAY. Measured in game by teleport; the entry records the road as entirely clear -- 'voies libres jusqu'a l'horizon'. z 53.1 is the deck, NOT the street. Sits 88 m SOUTH of this grid, on the freeway's southern approach.",
        position = { x = -2092.2, y = 807.9, z = 53.1 },
        block = "outside (south)",
        source = "docs/research/multiplayer-mode.md:1014, measured 2026-08-28",
        measured = true,
    },
    {
        what = "little_china_freeway -- a road node with a heading, imported from Night City Motorsports 2.0 and marked in-world validated BY THAT MOD, not by us. z 52 is the same elevated deck. Inside this grid, in block 2,3: the freeway crosses the map.",
        position = { x = -1909.0, y = 1245.0, z = 52.0 },
        heading = 153.219,
        block = "2,3",
        source = "base/resources/gamemodes/race/shared/ncm_courses.lua:34 (third-party validated, not walked here)",
        measured = false,
    },
    {
        what = "arasaka -- the nearest road node at STREET level, 27 m north of this grid's top edge. Its z of 18 is the second reading that supports a street plane near 18, the first being the Afterlife floor at 17.824.",
        position = { x = -2065.0, y = 1819.0, z = 18.0 },
        heading = -57.232,
        block = "outside (north, 27 m)",
        source = "base/resources/gamemodes/race/shared/ncm_courses.lua:33 (third-party validated, not walked here)",
        measured = false,
    },
}

Chinatown.grid = {
    -- SW corner of block (1,1), and a streaming-sector corner: -2112 = -33*64,
    -- 896 = 14*64. DERIVED from the index, never stood on.
    --
    -- z is a CANDIDATE and is only the fallback the in-world edge posts use when
    -- a cell has no ground override (server/main.lua:514-516). It is set equal
    -- to groundDefault on purpose: two numbers that disagree would be two
    -- guesses instead of one.
    origin = { x = -2112.0, y = 896.0, z = 18.0 },

    -- 7 * 128 = 896 m square. See the header: seven is what makes the lattice
    -- subdivide, and 128 makes every lattice cell exactly one 64 m sector.
    blockMetres = 128.0,
    cols = 7,
    rows = 7,

    -- The vertical box each block reaches, relative to origin.z. Little China is
    -- multi-level: the street plane is near 18, the freeway deck near 52, and
    -- Megabuilding H10 stands over it. -12 clears an underpass or a basement,
    -- +258 clears the deck and the low roofs without swallowing the tower. If
    -- the walk finds a block where the two levels need separating, that is what
    -- the per-block ABSOLUTE override `grid.blocks["c,r"] = { floor=, ceiling= }`
    -- is for (shared/grid.lua:36-53) -- not a change to these margins.
    floorMargin = 30.0,
    ceilingMargin = 240.0,

    -- CANDIDATE, AND THE NUMBER MOST LIKELY TO BE WRONG IN THIS FILE.
    --
    -- REQUIRED: a nil groundDefault is not a warning but a refusal --
    -- K.recomputeSurveyed treats it as an unsurveyed map, and an unsurveyed map
    -- refuses staging and deploy outright.
    --
    -- 18.0 rests on exactly two readings, neither of them a walked Little China
    -- street: the Afterlife interior floor at 17.824 (walked, but an interior)
    -- and the `arasaka` road node at 18 (third-party, 27 m outside the grid).
    -- A third band supports it only by analogy: Kabuki's fourteen walked spawns
    -- run 7.76 to 11.94, `kabuki_bridge` is 23, `north_tunnel` is -5.
    --
    -- WHAT IT IS NOT is the freeway. 52-56 appears twice in the evidence above
    -- and is the elevated deck, 34 m over the street. Anyone re-deriving this
    -- default from "the two Little China numbers in the repo" would land on the
    -- freeway and put every crate and every landing 34 m in the air.
    --
    -- REPLACE IT WITH THE MEDIAN of at least a dozen walked street reads, the
    -- way Watson's 7.9 is the median of fourteen. Pacifica's single-sample
    -- default of 5.787 stood where real land ran 5.8 to 42.6, and
    -- battle-royale-and-scale.md:248-253 records what that does to a player.
    -- The median of the 44 walkable samples. It is the fallback for a cell
    -- `ground` does not name, and after the survey there are none -- every
    -- walkable cell has its own number. It was 18.0 before the survey, which
    -- the probe found to be wrong by 35 m at the very first point measured
    -- (block 0,0 settled at 53.21).
    groundDefault = 31.17,

    -- Per-BLOCK z override, keyed "col,row" -- note the COMMA. Empty because
    -- nothing has been walked. Expect the freeway blocks (2,3 and its
    -- neighbours) and anything under Megabuilding H10 to need an entry.
    ground = {
        ["0,0"] = 53.21,
        ["3,0"] = 23.61,
        ["4,0"] = 23.42,
        ["5,0"] = 23.41,
        ["6,0"] = 23.73,
        ["1,1"] = 11.94,
        ["2,1"] = 48.35,
        ["3,1"] = 32.58,
        ["4,1"] = 56.63,
        ["5,1"] = 24.83,
        ["6,1"] = 20.05,
        ["0,2"] = 11.45,
        ["1,2"] = 60.21,
        ["2,2"] = 42.00,
        ["3,2"] = 30.98,
        ["4,2"] = 37.73,
        ["5,2"] = 22.88,
        ["6,2"] = 16.81,
        ["0,3"] = 25.63,
        ["1,3"] = 40.45,
        ["3,3"] = 28.93,
        ["4,3"] = 53.94,
        ["5,3"] = 57.40,
        ["0,4"] = 8.95,
        ["1,4"] = 47.10,
        ["2,4"] = 13.70,
        ["3,4"] = 17.98,
        ["4,4"] = 24.30,
        ["5,4"] = 18.18,
        ["6,4"] = 21.22,
        ["0,5"] = 8.93,
        ["1,5"] = 38.44,
        ["2,5"] = 31.36,
        ["3,5"] = 18.19,
        ["4,5"] = 50.59,
        ["5,5"] = 53.03,
        ["6,5"] = 53.00,
        ["0,6"] = 35.21,
        ["1,6"] = 39.29,
        ["2,6"] = 43.21,
        ["3,6"] = 44.11,
        ["4,6"] = 42.12,
        ["5,6"] = 54.00,
        ["6,6"] = 18.33,
    },
}

-- Cells with no walkable ground. EMPTY, and that is not a claim that there are
-- none -- it is a refusal to guess. The streaming index can say where Little
-- China's authored decoration is; it cannot say where a player can stand, and
-- a cell excluded by mistake is a cell the cordon will refuse to close.
--
-- battle-royale-and-scale.md:327-356: the SAME coordinate came back LAND in one
-- probe sweep and VOID in another, because after a long teleport the world has
-- not finished streaming and the player falls through terrain that is there.
-- "Geometry does not flicker; streaming does." CONFIRM EVERY EXCLUSION TWICE,
-- from a nearby start, before writing it here.
-- The five cells the probe found unwalkable, and each one is a measurement
-- rather than a judgement -- see the note above `groundSamples`. Two settled on
-- the water plane at -1.04, one at -2.97 beside them, and two fell through the
-- world entirely at -93.23 and -52.67. A cordon that sealed a player into any
-- of them would be asking him to stand on nothing.
Chinatown.excluded = {
    ["1,0"] = true,
    ["2,0"] = true,
    ["0,1"] = true,
    ["2,3"] = true,
    ["6,3"] = true,
}

-- CHOSEN, NOT WALKED -- which is what Watson says about its own two as well.
-- Six central blocks, all of which the streaming index shows as well inside
-- Little China. Stand in each before trusting it.
--
-- The choice moves the phase count, and it is worth knowing which way:
-- `Grid.blockCentreCell` puts the final cell at the low corner of the block at
-- factor 2, and `span` is measured from there, so block 4,4 gives span 7 and
-- 8 phases (zones 832 -> 704 -> 576 -> 448 -> 320 -> 192 -> 64 m), while the
-- ring blocks give span 8-9 and 9-10 phases of thinner, faster steps. Both are
-- legitimate; a mixed whitelist means two matches on this map do not feel
-- identical, which is the point of a whitelist rather than one block.
Chinatown.finalBlocks = { "3,3", "4,3", "5,3", "3,4", "4,4", "4,5" }

Chinatown.staging = {
    -- THE AFTERLIFE, unchanged from Watson, and the one position in this file
    -- that needs no walk: it is the only Little China coordinate anybody on this
    -- project has actually stood on.
    --
    -- It is INSIDE this grid (block 6,1) and that is harmless, not a conflict:
    -- staging runs in bucket 5100 and the match in 5101 (shared/config.lua:66-67),
    -- so the lobby is a different dimension that happens to share a postcode.
    -- Nothing about the play grid has to accommodate it.
    position = { x = -1455.068, y = 1010.975, z = 17.824 },
    heading = 0.0,
    radius = 12.0,
}

-- ---------------------------------------------------------------------------
-- EVERYTHING BELOW IS EMPTY BECAUSE IT HAS TO BE WALKED.
--
-- Capture with open77_cordonlab:
--     lab.mark origin | ground | staging | landmark <key> | landing <key> [hot]
--              | loot <tier> [count] [radius] | vehicle <record> | holdout | supply
-- then `lab.marks` dumps paste-ready Lua into the server log.
--
-- THREE TRAPS IN THAT DUMP, measured by reading it (open77_cordonlab/server/main.lua):
--   1. its `-- cell` comment divides by a hard-coded 100.0 (:1060-1064). On this
--      128 m map every cell comment it prints is WRONG.
--   2. it prints the cell as "%d:%d" -- a COLON. The key format is "col,row"
--      with a comma; pacifica.lua:290 records a pass that used "col:row" and
--      made every final block silently fail.
--   3. `lab.mark origin` captures x and y only, NO z, and the dump always says
--      `Pacifica.grid.origin` whatever map you are surveying.
-- ---------------------------------------------------------------------------

-- Named places for the tac-map. Ten wanted. The streaming index knows which
-- 64 m sector several of Little China's landmarks live in -- Megabuilding H10
-- (`loc_megabuilding_a_prefab`, 177 refs), the Afterlife (`#loc_q103_afterlife`,
-- 85), Misty's and Viktor's, Tom's Diner in sector x -1536..-1472 y 1152..1216
-- (block 5,3), the neon basement in x -1792..-1664 y 1472..1536 (blocks 3,5 and
-- 4,5), the dirty joint in x -1920..-1856 y 1152..1216 (block 2,3) -- but a
-- sector is a 64 m box, not a position, and a landmark needs a point and a name
-- the owner chose after standing there.
Chinatown.landmarks = {}
Chinatown.landmarkTarget = 10

-- ===========================================================================
-- THE INTERLOCK. Leaving this empty is what keeps the map from starting.
-- Twenty-four wanted, three marked `hot` (hot LZs are where tier-3 and tier-4
-- loot is allowed to sit -- wiki/cordon.md:216-223).
-- ===========================================================================
-- CHOSEN FROM THE SURVEY, not from the map. Every one of these ten is a point
-- where `lab.probe.line` actually put a body down on 2026-09-03, so `probed`
-- is true in the honest sense rather than the hopeful one -- the z is the
-- settled z, copied from `groundSamples` above.
--
-- They are spread deliberately: one per region of the grid, none in the five
-- excluded cells, and the vertical range is part of the point. Little China
-- runs from 11 m at the canal to 60 m at the market deck, so a squad choosing
-- a pin is choosing an ALTITUDE as much as a place -- which is the thing this
-- district offers that flat Kabuki cannot.
--
-- `hot` is set on the night market alone: it is the highest ground on the map
-- and the one cell every other landing can be reached from downhill.
Chinatown.landings = {
    { key = "lz_west_gate", label = "West Gate",        position = { x = -2048.0, y = 960.0, z = 53.21 }, hot = false, probed = true },
    { key = "lz_canal",     label = "Canal Walk",       position = { x = -2048.0, y = 1216.0, z = 11.45 }, hot = false, probed = true },
    { key = "lz_market",    label = "Night Market",     position = { x = -1920.0, y = 1216.0, z = 60.21 }, hot = true , probed = true },
    { key = "lz_terrace",   label = "The Terrace",      position = { x = -1792.0, y = 1088.0, z = 48.35 }, hot = false, probed = true },
    { key = "lz_crossing",  label = "Sector Crossing",  position = { x = -1664.0, y = 1216.0, z = 30.98 }, hot = false, probed = true },
    { key = "lz_high",      label = "High Deck",        position = { x = -1536.0, y = 1088.0, z = 56.63 }, hot = false, probed = true },
    { key = "lz_east_row",  label = "East Row",         position = { x = -1280.0, y = 1216.0, z = 16.81 }, hot = false, probed = true },
    { key = "lz_south",     label = "South Approach",   position = { x = -1408.0, y = 960.0, z = 23.41 }, hot = false, probed = true },
    { key = "lz_north",     label = "North Stalls",     position = { x = -1792.0, y = 1728.0, z = 43.21 }, hot = false, probed = true },
    { key = "lz_depot",     label = "The Depot",        position = { x = -1536.0, y = 1472.0, z = 24.30 }, hot = false, probed = true },
}
Chinatown.landingTarget = 24

-- Fifty-eight cluster anchors, 571 crates. The split is chosen to land on the
-- loot config's own `markShare` (0.55 / 0.30 / 0.12 / 0.03, shared/config.lua:779+)
-- rather than on a feeling:
--
--     tier 1 street     26 clusters x 12 = 312   54.6 %
--     tier 2 rare       19 clusters x  9 = 171   29.9 %
--     tier 3 epic       10 clusters x  7 =  70   12.3 %
--     tier 4 legendary   3 clusters x  6 =  18    3.2 %
--                                          ---
--                                          571
--
-- 6.5x Watson's 88, which is the owner's "plus de crate", and 8.9 crates per
-- contestant against Watson's 1.4. Registry cost 571 + a worst case 256 death
-- drops = 827 of 4096, and 571 of maxContainers 1200. At lootDensity 2.0 it is
-- 1 142 crates, which alone fits but exceeds 1 200 once death drops are counted
-- -- so 1.5 is the practical ceiling on this map.
--
-- TWO RULES THE WALK MUST OBEY, both measured by reading server/loot.lua:
--   * `radius` above 8.0 IS FICTION. loot.lua:283-284 clips every declared
--     radius to Config.loot.maxScatterMetres = 8.0, so Watson's 18/16/14/12 are
--     all really 8. Declare 8.0 and mean it. A cluster is a pile, not a room;
--     density on this map comes from MORE clusters, never from bigger ones.
--   * There is no ground query. Every drop takes its cluster anchor's own z
--     (loot.lua:294). An anchor must be walked onto ground flat within 8 m or a
--     third of its crates end up in a step or on a roof.
Chinatown.lootClusters = {}
Chinatown.lootClusterTarget = 58

-- ===========================================================================
-- VEHICLES -- the owner's second request, and the first map to carry any.
--
-- CORRECTED 2026-09-03: THE SPAWNER EXISTS NOW. This comment used to read
-- "nothing reads this array yet ... the schema exists, the spawner does not",
-- which was true when this file was written and became false when
-- `server/editor.lua` grew its "hand-placed cars" section: `spawnVehicles()`
-- calls `Open77.vehicles.create` off the `cordon:phase` event, so authored cars
-- appear when the match goes live and `clearVehicles()` removes them when it
-- leaves, in the match bucket so nothing leaks into staging. It is switchable
-- (`editor.spawnVehicles = false`) and stands down on its own if a real
-- `Cordon.vehicles` module ever lands.
--
-- The stale line cost a wrong answer to the owner on 2026-09-03 -- he was told
-- cars would not appear. Read the code, not the neighbouring comment.
-- The specification is still docs/gamemode-cordon-chinatown.md section 3.6.
--
-- Row shape, unchanged from Pacifica: { key, record, position, heading }.
--
-- THE ONE FACT THAT DECIDES EVERY z HERE. A vehicle created by
-- `Open77.vehicles.create` is PHYSICALLY ASLEEP until a client wakes its body:
-- it hovers at exactly the commanded height, wheels in the void, and the
-- canonical position does not move a centimetre (vehicles-api.md:2036-2050,
-- three consecutive Pursuit matches reading resting z == commanded z). So a
-- vehicle z is not a hint the physics will correct -- it is where the car will
-- hang. A car at rest sits 0.51-0.56 m above a player position read at the same
-- spot (vehicles-api.md:2062-2066) and the fallback lift used across the repo is
-- +0.85 (pursuit/shared/config.lua:1057). AUTHORING RULE:
--
--     vehicle.position.z = (the walked player read at that spot) + 0.85
--
-- PLACEMENT, in metres, each number derived rather than felt:
--   * >= 60 m from ANY landing zone. The seat-entry gate is 15 m
--     (VehicleAuthorityService.cs:708-709), so a car inside ~20 m of a landing
--     is at the spawn. 60 m is one lattice cell: you land, you do not see it,
--     you go and look -- which is "pas loin si on cherche un peu".
--   * <= 150 m from the NEAREST landing zone. graceSeconds is 45, and 150 m is
--     30 s of sprint, so a car is always reachable inside the loot window.
--     Past that it is scenery.
--   * >= 40 m from any loot cluster anchor, so taking the car and looting the
--     pile are two decisions.
--   * On a road wide enough that the sleeping body is not inside a kerb. The
--     elevated freeway crosses blocks 2,3 and its neighbours and is recorded as
--     entirely clear -- it is the obvious home for a run of spots.
--
-- RECORDS: the eight `v_standard2_*_player` saloons of
-- open77_vehiclepicker/shared/roster.lua, whose stated purpose is "eight
-- ordinary saloons that are roughly the same speed". FOR THE FIRST PLAYTEST USE
-- ONLY `Vehicle.v_standard2_archer_hella_player`: it is the only one with a
-- measured launch, and the only two launches anyone has timed differ by 45 %
-- within the same chassis class (roster.lua:112-113). No bikes, and there is no
-- NCPD `*_player` record at all.
--
-- COST, arithmetic on measured codec sizes, never run: a parked car publishes
-- 114 B at 2 Hz; a 425 m stream ball covers ~80 % of a 896 m map, so ~16 of 20
-- cars visible is ~3.6 KiB/s per viewer, about +16 % on the ~23 KB/s a player
-- pays with interest culling on. `ReconcileInterest` is O(vehicles x players)
-- with no spatial index: 20 x 64 = 1 280 tests a tick, negligible -- but the
-- same loop at the 4096 cap would be 262 144, so this budget does not scale by
-- an order of magnitude.
--
-- NOT MEASURED BY ANYONE: the cost of `Open77.vehicles.create`; more than TWO
-- network vehicles at once anywhere in this project; any per-vehicle
-- replication cost with real players. The three recorded client crashes near
-- vehicles were all at stream-in. Stagger the creates 50 ms apart, the way the
-- loot seed already does.
--
-- AND A CAR IS ROTATION AND COVER, NEVER A WEAPON (pacifica.lua:396-398):
-- E9 has never shown a vehicle can damage a player through the server ledger.
-- ===========================================================================
Chinatown.vehicles = {}
Chinatown.vehicleTarget = 20

-- Six gang holdouts of four NPCs, on the tier-3 and tier-4 anchors. The
-- `holdoutsEnabled` tunable exists and nothing reads it yet.
Chinatown.holdouts = {}
Chinatown.holdoutTarget = 6

-- Twelve supply candidates, biased toward blocks that survive late. The
-- `supplyDrops` tunable exists and nothing reads it yet.
Chinatown.supply = {}
Chinatown.supplyTarget = 12

Chinatown.extractions = {}

-- ---------------------------------------------------------------------------
-- THE WALK ROUTE. Forty-nine block centres -- read by nothing, and the reason
-- this file is worth having before the survey rather than after it.
--
-- Each entry is the centre of one 128 m block, which is also a streaming-sector
-- corner. Walk it, read z, and record one of three verdicts: STREET GROUND
-- (a `grid.ground` entry if it differs from groundDefault by more than ~3 m),
-- NO WALKABLE GROUND (an `excluded` key), or NOT LITTLE CHINA -- in which case
-- stop, move the origin, and capture nothing until it is right.
--
-- `index` is NOT a measurement of the world. It is how much of the block falls
-- inside the per-row x-envelopes the streaming index reports for Little China's
-- own prefabs: "in" >= 95 %, "edge" >= 25 %, "thin" below. TWO CAVEATS THAT
-- MATTER MORE THAN THE FIELD DOES. First, an envelope is a min/max per 64 m row,
-- not a mask, so a block inside one is not guaranteed to hold anything. Second,
-- the rows y 1280-1344 and y 1664-1728 came back with NO reported extent, which
-- is why every block in rows 4 and 7 reads "edge" -- that is a hole in my table,
-- not necessarily a hole in the district. A low `index` means "look here first
-- and be ready to exclude it", never "this is excluded".
--
-- IF THE WALK SHOWS LITTLE CHINA IS COMFORTABLY BIGGER THAN 896 m, raise
-- blockMetres 128 -> 140 (980 m; the interest cull rises from 43.7 % to 50.3 %
-- of pairs) BEFORE capturing a single mark. Afterwards it is a re-survey:
-- moving a block boundary re-keys every finalBlocks and excluded entry and
-- re-tags every mark, which is exactly what config.lua:1886 warns about.
-- ---------------------------------------------------------------------------
Chinatown.walk = {
    { block = "1,1", x = -2048.0, y = 960.0,  sectors = "exterior_-33..-32_14..15", index = "thin" },
    { block = "2,1", x = -1920.0, y = 960.0,  sectors = "exterior_-31..-30_14..15", index = "edge" },
    { block = "3,1", x = -1792.0, y = 960.0,  sectors = "exterior_-29..-28_14..15", index = "edge" },
    { block = "4,1", x = -1664.0, y = 960.0,  sectors = "exterior_-27..-26_14..15", index = "edge" },
    { block = "5,1", x = -1536.0, y = 960.0,  sectors = "exterior_-25..-24_14..15", index = "in" },
    { block = "6,1", x = -1408.0, y = 960.0,  sectors = "exterior_-23..-22_14..15", index = "in", note = "holds the Afterlife at -1455.068,1010.975,17.824 -- the one walked point in the district" },
    { block = "7,1", x = -1280.0, y = 960.0,  sectors = "exterior_-21..-20_14..15", index = "in" },

    { block = "1,2", x = -2048.0, y = 1088.0, sectors = "exterior_-33..-32_16..17", index = "edge" },
    { block = "2,2", x = -1920.0, y = 1088.0, sectors = "exterior_-31..-30_16..17", index = "in" },
    { block = "3,2", x = -1792.0, y = 1088.0, sectors = "exterior_-29..-28_16..17", index = "in" },
    { block = "4,2", x = -1664.0, y = 1088.0, sectors = "exterior_-27..-26_16..17", index = "in" },
    { block = "5,2", x = -1536.0, y = 1088.0, sectors = "exterior_-25..-24_16..17", index = "in" },
    { block = "6,2", x = -1408.0, y = 1088.0, sectors = "exterior_-23..-22_16..17", index = "in" },
    { block = "7,2", x = -1280.0, y = 1088.0, sectors = "exterior_-21..-20_16..17", index = "in" },

    { block = "1,3", x = -2048.0, y = 1216.0, sectors = "exterior_-33..-32_18..19", index = "edge" },
    { block = "2,3", x = -1920.0, y = 1216.0, sectors = "exterior_-31..-30_18..19", index = "in", note = "the elevated freeway crosses here (little_china_freeway -1909,1245,52) and the dirty joint prefab sits at street level -- expect two levels in one block" },
    { block = "3,3", x = -1792.0, y = 1216.0, sectors = "exterior_-29..-28_18..19", index = "in" },
    { block = "4,3", x = -1664.0, y = 1216.0, sectors = "exterior_-27..-26_18..19", index = "in" },
    { block = "5,3", x = -1536.0, y = 1216.0, sectors = "exterior_-25..-24_18..19", index = "in", note = "Tom's Diner prefab sector" },
    { block = "6,3", x = -1408.0, y = 1216.0, sectors = "exterior_-23..-22_18..19", index = "in" },
    { block = "7,3", x = -1280.0, y = 1216.0, sectors = "exterior_-21..-20_18..19", index = "edge", note = "east edge: Kabuki begins around x -1280" },

    { block = "1,4", x = -2048.0, y = 1344.0, sectors = "exterior_-33..-32_20..21", index = "thin" },
    { block = "2,4", x = -1920.0, y = 1344.0, sectors = "exterior_-31..-30_20..21", index = "edge" },
    { block = "3,4", x = -1792.0, y = 1344.0, sectors = "exterior_-29..-28_20..21", index = "edge" },
    { block = "4,4", x = -1664.0, y = 1344.0, sectors = "exterior_-27..-26_20..21", index = "edge", note = "grid centre; the final block that yields the classic 8-phase 832->64 m sequence" },
    { block = "5,4", x = -1536.0, y = 1344.0, sectors = "exterior_-25..-24_20..21", index = "edge" },
    { block = "6,4", x = -1408.0, y = 1344.0, sectors = "exterior_-23..-22_20..21", index = "edge" },
    { block = "7,4", x = -1280.0, y = 1344.0, sectors = "exterior_-21..-20_20..21", index = "edge" },

    { block = "1,5", x = -2048.0, y = 1472.0, sectors = "exterior_-33..-32_22..23", index = "edge" },
    { block = "2,5", x = -1920.0, y = 1472.0, sectors = "exterior_-31..-30_22..23", index = "edge" },
    { block = "3,5", x = -1792.0, y = 1472.0, sectors = "exterior_-29..-28_22..23", index = "in", note = "neon basement prefab sector" },
    { block = "4,5", x = -1664.0, y = 1472.0, sectors = "exterior_-27..-26_22..23", index = "in", note = "neon basement prefab sector" },
    { block = "5,5", x = -1536.0, y = 1472.0, sectors = "exterior_-25..-24_22..23", index = "in" },
    { block = "6,5", x = -1408.0, y = 1472.0, sectors = "exterior_-23..-22_22..23", index = "in" },
    { block = "7,5", x = -1280.0, y = 1472.0, sectors = "exterior_-21..-20_22..23", index = "edge" },

    { block = "1,6", x = -2048.0, y = 1600.0, sectors = "exterior_-33..-32_24..25", index = "edge" },
    { block = "2,6", x = -1920.0, y = 1600.0, sectors = "exterior_-31..-30_24..25", index = "in" },
    { block = "3,6", x = -1792.0, y = 1600.0, sectors = "exterior_-29..-28_24..25", index = "in" },
    { block = "4,6", x = -1664.0, y = 1600.0, sectors = "exterior_-27..-26_24..25", index = "in" },
    { block = "5,6", x = -1536.0, y = 1600.0, sectors = "exterior_-25..-24_24..25", index = "edge" },
    { block = "6,6", x = -1408.0, y = 1600.0, sectors = "exterior_-23..-22_24..25", index = "edge" },
    { block = "7,6", x = -1280.0, y = 1600.0, sectors = "exterior_-21..-20_24..25", index = "edge" },

    { block = "1,7", x = -2048.0, y = 1728.0, sectors = "exterior_-33..-32_26..27", index = "thin" },
    { block = "2,7", x = -1920.0, y = 1728.0, sectors = "exterior_-31..-30_26..27", index = "edge" },
    { block = "3,7", x = -1792.0, y = 1728.0, sectors = "exterior_-29..-28_26..27", index = "edge" },
    { block = "4,7", x = -1664.0, y = 1728.0, sectors = "exterior_-27..-26_26..27", index = "edge" },
    { block = "5,7", x = -1536.0, y = 1728.0, sectors = "exterior_-25..-24_26..27", index = "edge" },
    { block = "6,7", x = -1408.0, y = 1728.0, sectors = "exterior_-23..-22_26..27", index = "edge" },
    { block = "7,7", x = -1280.0, y = 1728.0, sectors = "exterior_-21..-20_26..27", index = "edge", note = "north-east corner: Kabuki and the Arasaka waterfront are past here" },
}

-- What `/br.map check` measures this map against. These are TARGETS for a
-- 896 m district with cars, not Watson's targets for a 200 m test square and
-- not Pacifica's for a 2 km sector -- so the readout says the truth about THIS
-- map. Every one of them currently reads 0.
Chinatown.progress = {
    { key = "origin",       need = 1,  what = "grid origin (SW corner of block 1,1) -- derived from the streaming index, NOT walked" },
    { key = "ground",       need = 1,  what = "default ground Z -- CANDIDATE 18.0; replace with the median of a dozen walked street reads" },
    { key = "staging",      need = 1,  what = "staging anchor -- done: the Afterlife, walked" },
    { key = "landmarks",    need = 10, what = "named landmarks for the tac-map" },
    { key = "landings",     need = 24, what = "landing zones, 3 marked hot -- THE INTERLOCK: empty until walked, and the map refuses to start" },
    { key = "lootClusters", need = 58, what = "loot cluster anchors, 26 street / 19 rare / 10 epic / 3 legendary = 571 crates" },
    { key = "vehicles",     need = 20, what = "vehicle spots on roads, 60-150 m from a landing zone, z = walked read + 0.85" },
    { key = "holdouts",     need = 6,  what = "gang holdout sites on the epic and legendary anchors" },
    { key = "supply",       need = 12, what = "supply drop candidates" },
    { key = "finalBlocks",  need = 6,  what = "final-block whitelist (chosen, not walked -- stand in each)" },
    { key = "excluded",     need = 0,  what = "cells with no walkable ground -- unknown until walked; confirm each twice" },
}

return Chinatown
