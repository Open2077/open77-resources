-- Cordon -- block math.
--
-- PURE ARITHMETIC. Nothing in this file calls the engine, reads a player, or
-- touches an Open77 namespace, and that is a hard rule rather than a happy
-- accident: the cordon runs 64 players x 4 Hz x up to 196 blocks, so this is the
-- hottest code in the mode, and it is also the code most likely to be WRONG in a
-- way that only shows up as a player bleeding on a street they can see is inside
-- the line. Code with no dependencies can be run against a table of expectations
-- in a plain `lua5.4` with no game, no server and no session -- which is exactly
-- how it should be checked before it is ever deployed.
--
-- A test harness loads this file and reads the `Grid` global:
--
--     dofile("resources/gamemodes/open77_cordon/shared/grid.lua")
--     assert(Grid.key(3, 7) == "3,7")
--
-- There is no `require`, no `io` and no `os` here -- the resource sandbox nils
-- all three -- and no upvalue outside this chunk. If a future edit needs one of
-- those, the function belongs in `server/cordon.lua`, not here.
--
-- ---------------------------------------------------------------------------
-- THE MAP, which is the only argument that carries state
--
-- Every function takes a `map` table and reads geometry out of it. That table
-- comes from the SURVEY (the map store, `/br.map`), never from
-- `shared/config.lua`: config holds rules, the store holds coordinates, and
-- `Config.grid` is only the set of defaults a map inherits when it says nothing.
-- The shape:
--
--     map = {
--         origin        = { x = <number>, y = <number>, z = <number> },
--         blockMetres   = 100,          -- one block, both axes
--         cols          = 14,           -- blocks along +x
--         rows          = 14,           -- blocks along +y
--         floorMargin   = 60.0,         -- metres BELOW origin.z that a block box reaches
--         ceilingMargin = 260.0,        -- metres ABOVE origin.z
--         blocks        = {             -- OPTIONAL per-block vertical override
--             ["7,9"] = { floor = 3.0, ceiling = 220.0 },   -- ABSOLUTE z, not margins
--         },
--     }
--
-- COLUMNS AND ROWS ARE 1-BASED, and the origin is the CORNER of block (1,1), not
-- its centre. Both choices are arbitrary and both are load-bearing: the survey
-- captures the origin by standing on a corner, and 1-based indexing means a key
-- read out loud in chat ("I'm in seven-nine") matches what the surveyor wrote
-- down. Changing either invalidates every captured mark.
--
-- WHY THE Z MARGINS ARE PART OF THE BLOCK AND NOT A GLOBAL. Pacifica is stilted
-- and multi-level -- the Grand Imperial Mall spans several floors, West Wind
-- sits on legs. A single flat pair of margins is right for most of the sector
-- and wrong for exactly the blocks where the interesting fights happen, so
-- `map.blocks[key]` overrides them per block with ABSOLUTE heights. A block with
-- no entry uses the margins; a block with one ignores them entirely.
-- ---------------------------------------------------------------------------

Grid = {}

local floor = math.floor
local sqrt = math.sqrt
local max = math.max
local abs = math.abs
local sort = table.sort
local format = string.format

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

-- Every public entry point goes through this rather than indexing `map`
-- directly, so a map missing a field degrades to the documented default instead
-- of producing `nil` arithmetic three frames later in the damage tick. A cordon
-- that silently stopped testing containment is indistinguishable, to a player,
-- from a cordon that never closes.
-- A map whose origin carries no height is a map whose vertical extent is a
-- guess. The fallback stays -- refusing outright would break a caller mid-match
-- over a field that has never been required -- but it is now said out loud,
-- once, so the next survey knows it owes a number.
local warnedOriginZ = false
local function warnMissingOriginZ(origin)
    local z = tonumber(origin.z)
    if z ~= nil then return z end
    if not warnedOriginZ then
        warnedOriginZ = true
        local warn = (Cordon and Cordon.warn) or print
        warn("grid: the map origin has no z, so every block box is measured from zero. " ..
            "The play volume is almost certainly in the wrong place vertically. " ..
            "Set origin.z to the walkable deck in the survey.")
    end
    return 0.0
end

local function geometry(map)
    if type(map) ~= "table" then return nil end
    local origin = map.origin
    if type(origin) ~= "table" then return nil end
    local size = tonumber(map.blockMetres) or 100
    if size <= 0 then return nil end
    local cols = floor(tonumber(map.cols) or 14)
    local rows = floor(tonumber(map.rows) or 14)
    if cols < 1 or rows < 1 then return nil end
    return {
        ox = tonumber(origin.x) or 0.0,
        oy = tonumber(origin.y) or 0.0,
        -- `or 0.0` USED TO BE INDISTINGUISHABLE FROM A DECISION, and that is
        -- how Pacifica shipped with no `origin.z` at all: every block box came
        -- out at z in [-40, +120] and `centreOf` returned z = 0, seventy to
        -- ninety metres under the deck, and nothing said a word. Say a word.
        oz = warnMissingOriginZ(origin),
        size = size,
        cols = cols,
        rows = rows,
        floorMargin = tonumber(map.floorMargin) or 60.0,
        ceilingMargin = tonumber(map.ceilingMargin) or 260.0,
        blocks = type(map.blocks) == "table" and map.blocks or nil,
    }
end

-- Cells reach this file in two shapes and both are legitimate: a SET
-- (`{ ["3,7"] = true }`), which is what the cordon holds because membership is
-- the only question it ever asks, and an ARRAY (`{ "3,7", "3,8" }`), which is
-- what a closure order is because order is its whole content. Normalising here
-- rather than at every call site is what lets `closureOrder` take the cordon's
-- own set as input and hand back an array without either side converting.
--
-- The discriminator is `cells[1]`: a key is always a `"<col>,<row>"` STRING, so
-- a set can never have an entry at integer index 1.
local function toSet(cells)
    if type(cells) ~= "table" then return {} end
    if cells[1] == nil then return cells end
    local set = {}
    for i = 1, #cells do
        local k = cells[i]
        if type(k) == "string" then set[k] = true end
    end
    return set
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

-- A cell key is `"<col>,<row>"`. It is a STRING and not a packed integer
-- (`col * 1000 + row`) for one reason that outweighs the arithmetic: it survives
-- a round trip through JSON, a net event, a chat line and a log file unchanged
-- and still readable. "7,9" in a crash log is a block somebody can walk to.
function Grid.key(col, row)
    col = tonumber(col)
    row = tonumber(row)
    if not col or not row then return nil end
    return format("%d,%d", floor(col), floor(row))
end

-- The inverse. Returns `nil` rather than raising on anything malformed, because
-- keys arrive from the map store and from carried state across a hot reload --
-- both of which are places a truncated or hand-edited value can appear, and
-- neither of which should be able to take a running match down.
function Grid.parse(key)
    if type(key) ~= "string" then return nil end
    local c, r = key:match("^(-?%d+),(-?%d+)$")
    if not c then return nil end
    return tonumber(c), tonumber(r)
end

-- ---------------------------------------------------------------------------
-- Cells and boxes
-- ---------------------------------------------------------------------------

function Grid.inBounds(map, col, row)
    local g = geometry(map)
    if not g then return false end
    col, row = tonumber(col), tonumber(row)
    if not col or not row then return false end
    return col >= 1 and col <= g.cols and row >= 1 and row <= g.rows
end

-- The point-to-block test. Returns `col, row`, or `nil` when the point is
-- outside the grid entirely.
--
-- NOTE THAT Z IS NOT AN ARGUMENT. Containment in this mode is a 2D question by
-- design: a player on a roof is in the block under the roof, and a player in a
-- basement garage is in the block above them. The z extent in `boxOf` exists to
-- describe the block to the CLIENT (bounds push, tac-map, edge drawing), not to
-- decide who bleeds. Adding a z test here would bleed everybody in the mall.
--
-- The floor is deliberate rather than a round: a point exactly on the boundary
-- between two blocks belongs to the HIGHER-numbered one, consistently, on both
-- axes. Which side it falls on matters not at all; that it always falls on the
-- SAME side matters a great deal, because a player standing on a street line
-- would otherwise flicker between "inside" and "outside" at 4 Hz.
function Grid.cellOf(map, x, y)
    local g = geometry(map)
    if not g then return nil end
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return nil end
    local col = floor((x - g.ox) / g.size) + 1
    local row = floor((y - g.oy) / g.size) + 1
    if col < 1 or col > g.cols or row < 1 or row > g.rows then return nil end
    return col, row
end

-- The axis-aligned box for one block, in world coordinates:
--
--     { min = { x, y, z }, max = { x, y, z } }
--
-- This is the shape the platform's own bounds code expects, and the shape the
-- bounds push sends to clients. `nil` for a cell outside the grid.
function Grid.boxOf(map, col, row)
    local g = geometry(map)
    if not g then return nil end
    col, row = tonumber(col), tonumber(row)
    if not col or not row then return nil end
    col, row = floor(col), floor(row)
    if col < 1 or col > g.cols or row < 1 or row > g.rows then return nil end

    local minX = g.ox + (col - 1) * g.size
    local minY = g.oy + (row - 1) * g.size

    -- Per-block absolute heights win over the map's margins. See the header:
    -- the override is ABSOLUTE z, so a surveyor who captured a mall floor at
    -- z = 3 writes 3, not "57 below the origin".
    local minZ = g.oz - g.floorMargin
    local maxZ = g.oz + g.ceilingMargin
    if g.blocks then
        local over = g.blocks[format("%d,%d", col, row)]
        if type(over) == "table" then
            local f, c = tonumber(over.floor), tonumber(over.ceiling)
            if f then minZ = f end
            if c then maxZ = c end
        end
    end

    return {
        min = { x = minX,          y = minY,          z = minZ },
        max = { x = minX + g.size, y = minY + g.size, z = maxZ },
    }
end

-- The block's centre at the origin's z plane. The point a bot is sent toward,
-- the point the tac-map labels, and the anchor for the final phase's sub-block
-- square. Z is the surveyed street plane rather than the middle of the box: the
-- middle of a box that reaches 260 m up is in the sky.
function Grid.centreOf(map, col, row)
    local g = geometry(map)
    if not g then return nil end
    col, row = tonumber(col), tonumber(row)
    if not col or not row then return nil end
    col, row = floor(col), floor(row)
    if col < 1 or col > g.cols or row < 1 or row > g.rows then return nil end
    return {
        x = g.ox + (col - 0.5) * g.size,
        y = g.oy + (row - 0.5) * g.size,
        z = g.oz,
    }
end

-- Every cell on the grid, as a set. This is `fromRings = "all"` -- the opening
-- cordon, before the first closure.
function Grid.allCells(map)
    local g = geometry(map)
    local out = {}
    if not g then return out end
    for c = 1, g.cols do
        for r = 1, g.rows do
            out[format("%d,%d", c, r)] = true
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Distance
-- ---------------------------------------------------------------------------

-- CHEBYSHEV, not Euclidean, and this is the decision the whole cordon rests on.
-- A Chebyshev ball of radius n is a (2n+1) x (2n+1) SQUARE of blocks, so "the
-- cordon at rings 3" is exactly the plan's 7x7 and closing from rings 3 to rings
-- 2 removes a complete perimeter ring. A Euclidean ball would produce a ragged
-- disc whose corners close before its edges, which reads as the boundary
-- forgetting where it was -- and, worse, is not expressible as a list of whole
-- blocks anybody can draw a line along.
function Grid.chebyshev(c1, r1, c2, r2)
    return max(abs(c1 - c2), abs(r1 - r2))
end

-- Used ONLY as a tie-break inside `closureOrder`. It never decides which shape
-- the cordon is; see the note there.
function Grid.euclidean(c1, r1, c2, r2)
    local dc, dr = c1 - c2, r1 - r2
    return sqrt(dc * dc + dr * dr)
end

-- ---------------------------------------------------------------------------
-- Rings
-- ---------------------------------------------------------------------------

-- Every cell within `rings` Chebyshev steps of the final block, clipped to the
-- grid, as a set of keys.
--
-- CLIPPING IS THE INTERESTING PART. A ball centred near an edge of the sector is
-- cut by that edge, so a rings-5 cordon around a final block on the Pacifica
-- coastline is not 11x11 -- it is whatever survives the water. That asymmetry is
-- deliberate and it is why the plan's "10x10 core" and this function's rings-5
-- do not produce the same count on two different maps or two different final
-- blocks. The cordon is defined by the RULE, and the block count is a
-- consequence.
--
-- `rings < 0` is the empty set, which is the schedule's "none" sentinel: nothing
-- open, everybody outside everything. A very large `rings` is the whole grid,
-- which makes `ringsFrom(map, c, r, math.huge)` and `allCells(map)` agree.
function Grid.ringsFrom(map, finalCol, finalRow, rings)
    local g = geometry(map)
    local out = {}
    if not g then return out end
    finalCol, finalRow = tonumber(finalCol), tonumber(finalRow)
    rings = tonumber(rings)
    if not finalCol or not finalRow or not rings then return out end
    if rings < 0 then return out end
    -- Floored so a caller passing 5.0 cannot produce float loop variables and a
    -- `string.format("%d", ...)` on a non-integral number. `math.huge` floors to
    -- itself, which is the "whole grid" case and still behaves.
    rings = floor(rings)
    finalCol, finalRow = floor(finalCol), floor(finalRow)

    -- Walk only the window the ball can reach rather than the whole grid: at
    -- rings 0 this touches one cell instead of 196, which matters because the
    -- schedule re-derives target sets on every closure.
    local loCol = max(1, finalCol - rings)
    local hiCol = g.cols
    if finalCol + rings < hiCol then hiCol = finalCol + rings end
    local loRow = max(1, finalRow - rings)
    local hiRow = g.rows
    if finalRow + rings < hiRow then hiRow = finalRow + rings end

    for c = loCol, hiCol do
        for r = loRow, hiRow do
            out[format("%d,%d", c, r)] = true
        end
    end
    return out
end

-- Membership. Takes either shape (set or array) so a caller can ask the same
-- question of the live cordon and of a closure list.
--
-- Against a SET this is one hash lookup, which is what the 4 Hz containment tick
-- needs. Against an ARRAY it rebuilds a set every call, so it is O(n) -- fine
-- for a one-off check, wrong inside a loop over 64 players. Hold the cordon as a
-- set; that is what it is.
function Grid.contains(cells, col, row)
    local key = Grid.key(col, row)
    if not key then return false end
    local value = toSet(cells)[key]
    -- `~= nil and ~= false` rather than a plain truth test, so a set that stores
    -- something other than `true` (a close timestamp, say, which is exactly what
    -- the precomputed schedule holds) still counts as present.
    return value ~= nil and value ~= false
end

-- ---------------------------------------------------------------------------
-- Closure order
-- ---------------------------------------------------------------------------

-- The cells to close during one phase, ORDERED FARTHEST FROM THE FINAL BLOCK
-- FIRST: `openCells` minus `targetCells`, sorted.
--
-- The caller spaces these evenly across `closeOverSeconds`, so this list IS the
-- animation: the edge marches inward one block at a time instead of a whole ring
-- vanishing at once. That is the entire reason the function returns an array and
-- not a set.
--
-- DETERMINISM IS A REQUIREMENT, NOT A NICETY, and it has two teeth. The closure
-- schedule is precomputed once at match start and then compared against the
-- clock on every tick; if two runs of this function over the same input could
-- disagree, the precomputed list and any later recomputation (a hot reload
-- rebuilding from carried state, say) would drift, and blocks would close twice
-- or never. So the comparator is a TOTAL order with no ties left over:
--
--   1. Chebyshev distance, descending -- the rule the cordon is defined by.
--   2. Euclidean distance, descending -- within one Chebyshev ring, corners are
--      farther from the final block than edge midpoints, so a corner closes
--      first. Without this the ring would close in whatever order `pairs`
--      happened to yield, which in Lua is not stable across runs.
--   3. The key's two numbers, column then row, ascending -- the last resort, and
--      it fires often: four corners of a ring are exactly equidistant by both
--      measures. Compared NUMERICALLY rather than as strings; a raw string
--      compare is equally deterministic but orders block 10 before block 2,
--      which makes a closure log unreadable by the person who most needs to read
--      it.
--
-- The comparator must also never report `a < b` AND `b < a`, or Lua 5.4's
-- `table.sort` raises "invalid order function for sorting" -- which is why every
-- level falls through to the next on equality rather than returning a guess.
function Grid.closureOrder(map, openCells, targetCells, finalCol, finalRow)
    local g = geometry(map)
    local order = {}
    if not g then return order end
    finalCol, finalRow = tonumber(finalCol), tonumber(finalRow)
    if not finalCol or not finalRow then return order end
    finalCol, finalRow = floor(finalCol), floor(finalRow)

    local open = toSet(openCells)
    local target = toSet(targetCells)

    -- Distances are computed once per cell here rather than inside the
    -- comparator. `table.sort` calls the comparator O(n log n) times, so a
    -- square root per comparison on 196 cells is ~1500 square roots for a list
    -- that has at most 196 distinct values.
    local pending = {}
    local n = 0
    for key, alive in pairs(open) do
        if alive and not target[key] then
            local c, r = Grid.parse(key)
            -- A key the grid cannot place is dropped rather than closed. It can
            -- only come from a corrupt store or a stale carried-state bag, and
            -- closing a block that does not exist would leave the cordon's block
            -- count permanently wrong.
            if c and r and c >= 1 and c <= g.cols and r >= 1 and r <= g.rows then
                n = n + 1
                pending[n] = {
                    key = key,
                    col = c,
                    row = r,
                    cheb = max(abs(c - finalCol), abs(r - finalRow)),
                    eucl = (c - finalCol) * (c - finalCol) + (r - finalRow) * (r - finalRow),
                }
            end
        end
    end

    sort(pending, function(a, b)
        if a.cheb ~= b.cheb then return a.cheb > b.cheb end
        -- Squared Euclidean: monotonic in the real distance, so it orders
        -- identically and costs no square root.
        if a.eucl ~= b.eucl then return a.eucl > b.eucl end
        if a.col ~= b.col then return a.col < b.col end
        return a.row < b.row
    end)

    for i = 1, n do order[i] = pending[i].key end
    return order
end

-- ---------------------------------------------------------------------------
-- SUBDIVISION -- the cordon lattice
--
-- WHY THIS EXISTS, and it is the whole reason the closure was redesigned on
-- 2026-09-02.
--
-- The block grid is sized by the SURVEY: it is as coarse as the ground somebody
-- actually walked. Watson, the map the mode is playable on today, is 2x2 -- four
-- 100 m cells. A cordon that closes whole cells has, on that map, exactly three
-- closures available to it, each removing a quarter of a 200 m district. That is
-- not a shrinking zone; it is a guillotine -- and the schedule written above it
-- was worse than that: every ring count above 1 is the WHOLE 2x2 grid once
-- `ringsFrom` clips it, so the first four phases closed nothing at all and the
-- map went from four cells to one in a single window, thirteen minutes in.
--
-- The fix is not a second geometry. It is the SAME geometry at a finer pitch: a
-- LATTICE is the survey grid with every block split `factor` ways on each axis,
-- so a 2x2 of 100 m blocks becomes an 8x8 of 25 m cells. Every downstream
-- consumer -- containment, the tac-map, the in-world edge -- reads the grid
-- origin, cols, rows and block size off the message the server sends it, so
-- publishing the lattice AS the grid makes all three agree by construction and
-- needs no client change at all. The cordon then closes twenty-five metre cells
-- six or seven rings deep, which is a shrinking zone.
--
-- THE MAP IS STILL AUTHORED IN BLOCKS. Loot marks, landing zones, the final-block
-- whitelist and the per-block heights are all keyed by the surveyed cell, so the
-- expansion helpers below are the one seam where a block key becomes lattice
-- keys. Nothing in the survey is re-authored, and `factor = 1` reproduces the
-- old behaviour exactly -- which is what a 14x14 map gets, because it already
-- has rings enough.
-- ---------------------------------------------------------------------------

-- How many times each block is split, on each axis.
--
-- The rule is "enough rings to make a schedule out of, and no finer than the
-- wire and the fight can stand", so three caps bound it:
--
--   minCellsPerSide  the shortest side of the lattice, in cells. Eight gives at
--                    least four Chebyshev rings around a central final cell and
--                    seven around a corner one, which is the point at which the
--                    closure reads as a zone converging rather than as a wall
--                    falling.
--   minCellMetres    the smallest final zone the mode is willing to produce. A
--                    zone below about twenty metres is a corridor, not an arena,
--                    and the last fight stops being a fight.
--   maxCells         the wire. The open-cell list is published as an array of
--                    "col,row" strings on every closure; a net event caps at
--                    48 KiB, and 1024 keys is roughly 8 KB, which leaves the
--                    payload an order of magnitude of headroom.
--
-- The SMALLEST factor that satisfies `minCellsPerSide` wins -- never the largest
-- the caps allow -- because a finer lattice costs wire on every closure and buys
-- nothing once there are rings enough.
function Grid.subdivisionFor(map, options)
    local g = geometry(map)
    if not g then return 1 end
    options = type(options) == "table" and options or {}
    if options.enabled == false then return 1 end

    local minSide = floor(tonumber(options.minCellsPerSide) or 8)
    local minMetres = tonumber(options.minCellMetres) or 20.0
    local maxCells = floor(tonumber(options.maxCells) or 1024)
    if minSide < 1 then minSide = 1 end

    local shortest = g.cols < g.rows and g.cols or g.rows
    local factor = 1
    while shortest * factor < minSide do
        local step = factor + 1
        if minMetres > 0 and (g.size / step) < minMetres then break end
        if (g.cols * step) * (g.rows * step) > maxCells then break end
        factor = step
    end
    return factor
end

-- Every key in a per-cell table, restated for the lattice. The VALUE is shared,
-- not copied: a block ground height is the height of every cell inside it, which
-- is the honest reading of a survey that measured the block and not the cell.
function Grid.expandCellTable(cells, factor)
    if type(cells) ~= "table" then return nil end
    factor = floor(tonumber(factor) or 1)
    if factor <= 1 then return cells end
    local out = {}
    for key, value in pairs(cells) do
        local c, r = Grid.parse(key)
        if c and r then
            for i = 1, factor do
                for j = 1, factor do
                    out[format("%d,%d", (c - 1) * factor + i, (r - 1) * factor + j)] = value
                end
            end
        end
    end
    return out
end

-- The same, for a LIST of keys (`excluded`, `finalBlocks`). Returns an array so
-- the caller keeps using `ipairs`.
function Grid.expandKeys(keys, factor)
    local out = {}
    if type(keys) ~= "table" then return out end
    factor = floor(tonumber(factor) or 1)
    if factor < 1 then factor = 1 end
    for _, key in ipairs(keys) do
        local c, r = Grid.parse(key)
        if c and r then
            for i = 1, factor do
                for j = 1, factor do
                    out[#out + 1] = format("%d,%d", (c - 1) * factor + i, (r - 1) * factor + j)
                end
            end
        end
    end
    return out
end

-- The lattice itself: the same origin and the same z rules, at a finer pitch.
--
-- ALWAYS A COPY, even at factor 1, and that is deliberate. Every consumer reads
-- `grid.subdivide` to convert a lattice cell back to a surveyed block; a caller
-- handed the original table at factor 1 would have to test for the field being
-- absent, and the one that forgot would be off by a factor of four on a map
-- where it mattered and exactly right on the map it was tested against.
--
-- The copy is SHALLOW: `origin` is shared by reference, which is safe because
-- nothing in this file or in the cordon ever mutates a map origin.
function Grid.subdivide(map, factor)
    if type(map) ~= "table" then return nil end
    factor = floor(tonumber(factor) or 1)
    if factor < 1 then factor = 1 end
    local g = geometry(map)

    local out = {}
    for key, value in pairs(map) do out[key] = value end
    out.subdivide = factor
    if g then
        -- The surveyed shape, kept alongside so a consumer can say "cell 6,7 of
        -- the lattice is block 2,2 of the survey" without a second table.
        out.blockCols = g.cols
        out.blockRows = g.rows
        out.blockSizeMetres = g.size
        out.blockMetres = g.size / factor
        out.cols = g.cols * factor
        out.rows = g.rows * factor
    end
    if factor > 1 then
        out.blocks = Grid.expandCellTable(map.blocks, factor)
        out.ground = Grid.expandCellTable(map.ground, factor)
    end
    return out
end

-- A lattice cell, back to the surveyed block that contains it.
function Grid.coarseKey(col, row, factor)
    col, row = tonumber(col), tonumber(row)
    factor = floor(tonumber(factor) or 1)
    if not col or not row or factor < 1 then return nil end
    return format("%d,%d", floor((col - 1) / factor) + 1, floor((row - 1) / factor) + 1)
end

-- The lattice cell at the middle of a surveyed block.
--
-- THE FINAL ZONE IS CHOSEN FROM HERE, and the reason is the one that made
-- `finalBlocks` a whitelist in the first place: the survey vouches for the
-- BLOCK, so a lattice cell in the middle of it is ground somebody walked, while
-- a corner cell is a coin flip on a wall, a roof edge or the water. At factor 1
-- this returns the block itself, which is what it should.
function Grid.blockCentreCell(col, row, factor)
    col, row = tonumber(col), tonumber(row)
    factor = floor(tonumber(factor) or 1)
    if not col or not row or factor < 1 then return nil end
    local offset = floor((factor + 1) / 2)
    return (col - 1) * factor + offset, (row - 1) * factor + offset
end

-- The Chebyshev radius that still contains every one of `cells`.
--
-- This is the cordon STARTING radius, and it is measured against the open set
-- rather than against the grid corners on purpose: a map with excluded cells
-- (water, a highway) has an open set smaller than its grid, and a schedule that
-- began at the grid radius would spend its first closures removing cells that
-- were never open -- phases that visibly do nothing, which is exactly the
-- failure the lattice exists to end.
function Grid.spanOf(cells, finalCol, finalRow)
    local set = toSet(cells)
    finalCol = floor(tonumber(finalCol) or 1)
    finalRow = floor(tonumber(finalRow) or 1)
    local best = 0
    for key, alive in pairs(set) do
        if alive ~= nil and alive ~= false then
            local c, r = Grid.parse(key)
            if c and r then
                local d = max(abs(c - finalCol), abs(r - finalRow))
                if d > best then best = d end
            end
        end
    end
    return best
end

-- Continuous cordon geometry. A rectangle is always intersected with the
-- original allowed-cell mask; interpolation can never reopen an excluded cell.
function Grid.ringRect(map, col, row, rings)
    local g = geometry(map)
    if not g then return nil end
    local radius = math.max(0, tonumber(rings) or 0)
    return { minX = g.ox + (col - 1 - radius) * g.size,
        minY = g.oy + (row - 1 - radius) * g.size,
        maxX = g.ox + (col + radius) * g.size,
        maxY = g.oy + (row + radius) * g.size }
end

-- `startsInMs` is relative to receipt/publication; elapsedMs is measured on
-- the caller's monotonic clock. Terminal closure preserves the last refuge
-- throughout its final hold and removes it exactly at the interval end.
function Grid.sweepRect(sweep, elapsedMs)
    if type(sweep) ~= "table" or type(sweep.from) ~= "table" then return nil end
    local t = math.max(0, math.min(1, ((elapsedMs or 0) - (sweep.startsInMs or 0))
        / math.max(1, sweep.durationMs or 1)))
    if sweep.terminal and t >= 1 then return nil end
    local a, b = sweep.from, sweep.to or sweep.from
    if sweep.terminal then b = a end
    return { minX = a.minX + (b.minX - a.minX) * t,
        minY = a.minY + (b.minY - a.minY) * t,
        maxX = a.maxX + (b.maxX - a.maxX) * t,
        maxY = a.maxY + (b.maxY - a.maxY) * t }
end

function Grid.clipBox(map, col, row, rect)
    if rect == nil then return nil end
    local box = Grid.boxOf(map, col, row)
    if box == nil then return nil end
    local out = { minX = math.max(box.min.x, rect.minX), minY = math.max(box.min.y, rect.minY),
        maxX = math.min(box.max.x, rect.maxX), maxY = math.min(box.max.y, rect.maxY) }
    if out.minX >= out.maxX or out.minY >= out.maxY then return nil end
    return out
end

-- Fraction at which a shrinking rectangle has completely left a cell.
function Grid.sweepExitFraction(map, col, row, from, to)
    local box = Grid.boxOf(map, col, row)
    if not box then return 0 end
    local t = 1
    if to.minX > from.minX then t = math.min(t, (box.max.x - from.minX) / (to.minX - from.minX)) end
    if to.minY > from.minY then t = math.min(t, (box.max.y - from.minY) / (to.minY - from.minY)) end
    if to.maxX < from.maxX then t = math.min(t, (from.maxX - box.min.x) / (from.maxX - to.maxX)) end
    if to.maxY < from.maxY then t = math.min(t, (from.maxY - box.min.y) / (from.maxY - to.maxY)) end
    return math.max(0, math.min(1, t))
end

function Grid.sweepContains(map, allowed, rect, x, y)
    if rect == nil or x < rect.minX or x >= rect.maxX or y < rect.minY or y >= rect.maxY then return false end
    local col, row = Grid.cellOf(map, x, y)
    return col ~= nil and allowed[Grid.key(col, row)] == true
end

-- External union edges only. A single common clipping rectangle means adjacent
-- surviving cells have identical shared intervals, so each internal side can
-- be omitted completely. Optional cell bounds restrict client scanning without
-- turning the scan window itself into a false boundary. `visit` avoids a large
-- allocation and can yield between cells in the client's bounded coroutine.
function Grid.sweepSegments(map, allowed, rect, visit, bounds)
    local g = geometry(map)
    local segments = {}
    if not g or not rect then return segments end
    local loC, hiC = bounds and bounds.loCol or 1, bounds and bounds.hiCol or g.cols
    local loR, hiR = bounds and bounds.loRow or 1, bounds and bounds.hiRow or g.rows
    local function emit(c, r, side, ax, ay, bx, by, nx, ny)
        local segment = { col = c, row = r, side = side, ax = ax, ay = ay, bx = bx, by = by, nx = nx, ny = ny }
        if visit then visit(segment) else segments[#segments + 1] = segment end
    end
    local function neighbour(c,r)
        return allowed[Grid.key(c,r)] == true and Grid.clipBox(map,c,r,rect) or nil
    end
    for c = math.max(1,loC), math.min(g.cols,hiC) do
        for r = math.max(1,loR), math.min(g.rows,hiR) do
            if allowed[Grid.key(c,r)] == true then
                local b = Grid.clipBox(map,c,r,rect)
                if b then
                    if not neighbour(c-1,r) then emit(c,r,"west",b.minX,b.minY,b.minX,b.maxY,-1,0) end
                    if not neighbour(c+1,r) then emit(c,r,"east",b.maxX,b.minY,b.maxX,b.maxY,1,0) end
                    if not neighbour(c,r-1) then emit(c,r,"south",b.minX,b.minY,b.maxX,b.minY,0,-1) end
                    if not neighbour(c,r+1) then emit(c,r,"north",b.minX,b.maxY,b.maxX,b.maxY,0,1) end
                end
            end
        end
    end
    return segments
end
