-- The cordon: which cells are open, when they close, and what happens to a
-- player standing outside them.
--
-- ---------------------------------------------------------------------------
-- THE MODE'S ONE ORIGINAL IDEA, AND WHY IT IS BLOCKS RATHER THAN A CIRCLE.
--
-- No shipped primitive draws a circle wider than 50 m — open77_groundcircle,
-- Open77.anchors and Open77.markers all clamp there — and the platform's
-- containment code is written for axis-aligned boxes. A block edge is also a
-- straight segment on a street grid, which is the one shape that CAN be drawn
-- cheaply, and "NCPD sealed the block" is a better sentence about Night City
-- than "the storm is coming".
--
-- The closing order still reads as closing in: cells go farthest-from-final
-- first, one at a time across the closure window, so the edge marches inward
-- rather than snapping.
--
-- ---------------------------------------------------------------------------
-- THE 2026-09-02 REDESIGN: MANY SMALL ZONES, ON A LATTICE, ON A CLOCK.
--
-- WHAT WAS WRONG, and it was not the block idea. The cordon closed cells of the
-- SURVEY grid, and the survey grid is as coarse as the ground somebody walked.
-- On Watson — the only map that plays today — that is 2x2, four 100 m cells.
-- Worse, the hand-written schedule above it named Chebyshev radii sized for a
-- 14x14 Pacifica: rings 5, 3, 2 and 1 are all the WHOLE 2x2 grid once
-- `Grid.ringsFrom` clips them, so
--
--     phases 1..4 closed NOTHING (t = 2:30 to 11:00, four announced closures,
--                                 zero blocks removed)
--     phase  5    closed three of the four cells in 45 s at t = 13:00
--     phase  7    closed the last one at t = 16:30
--
-- Thirteen minutes of nothing, then a guillotine. That is not a shrinking zone,
-- and no amount of retiming the old table fixes it: four cells cannot express
-- more than three closures.
--
-- WHAT CHANGED. Three things, and they are independent:
--
--   1. THE LATTICE. The cordon no longer closes survey blocks; it closes cells
--      of the survey grid SUBDIVIDED (`Grid.subdivide`). Watson's 2x2 of 100 m
--      blocks becomes an 8x8 of 25 m cells, and the final zone is 25 m across
--      instead of 100. A 14x14 map is already fine and gets factor 1, i.e.
--      exactly the old geometry. See `Grid.subdivisionFor`.
--
--      This is invisible to every client BECAUSE the lattice is published as
--      "the grid": the tac-map, the in-world edge and the containment test all
--      read origin/cols/rows/blockMetres off the server's own message, so all
--      three agree by construction and not one client file changed.
--
--   2. THE SCHEDULE IS GENERATED, NOT WRITTEN. A hand-authored table of ring
--      counts is a statement about ONE map size and silently degenerates on
--      every other, which is precisely the bug above. `C.buildSchedule` takes
--      the measured span of the open set and a preset that describes a SHAPE —
--      how long the whole cordon lasts, how many steps, how much faster the
--      last step is than the first, where the damage starts and ends — and
--      emits as many phases as the map can actually carry.
--
--   3. THE NEXT ZONE IS ANNOUNCED. Every cell a phase is going to close is
--      marked `closing` from the moment the previous phase finishes, so the
--      tac-map flashes the whole doomed region and the ground that survives is
--      the ground that is NOT flashing. That is the Apex reading — the next
--      ring is drawn before it closes — expressed in the vocabulary the overlay
--      already had.
--
-- WHERE THIS CONTRADICTS THE PLAN, said plainly rather than left to drift.
-- `docs/gamemode-cordon-plan.md` section 2 gives a 17:30 cordon over seven
-- named phases with the last block shrinking to a 40 m square; decision 2 fixes
-- the cordon as "100 m axis-aligned blocks". The lattice keeps decision 2's
-- SHAPE (axis-aligned cells, Chebyshev rings, no circle anywhere) and breaks
-- its SIZE: the closing unit is 25 m on Watson and 50 m on a 9x5 Pacifica. The
-- plan's `finalSquareMetres` sub-block shrink is subsumed — it was never
-- implemented (`C.innerSquare` does not exist, so `"square"` has always been a
-- synonym for rings 0), and a 25 m final cell is smaller than the 40 m square
-- it stood in for. The timetable is now ~6:10 of cordon rather than ~17:30, at
-- the owner's request, and it is a preset plus three tunables rather than a
-- table of absolute times. Owner request, not a measurement.
-- ---------------------------------------------------------------------------

local K = Cordon
K.cordon = {}
local C = K.cordon

-- Live state, rebuilt by begin() at every match.
local state = {
    active = false,
    map = nil,             -- the applied map (Pacifica, Watson or a runtime one)
    lattice = nil,         -- the SUBDIVIDED grid the cordon actually closes
    open = {},             -- [cellKey] = true
    allowed = {},          -- immutable original mask for continuous containment
    closing = {},          -- [cellKey] = true, announced and not yet gone
    finalCell = nil,       -- "col,row", in LATTICE coordinates
    finalBlock = nil,      -- "col,row", the surveyed block it sits in
    schedule = nil,        -- the generated phase array
    phases = {},           -- per-phase bookkeeping: doomed list, announce time, box
    announcedThrough = 0,
    phaseIndex = 0,
    phaseStartedMs = nil,
    damagePerSecond = 0.0, -- the phase's BASE rate; `C.damagePerSecond()` scales it
    startedAtMs = nil,
    queue = {},            -- ordered { cell, atMs } still to close
    closeAt = {},          -- [cellKey] = atMs, the whole timetable, for O(1) lookup
    -- Bumped whenever the open or the doomed set changes. `C.nearestSafe`
    -- caches its candidate list against it, so sixty-four doomed players at
    -- 2 Hz cost one walk of the lattice per change rather than one each.
    geometryRev = 0,
}

function C.state() return state end

local function cfg()
    return (Config and Config.cordon) or {}
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback end
    return n
end

-- ---------------------------------------------------------------------------
-- THE LATTICE
--
-- Memoised on the grid table itself, with WEAK KEYS. Two reasons for both
-- halves: `K.map` is re-read at every point of use (the runtime map store
-- replaces the table wholesale when an operator selects another map), so a
-- file-scope cache keyed on anything else would pin the mode to the map that
-- was active when it loaded; and the expansion walks the per-cell ground and
-- height tables, which is cheap once and wasteful at the 2 Hz the state push
-- calls `C.fragment()`.
-- ---------------------------------------------------------------------------
local latticeCache = setmetatable({}, { __mode = "k" })

--- The cordon lattice for a SURVEY grid (the `map.grid` table, not the map).
function C.lattice(grid)
    if type(grid) ~= "table" then return nil end
    local cached = latticeCache[grid]
    if cached ~= nil then return cached end
    local factor = Grid.subdivisionFor(grid, cfg().lattice)
    local lattice = Grid.subdivide(grid, factor)
    latticeCache[grid] = lattice
    return lattice
end

--- The lattice in force right now: the match's when a match is running, and the
--- active map's otherwise. Never nil-checked away by callers — the fragment is
--- built for a player standing in staging on a server with no map at all.
local function activeLattice()
    if state.lattice ~= nil then return state.lattice end
    local grid = K.map and K.map.grid or nil
    if grid == nil then return nil end
    return C.lattice(grid)
end
C.activeLattice = activeLattice

-- ---------------------------------------------------------------------------
-- THE SCHEDULE, GENERATED
--
-- A preset is a SHAPE, not a timetable. The fields, and why each is the one an
-- operator would reach for:
--
--   graceSeconds          from the drop to the first closure starting. The loot
--                         window, and the only number that says "how long
--                         before this becomes a fight".
--   cordonSeconds         from the first closure starting to the last shrink
--                         ending. The match length, in one number.
--   steps                 how many zones the player is asked to move between.
--                         A CEILING, not a promise: a map with fewer rings than
--                         this gets fewer phases, because a phase that closes
--                         nothing is the bug this redesign exists to remove.
--   closeShare            of each step's time, the fraction spent CLOSING. The
--                         rest is the hold, which is the time a player has to
--                         cross into the zone they can already see. 0.55 leaves
--                         the hold slightly shorter than the close, which is
--                         what makes a late rotation frightening rather than
--                         merely inconvenient.
--   speedUp               the first step's total time divided by the last's.
--                         This is the whole Apex feel in one number: early
--                         zones are slow and forgiving, late ones arrive before
--                         you have finished the fight you are in.
--   firstDamagePerSecond  the bleed in step 1 ...
--   lastDamagePerSecond   ... and in the last shrink. Interpolated
--                         GEOMETRICALLY between them, not linearly, and that is
--                         deliberate: a linear ramp from 2.5 to 30 over seven
--                         steps puts 11 HP/s in the middle of a match where
--                         players still have a whole zone to cross, which kills
--                         rotations rather than punishing them. Geometric keeps
--                         the early steps survivable and spends the whole
--                         increase in the last two.
--   finalSeconds          the terminal phase, which closes the last cell.
--   finalDamagePerSecond  its rate. It has no survivors BY ARITHMETIC and not
--                         by a special case: nothing is open, and 60 HP/s
--                         against a 100 HP ledger with 75 armour is under three
--                         seconds. The mode never needs a "kill everyone"
--                         branch, which is the branch that would eventually
--                         fire during a live match by mistake.
--
-- Three of them are also live tunables (`cordonGrace`, `cordonSeconds`,
-- `cordonSteps`); zero there means "the preset decides", so the panel can
-- shorten a match without authoring a schedule.
-- ---------------------------------------------------------------------------

local function schedulePreset(name)
    local presets = Config and Config.schedule
    if type(presets) ~= "table" then return nil, nil end
    if type(presets[name]) == "table" then return presets[name], name end
    -- A NAME THAT NO LONGER EXISTS IS THE COMMON CASE, not the exotic one:
    -- tunables persist to `tunables.json`, so a server that ran the old
    -- `"short"` preset comes back asking for it after this file has replaced it.
    -- Falling back silently is how a match ends up running a schedule nobody
    -- chose, so it is said out loud once per match.
    local fallbackName = presets.fallback or "standard"
    K.warn(("schedule preset %q does not exist; using %q"):format(
        tostring(name), tostring(fallbackName)))
    return presets[fallbackName], fallbackName
end

--- The radii the cordon shrinks through, from `span` down to 0.
---
--- `span` is the Chebyshev radius that still contains every OPEN cell, measured
--- rather than assumed — see `Grid.spanOf`. The first target is therefore
--- always strictly inside it, so step 1 always removes something.
local function shrinkRadii(span, wanted)
    local radii = {}
    span = math.max(0, math.floor(span or 0))
    if span <= 0 then return radii end
    local steps = math.min(math.max(1, math.floor(wanted or 1)), span)
    local seen = {}
    for index = 1, steps do
        local radius = math.floor(span * (steps - index) / steps + 0.5)
        if radius >= span then radius = span - 1 end
        if radius < 0 then radius = 0 end
        if not seen[radius] then
            seen[radius] = true
            radii[#radii + 1] = radius
        end
    end
    if radii[#radii] ~= 0 then radii[#radii + 1] = 0 end
    return radii
end

--- The phase array. Same shape the hand-written table had, so everything
--- downstream — the timetable, the phase counter on the HUD, the log line —
--- is untouched by the fact that it is now computed.
function C.buildSchedule(span, preset)
    preset = type(preset) == "table" and preset or {}

    local grace = math.max(0, math.floor(number(K.tune("cordonGrace", 0), 0)))
    if grace <= 0 then grace = math.max(0, number(preset.graceSeconds, 45)) end
    local total = math.floor(number(K.tune("cordonSeconds", 0), 0))
    if total <= 0 then total = number(preset.cordonSeconds, 300) end
    total = math.max(20, total)
    local wanted = math.floor(number(K.tune("cordonSteps", 0), 0))
    if wanted <= 0 then wanted = math.floor(number(preset.steps, 9)) end
    wanted = math.max(1, wanted)

    local radii = shrinkRadii(span, wanted)
    local count = #radii
    local phases = {}
    local at = grace

    if count > 0 then
        -- Weights run from `speedUp` down to 1, so step 1 is the longest and the
        -- last shrink the shortest, and the whole set is normalised to
        -- `cordonSeconds`. Normalising rather than summing fixed durations is
        -- what keeps the match length a single knob on every map: Watson gets
        -- six steps and Pacifica nine, and both take the same wall clock.
        local ratio = math.max(1.0, number(preset.speedUp, 2.6))
        local share = math.min(0.9, math.max(0.2, number(preset.closeShare, 0.55)))
        local weights, sum = {}, 0.0
        for index = 1, count do
            local t = count > 1 and ((count - index) / (count - 1)) or 1.0
            weights[index] = 1.0 + (ratio - 1.0) * t
            sum = sum + weights[index]
        end

        local firstDps = math.max(0.1, number(preset.firstDamagePerSecond, 2.5))
        local lastDps = math.max(firstDps, number(preset.lastDamagePerSecond, 30.0))
        local growth = count > 1 and ((lastDps / firstDps) ^ (1.0 / (count - 1))) or 1.0

        for index = 1, count do
            local slice = total * weights[index] / sum
            phases[index] = {
                atSeconds = at,
                -- Prefer at least two seconds, but never overlap the next
                -- phase on a minimum-duration schedule with many small slices.
                closeOverSeconds = math.min(slice, math.max(2.0, slice * share)),
                toRings = radii[index],
                damagePerSecond = firstDps * (growth ^ (index - 1)),
                label = "cordon" .. index,
            }
            at = at + slice
        end
    end

    -- The terminal phase always exists, even on a degenerate one-cell map: a
    -- match must not be able to outlive its own timetable. Two players hiding in
    -- opposite corners of the last cell would otherwise stand there until the
    -- server restarted.
    phases[#phases + 1] = {
        atSeconds = at,
        closeOverSeconds = math.max(2.0, number(preset.finalSeconds, 25)),
        toRings = "none",
        damagePerSecond = math.max(
            number(preset.lastDamagePerSecond, 30.0),
            number(preset.finalDamagePerSecond, 60.0)),
        label = "cordonFinal",
    }
    return phases
end

-- ---------------------------------------------------------------------------
-- BEGIN. Chooses the final cell, generates the schedule, and precomputes the
-- whole closure timetable up front.
--
-- Precomputed rather than decided per tick on purpose: the tick then does one
-- comparison per pending cell instead of re-deriving distances for hundreds of
-- cells at 4 Hz, and — more important — the timetable can be pushed to the
-- client once per closure instead of streamed, so the tac-map is never guessing.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Resolving `toRings`. Three of the schedule's values are not ring counts:
--
--   "all"     everything stays open (only ever a `fromRings`, kept for symmetry)
--   "square"  the final cell survives, but only its inner square. NOTHING
--             NARROWS CONTAINMENT INSIDE A CELL — `C.innerSquare` was described
--             here and never written — so this has always behaved as rings 0.
--             The generated schedule no longer emits it; the lattice makes the
--             final cell 25 m on Watson, which is smaller than the 40 m square
--             the sentinel stood in for. Kept only so a hand-written preset
--             carrying it still resolves to something legal.
--   "none"    nothing survives. The terminal phase, so a match cannot outlive
--             its own timetable.
-- ---------------------------------------------------------------------------
function C.keepSet(lattice, finalCol, finalRow, toRings)
    if toRings == "none" then return {} end
    if toRings == "all" then return Grid.allCells(lattice) end
    if toRings == "square" then
        return { [Grid.key(finalCol, finalRow)] = true }
    end
    return Grid.ringsFrom(lattice, finalCol, finalRow, tonumber(toRings) or 0)
end

--- Every lattice cell the survey has actually put a point in.
---
--- THIS IS THE ANSWER TO THE ONE REAL RISK THE LATTICE CREATES. A 100 m final
--- block is vouched for as a whole -- "the last fight happens here" -- but a
--- 25 m cell inside it is not: a quarter of Watson's block (1,1) is roof, stall
--- canopy and the far side of a wall, and a final zone that lands there is a
--- match nobody can win. The survey already knows where the floor is, in four
--- independent forms (landing zones, loot anchors, landmarks, supply points)
--- plus, on Watson, the fourteen `groundSamples` that are literal walked
--- deathmatch spawns. A cell holding one of those is a cell somebody has stood
--- in.
---
--- Cheap enough to do inline: it is a few dozen points, once per match.
local function surveyedCells(map, lattice)
    local cells = {}
    local function mark(x, y)
        local col, row = Grid.cellOf(lattice, x, y)
        if col ~= nil then cells[Grid.key(col, row)] = true end
    end
    for _, list in ipairs({ map.landings, map.lootClusters, map.landmarks, map.supply }) do
        for _, entry in ipairs(list or {}) do
            local p = type(entry) == "table" and entry.position or nil
            if type(p) == "table" then mark(p.x, p.y) end
        end
    end
    for _, p in ipairs(map.groundSamples or {}) do
        if type(p) == "table" then mark(p.x, p.y) end
    end
    return cells
end

--- The lattice cells a surveyed final block offers. Two lists, and the order
--- between them is the whole rule:
---
---   WALKED   every OPEN cell of the block that holds a survey point -- a
---            landing zone, a loot anchor, a landmark, a supply mark or a
---            walked ground sample. The whitelist vouches for the BLOCK; the
---            point vouches for the CELL. A walked cell at the edge of a block
---            is exactly as good a final as a walked cell at its middle:
---            somebody stood there.
---   FALLBACK the cells within `finalJitterCells` of the block's centre,
---            walked or not. For a block nobody has put a point in (a
---            hand-authored runtime map, say) the middle is the least-bad guess
---            about where its ground is, and a corner cell of an UNWALKED
---            block is a coin flip on a wall, a roof edge or the water.
---
--- THE RULE THIS REPLACES, AND WHY IT HAD TO GO. Until 2026-09-04 the only
--- candidates were the centre cells, filtered to the walked ones -- the
--- intersection of the two lists above. That intersection is small, and on
--- Watson it was small in one direction: with `blockCentreCell` at offset 2 of
--- a 4-cell block and jitter 1, block (1,1) offered columns 1-3 x rows 1-3 and
--- block (1,2) columns 1-3 x rows 5-7, so all eight walked candidates sat in
--- the west three-eighths of an eight-column lattice. The owner played it and
--- said "le cercle se ferme toujours au meme endroit sur les meme bloc" -- and
--- he was right: the final was always in the same corner, and the rings that
--- close around it swept the same streets in the same order every match.
--- Widening the whitelist alone would not have fixed it -- East Row's walked
--- cell (5,4) is not within one cell of block (2,1)'s centre, so under the old
--- rule the eastern blocks would have contributed nothing.
local function finalCandidates(lattice, blockKey, open, surveyed)
    local factor = math.max(1, math.floor(number(lattice.subdivide, 1)))
    local blockCol, blockRow = Grid.parse(blockKey)
    if blockCol == nil then return {}, {} end
    local centreCol, centreRow = Grid.blockCentreCell(blockCol, blockRow, factor)
    if centreCol == nil then return {}, {} end
    local jitter = math.max(0, math.floor(number(cfg().finalJitterCells, 1)))

    -- The block's own cells, in lattice coordinates. Everything below stays
    -- inside this square: a candidate outside the whitelisted block would be
    -- choosing unsurveyed ground by accident.
    local blockLoCol, blockHiCol = (blockCol - 1) * factor + 1, blockCol * factor
    local blockLoRow, blockHiRow = (blockRow - 1) * factor + 1, blockRow * factor

    local walked = {}
    for col = blockLoCol, blockHiCol do
        for row = blockLoRow, blockHiRow do
            local key = Grid.key(col, row)
            if open[key] == true and surveyed[key] == true then
                walked[#walked + 1] = key
            end
        end
    end

    local loCol = math.max(blockLoCol, centreCol - jitter)
    local hiCol = math.min(blockHiCol, centreCol + jitter)
    local loRow = math.max(blockLoRow, centreRow - jitter)
    local hiRow = math.min(blockHiRow, centreRow + jitter)
    local fallback = {}
    for col = loCol, hiCol do
        for row = loRow, hiRow do
            local key = Grid.key(col, row)
            if open[key] == true then fallback[#fallback + 1] = key end
        end
    end
    return walked, fallback
end

-- ---------------------------------------------------------------------------
-- WHICH FINAL, AND WHY THE LAST FEW ARE REMEMBERED.
--
-- A uniform draw over fourteen cells repeats one match in fourteen, which is
-- rare enough to be fine and common enough to be noticed by somebody playing
-- ten matches in an evening -- and the owner's complaint was made after a
-- session of exactly that shape. So the server keeps the last few finals and
-- draws from the candidates that are NOT among them, and then prefers a
-- candidate in a different BLOCK from the previous final when it has the
-- choice. Neither rule ever refuses: a map with a single candidate still
-- plays, it just plays the same ending.
--
-- Memory lives for the server process, not across restarts. A restart forgets,
-- which is the correct amount of forgetting: the memory exists to stop one
-- evening's matches repeating, not to spread endings over a season.
-- ---------------------------------------------------------------------------
local recentFinals = {}     -- "col,row" keys, oldest first
local recentBlocks = {}     -- the surveyed block of each, same order
local RECENT_CAP = 16

local function pickFinal(pool, blockOf)
    local memory = math.max(0, math.floor(number(cfg().finalRepeatMemory, 3)))
    local avoid = {}
    local remembered = math.min(memory, #recentFinals)
    for index = #recentFinals - remembered + 1, #recentFinals do
        avoid[recentFinals[index]] = true
    end

    local fresh = {}
    for _, cell in ipairs(pool) do
        if not avoid[cell] then fresh[#fresh + 1] = cell end
    end
    if #fresh == 0 then fresh = pool end

    -- A different block from last time, when there is one. Distinct cells of
    -- the same block are the same ending to a player -- the rings close on
    -- the same streets -- so this is the half of the rule that answers "the
    -- same blocks" rather than "the same metre".
    local lastBlock = recentBlocks[#recentBlocks]
    if lastBlock ~= nil then
        local elsewhere = {}
        for _, cell in ipairs(fresh) do
            if blockOf[cell] ~= lastBlock then elsewhere[#elsewhere + 1] = cell end
        end
        if #elsewhere > 0 then fresh = elsewhere end
    end

    local chosen = fresh[math.random(1, #fresh)]
    recentFinals[#recentFinals + 1] = chosen
    recentBlocks[#recentBlocks + 1] = blockOf[chosen]
    if #recentFinals > RECENT_CAP then
        table.remove(recentFinals, 1)
        table.remove(recentBlocks, 1)
    end
    return chosen
end

--- The finals this server has drawn so far, newest last. For the log line and
--- for `/br.status`-style readouts; never consulted by the rules above except
--- through `pickFinal`.
function C.recentFinals()
    local out = {}
    for index, cell in ipairs(recentFinals) do
        out[index] = { cell = cell, block = recentBlocks[index] }
    end
    return out
end

-- Seeded once, at load. Lua 5.4 seeds its generator at state creation on its
-- own, so this is belt and braces rather than a fix -- but the one thing a
-- battle royale must never do is play the same final twice because two servers
-- booted into the same sequence, and the freeroam and weather resources
-- already take the same precaution. `pcall` because the clock binding is the
-- one thing here that could be missing on an old host.
pcall(function()
    math.randomseed(math.floor(Open77.time.monotonic() * 1000000) % 2147483647)
end)

function C.begin(map, presetName)
    local grid = map and map.grid or nil
    local lattice = grid and C.lattice(grid) or nil
    if lattice == nil then
        state.active = false
        return false, "no_grid"
    end
    local factor = math.max(1, math.floor(number(lattice.subdivide, 1)))

    state.map = map
    state.lattice = lattice
    state.open = {}
    state.closing = {}
    state.queue = {}
    state.closeAt = {}
    state.phases = {}
    state.announcedThrough = 0
    state.phaseIndex = 0
    state.damagePerSecond = 0.0
    state.startedAtMs = K.nowMs()
    state.geometryRev = state.geometryRev + 1
    state.active = true

    -- Exclusions are authored per SURVEYED BLOCK (water, a highway, a blind
    -- roof), so each one excludes every lattice cell inside it.
    local excluded = {}
    for _, key in ipairs(Grid.expandKeys(map.excluded or {}, factor)) do
        excluded[key] = true
    end

    for col = 1, lattice.cols do
        for row = 1, lattice.rows do
            local key = Grid.key(col, row)
            if not excluded[key] then state.open[key] = true end
        end
    end

    -- The final cell is drawn from the surveyed whitelist. Without one the mode
    -- refuses to start rather than picking the middle: a final block in the sea,
    -- on a roof nobody can reach, or in a corner with one approach is a match
    -- that cannot be won, and "the centre" is all three often enough.
    local walked = {}
    local fallback = {}
    local blockOf = {}
    local surveyed = surveyedCells(map, lattice)
    for _, blockKey in ipairs(map.finalBlocks or {}) do
        local walkedHere, fallbackHere = finalCandidates(lattice, blockKey, state.open, surveyed)
        for _, cell in ipairs(walkedHere) do
            if blockOf[cell] == nil then walked[#walked + 1] = cell end
            blockOf[cell] = blockKey
        end
        for _, cell in ipairs(fallbackHere) do
            if blockOf[cell] == nil then
                fallback[#fallback + 1] = cell
                blockOf[cell] = blockKey
            end
        end
    end
    if #walked == 0 and #fallback == 0 then
        state.active = false
        return false, "no_final_block_whitelist"
    end
    -- A cell with a survey point in it wins outright. The centre cells are
    -- only the fallback, and it is a real one -- a map whose final blocks carry
    -- no marks at all (a hand-authored runtime map, say) still plays -- but it
    -- is the case where the last zone might be a rooftop, so it says so.
    if #walked > 0 then
        state.finalCell = pickFinal(walked, blockOf)
    else
        state.finalCell = pickFinal(fallback, blockOf)
        K.warn(("no surveyed point falls in any final block on %s; the last zone is " ..
            "centred on unwalked ground. Add a landing zone, loot anchor or landmark " ..
            "inside a finalBlocks entry."):format(tostring(map.name)))
    end
    state.finalBlock = blockOf[state.finalCell]
    local finalCol, finalRow = Grid.parse(state.finalCell)

    local preset, presetUsed = schedulePreset(presetName)
    -- MEASURED, NOT ASSUMED. The span is the radius that still contains every
    -- open cell, so the generated schedule is sized to the map that is actually
    -- being played rather than to the one the numbers were written against.
    local span = Grid.spanOf(state.open, finalCol, finalRow)
    state.schedule = C.buildSchedule(span, preset)
    if type(state.schedule) ~= "table" or #state.schedule == 0 then
        state.active = false
        return false, "no_schedule"
    end

    -- Build the timetable from continuous rectangle crossings. The phase's
    -- target set is unchanged; a cell retires once its last safe sliver closes.
    local remaining = {}
    for key in pairs(state.open) do remaining[key] = true end
    state.allowed = {}
    for key in pairs(state.open) do state.allowed[key] = true end
    local previousRect = Grid.ringRect(lattice, finalCol, finalRow, span)

    local warnMs = math.max(0, number(cfg().warnSeconds, 30)) * 1000
    local previousEndMs = state.startedAtMs

    for index, phase in ipairs(state.schedule) do
        -- `keep` is what this phase leaves standing. The deterministic order
        -- selects the doomed set; crossing times below determine retirement.
        local keep = C.keepSet(lattice, finalCol, finalRow, phase.toRings)
        local ordered = Grid.closureOrder(lattice, remaining, keep, finalCol, finalRow)
        local windowMs = math.max(1, number(phase.closeOverSeconds, 20) * 1000)
        local startMs = state.startedAtMs + number(phase.atSeconds, 0) * 1000
        local terminal = phase.toRings == "none"
        local targetRect = terminal and previousRect or
            Grid.ringRect(lattice, finalCol, finalRow,
                phase.toRings == "all" and span or tonumber(phase.toRings) or 0)

        for _, key in ipairs(ordered) do
            local col, row = Grid.parse(key)
            local fraction = terminal and 1 or Grid.sweepExitFraction(lattice, col, row, previousRect, targetRect)
            local atMs = startMs + fraction * windowMs
            state.queue[#state.queue + 1] = {
                cell = key,
                atMs = atMs,
                phaseIndex = index,
                damagePerSecond = phase.damagePerSecond or 2.0,
            }
            -- The same deadline, keyed by cell, so "when does MY block close"
            -- is one lookup per player per push rather than a walk of the
            -- queue. See `C.cellClosesInMs`.
            state.closeAt[key] = atMs
            remaining[key] = nil
        end

        -- WHEN THE PLAYER IS TOLD: the moment the PREVIOUS window finished, so
        -- the doomed region is on the tac-map for the whole hold — which is
        -- exactly the time a player is deciding whether to rotate. Apex draws
        -- the next ring before it closes for the same reason; a boundary you
        -- only learn about when it reaches you is a coin flip, not a decision.
        --
        -- The first phase has no predecessor, so it uses `warnSeconds` and is
        -- clamped to the start of the match. That is also why announcement is
        -- chained off the previous window rather than computed as
        -- `start - warnSeconds` throughout: with a short hold (blitz holds ~9 s
        -- against a 30 s warning) that formula announces phase N before phase
        -- N-1 has even begun, and `state.closing` would then flash two rings at
        -- once — telling the player that ground is going which is not going yet.
        local announceAtMs = previousEndMs
        if index == 1 then
            announceAtMs = math.max(state.startedAtMs, startMs - warnMs)
        end
        state.phases[index] = {
            index = index,
            doomed = ordered,
            announceAtMs = announceAtMs,
            startMs = startMs,
            endMs = startMs + windowMs,
            toRings = phase.toRings,
            damagePerSecond = phase.damagePerSecond,
            from = previousRect,
            to = targetRect,
            terminal = terminal,
            -- The surviving rectangle, in LATTICE cells, for the "next zone"
            -- readout. Numeric radii only: "none" survives nothing and "square"
            -- is a cell, and neither is a box worth drawing.
            box = (type(phase.toRings) == "number") and {
                loCol = math.max(1, finalCol - phase.toRings),
                hiCol = math.min(lattice.cols, finalCol + phase.toRings),
                loRow = math.max(1, finalRow - phase.toRings),
                hiRow = math.min(lattice.rows, finalRow + phase.toRings),
            } or nil,
        }
        previousEndMs = startMs + windowMs
        previousRect = targetRect
    end

    table.sort(state.queue, function(a, b)
        if a.atMs == b.atMs then return a.cell < b.cell end
        return a.atMs < b.atMs
    end)

    -- `candidates=` and `recent=` are on this line so that "it always closes in
    -- the same place" can be checked from the server log alone: a candidate
    -- count of two, or a recent list that repeats, is the answer before
    -- anybody has to play a second match.
    local recent = {}
    for _, entry in ipairs(C.recentFinals()) do recent[#recent + 1] = entry.cell end
    K.log(("cordon armed: map=%s lattice=%dx%d @%.0fm (x%d) final=%s in block %s span=%d " ..
        "preset=%s phases=%d cells=%d closures=%d ends=%.0fs candidates=%d walked=%d " ..
        "recent=[%s]"):format(
        tostring(map.name), lattice.cols, lattice.rows, number(lattice.blockMetres, 0), factor,
        tostring(state.finalCell), tostring(state.finalBlock), span, tostring(presetUsed),
        #state.schedule, C.openCount(), #state.queue,
        number(state.schedule[#state.schedule].atSeconds, 0) +
        number(state.schedule[#state.schedule].closeOverSeconds, 0),
        #walked + #fallback, #walked, table.concat(recent, " ")))
    return true
end

function C.stop()
    state.active = false
    state.allowed = {}
    state.open = {}
    state.closing = {}
    state.queue = {}
    state.closeAt = {}
    state.phases = {}
    state.announcedThrough = 0
    state.finalCell = nil
    state.finalBlock = nil
    state.lattice = nil
    state.geometryRev = state.geometryRev + 1
    -- AND SAY SO, once, on the wire.
    --
    -- `cordon:bounds` is published on CHANGE, and the tac-map HOLDS the last one
    -- it received for the life of the client (`open77_cordon_hud/client/tacmap.lua`,
    -- the `bounds` upvalue) and merges it OVER the state fragment. So the last
    -- publish of a finished match -- one cell open, everything else sealed, and
    -- now a flashing doomed set as well -- survived the match that produced it
    -- and painted the NEXT match's staging and deploy window with the previous
    -- winner's final zone. The fragment said the district was untouched and the
    -- stale bounds overruled it.
    --
    -- Ending a cordon is a change like any other. This is the publish that says
    -- so. `pcall` because a stop can also arrive on a shutdown path, where there
    -- may be no one left to tell.
    pcall(C.publish)
end

-- Compact timeline shared with the renderer. Never send server process-clock
-- timestamps as though they belonged to a client's monotonic clock.
function C.sweepDescriptor(now)
    if not state.active then return nil end
    now = now or K.nowMs()
    local selected = state.phases[#state.phases]
    for _, info in ipairs(state.phases) do
        if now < info.endMs then selected = info break end
    end
    if selected == nil then return nil end
    return { revision = state.geometryRev, generation = state.startedAtMs,
        phaseIndex = selected.index, startsInMs = selected.startMs - now,
        durationMs = selected.endMs - selected.startMs, from = selected.from,
        to = selected.to, terminal = selected.terminal }
end

function C.currentRect(now)
    return Grid.sweepRect(C.sweepDescriptor(now), 0)
end

function C.motionStartsInMs()
    local sweep = C.sweepDescriptor()
    return sweep and math.max(0, sweep.startsInMs) or nil
end

function C.openCount()
    local n = 0
    for _ in pairs(state.open) do n = n + 1 end
    return n
end

--- The bleed actually applied, which is the phase's rate through the live
--- `damageScale` tunable. Resolved in ONE place and used by the tick, the
--- fragment and the bounds push alike: a HUD showing 6 HP/s while the server
--- applies 12 is worse than either number on its own, and the tunable was
--- declared in `Config.tunables` from the first day and read by nobody.
function C.damagePerSecond()
    local scale = number(K.tune("damageScale", 1.0), 1.0)
    if scale < 0.0 then scale = 0.0 end
    return state.damagePerSecond * scale
end

--- The open and closing cells as flat arrays of "col,row" keys, which is what
--- the tactical overlay draws. `state.open` and `state.closing` are sets, and a
--- set with string keys does not survive the trip to a browser surface as
--- anything the overlay can index, so they are flattened here.
function C.openKeys()
    -- BEFORE THE CORDON ARMS, EVERY CELL IS OPEN. `state.open` is empty until
    -- `C.begin` runs at the live transition, and the tactical overlay paints
    -- anything absent from this list as SEALED -- so during the deploy window,
    -- which is exactly when a player is choosing a drop pin, the whole district
    -- came up hatched red and nothing could be clicked. Reported by the owner,
    -- 2026-09-02, the first time the map had data to draw at all.
    --
    -- The district is not sealed then; it is untouched. Say so -- and say it in
    -- LATTICE cells, because that is the grid the same message publishes.
    local lattice = activeLattice()
    if not state.active and lattice ~= nil and lattice.cols and lattice.rows then
        local all = {}
        for col = 1, lattice.cols do
            for row = 1, lattice.rows do
                all[#all + 1] = ("%d,%d"):format(col, row)
            end
        end
        return all
    end

    local keys = {}
    for key in pairs(state.open) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

function C.closingKeys()
    local keys = {}
    for key in pairs(state.closing) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

--- The zone that survives the phase currently being announced or closed, in
--- WORLD metres. Four numbers, sent so a client can point at it without
--- reconstructing the ring maths — and so that "where do I run" has an answer
--- that does not depend on the player reading a grid.
function C.nextZone()
    if not state.active then return nil end
    local info = state.phases[state.announcedThrough]
    if info == nil or info.box == nil then return nil end
    local lattice = state.lattice
    if lattice == nil then return nil end
    local origin = lattice.origin or {}
    local size = number(lattice.blockMetres, 100.0)
    local ox = number(origin.x, 0.0)
    local oy = number(origin.y, 0.0)
    local minX = ox + (info.box.loCol - 1) * size
    local minY = oy + (info.box.loRow - 1) * size
    local maxX = ox + info.box.hiCol * size
    local maxY = oy + info.box.hiRow * size
    return {
        minX = minX, minY = minY, maxX = maxX, maxY = maxY,
        centreX = (minX + maxX) * 0.5,
        centreY = (minY + maxY) * 0.5,
        cells = (info.box.hiCol - info.box.loCol + 1)
              * (info.box.hiRow - info.box.loRow + 1),
        metres = math.max(maxX - minX, maxY - minY),
        phase = info.index,
    }
end

-- ---------------------------------------------------------------------------
-- THE TICK. Announces what is doomed, closes what is due, and bleeds whoever is
-- outside.
--
-- Two rules inherited from the arena's bounds work, both paid for:
--
--   * NEVER JUDGE A SINGLE SAMPLE. `Open77.players.position` is a replicated
--     snapshot, not a live read, so a player is only "outside" once they have
--     been outside for N consecutive samples.
--   * AN UNREADABLE POSITION FREEZES THE ACCUMULATOR, it does not reset it.
--     Resetting would let anyone stand outside forever by interrupting their
--     own replication; deciding "outside" on no data would kill people for
--     their connection. Cannot-tell is its own answer.
-- ---------------------------------------------------------------------------
local lastTickMs = nil
local lastPublishMs = 0
local publishDirty = false

--- Coalesced publish. The bounds message carries the whole open-cell list, and
--- the closure loop can retire several cells inside one 4 Hz tick — so on a
--- large lattice an un-throttled publish would send the same kilobyte to every
--- player four times a second for the length of a closure window, to describe a
--- boundary that has moved one cell. A closure that is one interval late on the
--- tac-map is invisible; containment is decided on the server either way.
local function flushPublish(now, force)
    if not publishDirty then return end
    local minGap = math.max(0, number(cfg().publishMinIntervalMs, 500))
    if not force and (now - lastPublishMs) < minGap then return end
    publishDirty = false
    lastPublishMs = now
    C.publish()
end

function C.tick()
    if not state.active then return end
    local now = K.nowMs()
    local deltaMs = lastTickMs and (now - lastTickMs) or 0
    lastTickMs = now

    -- ANNOUNCE. Everything the next phase will take, marked before it takes it.
    local announced = false
    local announcedIn = 0
    while state.announcedThrough < #state.phases do
        local info = state.phases[state.announcedThrough + 1]
        if info == nil or info.announceAtMs > now then break end
        state.announcedThrough = state.announcedThrough + 1
        for _, key in ipairs(info.doomed) do
            if state.open[key] == true then state.closing[key] = true end
        end
        announced = true
        announcedIn = math.max(0, math.floor((info.startMs - now) / 1000))
    end
    if announced then
        publishDirty = true
        state.geometryRev = state.geometryRev + 1
        -- `cordonWarning` and `cordonClosing` below are the two notice kinds the
        -- HUD string table actually names ("CORDON CLOSES IN {seconds}s" and
        -- "THE CORDON IS CLOSING"). The kind this loop used to send on a phase
        -- turn, `cordonPhase`, is named by NOTHING -- and `web/match.js` draws
        -- nothing for a kind its table does not carry, deliberately, because "a
        -- toast reading notice.somethingNew would be worse than silence". So
        -- every closure this mode has ever run has announced itself to an empty
        -- room. Both kinds here exist; both draw.
        K.broadcastNotice("cordonWarning", { seconds = announcedIn })
    end

    -- Close everything due.
    local closed = 0
    local phaseChanged = false
    for _, info in ipairs(state.phases) do
        if info.startMs <= now and info.index > state.phaseIndex then
            state.phaseIndex = info.index
            state.phaseStartedMs = info.startMs
            state.damagePerSecond = info.damagePerSecond
            phaseChanged = true
            publishDirty = true
            K.broadcastNotice("cordonClosing", { phase = info.index, damage = C.damagePerSecond() })
        end
    end
    while #state.queue > 0 and state.queue[1].atMs <= now do
        local entry = table.remove(state.queue, 1)
        if state.open[entry.cell] then
            state.open[entry.cell] = nil
            closed = closed + 1
        end
        state.closing[entry.cell] = nil
    end
    if closed > 0 then
        publishDirty = true
        state.geometryRev = state.geometryRev + 1
        -- Bots are told ONCE per closure to walk toward the next cordon. Never
        -- on a tick: re-issued movement cancels the behaviour tree the engine is
        -- using to fight, and a bot that cannot fight is scenery.
        if K.bots ~= nil then pcall(K.bots.onCordonClosed) end
    end
    -- Forced on the two edges that must never be late: the moment a phase turns
    -- over (the HUD's rate and phase number change with it) and the moment the
    -- timetable empties (the last frame of the match).
    flushPublish(now, announced or phaseChanged or #state.queue == 0)

    if deltaMs <= 0 then return end
    local settings = cfg()
    -- `holdSamples` is the name the config declares and documents; `outsideSamples`
    -- is the name this loop was written against. Both are read, config first,
    -- because for weeks neither matched and the loop silently used the hard-coded
    -- 3 while the file next to it explained why the answer was 2.
    local needSamples = math.max(1, math.floor(
        number(settings.outsideSamples, number(settings.holdSamples, 3))))
    local dps = C.damagePerSecond()
    if dps <= 0 then return end

    -- Bots bleed too, through the NPC damage path. A cordon that only closes on
    -- players is a cordon the bots win.
    if K.bots ~= nil then pcall(K.bots.applyCordonDamage, dps) end

    for _, record in ipairs(K.alive()) do
        local inside = C.evaluate(record)
        if inside == true then
            record.outsideSamples = 0
            record.outsideSinceMs = nil
        elseif inside == false then
            record.outsideSamples = (record.outsideSamples or 0) + 1
            record.outsideSinceMs = record.outsideSinceMs or now
            if record.outsideSamples >= needSamples and record.id > 0 then
                local amount = dps * (deltaMs / 1000.0)
                -- kind MUST be "environment". Measured 2026-09-02 (E5): the Lua
                -- wrapper reads options.cause BEFORE options.kind and both feed
                -- the engine ATTACK KIND parser, so a free-text cause such as
                -- "cordon" is rejected outright with invalid_argument. Pass
                -- kind, and pass nothing else.
                pcall(Open77.players.damage, record.id, amount, { kind = "environment" })
            end
        end
        -- inside == nil is cannot-tell: freeze, decide nothing.
    end
end

--- Three answers, never two: true inside, false outside, nil cannot tell.
function C.evaluate(record)
    if not state.active then return true end
    local position = K.position(record.id)
    if position == nil then return nil end
    local lattice = state.lattice
    if lattice == nil or lattice.origin == nil then
        -- An unsurveyed map cannot contain anybody. Suspending containment is
        -- the honest answer: a mode that silently reported everyone outside
        -- would kill the whole lobby the moment it started.
        return nil
    end
    local col, row = Grid.cellOf(lattice, position.x, position.y)
    if col == nil then return false end
    local key = Grid.key(col, row)
    record.lastCell = key
    return Grid.sweepContains(lattice, state.allowed, C.currentRect(), position.x, position.y)
end

-- Every player uses the same clipped geometry within a server tick. Cache
-- centres by the actual rectangle, not only by retired-cell revision: the
-- front moves between retirements. Group on the shorter grid axis so even the
-- 1024-cell cap needs at most 32 binary searches per outside player.
local openCentreCache = {}
local function openCentres(rect)
    local cache = openCentreCache
    local sameRect = cache.rect == nil and rect == nil or
        cache.rect ~= nil and rect ~= nil and cache.rect.minX == rect.minX and
        cache.rect.minY == rect.minY and cache.rect.maxX == rect.maxX and cache.rect.maxY == rect.maxY
    if cache.rev == state.geometryRev and cache.lattice == state.lattice and sameRect then return cache end
    local lattice = state.lattice
    cache = { rev = state.geometryRev, lattice = lattice, rect = rect, groups = {},
        horizontal = lattice ~= nil and lattice.cols >= lattice.rows }
    openCentreCache = cache
    if not lattice or not rect then return cache end
    local byMinor = {}
    for key in pairs(state.open) do
        local col, row = Grid.parse(key)
        local box = Grid.clipBox(lattice, col, row, rect)
        if box then
            local x, y = (box.minX + box.maxX) * 0.5, (box.minY + box.maxY) * 0.5
            local minor = cache.horizontal and row or col
            local group = byMinor[minor]
            if not group then
                group = { v = cache.horizontal and y or x, values = {} }
                byMinor[minor] = group
                cache.groups[#cache.groups + 1] = group
            end
            group.values[#group.values + 1] = cache.horizontal and x or y
        end
    end
    for _, group in ipairs(cache.groups) do table.sort(group.values) end
    table.sort(cache.groups, function(a, b) return a.v < b.v end)
    return cache
end

--- Nearest centre of a surviving cell portion, including partial edge cells.
function C.nearestOpen(position)
    if state.lattice == nil or position == nil then return nil end
    local cache = openCentres(C.currentRect())
    local u = cache.horizontal and position.x or position.y
    local v = cache.horizontal and position.y or position.x
    local bestU, bestV, bestDistance
    for _, group in ipairs(cache.groups) do
        local dy = group.v - v
        local dy2 = dy * dy
        if bestDistance == nil or dy2 <= bestDistance then
            local values = group.values
            local lo, hi = 1, #values
            while lo <= hi do
                local mid = (lo + hi) // 2
                if values[mid] < u then lo = mid + 1 else hi = mid - 1 end
            end
            -- The closest x must be one of the two neighbours of the insertion
            -- point; disconnected holes do not change that property.
            for index = math.max(1, lo - 1), math.min(#values, lo) do
                local dx = values[index] - u
                local distance = dx * dx + dy2
                if bestDistance == nil or distance < bestDistance then
                    bestU, bestV, bestDistance = values[index], group.v, distance
                end
            end
        end
    end
    if bestDistance == nil then return nil end
    return { x = cache.horizontal and bestU or bestV, y = cache.horizontal and bestV or bestU,
        distance = math.sqrt(bestDistance) }
end

-- ---------------------------------------------------------------------------
-- THE GROUND THAT IS ABOUT TO GO, per player.
--
-- The owner's verdict after playing the mode with a visible boundary: "le
-- principe de voir la zone ... c'est de savoir que la zone s'approche au fur
-- et a mesure et qu'il faut avancer vers la prochaine zone" -- and "la on a
-- pas du tout cette impression". The mode already announced the doomed set to
-- the tac-map; what it never told the PLAYER STANDING ON IT was that he was
-- standing on it. The HUD spoke only once he was already outside and bleeding,
-- which is a coin flip, not a decision (the same words the announce logic in
-- `C.begin` uses about the tac-map).
--
-- Three answers ride the state push for a living player whose cell has been
-- announced and has not yet closed: THAT he is on doomed ground, WHEN his own
-- cell closes, and WHERE the nearest cell that survives the announced phase is
-- -- the same shape as `outside` / `nearestOpen`, one phase earlier.
-- ---------------------------------------------------------------------------

--- Whether `cell` is announced and still open.
function C.isDoomed(cell)
    return state.active and cell ~= nil and state.closing[cell] == true
        and state.open[cell] == true
end

--- Milliseconds until `cell` closes, or nil when it is not scheduled (never
--- announced, already closed, or the cordon is not armed). Clamped at zero:
--- a cell whose deadline has passed but which the tick has not yet retired is
--- closing NOW, not "minus forty milliseconds ago".
function C.cellClosesInMs(cell)
    if not state.active or cell == nil then return nil end
    local atMs = state.closeAt[cell]
    if atMs == nil then return nil end
    return math.max(0, atMs - K.nowMs())
end

--- When the moving boundary reaches THIS position, rather than when the last
--- safe sliver of its cell disappears. Kept separate from block retirement ETA.
function C.positionClosesInMs(position)
    if not state.active or position == nil then return nil end
    local now = K.nowMs()
    if not Grid.sweepContains(state.lattice, state.allowed, C.currentRect(now), position.x, position.y) then return 0 end
    for _, info in ipairs(state.phases) do
        if info.endMs >= now then
            if info.terminal then return math.max(0, info.endMs - now) end
            local a,b=info.from,info.to
            local x,y=position.x,position.y
            if x < b.minX or x >= b.maxX or y < b.minY or y >= b.maxY then
                local t=1
                if b.minX>a.minX then t=math.min(t,(x-a.minX)/(b.minX-a.minX)) end
                if b.minY>a.minY then t=math.min(t,(y-a.minY)/(b.minY-a.minY)) end
                if b.maxX<a.maxX then t=math.min(t,(a.maxX-x)/(a.maxX-b.maxX)) end
                if b.maxY<a.maxY then t=math.min(t,(a.maxY-y)/(a.maxY-b.maxY)) end
                return math.max(0, info.startMs + math.max(0,t)*(info.endMs-info.startMs) - now)
            end
        end
    end
    return nil
end

-- Centres of the cells that survive the announced phase, rebuilt only when
-- the geometry changes. `state.geometryRev` is bumped on begin, stop, every
-- announcement and every closure -- so during a hold, which is when most
-- players are doomed at once, the list is built once and read sixty-four
-- times a push.
local safeCache = { rev = -1, list = {} }

local function safeCentres()
    if safeCache.rev == state.geometryRev then return safeCache.list end
    local lattice = state.lattice
    local list = {}
    if lattice ~= nil then
        for key in pairs(state.open) do
            if state.closing[key] ~= true then
                local col, row = Grid.parse(key)
                local box = Grid.boxOf(lattice, col, row)
                if box ~= nil then
                    list[#list + 1] = {
                        x = (box.min.x + box.max.x) * 0.5,
                        y = (box.min.y + box.max.y) * 0.5,
                    }
                end
            end
        end
    end
    safeCache.rev = state.geometryRev
    safeCache.list = list
    return list
end

--- The nearest cell that is open AND not announced -- the ground a doomed
--- player has to reach. Nil when nothing survives the announced phase, which is
--- the terminal phase: there is nowhere to point, and the HUD shows the clock
--- without a compass rather than a compass pointing at nothing.
function C.nearestSafe(position)
    if not state.active or position == nil then return nil end
    local best, bestDistance = nil, nil
    for _, centre in ipairs(safeCentres()) do
        local dx, dy = centre.x - position.x, centre.y - position.y
        local distance = (dx * dx) + (dy * dy)
        if bestDistance == nil or distance < bestDistance then
            bestDistance = distance
            best = centre
        end
    end
    if best == nil then return nil end
    return { x = best.x, y = best.y, distance = math.sqrt(bestDistance) }
end

-- ---------------------------------------------------------------------------
-- PUBLISH. The cordon geometry is pushed on CHANGE, not on the state tick:
-- a several-hundred-cell set at 2 Hz to 64 players is a needless kilobyte a
-- second each, and the client only needs it when it moves.
-- ---------------------------------------------------------------------------
function C.publish()
    -- `C.openKeys()` and not a walk of `state.open`, so that the two messages
    -- carrying an open-cell list cannot disagree about what "before the cordon
    -- arms" means. The fragment has always answered "the whole district, because
    -- it is untouched rather than sealed"; the bounds push used to answer "the
    -- empty set", which the overlay draws as every cell hatched red. That only
    -- became reachable when `C.stop` started publishing -- but a disagreement
    -- between two sources of the same fact is worth removing on sight, not once
    -- something finally reads the wrong one.
    local open = C.openKeys()
    local nextClosure = state.queue[1]
    -- The grid geometry rides the bounds payload, not the 500 ms state push.
    -- The tac-map cannot draw a single cell without origin/cols/rows/size, and
    -- those never change during a match — so they belong on the message that is
    -- sent on change, and sending them 120 times a minute to 64 players instead
    -- would be a kilobyte a second each for four numbers that never move.
    --
    -- IT IS THE LATTICE THAT IS PUBLISHED, not the survey grid, and that single
    -- choice is what let the whole redesign land without touching one client
    -- file: the tac-map and the in-world edge derive everything they draw from
    -- these four numbers plus the open-cell list, so subdividing the grid on the
    -- server subdivides both of them for free.
    local lattice = activeLattice()
    local payload = {
        grid = lattice and {
            originX = lattice.origin and lattice.origin.x or nil,
            originY = lattice.origin and lattice.origin.y or nil,
            -- ORIGIN Z RIDES HERE TOO, and it is not decoration: the in-world
            -- edge (client/edge.lua) stands its posts on the ground, and the
            -- only height the client has otherwise is its own feet -- which is
            -- the wrong storey for a post eighty metres away.
            originZ = lattice.origin and lattice.origin.z or nil,
            cols = lattice.cols, rows = lattice.rows,
            blockMetres = lattice.blockMetres,
            -- How many lattice cells make one surveyed block. Carried so a
            -- consumer holding survey data keyed by block can still find it.
            subdivide = lattice.subdivide,
        } or nil,
        -- HOW THE EDGE SHOULD BE DRAWN, resolved from the `cordonEdge` tunable
        -- so a change made in the Warden panel reaches a client whose copy of
        -- shared/config.lua says something else. A tunable that only takes
        -- effect on a resource reload is not a live tunable, and this is the one
        -- an operator reaches for first the moment the world edge misbehaves.
        edgeStyle = C.edgeStyle(),
        finalCell = state.finalCell,
        sweep = C.sweepDescriptor(),
        allowed = state.active and (function()
            local keys = {}
            for key in pairs(state.allowed) do keys[#keys + 1] = key end
            table.sort(keys)
            return keys
        end)() or nil,
        open = open,
        -- THE DOOMED SET, and it rides the BOUNDS message rather than the state
        -- push on purpose. The tac-map merges bounds over the fragment and
        -- flashes `closing`, which is exactly the "next ring" reading this
        -- redesign wanted: the ground that survives is the ground that is not
        -- flashing. The match strip reads the FRAGMENT's `closing` instead, and
        -- that one stays empty until a window is genuinely running -- because
        -- the strip replaces its countdown with CLOSING NOW the moment the list
        -- is non-empty, and a countdown is the more useful of the two during the
        -- hold. Two audiences, two readings of the same fact, stated here so the
        -- next reader does not "fix" one of them into the other.
        closing = C.closingKeys(),
        nextZone = C.nextZone(),
        closeAtMs = C.motionStartsInMs(),
        nextCell = nextClosure and nextClosure.cell or nil,
        damagePerSecond = C.damagePerSecond(),
        phaseIndex = state.phaseIndex,
        phases = state.schedule and #state.schedule or 0,
    }
    for _, record in ipairs(K.humans()) do
        TriggerClientEvent("cordon:bounds", record.id, payload)
    end
end

-- ---------------------------------------------------------------------------
-- THE EDGE. Two small resolvers, because both answers have to be the SAME on
-- the wire and in the log, and both read the LIVE tunable rather than a
-- captured local -- `K.tune` is a call for exactly that reason.
-- ---------------------------------------------------------------------------

--- "off" | "hud" | "world". Anything unrecognised degrades to "hud", which is
--- the recorded fallback and still a playable mode: a typo in the Warden panel
--- must not be able to leave a match with no boundary feedback at all.
function C.edgeStyle()
    local settings = cfg()
    local edge = settings.edge or {}
    local value = tostring(K.tune("cordonEdge", edge.style or settings.edgeStyle or "hud"))
    if value ~= "off" and value ~= "hud" and value ~= "world" then
        return "hud"
    end
    return value
end

--- The vignette tuning the HUD needs, or nil when the edge is off entirely.
--- Nil rather than `enabled = false` because the HUD reads a missing block as
--- "no grading, keep the old on/off behaviour", which is also what an older HUD
--- that has never heard of this field does -- so the two agree by construction.
---
--- The style is passed IN rather than resolved again. `C.edgeStyle` goes through
--- `K.tune`, which is a call into the host's tunable store, and this runs once
--- per player per state push -- 64 players at 2 Hz is 128 of them a second, and
--- resolving twice would make it 256 for an answer that cannot have changed
--- between the two lines.
local function edgeVignette(style)
    if style == "off" then return nil end
    local edge = cfg().edge or {}
    local settings = edge.vignette or {}
    if settings.enabled == false then return nil end
    return {
        rampMs = tonumber(settings.rampMs) or 12000,
        fullRateDps = tonumber(settings.fullRateDps) or 25.0,
        minimum = tonumber(settings.minimum) or 0.35,
    }
end

--- The fragment the per-player state push carries. Deliberately small: the
--- open-cell list rides `cordon:bounds` on change instead.
local fragmentCache = {}
function C.fragment()
    -- Resolved ONCE per fragment; see `edgeVignette`.
    local edgeStyle = C.edgeStyle()
    local nextClosure = state.queue[1]
    local lattice = activeLattice()
    local now, damage = K.nowMs(), C.damagePerSecond()
    if fragmentCache.now == now and fragmentCache.rev == state.geometryRev and
        fragmentCache.lattice == lattice and fragmentCache.phase == state.phaseIndex and
        fragmentCache.active == state.active and fragmentCache.style == edgeStyle and
        fragmentCache.damage == damage then return fragmentCache.payload end

    -- ONLY THE WINDOW IN PROGRESS, never the announced set. The match strip
    -- swaps its countdown for CLOSING NOW as soon as this list is non-empty, and
    -- during the hold the countdown is the thing worth having; the tac-map gets
    -- the announced set off `cordon:bounds` instead. See the note in `C.publish`.
    local closing = {}
    local window = state.phases[state.phaseIndex]
    if window ~= nil and state.active then
        if now >= window.startMs and now <= window.endMs then
            for _, key in ipairs(window.doomed) do
                if state.open[key] == true then closing[#closing + 1] = key end
            end
            table.sort(closing)
        end
    end
    local payload = {
        active = state.active,
        phaseIndex = state.phaseIndex,
        phases = state.schedule and #state.schedule or 0,
        damagePerSecond = damage,
        openCells = C.openCount(),
        closeInMs = C.motionStartsInMs(),

        -- THE VIGNETTE'S TUNING, and it travels because it cannot be read where
        -- it is needed. The screen-side edge lives in `open77_cordon_hud`, which
        -- is a SEPARATE RESOURCE with its own Lua state: it cannot see `Config`,
        -- and copying the numbers into the HUD would mean two files to edit and
        -- one of them eventually forgotten.
        --
        -- Three numbers at 2 Hz to 64 players is roughly 7 KB/s across the whole
        -- server, against the ~23 KB/s PER PLAYER the snapshot relay already
        -- costs with player interest on (E1). That is not a cost worth splitting
        -- the tuning over two resources to avoid.
        vignette = edgeVignette(edgeStyle),
        -- The resolved style, so the HUD can drop the vignette entirely on
        -- "off" without a second source of truth about what "off" means.
        edgeStyle = edgeStyle,

        -- THE GRID ITSELF, without which the tactical overlay has nothing to
        -- draw and says so: "NO SURVEY DATA -- the server has not published a
        -- block grid yet." Reported by the owner on first play, 2026-09-02, and
        -- true since the overlay was written: it reads these names off the
        -- CORDON fragment, and the fragment carried only the phase and the
        -- countdown.
        --
        -- Both spellings of each pair are sent (`gridCols`/`cols`,
        -- `blockSize`/`blockMetres`) because the survey table and `grid.lua`
        -- disagree on which, and the overlay accepts either. Sending both means
        -- neither side has to win that argument for the map to draw.
        --
        -- These are LATTICE numbers, the same ones `C.publish` sends, so the
        -- overlay draws the grid the cordon actually closes. `subdivide` says
        -- how many of them make one surveyed block.
        --
        -- `originX`/`originY` is the CORNER of cell (1,1), not its centre, and
        -- columns and rows are 1-based; `indexBase` says so explicitly so that a
        -- future server publishing 0-based cells does not silently draw the
        -- whole map one cell off.
        gridCols = lattice and lattice.cols or nil,
        gridRows = lattice and lattice.rows or nil,
        cols = lattice and lattice.cols or nil,
        rows = lattice and lattice.rows or nil,
        blockMetres = lattice and lattice.blockMetres or nil,
        blockSize = lattice and lattice.blockMetres or nil,
        subdivide = lattice and lattice.subdivide or 1,
        originX = lattice and lattice.origin and lattice.origin.x or nil,
        originY = lattice and lattice.origin and lattice.origin.y or nil,
        originZ = lattice and lattice.origin and lattice.origin.z or nil,
        indexBase = 1,
        open = C.openKeys(),
        closing = closing,
        nextZone = C.nextZone(),
        nextCell = nextClosure and nextClosure.cell or nil,
    }
    -- Read-only shared payload: each recipient is serialized independently by
    -- the host. The timestamp keeps relative countdowns fresh on every push.
    fragmentCache = { now = now, rev = state.geometryRev, lattice = lattice,
        phase = state.phaseIndex, active = state.active, style = edgeStyle, damage = damage, payload = payload }
    return payload
end

K.log("cordon ready")
