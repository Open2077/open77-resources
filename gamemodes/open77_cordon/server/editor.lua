-- Cordon: THE IN-WORLD MAP EDITOR.
--
-- The bottleneck this file exists to remove, in the owner's words (2026-09-03):
-- "faut que tu prepare des commandes comme sur le mode pvp pour que je puisse
-- set a la main les spawns de loot et les spawns de joueurs / voiture (en gros
-- un editeur du mode parce que sinon tu spawn un peu randomly et ca fonctionne
-- pas hyper bien)".
--
-- Until now the only way to get a coordinate into this mode was to walk it,
-- read it out of `/br.where`, and hand-edit `shared/watson.lua` -- which is a
-- file under `resources/`, so every save hot-swapped the whole resource set and
-- emptied a live match. Nine loot clusters and twelve landing zones went
-- through that loop and it blocked the loot pass for a day.
--
-- `/br.map` closes it: walk somewhere, capture, and the very next match uses it.
--
-- ===========================================================================
-- WHY THE HAND-PLACED POINTS DO NOT REPLACE THE PROCEDURAL SEEDING
-- ===========================================================================
--
-- Because there is nothing to replace. `L.seed` already reads a LIST OF
-- ANCHORS, each with a `count` and a `radius`, and scatters `count` drops
-- inside `radius` of the anchor. A hand-placed loot point is that same shape
-- with `radius = 0` and `count = 1` -- the degenerate case, not a second code
-- path. So the editor FEEDS the seeder rather than bypassing it, and the
-- operator chooses the granularity per point:
--
--   * `add loot rare 1 0`   -- exactly one rare crate, here, on this pavement;
--   * `add loot street 12 18` -- the old cluster behaviour, a neighbourhood.
--
-- Two code paths would have meant two ways for the district to be empty, two
-- places for the density tunable to apply, and a flag somebody has to remember
-- to set. There is one list, and `lootDensity` still scales all of it.
--
-- The same argument holds for landing zones, the staging anchor, landmarks and
-- supply points: the editor writes THE SAME TABLES the mode already reads, so
-- nothing downstream had to change and nothing downstream can disagree with it.
--
-- ===========================================================================
-- WHERE THE STORE LIVES, AND WHY THERE
-- ===========================================================================
--
-- THE CONSTRAINT THAT DECIDES EVERYTHING: the dev server watches `resources/`
-- and reloads a resource whose scripts changed, which despawns bots, resets the
-- roster and drops a live match. So the store MUST NOT be a file the resource
-- set can see. This file follows `open77_deathmatch/server/mapstore.lua`
-- exactly, because it already paid for the reasoning:
--
--   1. `Open77.tunables` holds ONE value -- `activeMap`, the NAME of the map
--      this server plays. It is a <=32-character string, it is a per-server
--      SETTING rather than runtime state, and it persists to `tunables.json`
--      beside `server.jsonc`, outside the watched tree. The key is already
--      declared in shared/config.lua; this file only ever writes it.
--
--   2. `Open77.state` is the HOT-RELOAD BRIDGE and is used COOPERATIVELY. The
--      bag is one 64 KiB JSON string for the WHOLE resource and
--      `server/kernel.lua` (roster) and `server/ranked.lua` (pending career
--      writes) already write it, so this read-modify-writes under its own key
--      and preserves theirs. A writer that built its payload from scratch would
--      silently delete a match's worth of careers. It is NOT durable: a stop or
--      a restart drops it, by design.
--
--   3. `Open77.database` is the only durable store server Lua has, and this
--      uses ranked.lua's pattern verbatim -- same permission (`database.access`,
--      already declared), same serialised single-coroutine worker, same
--      tri-state probe, same rule that a MISSING BRIDGE IS A SUPPORTED STATE.
--
--   4. `Open77.io` writes one JSON file per map under the resource's own
--      `data/maps/`. Its own section below carries the evidence for why writing
--      there does not violate the standing rule against runtime writes under
--      `resources/` -- in short, the reload digest provably cannot see it, the
--      client package provably cannot carry it, and `resources/gamemodes/race` has done
--      exactly this for its course editor all along.
--
-- AND THE PART THAT MATTERS ON THIS DEV BOX, which is why tier 4 exists at all:
-- `server/server.cordon-local.jsonc` ships `"database": { "enabled": false }`.
-- With only tiers 1-3 the store here would be MEMORY plus the reload bridge --
-- surviving every hot reload, which is the failure that happens twenty times an
-- hour while three people edit this resource, and dying on the next server
-- restart. The owner intends to walk the real PRODUCTION spawns with this tool,
-- and losing that to a restart would be silent: the next match would simply
-- place everybody back on the procedural defaults. Tier 4 is what stops that.
--
-- When a tier is down the readouts say so in capitals, every time, and
-- `/br.map export` remains the escape hatch: it prints the active map as
-- pasteable Lua so a finished map is promoted into `shared/<name>.lua`, becomes
-- a built-in under source control, and stops depending on any store at all. A
-- volatile store that looked durable would be worse than no store.
--
-- THE PRECEDENCE AT LOAD IS BAG > FILES > DATABASE, and it is not arbitrary.
-- The bag is this VM's predecessor's memory, so it is the most recent thing
-- that exists. Files are this server's own disk. The database may be SHARED
-- with another server, and a row written elsewhere silently replacing a local
-- edit is the surprise nobody would think to debug. Each tier only fills the
-- gaps the previous one left; `/br.map reload [files|db]` is the explicit
-- override that replaces unconditionally.
--
-- Note that `updatedMs` is `K.nowMs()`, which is PROCESS-MONOTONIC and resets
-- to zero on a restart. It is therefore comparable only WITHIN one process, and
-- nothing here compares it across tiers -- an earlier draft did, and after a
-- restart that would have made every stored map look newer than every edit made
-- since.
--
-- ===========================================================================
-- WHY THIS FILE LOADS AFTER server/main.lua
-- ===========================================================================
--
-- main.lua's header says it is last "deliberately", and the reason it gives is
-- that everything in it wires parts earlier files defined. That reason applies
-- to this file MORE strongly, not less: it reads `K.map`, `K.recomputeSurveyed`,
-- `K.publishSurvey`, `K.builtinMaps`, `M.phase` and `C.publish`, every one of
-- which main.lua declares. Loading before it would leave the store unable to
-- apply anything.
--
-- Nothing here registers a handler main.lua then calls, so the ordering rule
-- main.lua protects is not weakened. The one interaction is main.lua's tick
-- thread, which calls `K.publishSurvey()` once at startup: this file applies its
-- map SYNCHRONOUSLY at load and publishes the survey itself, so whichever of the
-- two runs first, the clients get the map that is actually active.
--
-- ===========================================================================
-- WHAT A COMMAND MAY AND MAY NOT CARRY
-- ===========================================================================
--
-- COORDINATES ARE NEVER ACCEPTED FROM A CLIENT PAYLOAD. It is the same rule
-- `open77_deathmatch/server/survey.lua` and `race/server/courses.lua` state in
-- their own headers. A command carries a kind, an index, a tier and at most a
-- heading; never a place. Every position in this file comes from
-- `Open77.players.position` through `K.position`, read on the server.
--
-- Heading defaults to the same fresh authoritative snapshot as the position.
-- An explicit heading (including zero) overrides the captured body orientation.
--
-- ===========================================================================
-- ACL
-- ===========================================================================
--
-- ONE `RegisterCommand`, restricted, exactly as `open77_admin` does it: there is
-- no argument for "unrestricted" and no code path here that reaches
-- `RegisterCommand` without `true`. An editor any player could call is a
-- griefing tool -- `select` alone would let a stranger swap the map out from
-- under a live match. The permission is `command.br.map`.

local K = Cordon
local M = K.match
local C = K.cordon


-- ------------------------------------------------------------------ config --
--
-- Declared HERE, not in shared/config.lua, and read through `setting()` so a
-- `Config.editor` block pasted in later wins without a line changing here.

local DEFAULTS = {
    tablePrefix       = nil,     -- falls back to Config.career.tablePrefix, then open77_br_
    minimumSeparation = 2.0,     -- metres between two points of the same kind
    maxMaps           = 24,
    carryBudgetBytes  = 16 * 1024,
    paintEveryMetres  = 6.0,     -- a spawn every six metres of walking
    paintPollMs       = 250,
    paintMaxPoints    = 128,
    spreadRadius      = 8.0,     -- a POD, not a scatter -- see `spread` below
    spawnVehicles     = true,    -- spawn hand-placed vehicles when a match goes live
    -- Relative to the resource's own `data/` directory, which is the only place
    -- `Open77.io` can reach. See the file-store section.
    mapDirectory      = "maps",
}

local function editorBlock()
    return type(Config) == "table" and type(Config.editor) == "table" and Config.editor or nil
end

local function setting(key)
    local block = editorBlock()
    if block ~= nil and block[key] ~= nil then return block[key] end
    return DEFAULTS[key]
end

local function number(key)
    return tonumber(setting(key)) or tonumber(DEFAULTS[key]) or 0
end

local function log(text)
    K.log("editor: " .. tostring(text))
end

local function warn(text)
    K.warn("editor: " .. tostring(text))
end


-- ----------------------------------------------------------------- helpers --

local function finite(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function normalizeHeading(value)
    local heading = finite(value)
    if heading == nil then return nil end
    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    return heading
end

-- Names reach SQL, JSON and generated Lua source (the export). Whitelisted at
-- the door so none of the three has to defend itself.
local function cleanName(value, maximum)
    local name = tostring(value or ""):lower()
    if name == "" or #name > (maximum or 32) then return nil end
    if name:match("^[a-z0-9][a-z0-9_%-]*$") == nil then return nil end
    return name
end

local function cleanLabel(value, maximum)
    local label = tostring(value or ""):gsub("%c", " "):gsub("%s+", " ")
    label = label:gsub("^%s+", ""):gsub("%s+$", "")
    if #label == 0 then return nil end
    local limit = maximum or 48
    if #label > limit then label = label:sub(1, limit) end
    return label
end

local function copyPoint(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = finite(value.x), finite(value.y), finite(value.z)
    if x == nil or y == nil or z == nil then return nil end
    -- A coordinate this far out is a corrupted payload, not a place: Night City
    -- fits inside a few thousand metres of the origin on every axis.
    if math.abs(x) > 100000.0 or math.abs(y) > 100000.0 or math.abs(z) > 100000.0 then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function distance2D(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function distance3D(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function argAt(args, index)
    if type(args) ~= "table" then return nil end
    local value = args[index]
    if value == nil then return nil end
    value = tostring(value)
    if value == "" then return nil end
    return value
end

--- Everything from `index` onwards, joined. Labels are typed with spaces.
local function argRest(args, index)
    if type(args) ~= "table" then return nil end
    local parts = {}
    local count = tonumber(args.n) or #args
    for position = index, count do
        local value = args[position]
        if value ~= nil then parts[#parts + 1] = tostring(value) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

local function truthy(value)
    local text = tostring(value or ""):lower()
    return text == "1" or text == "true" or text == "yes" or text == "on" or text == "hot"
end

local function globalTable(name)
    local ok, value = pcall(function() return _ENV[name] end)
    if not ok or type(value) ~= "table" then return nil end
    return value
end


-- ------------------------------------------------------------- loot tiers --
--
-- Rarity is `tier`, and it is an INDEX into `Config.loot.tiers` because that is
-- what `L.seed` already reads (`tiers[cluster.tier]`). The editor accepts the
-- KEY as well -- `street`, `rare`, `epic`, `legendary` -- because that is what a
-- person says and what `/br.loot.here` already takes, and resolves it to the
-- index at the door so nothing downstream has to know two spellings.

local function tierList()
    local block = type(Config) == "table" and Config.loot or nil
    return (type(block) == "table" and type(block.tiers) == "table") and block.tiers or {}
end

local function tierKeys()
    local keys = {}
    for index, tier in ipairs(tierList()) do
        keys[#keys + 1] = ("%d=%s"):format(index, tostring(tier.key))
    end
    return #keys > 0 and table.concat(keys, " ") or "none configured"
end

--- Resolve a tier token to an index, or nil.
local function resolveTier(token)
    local tiers = tierList()
    if #tiers == 0 then return nil end
    local index = math.floor(tonumber(token) or 0)
    if index >= 1 and index <= #tiers then return index end
    local wanted = tostring(token or ""):lower()
    for position, tier in ipairs(tiers) do
        if tostring(tier.key):lower() == wanted then return position end
    end
    return nil
end

local function tierName(index)
    local tiers = tierList()
    local tier = tiers[math.floor(tonumber(index) or 0)]
    return tier ~= nil and tostring(tier.key) or ("?" .. tostring(index))
end


-- ============================================================== THE SHAPE ==
--
-- ONE declaration of what a point kind is, and every verb reads it: `add`,
-- `move`, `del`, `points`, `set`, `near`, `count`, `paint`, `spread`, `check`
-- and `export` all iterate this table and nothing else. That is what makes the
-- admin UI a SECOND FRONT END rather than a rewrite -- it renders this schema
-- (kind, label, option name, type, bounds, default) as a form and calls the
-- same `Editor.*` functions the commands call.
--
-- `field` is the name of the list ON THE MAP RECORD, and it is the name the
-- rest of the mode already reads. That is the whole integration: there is no
-- translation layer, because the editor's record IS `K.map`.
--
-- `live` says whether anything consumes the list TODAY. It is printed by
-- `check` and by `count`, because an operator who spends an hour placing
-- vehicles deserves to be told, at the time, that nothing spawns them yet.

local OPT_TIER = { name = "tier", kind = "tier", default = 1 }

local KINDS = {
    {
        key = "spawn", field = "spawns", label = "player spawn", prefix = "sp",
        aliases = { "spawns", "player", "players", "ground" },
        cap = 96, separation = 2.0, live = true,
        liveNote = "used for per-player ground placement when the grav-chute is disabled; chute deployment uses landing zones",
        options = {
            { name = "heading", kind = "heading", default = 0.0, lenient = true },
            { name = "label", kind = "text", default = nil },
        },
    },
    {
        key = "land", field = "landings", label = "landing zone", prefix = "lz",
        aliases = { "landing", "landings", "lz", "drop" },
        cap = 48, separation = 20.0, live = true,
        options = {
            -- `hot` before `label` because the label is greedy and must be last;
            -- `lenient` so `add land Market Centre` reads as a label rather than
            -- eating the first word as a flag. See `readOptions`.
            { name = "hot", kind = "bool", default = false, lenient = true },
            { name = "label", kind = "text", default = nil },
        },
    },
    {
        key = "loot", field = "lootClusters", label = "loot point", prefix = "lp",
        aliases = { "loots", "crate", "crates", "cluster", "clusters" },
        cap = 400, separation = 1.5, live = true,
        options = {
            OPT_TIER,
            { name = "count", kind = "int", default = 1, min = 1, max = 40 },
            -- ZERO IS THE DEFAULT AND IT IS THE POINT. A hand-placed point is
            -- one crate where the operator is standing. `L.seed` caps the
            -- scatter at `loot.maxScatterMetres` anyway, because every drop in a
            -- cluster inherits the ANCHOR'S z and the ground does not stay flat.
            { name = "radius", kind = "number", default = 0.0, min = 0.0, max = 40.0 },
        },
    },
    {
        key = "veh", field = "vehicles", label = "vehicle spawn", prefix = "vh",
        aliases = { "vehicle", "vehicles", "car", "cars" },
        cap = 64, separation = 6.0, live = true,
        liveNote = "spawned by this file at `live`; set editor.spawnVehicles=false to stop",
        options = {
            { name = "record", kind = "text", default = nil },
            { name = "heading", kind = "heading", default = 0.0, lenient = true },
        },
    },
    {
        key = "mark", field = "landmarks", label = "landmark", prefix = "lm",
        aliases = { "landmark", "landmarks", "poi" },
        cap = 32, separation = 25.0, live = true,
        options = {
            { name = "label", kind = "text", default = nil },
        },
    },
    {
        key = "supply", field = "supply", label = "supply point", prefix = "sd",
        aliases = { "supplies", "drop" },
        cap = 24, separation = 40.0, live = true,
        options = {
            { name = "label", kind = "text", default = nil },
        },
    },
    {
        key = "hold", field = "holdouts", label = "gang holdout", prefix = "ho",
        aliases = { "holdout", "holdouts", "gang" },
        cap = 32, separation = 40.0, live = false,
        liveNote = "no holdout spawner exists yet",
        options = {
            { name = "label", kind = "text", default = nil },
        },
    },
    {
        key = "exit", field = "extractions", label = "extraction point", prefix = "ex",
        aliases = { "extract", "extraction", "extractions", "exfil" },
        cap = 16, separation = 40.0, live = false,
        liveNote = "no extraction placer exists yet",
        options = {
            { name = "label", kind = "text", default = nil },
        },
    },
    {
        key = "stage", field = "staging", label = "staging anchor", prefix = "st",
        aliases = { "staging", "lobby" },
        singleton = true, live = true,
        options = {
            { name = "heading", kind = "heading", default = 0.0, lenient = true },
            { name = "radius", kind = "number", default = 12.0, min = 2.0, max = 80.0 },
        },
    },
}

local function kindKeys()
    local keys = {}
    for index, entry in ipairs(KINDS) do keys[index] = entry.key end
    return table.concat(keys, " ")
end

local function findKind(token)
    local wanted = tostring(token or ""):lower()
    if wanted == "" then return nil end
    for _, entry in ipairs(KINDS) do
        if entry.key == wanted then return entry end
        for _, alias in ipairs(entry.aliases or {}) do
            if alias == wanted then return entry end
        end
    end
    return nil
end

local function findOption(entry, name)
    local wanted = tostring(name or ""):lower()
    for _, option in ipairs(entry.options or {}) do
        if option.name == wanted then return option end
    end
    return nil
end

local function optionNames(entry)
    local names = {}
    for index, option in ipairs(entry.options or {}) do
        names[index] = ("%s:%s"):format(option.name, option.kind)
    end
    return #names > 0 and table.concat(names, " ") or "none"
end

--- Coerce one option token. Returns value, error. A nil value with a nil error
--- means "not supplied", which is not the same as "invalid" and must not be.
local function coerceOption(option, token)
    if token == nil then return nil, nil end
    if option.kind == "text" then
        local label = cleanLabel(token)
        if label == nil then return nil, "empty text" end
        return label
    elseif option.kind == "bool" then
        local text = tostring(token):lower()
        if text == "1" or text == "true" or text == "yes" or text == "on" or text == "hot" then
            return true
        end
        if text == "0" or text == "false" or text == "no" or text == "off" or text == "cold" then
            return false
        end
        return nil, "expected 1/0, true/false, yes/no, on/off"
    elseif option.kind == "heading" then
        local heading = normalizeHeading(token)
        if heading == nil then return nil, "not a heading" end
        return heading
    elseif option.kind == "tier" then
        local tier = resolveTier(token)
        if tier == nil then return nil, "unknown tier; have " .. tierKeys() end
        return tier
    elseif option.kind == "int" or option.kind == "number" then
        local value = finite(token)
        if value == nil then return nil, "not a number" end
        if option.kind == "int" then value = math.floor(value) end
        if option.min ~= nil and value < option.min then return nil, ("below %s"):format(option.min) end
        if option.max ~= nil and value > option.max then return nil, ("above %s"):format(option.max) end
        return value
    end
    return nil, "unknown option type"
end

--- The stored value of one option on one point, or its default.
local function optionValue(entry, point, option)
    local value = point[option.name]
    if value ~= nil then return value end
    return option.default
end

--- One point rendered as `name=value` pairs, for a listing.
local function describeOptions(entry, point)
    local parts = {}
    for _, option in ipairs(entry.options or {}) do
        local value = optionValue(entry, point, option)
        if option.name == "tier" and value ~= nil then
            parts[#parts + 1] = ("tier=%s"):format(tierName(value))
        elseif value ~= nil and value ~= "" then
            parts[#parts + 1] = ("%s=%s"):format(option.name, tostring(value))
        end
    end
    if point.headingKnown == false and findOption(entry, "heading") ~= nil then
        parts[#parts + 1] = "(heading not captured)"
    end
    return #parts > 0 and (" " .. table.concat(parts, " ")) or ""
end


-- ========================================================== MAP RECORDS ==
--
-- The record IS `K.map`. Every field below is a field the rest of the mode
-- already reads, spelled the way it already spells it, which is why applying a
-- map is one assignment and why no consumer had to change.

local PROTOCOL = 1

local function blankGrid(from)
    local source = type(from) == "table" and from or {}
    return {
        origin = copyPoint(source.origin),
        blockMetres = finite(source.blockMetres) or 100.0,
        cols = math.floor(finite(source.cols) or 8),
        rows = math.floor(finite(source.rows) or 8),
        floorMargin = finite(source.floorMargin) or 20.0,
        ceilingMargin = finite(source.ceilingMargin) or 200.0,
        groundDefault = finite(source.groundDefault),
        ground = {},
    }
end

--- A new map. The GRID is inherited from `seed` (normally the active map) and
--- the point lists are not: the grid is the hardest thing to get right and an
--- operator making a second map of the same district wants the same one, while
--- the points are precisely what they are about to walk.
local function blankMap(name, title, seed)
    return {
        name = name,
        title = title or name,
        -- Never asserted -- `K.recomputeSurveyed()` overwrites it on every
        -- apply. Written here only so a consumer reading the record before the
        -- first apply sees a boolean rather than nil.
        surveyed = false,
        -- TRUE, and it stays true until a human says otherwise with
        -- `/br.map probed`. Every coordinate in a runtime map was walked, so
        -- `provisional` is arguably wrong -- but it is a claim about a WHOLE
        -- map, and a map that is half walked and announces itself as final is
        -- the failure mode shared/pacifica.lua's header warns about.
        provisional = true,
        grid = blankGrid(seed and seed.grid or nil),
        staging = nil,
        spawns = {}, landings = {}, lootClusters = {}, vehicles = {},
        landmarks = {}, supply = {}, holdouts = {}, extractions = {},
        finalBlocks = {}, excluded = {},
        updatedMs = K.nowMs(),
    }
end

--- Rebuild `map.progress`, which `/br.map.check` in server/main.lua reads.
---
--- `need` is the HARD MINIMUM the mode refuses to start without, not an
--- aspiration: measuring a hand-built map against Pacifica's forty clusters
--- would report it incomplete forever, which is the mistake Watson's own
--- progress table was written to avoid.
local function rebuildProgress(map)
    map.progress = {
        { key = "origin", need = 1, what = "grid origin (SW corner of block 1,1)" },
        { key = "ground", need = 1, what = "default ground Z" },
        { key = "staging", need = 1, what = "staging anchor" },
        { key = "landings", need = 1, what = "landing zones" },
        { key = "finalBlocks", need = 1, what = "final-block whitelist" },
        { key = "lootClusters", need = 1, what = "loot points" },
        { key = "spawns", need = 0, what = "hand-placed player spawns" },
        { key = "vehicles", need = 0, what = "vehicle spawns" },
        { key = "landmarks", need = 0, what = "named landmarks for the tac-map" },
        { key = "supply", need = 0, what = "supply drop candidates" },
        { key = "excluded", need = 0, what = "cells with no walkable ground" },
    }
    -- The `*Target` fields are read by nothing but a human eye; keeping them
    -- equal to the counts stops a stale target from claiming a gap that closed.
    map.landingTarget = #map.landings
    map.lootClusterTarget = #map.lootClusters
    map.vehicleTarget = #map.vehicles
    map.holdoutTarget = #map.holdouts
    map.supplyTarget = #map.supply
end

--- Normalise one point out of an untrusted payload (the carried bag, or a
--- database row written by a previous generation of this file).
local function normalizePoint(entry, raw, index)
    if type(raw) ~= "table" then return nil end
    local position = copyPoint(raw.position) or copyPoint(raw)
    if position == nil then return nil end
    local point = {
        key = cleanName(raw.key, 24) or ("%s%02d"):format(entry.prefix, index),
        position = position,
    }
    if raw.label ~= nil then point.label = cleanLabel(raw.label) end
    if raw.headingKnown ~= nil then point.headingKnown = raw.headingKnown == true end
    if raw.grounded == true then point.grounded = true end
    for _, option in ipairs(entry.options or {}) do
        if option.name ~= "label" then
            local value = coerceOption(option, raw[option.name])
            if value ~= nil then point[option.name] = value end
        end
    end
    -- `probed` is what shared/watson.lua and shared/pacifica.lua carry to say
    -- "this coordinate was walked". Everything the editor captures was.
    point.probed = true
    return point
end

local function normalizeCellKeys(raw, grid)
    local keys, seen = {}, {}
    for _, value in ipairs(type(raw) == "table" and raw or {}) do
        local key = tostring(value or "")
        local col, row = Grid.parse(key)
        if col ~= nil and not seen[key] and Grid.inBounds(grid, col, row) then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    return keys
end

--- The one door untrusted map payloads come through. REVALIDATED, NOT TRUSTED:
--- this is JSON written by a previous generation of this file's own code, and a
--- truncated bag or a hand-edited row must not be able to take the mode down.
local function normalizeMap(raw, name)
    if type(raw) ~= "table" then raw = {} end
    local map = blankMap(name, cleanLabel(raw.title, 64) or name, raw)
    map.updatedMs = math.floor(finite(raw.updatedMs) or K.nowMs())
    map.provisional = raw.provisional ~= false

    local grid = map.grid
    grid.ground = {}
    for key, value in pairs(type(raw.grid) == "table" and type(raw.grid.ground) == "table"
        and raw.grid.ground or {}) do
        local col, row = Grid.parse(tostring(key))
        local z = finite(value)
        if col ~= nil and z ~= nil then grid.ground[Grid.key(col, row)] = z end
    end

    for _, entry in ipairs(KINDS) do
        if entry.singleton then
            local incoming = type(raw[entry.field]) == "table" and raw[entry.field] or nil
            local point = incoming ~= nil and normalizePoint(entry, incoming, 1) or nil
            map[entry.field] = point
        else
            local list = {}
            for index, incoming in ipairs(type(raw[entry.field]) == "table" and raw[entry.field] or {}) do
                if #list >= entry.cap then break end
                local point = normalizePoint(entry, incoming, index)
                if point ~= nil then list[#list + 1] = point end
            end
            map[entry.field] = list
        end
    end

    map.finalBlocks = normalizeCellKeys(raw.finalBlocks, grid)
    map.excluded = normalizeCellKeys(raw.excluded, grid)
    rebuildProgress(map)
    return map
end

--- The payload written to both stores. FLAT positions, because nesting `x,y,z`
--- under `position` costs fourteen bytes a point and the carried bag is a
--- 64 KiB budget shared with the roster and the career queue.
local function serializePoint(entry, point)
    local row = {
        key = point.key,
        x = point.position.x, y = point.position.y, z = point.position.z,
    }
    if point.label ~= nil then row.label = point.label end
    if point.headingKnown == false then row.headingKnown = false end
    if point.grounded == true then row.grounded = true end
    for _, option in ipairs(entry.options or {}) do
        if option.name ~= "label" and point[option.name] ~= nil then
            row[option.name] = point[option.name]
        end
    end
    return row
end

local function serialize(map)
    local payload = {
        name = map.name, title = map.title,
        provisional = map.provisional == true,
        updatedMs = map.updatedMs,
        grid = {
            origin = map.grid.origin, blockMetres = map.grid.blockMetres,
            cols = map.grid.cols, rows = map.grid.rows,
            floorMargin = map.grid.floorMargin, ceilingMargin = map.grid.ceilingMargin,
            groundDefault = map.grid.groundDefault, ground = map.grid.ground,
        },
        finalBlocks = map.finalBlocks, excluded = map.excluded,
    }
    for _, entry in ipairs(KINDS) do
        if entry.singleton then
            local point = map[entry.field]
            payload[entry.field] = point ~= nil and serializePoint(entry, point) or nil
        else
            local rows = {}
            for index, point in ipairs(map[entry.field] or {}) do
                rows[index] = serializePoint(entry, point)
            end
            payload[entry.field] = rows
        end
    end
    return payload
end


-- ================================================================ the store ==

local store = {}          -- name -> map record (a built-in is the ORIGINAL table)
local builtin = {}        -- name -> true
local activeName = nil
local starterSeeds = {} -- unedited starters never outrank persisted maps

-- The shipped maps are the floor everything else stands on: an empty store
-- plays them, `select pacifica` restores one at any time, and `copy` promotes
-- one into an editable draft. Letting the editor write to them would remove the
-- one thing that is always known-good -- and would mutate a table
-- `shared/watson.lua` owns, which survives no reload anyway.
for name, map in pairs(K.builtinMaps or {}) do
    local clean = cleanName(name, 32)
    if clean ~= nil and type(map) == "table" then
        store[clean] = map
        builtin[clean] = true
    end
end

local function mapNames()
    local names = {}
    for name in pairs(store) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function nameList()
    local names = mapNames()
    return #names > 0 and table.concat(names, ", ") or "none"
end

local function active()
    return activeName ~= nil and store[activeName] or K.map
end

--- Make `map` the map this server plays.
---
--- ONE assignment, because the record IS `K.map`. `K.recomputeSurveyed()` is
--- MEASURED here rather than carried in the payload: a map that CLAIMS to be
--- surveyed and is not produces a mode that starts and then cannot place
--- anybody, which is the worst of the three states because it looks like it
--- worked.
local function apply(map)
    if type(map) ~= "table" then return false, "no_map" end
    K.map = map
    activeName = map.name
    -- Registered so any later `K.resolveMap()` -- a hot reload of a neighbouring
    -- file, a future caller -- finds a runtime map by name instead of warning
    -- that it "is not a built-in" and falling back to Pacifica.
    K.builtinMaps = K.builtinMaps or {}
    K.builtinMaps[map.name] = map
    K.recomputeSurveyed()
    -- Guarded: `apply` also runs at LOAD, and a broadcast from a resource that
    -- is still coming up has no audience worth raising over. A survey that does
    -- not land is corrected by main.lua's own startup publish; a raise here
    -- would take the resource down.
    pcall(K.publishSurvey)
    if type(C) == "table" and type(C.publish) == "function" then pcall(C.publish) end
    return true
end

--- Every mutating verb ends here, which is why "the next match uses it" is a
--- property of the design rather than of remembering.
local function touch(map)
    map.updatedMs = K.nowMs()
    if not builtin[map.name] then rebuildProgress(map) end
    if map.name == activeName then apply(map) end
end


-- ------------------------------------------------------- the active name --
--
-- Held in the ONE tunable this file writes. `activeMap` is already declared in
-- shared/config.lua, is a per-server SETTING rather than runtime state, and
-- persists to `tunables.json` beside `server.jsonc` -- outside the watched
-- `resources/` tree, so writing it moves nothing the watcher can see.

local function persistActiveName(name)
    if type(Open77.tunables) ~= "table" or type(Open77.tunables.set) ~= "function" then
        return false, "this server exposes no tunable store"
    end
    -- `set` reports a REFUSAL as a return value, not a raise. A pcall alone
    -- would call a refused write a success and then report a map the server
    -- never adopted.
    local called, result, message = pcall(Open77.tunables.set, "activeMap", name)
    if not called then return false, tostring(result) end
    if result == false then return false, tostring(message) end
    return true
end


-- --------------------------------------------------- the hot-reload bridge --
--
-- COOPERATIVE, and that is the whole subtlety: the bag is one JSON string for
-- the WHOLE resource and `server/kernel.lua` (the roster) and
-- `server/ranked.lua` (pending career writes) both write it. Both sides
-- read-modify-write and preserve each other's top-level keys.

local CARRY_KEY = "cordonMaps"

local function loadBag()
    if type(Open77.state) ~= "table" or type(Open77.state.load) ~= "function" then return nil end
    local ok, bag = pcall(Open77.state.load)
    if not ok or type(bag) ~= "table" then return nil end
    return bag
end

local function mergeIntoBag(payload)
    if type(Open77.state) ~= "table" or type(Open77.state.save) ~= "function" then return false end
    local bag = loadBag() or {}
    bag[CARRY_KEY] = payload
    local ok, saved = pcall(Open77.state.save, bag)
    return ok and saved ~= false
end

local function carry()
    local budget = math.floor(number("carryBudgetBytes"))
    -- Everything, then the active map alone, then nothing. The active map is
    -- the one somebody is standing in the middle of authoring; the others are
    -- already in the database if there is one, and re-walkable if there is not.
    for _, scope in ipairs({ "all", "active" }) do
        local maps = {}
        for name, map in pairs(store) do
            if not builtin[name] and starterSeeds[name] ~= map and (scope == "all" or name == activeName) then
                maps[name] = serialize(map)
            end
        end
        local payload = { protocol = PROTOCOL, active = activeName, maps = maps }
        local ok, encoded = pcall(json.encode, payload)
        if ok and #encoded <= budget then
            if mergeIntoBag(payload) then return true end
        end
    end
    warn("the draft map does not fit its share of the 64 KiB carried bag -- it is NOT reload-safe " ..
        "right now. Run /br.map export and keep the output.")
    return false
end

local function adoptCarried()
    local bag = loadBag()
    local payload = bag ~= nil and bag[CARRY_KEY] or nil
    if type(payload) ~= "table" then return 0 end
    if payload.protocol ~= PROTOCOL then
        log("carried map state from another protocol version discarded")
        return 0
    end
    local adopted = 0
    for name, raw in pairs(type(payload.maps) == "table" and payload.maps or {}) do
        local clean = cleanName(name, 32)
        if clean ~= nil and not builtin[clean] then
            store[clean] = normalizeMap(raw, clean)
            adopted = adopted + 1
        end
    end
    return adopted
end


-- ------------------------------------------------ the durable store: FILES --
--
-- One JSON file per map under the resource's own `data/maps/`, through
-- `Open77.io`. This is the tier that actually works on the box this editor is
-- used on, and the reason it exists is concrete: `server.cordon-local.jsonc`
-- ships a disabled database, so without it the owner's walked production spawns
-- would survive every hot reload and die on the next server restart --
-- silently, with the following match placing everybody back on the procedural
-- defaults.
--
-- WHY THIS DOES NOT VIOLATE "NEVER WRITE UNDER resources/ AT RUNTIME".
--
-- The rule's PURPOSE is to stop a runtime write hot-reloading the session, and
-- three measurements say a write here cannot:
--
--   * `ServerResourceHost.Digest()` hashes ONLY the manifest-declared shared and
--     server scripts plus `open77.lua`. It does not walk the directory, so a
--     file under `data/` is invisible to `ReloadChanged()`.
--   * The client package is built from `Manifest.ClientFiles` -- the declared
--     `client_script` and `web_files` set -- so a write here cannot republish
--     the resource set to clients either.
--   * `ResourceDataStore` exposes `data/` AND NOTHING ELSE, by design, so that
--     "a resource that may save gameplay data must not be able to rewrite its
--     own manifest or executable Lua and grant itself more capabilities on the
--     next hot reload".
--
-- It is also an established pattern in this repository rather than a new
-- exception: `resources/gamemodes/race/server/courses.lua` persists hand-authored course
-- geometry exactly this way, and `resources/gamemodes/race/data/courses/` is tracked
-- today.
--
-- The host writes to a temporary file and renames, so a crash mid-write leaves
-- an unreferenced `.tmp` but never half a map.
--
-- A MISSING PERMISSION IS A SUPPORTED STATE, exactly like a missing database:
-- without `filesystem.read` / `filesystem.write` in the manifest every call
-- answers `permission_denied:...`, this tier reports itself off, and the store
-- degrades to precisely the behaviour it had before the tier existed.

local fsReady = nil       -- nil = not probed, true = durable, false = degraded
local fsReason = "not probed"
local fsDirectoryMade = false

local function mapDirectory()
    local name = tostring(setting("mapDirectory") or "maps")
    -- The path reaches the host's own resolver, which refuses anything escaping
    -- `data/`. Whitelisted here anyway so a mistyped config produces a named
    -- refusal rather than a path error raised from inside a C function.
    if name:match("^[a-z0-9][a-z0-9_%-]*$") == nil then name = "maps" end
    return name
end

local function fileFor(name)
    return ("%s/%s.json"):format(mapDirectory(), name)
end

--- Probe the binding WITHOUT creating anything. A `not_found` from `list` means
--- "no maps written yet", which is a ready store with nothing in it -- creating
--- the directory to discover that would leave a footprint on every server that
--- never opens the editor.
local function probeFiles()
    if fsReady ~= nil then return fsReady end
    if type(Open77.io) ~= "table" or type(Open77.io.writeJson) ~= "function"
        or type(Open77.io.readJson) ~= "function" or type(Open77.io.list) ~= "function" then
        fsReady = false
        fsReason = "no Open77.io in this runtime"
        return false
    end
    local entries, reason = Open77.io.list(mapDirectory())
    if entries == nil and tostring(reason) ~= "not_found" then
        fsReady = false
        fsReason = tostring(reason or "list_failed")
        local hint = ""
        if fsReason:find("permission_denied", 1, true) ~= nil then
            hint = " -- add "filesystem.read" and "filesystem.write" to open77.lua"
        end
        warn("FILE STORE UNAVAILABLE (" .. fsReason .. ")" .. hint)
        return false
    end
    fsReady = true
    fsReason = "ready"
    return true
end

local function writeFile(map)
    if not probeFiles() then return false end
    if not fsDirectoryMade then
        -- Created on the FIRST WRITE, not at load. `makeDirectory` is idempotent
        -- and a failure here is reported by the write that immediately follows.
        pcall(Open77.io.makeDirectory, mapDirectory())
        fsDirectoryMade = true
    end
    local payload = serialize(map)
    payload.schemaVersion = PROTOCOL
    local called, ok, reason = pcall(Open77.io.writeJson, fileFor(map.name), payload)
    if not called then
        fsReady = false
        fsReason = tostring(ok)
        warn(("map file write raised for '%s': %s"):format(map.name, fsReason))
        return false
    end
    if ok == false then
        -- The tier is marked DOWN rather than retried silently. A store that
        -- keeps reporting itself durable while every write bounces is the one
        -- failure mode that costs an afternoon without saying anything.
        fsReady = false
        fsReason = tostring(reason or "write_failed")
        warn(("map file write failed for '%s': %s -- the file store is OFF for the rest of this run")
            :format(map.name, fsReason))
        return false
    end
    return true
end

local function deleteFile(name)
    if fsReady ~= true or type(Open77.io.remove) ~= "function" then return end
    -- A missing file is a success: the caller asked for it to be gone.
    pcall(Open77.io.remove, fileFor(name))
end

--- Read every map file. `replace` is the whole difference between the two
--- callers: at LOAD it is false, so the carried bag -- this VM's predecessor's
--- memory, and therefore newer than anything on disk -- is not overwritten; from
--- `/br.map reload` it is true, because an operator asking to reload is asking
--- for exactly that.
local function readFiles(replace)
    if not probeFiles() then return 0 end
    local entries, reason = Open77.io.list(mapDirectory())
    if entries == nil then
        if tostring(reason) ~= "not_found" then
            fsReady = false
            fsReason = tostring(reason)
        end
        return 0
    end
    local loaded = 0
    for _, entry in ipairs(entries) do
        local stem = entry.type == "file"
            and tostring(entry.name or ""):match("^(.+)%.json$") or nil
        local name = stem ~= nil and cleanName(stem, 32) or nil
        if name ~= nil and not builtin[name] and (replace == true or store[name] == nil) then
            local payload, readReason = Open77.io.readJson(fileFor(name))
            if type(payload) ~= "table" then
                warn(("map file '%s' unreadable: %s"):format(fileFor(name), tostring(readReason)))
            elseif payload.schemaVersion ~= nil and payload.schemaVersion ~= PROTOCOL then
                warn(("map file '%s' rejected: schema %s, this build writes %d")
                    :format(fileFor(name), tostring(payload.schemaVersion), PROTOCOL))
            else
                -- REVALIDATED, NOT TRUSTED. This is JSON written by a previous
                -- generation of this file's own code, sitting in a directory a
                -- human can open in an editor.
                store[name] = normalizeMap(payload, name)
                loaded = loaded + 1
            end
        end
    end
    if loaded > 0 then
        log(("loaded %d map(s) from data/%s/"):format(loaded, mapDirectory()))
    end
    return loaded
end


-- ------------------------------------------------------- the durable store --
--
-- `server/ranked.lua`'s pattern, for exactly its reasons. A MISSING BRIDGE IS A
-- SUPPORTED STATE, not a failure -- the readouts just have to say so, in
-- capitals, every time. On `server.cordon-local.jsonc` the database is disabled,
-- so this is the state the dev box is in and the one the readouts describe.

local dbReady = nil       -- nil = not probed, true = durable, false = degraded
local dbReason = "not probed"

local function tableName()
    local prefix = tostring(setting("tablePrefix")
        or (type(Config) == "table" and type(Config.career) == "table" and Config.career.tablePrefix)
        or "open77_br_")
    -- The prefix reaches SQL as an IDENTIFIER, and identifiers cannot be bound
    -- as parameters, so operator-supplied config is whitelisted rather than
    -- trusted.
    if prefix:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then prefix = "open77_br_" end
    return prefix .. "maps"
end

--- What the store actually is, right now, in one clause. Printed by every
--- readout that could otherwise let somebody believe their walking is safe.
local function storageLine()
    local durable, off = {}, {}
    if fsReady == true then durable[#durable + 1] = ("files (data/%s/)"):format(mapDirectory())
    elseif fsReady == false then off[#off + 1] = ("no files: %s"):format(fsReason) end
    if dbReady == true then durable[#durable + 1] = ("database (%s)"):format(tableName())
    elseif dbReady == false then off[#off + 1] = ("no database: %s"):format(dbReason) end

    if #durable > 0 then
        return ("durable in %s%s"):format(table.concat(durable, " + "),
            #off > 0 and (" [" .. table.concat(off, "; ") .. "]") or "")
    end
    if fsReady == nil and dbReady == nil then return "storage not probed yet" end
    return ("MEMORY ONLY, VOLATILE ACROSS A RESTART (%s) -- /br.map export before you stop the server")
        :format(table.concat(off, "; "))
end

local function ensureSchema()
    if dbReady ~= nil then return dbReady end
    local sql = globalTable("MySQL")
    if sql == nil then
        dbReady = false
        dbReason = "no MySQL global in this runtime"
        warn("DATABASE UNAVAILABLE (" .. dbReason .. ") -- maps are VOLATILE this run")
        return false
    end
    local ok, reason = pcall(function()
        sql.update.await(([[
            CREATE TABLE IF NOT EXISTS %s (
                name        VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                title       VARCHAR(64) NOT NULL,
                payload     MEDIUMTEXT NOT NULL,
                updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (name)
            ) ENGINE=InnoDB
        ]]):format(tableName()))
    end)
    if not ok then
        dbReady = false
        dbReason = tostring(reason)
        warn("DATABASE UNAVAILABLE (" .. dbReason .. ") -- maps are VOLATILE this run")
        return false
    end
    dbReady = true
    dbReason = "ready"
    log("database ready -- maps persist in " .. tableName())
    return true
end

-- ONE coroutine owns every database call, for the reason ranked.lua spells out:
-- `.await` yields, so two independent threads can interleave mid-write and a
-- load can overwrite a save that has not landed. Serialised in one FIFO, every
-- order is correct.
local jobs = {}
local workerRunning = false
local drain

local function enqueue(job)
    jobs[#jobs + 1] = job
    if workerRunning then return end
    workerRunning = true
    CreateThread(function()
        local ok, err = pcall(drain)
        workerRunning = false
        if not ok then warn("store worker raised: " .. tostring(err)) end
    end)
end

drain = function()
    while #jobs > 0 do
        local job = table.remove(jobs, 1)
        local ok, err = pcall(job)
        if not ok then warn("store job raised: " .. tostring(err)) end
    end
end

local function writeMap(map)
    if not ensureSchema() then return end
    local ok, encoded = pcall(json.encode, serialize(map))
    if not ok then return warn("could not encode map '" .. tostring(map.name) .. "'") end
    local sql = globalTable("MySQL")
    if sql == nil then return end
    local written, reason = pcall(function()
        sql.update.await(([[
            INSERT INTO %s (name, title, payload) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE title = VALUES(title), payload = VALUES(payload)
        ]]):format(tableName()), { map.name, map.title, encoded })
    end)
    if not written then warn(("save of '%s' failed: %s"):format(map.name, tostring(reason))) end
end

local function deleteMap(name)
    if not ensureSchema() then return end
    local sql = globalTable("MySQL")
    if sql == nil then return end
    pcall(function()
        sql.update.await(("DELETE FROM %s WHERE name = ?"):format(tableName()), { name })
    end)
end

local function readAll(replace)
    if not ensureSchema() then return 0 end
    local sql = globalTable("MySQL")
    if sql == nil then return 0 end
    local ok, rows = pcall(function()
        return sql.query.await(("SELECT name, title, payload FROM %s"):format(tableName()))
    end)
    if not ok then
        warn("map load failed: " .. tostring(rows))
        return 0
    end
    local loaded = 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local name = cleanName(row.name, 32)
        if name ~= nil and not builtin[name] then
            local decoded, payload = pcall(json.decode, tostring(row.payload or ""))
            if decoded and type(payload) == "table" then
                payload.title = payload.title or row.title
                -- FILL GAPS ONLY unless the operator asked for a replace. The
                -- bag and the files are this server's own memory; a database row
                -- may have been written by ANOTHER server sharing the schema,
                -- and letting it silently overwrite a local edit is the failure
                -- nobody would think to look for. `updatedMs` cannot arbitrate
                -- it either -- see the header: it is process-monotonic and
                -- resets on a restart.
                if replace == true or store[name] == nil or starterSeeds[name] == store[name] then
                    starterSeeds[name] = nil
                    store[name] = normalizeMap(payload, name)
                    loaded = loaded + 1
                end
            end
        end
    end
    if loaded > 0 then log(("loaded %d map(s) from %s"):format(loaded, tableName())) end
    local wanted = cleanName(K.tune("activeMap", nil), 32)
    if wanted ~= nil and store[wanted] ~= nil and (wanted ~= activeName or K.map ~= store[wanted]) then
        apply(store[wanted])
        log("active map is now '" .. wanted .. "' (restored from the store)")
    end
    return loaded
end

--- Persist everything a change could have touched: the carried bag always
--- (cheap, synchronous, and the only thing that survives a reload) and the
--- database when there is one.
--- Persist everything a change could have touched, across every tier that is up.
---
--- The bag and the file are written SYNCHRONOUSLY -- both are cheap, and both
--- are what survives the thing that actually happens twenty times an hour while
--- this resource is being edited. The database write is QUEUED, because `.await`
--- yields and a slow database must never hold up a capture.
local function persist(map, removedName)
    if map ~= nil then starterSeeds[map.name] = nil end
    carry()
    if removedName ~= nil then
        deleteFile(removedName)
        enqueue(function() deleteMap(removedName) end)
    end
    if map ~= nil and not builtin[map.name] then
        writeFile(map)
        enqueue(function() writeMap(map) end)
    end
end


-- ================================================================ commands ==

local function reply(source, raw, ok, text)
    K.log("editor: " .. tostring(text))
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

--- The ONE source of coordinates in this file. See the header: a command
--- carries a kind, an index, a tier and at most a heading; never a place.
local function callerPosition(playerId)
    local position = K.position(playerId)
    if position == nil then return nil, "position_unknown" end
    local point = copyPoint(position)
    if point == nil then return nil, "position_unreadable" end
    point.yaw = normalizeHeading(position.yaw)
    return point
end

--- The active map, refusing the built-in.
local function editable(source, raw)
    local map = active()
    if map == nil then
        reply(source, raw, false, "no active map")
        return nil
    end
    if builtin[map.name] then
        reply(source, raw, false, ("'%s' is a built-in and is read-only. " ..
            "Run: /br.map copy %s <newname>  then  /br.map select <newname>")
            :format(map.name, map.name))
        return nil
    end
    return map
end

local function listOf(map, entry)
    if entry.singleton then return nil end
    map[entry.field] = map[entry.field] or {}
    return map[entry.field]
end

--- A free key for a new point of this kind.
local function nextKey(list, entry)
    local used = {}
    for _, point in ipairs(list or {}) do used[point.key] = true end
    for index = 1, (entry.cap or 999) + 1 do
        local candidate = ("%s%02d"):format(entry.prefix, index)
        if not used[candidate] then return candidate end
    end
    return ("%s%d"):format(entry.prefix, math.floor(K.nowMs() % 100000))
end

--- `<kind> <ref>` where ref is a 1-based index or the point's key.
local function resolveRef(list, token)
    local index = math.floor(tonumber(token) or 0)
    if index >= 1 and index <= #list then return index end
    local wanted = tostring(token or ""):lower()
    for position, point in ipairs(list) do
        if tostring(point.key):lower() == wanted then return position end
    end
    return nil
end

local function tooClose(entry, list, point, skipIndex)
    local minimum = finite(entry.separation) or number("minimumSeparation")
    if minimum <= 0 then return nil end
    for index, existing in ipairs(list) do
        if index ~= skipIndex then
            local gap = distance3D(point, existing.position)
            if gap < minimum then return index, gap, minimum end
        end
    end
    return nil
end

--- Read this kind's options off a positional argument list, starting at
--- `first`. `label` is greedy and must therefore be last in the declaration.
local function readOptions(entry, args, first)
    local options = entry.options or {}
    local values, index = {}, first
    for position, option in ipairs(options) do
        local token
        -- POSITIONAL ORDER IS DECLARATION ORDER, and a text option is greedy
        -- ONLY when it is the last one declared. Otherwise `add land Market 1`
        -- would swallow the `1` into the label and silently drop the flag --
        -- which is worse than refusing, because the point IS created and merely
        -- wrong. Every kind whose label may contain spaces declares it last.
        if option.kind == "text" and position == #options then
            token = argRest(args, index)
            index = (tonumber(args.n) or #args) + 1
        else
            token = argAt(args, index)
            index = index + 1
        end
        local value, err = coerceOption(option, token)
        -- A LENIENT option does not consume a token it cannot read. `hot` and
        -- `heading` are flags whose spelling overlaps with a label -- without
        -- this, `add land Market Centre` sets hot=false from "Market" and calls
        -- the zone "Centre", which is worse than refusing because the point IS
        -- created and merely wrong. A strict option (tier, count, radius) still
        -- refuses, because a bad tier is a typo and not a label.
        if err ~= nil and option.lenient == true then
            index = index - 1
            value, err = nil, nil
        end
        if err ~= nil then return nil, ("%s: %s"):format(option.name, err) end
        if value ~= nil then values[option.name] = value end
    end
    return values
end


-- ------------------------------------------------------------ point verbs --

local function cmdAdd(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findKind(argAt(args, 1))
    if entry == nil then
        return reply(source, raw, false, ("unknown kind %q; have: %s")
            :format(tostring(argAt(args, 1) or ""), kindKeys()))
    end

    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end

    local values, optionError = readOptions(entry, args, 2)
    if values == nil then return reply(source, raw, false, optionError) end

    local record = { position = point, probed = true }
    for name, value in pairs(values) do record[name] = value end
    if findOption(entry, "heading") ~= nil then
        record.heading = values.heading or point.yaw or 0.0
        record.headingKnown = values.heading ~= nil or point.yaw ~= nil
    end

    if entry.singleton then
        record.key = entry.prefix
        map[entry.field] = record
        touch(map)
        persist(map)
        return reply(source, raw, true, ("%s set at %.2f %.2f %.2f%s")
            :format(entry.label, point.x, point.y, point.z, describeOptions(entry, record)))
    end

    local list = listOf(map, entry)
    if #list >= entry.cap then
        return reply(source, raw, false, ("%s is full (%d); delete one first")
            :format(entry.key, entry.cap))
    end
    local clash, gap, minimum = tooClose(entry, list, point)
    if clash ~= nil then
        return reply(source, raw, false, ("%.1f m from %s #%d, minimum is %.1f m " ..
            "(move, or use `/br.map move %s %d` to relocate that one)")
            :format(gap, entry.key, clash, minimum, entry.key, clash))
    end

    record.key = nextKey(list, entry)
    list[#list + 1] = record
    touch(map)
    persist(map)
    reply(source, raw, true, ("%s #%d (%s) at %.2f %.2f %.2f%s -- %d total")
        :format(entry.label, #list, record.key, point.x, point.y, point.z,
            describeOptions(entry, record), #list))
    if entry.live == false then
        reply(source, raw, true, ("note: %s -- %s"):format(entry.key, tostring(entry.liveNote)))
    end
end

local function cmdMove(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findKind(argAt(args, 1))
    if entry == nil then
        return reply(source, raw, false, ("unknown kind; have: %s"):format(kindKeys()))
    end
    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end

    if entry.singleton then
        local record = map[entry.field]
        if record == nil then return reply(source, raw, false, "no " .. entry.label .. " to move; use `add`") end
        record.position = point
        if findOption(entry, "heading") ~= nil then
            local heading = normalizeHeading(argAt(args, 2)) or point.yaw
            if heading ~= nil then record.heading, record.headingKnown = heading, true end
        end
        touch(map)
        persist(map)
        return reply(source, raw, true, ("%s moved to %.2f %.2f %.2f")
            :format(entry.label, point.x, point.y, point.z))
    end

    local list = listOf(map, entry)
    local index = resolveRef(list, argAt(args, 2))
    if index == nil then
        return reply(source, raw, false, ("no such %s: %q (1..%d, or a key)")
            :format(entry.key, tostring(argAt(args, 2) or ""), #list))
    end
    local clash, gap, minimum = tooClose(entry, list, point, index)
    if clash ~= nil then
        return reply(source, raw, false, ("%.1f m from %s #%d, minimum is %.1f m")
            :format(gap, entry.key, clash, minimum))
    end
    local heading = normalizeHeading(argAt(args, 3)) or point.yaw
    list[index].position = point
    list[index].grounded = nil -- a walked move invalidates the prior ray-ground survey
    if heading ~= nil and findOption(entry, "heading") ~= nil then
        list[index].heading = heading
        list[index].headingKnown = true
    end
    touch(map)
    persist(map)
    reply(source, raw, true, ("%s #%d (%s) moved to %.2f %.2f %.2f")
        :format(entry.label, index, tostring(list[index].key), point.x, point.y, point.z))
end

local function cmdDelete(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findKind(argAt(args, 1))
    if entry == nil then
        return reply(source, raw, false, ("unknown kind; have: %s"):format(kindKeys()))
    end
    if entry.singleton then
        map[entry.field] = nil
        touch(map)
        persist(map)
        return reply(source, raw, true, entry.label .. " cleared -- the map will refuse to stage until it is set again")
    end
    local list = listOf(map, entry)
    local token = argAt(args, 2)
    if tostring(token or ""):lower() == "all" then
        local removed = #list
        map[entry.field] = {}
        touch(map)
        persist(map)
        return reply(source, raw, true, ("%d %s(s) deleted"):format(removed, entry.key))
    end
    local index = resolveRef(list, token)
    if index == nil then
        return reply(source, raw, false, ("no such %s: %q (1..%d, a key, or `all`)")
            :format(entry.key, tostring(token or ""), #list))
    end
    local key = tostring(list[index].key)
    table.remove(list, index)
    touch(map)
    persist(map)
    reply(source, raw, true, ("%s #%d (%s) deleted -- %d left"):format(entry.label, index, key, #list))
end

local function cmdSet(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findKind(argAt(args, 1))
    if entry == nil then
        return reply(source, raw, false, ("unknown kind; have: %s"):format(kindKeys()))
    end
    local record, label
    if entry.singleton then
        record = map[entry.field]
        label = entry.label
        if record == nil then return reply(source, raw, false, "no " .. entry.label .. " yet") end
    else
        local list = listOf(map, entry)
        local index = resolveRef(list, argAt(args, 2))
        if index == nil then
            return reply(source, raw, false, ("no such %s: %q (1..%d, or a key)")
                :format(entry.key, tostring(argAt(args, 2) or ""), #list))
        end
        record = list[index]
        label = ("%s #%d (%s)"):format(entry.label, index, tostring(record.key))
    end
    local base = entry.singleton and 2 or 3
    local option = findOption(entry, argAt(args, base))
    if option == nil then
        return reply(source, raw, false, ("usage: /br.map set %s <ref> <field> <value> -- fields: %s")
            :format(entry.key, optionNames(entry)))
    end
    local token = option.kind == "text" and argRest(args, base + 1) or argAt(args, base + 1)
    local value, err = coerceOption(option, token)
    if err ~= nil then return reply(source, raw, false, ("%s: %s"):format(option.name, err)) end
    record[option.name] = value
    if option.name == "heading" then record.headingKnown = value ~= nil end
    touch(map)
    persist(map)
    reply(source, raw, true, ("%s %s=%s"):format(label, option.name,
        option.name == "tier" and tierName(value) or tostring(value)))
end

local function cmdPoints(source, raw, args)
    local map = active()
    if map == nil then return reply(source, raw, false, "no active map") end
    local only = argAt(args, 1) ~= nil and findKind(argAt(args, 1)) or nil
    if argAt(args, 1) ~= nil and only == nil then
        return reply(source, raw, false, ("unknown kind; have: %s"):format(kindKeys()))
    end
    reply(source, raw, true, ("map '%s' (%s) -- %s"):format(map.name,
        builtin[map.name] and "built-in, read-only" or "runtime", storageLine()))
    for _, entry in ipairs(KINDS) do
        if only == nil or only.key == entry.key then
            if entry.singleton then
                local point = map[entry.field]
                if point == nil or point.position == nil then
                    reply(source, raw, true, ("%s: NOT SET"):format(entry.key))
                else
                    reply(source, raw, true, ("%s: %.2f %.2f %.2f%s"):format(entry.key,
                        point.position.x, point.position.y, point.position.z,
                        describeOptions(entry, point)))
                end
            else
                local list = map[entry.field] or {}
                reply(source, raw, true, ("%s (%s): %d"):format(entry.key, entry.label, #list))
                for index, point in ipairs(list) do
                    reply(source, raw, true, ("  %2d %-6s %9.2f %9.2f %7.2f%s%s"):format(
                        index, tostring(point.key),
                        point.position.x, point.position.y, point.position.z,
                        point.label ~= nil and (" \"" .. point.label .. "\"") or "",
                        describeOptions(entry, point)))
                end
            end
        end
    end
end

local function cmdCount(source, raw)
    local map = active()
    if map == nil then return reply(source, raw, false, "no active map") end
    local parts = {}
    for _, entry in ipairs(KINDS) do
        if entry.singleton then
            parts[#parts + 1] = ("%s=%s"):format(entry.key, map[entry.field] ~= nil and "set" or "MISSING")
        else
            parts[#parts + 1] = ("%s=%d%s"):format(entry.key, #(map[entry.field] or {}),
                entry.live == false and "*" or "")
        end
    end
    reply(source, raw, true, ("map=%s surveyed=%s cells=%dx%d final=%d excluded=%d | %s | %s")
        :format(tostring(map.name), tostring(map.surveyed),
            map.grid and map.grid.cols or 0, map.grid and map.grid.rows or 0,
            #(map.finalBlocks or {}), #(map.excluded or {}),
            table.concat(parts, " "), storageLine()))
    reply(source, raw, true, "* = captured and exported, but nothing consumes it yet; /br.map check names them")
end

local function cmdNear(source, raw, args)
    local map = active()
    if map == nil then return reply(source, raw, false, "no active map") end
    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end
    local only = argAt(args, 1) ~= nil and findKind(argAt(args, 1)) or nil
    if argAt(args, 1) ~= nil and only == nil then
        return reply(source, raw, false, ("unknown kind; have: %s"):format(kindKeys()))
    end

    local found = false
    for _, entry in ipairs(KINDS) do
        if (only == nil or only.key == entry.key) and not entry.singleton then
            local best, bestIndex, bestGap = nil, nil, nil
            for index, candidate in ipairs(map[entry.field] or {}) do
                local gap = distance3D(point, candidate.position)
                if bestGap == nil or gap < bestGap then
                    best, bestIndex, bestGap = candidate, index, gap
                end
            end
            if best ~= nil then
                found = true
                reply(source, raw, true, ("%s: #%d %s at %.1f m (%.2f %.2f %.2f)%s"):format(
                    entry.key, bestIndex, tostring(best.key), bestGap,
                    best.position.x, best.position.y, best.position.z,
                    describeOptions(entry, best)))
            end
        end
    end

    local col, row = Grid.cellOf(map.grid, point.x, point.y)
    reply(source, raw, true, ("you: %.2f %.2f %.2f  cell=%s  groundDefault=%s"):format(
        point.x, point.y, point.z,
        col ~= nil and Grid.key(col, row) or "OUTSIDE THE GRID",
        tostring(map.grid and map.grid.groundDefault)))
    if not found then reply(source, raw, true, "no points of that kind on this map yet") end
end


-- --------------------------------------------------------------- the pod --
--
-- THE ANSWER TO "HOW DO 64 PLAYER SPAWNS GET PLACED WITHOUT 64 CAPTURES", and
-- the reason it is a POD and not a scatter.
--
-- `spread` fans `n` extra points in a ring around EACH point of a kind that is
-- already captured, at the SAME z as its anchor and at a small radius. It is
-- deliberately tight -- eight metres by default -- for two independent reasons:
--
--   1. THE GROUND. Every generated point inherits its anchor's height, because
--      the server has no way to sample the surface anywhere else. That is sound
--      only while the ground stays flat across the ring, and `L.seed`'s header
--      records what happens when it does not: within a couple of dozen metres
--      on Pacifica the walkable surface moved between 37.6 and 45.3, and drops
--      landed on container roofs and in the air.
--
--   2. THE HEADCOUNT. `Config.match.minPlayers` is 2 and `startAtPlayers` is 5,
--      so most matches on this server will be four or five people, not
--      sixty-four. A rule that scattered spawns across a district would leave
--      four players unable to find each other, and a match nobody can find is
--      worse than one that starts slowly. A pod keeps a lobby's worth of spawns
--      inside one fight.
--
-- So the shape of a full map is a handful of walked ANCHORS, each expanded into
-- a pod: walk eight places, `spread spawn 8`, and there are sixty-four spawns
-- in eight fights rather than sixty-four lonely ones.
--
-- `paint` is the other half and is for lines rather than clumps: it drops a
-- point every `everyMetres` while the operator walks, which is how a street of
-- loot or a row of vehicles gets placed in one pass.

local function cmdSpread(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local entry = findKind(argAt(args, 1))
    if entry == nil or entry.singleton then
        return reply(source, raw, false, ("usage: /br.map spread <kind> <n> [radius] -- kinds: %s")
            :format(kindKeys()))
    end
    local wanted = math.floor(tonumber(argAt(args, 2)) or 0)
    if wanted < 1 or wanted > 32 then
        return reply(source, raw, false, "usage: /br.map spread <kind> <n> [radius]  (n is 1..32, per anchor)")
    end
    local radius = finite(argAt(args, 3)) or number("spreadRadius")
    if radius < 1.0 or radius > 60.0 then
        return reply(source, raw, false, "radius must be between 1 and 60 metres -- a pod, not a scatter")
    end

    local list = listOf(map, entry)
    local anchors = {}
    for index, point in ipairs(list) do anchors[index] = point end
    if #anchors == 0 then
        return reply(source, raw, false, ("no %s to spread from -- capture at least one with /br.map add %s")
            :format(entry.key, entry.key))
    end

    local made, refused = 0, 0
    for _, anchor in ipairs(anchors) do
        for step = 1, wanted do
            if #list >= entry.cap then break end
            local angle = (step / wanted) * math.pi * 2.0
            local candidate = {
                x = anchor.position.x + math.cos(angle) * radius,
                y = anchor.position.y + math.sin(angle) * radius,
                -- THE ANCHOR'S OWN Z. See the header above: it is the only
                -- height the server can honestly claim for this point.
                z = anchor.position.z,
            }
            if tooClose(entry, list, candidate) ~= nil then
                refused = refused + 1
            else
                local record = { position = candidate, probed = false, key = nextKey(list, entry) }
                -- The generated point inherits its anchor's OPTIONS -- a pod of
                -- rare loot stays rare, a pod of hot landings stays hot.
                for _, option in ipairs(entry.options or {}) do
                    if option.name ~= "label" and anchor[option.name] ~= nil then
                        record[option.name] = anchor[option.name]
                    end
                end
                if findOption(entry, "heading") ~= nil then
                    record.headingKnown = anchor.headingKnown == true
                end
                list[#list + 1] = record
                made = made + 1
            end
        end
    end
    touch(map)
    persist(map)
    reply(source, raw, true, ("spread %s: %d added around %d anchor(s) at %.1f m, %d refused for separation -- %d total")
        :format(entry.key, made, #anchors, radius, refused, #list))
    reply(source, raw, true, "generated points carry probed=false: their z is their anchor's, not walked. " ..
        "Walk the pod and /br.map move any that sit wrong.")
end


-- ------------------------------------------------------------------ paint --
--
-- A point every `everyMetres` of walking, until `paint off`. The loop reads the
-- operator's own position on the SERVER at 4 Hz -- it is not a client stream --
-- so it inherits the same rule as every other capture here.

local painting = {}   -- playerId -> session

local function stopPaint(playerId, why)
    local session = painting[playerId]
    if session == nil then return nil end
    painting[playerId] = nil
    session.stopped = why or "off"
    return session
end

local function cmdPaint(source, raw, args)
    local token = tostring(argAt(args, 1) or ""):lower()
    if token == "off" or token == "stop" or token == "0" then
        local session = stopPaint(source, "operator")
        if session == nil then return reply(source, raw, false, "not painting") end
        return reply(source, raw, true, ("paint off -- %d %s(s) placed"):format(session.made, session.kind))
    end

    local map = editable(source, raw)
    if map == nil then return end
    local entry = findKind(token)
    if entry == nil or entry.singleton then
        return reply(source, raw, false, ("usage: /br.map paint <kind> [everyMetres] | /br.map paint off -- kinds: %s")
            :format(kindKeys()))
    end
    if painting[source] ~= nil then
        return reply(source, raw, false, "already painting; /br.map paint off first")
    end
    local every = finite(argAt(args, 2)) or number("paintEveryMetres")
    if every < 1.0 or every > 200.0 then
        return reply(source, raw, false, "everyMetres must be between 1 and 200")
    end

    local start, failure = callerPosition(source)
    if start == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end

    -- The options are read ONCE, at `paint`, and every point in the pass gets
    -- them. An omitted heading is captured afresh from each position snapshot.
    local values, optionError = readOptions(entry, args, 3)
    if values == nil then return reply(source, raw, false, optionError) end

    local session = {
        kind = entry.key, entry = entry, every = every, values = values,
        last = start, made = 0, mapName = map.name,
        limit = math.floor(number("paintMaxPoints")),
    }
    painting[source] = session
    reply(source, raw, true, ("painting %s every %.1f m -- walk. /br.map paint off to stop (cap %d)")
        :format(entry.key, every, session.limit))

    CreateThread(function()
        local pollMs = math.max(100, math.floor(number("paintPollMs")))
        while painting[source] == session do
            Wait(pollMs)
            local ok, err = pcall(function()
                if painting[source] ~= session then return end
                local current = active()
                -- The operator changed maps, or somebody reloaded under us.
                if current == nil or current.name ~= session.mapName or builtin[current.name] then
                    stopPaint(source, "map changed")
                    reply(source, raw, false, "paint stopped: the active map changed")
                    return
                end
                local point = callerPosition(source)
                if point == nil then
                    stopPaint(source, "no position")
                    return
                end
                if distance2D(point, session.last) < session.every then return end

                local list = listOf(current, session.entry)
                if #list >= session.entry.cap or session.made >= session.limit then
                    stopPaint(source, "cap")
                    reply(source, raw, false, ("paint stopped: %s is at its cap (%d placed)")
                        :format(session.entry.key, session.made))
                    return
                end
                if tooClose(session.entry, list, point) ~= nil then
                    -- Not an error: the operator doubled back. Move the ruler
                    -- forward so the next step is measured from here.
                    session.last = point
                    return
                end

                local record = { position = point, probed = true, key = nextKey(list, session.entry) }
                for name, value in pairs(session.values) do record[name] = value end
                if findOption(session.entry, "heading") ~= nil then
                    record.heading = session.values.heading or point.yaw or 0.0
                    record.headingKnown = session.values.heading ~= nil or point.yaw ~= nil
                end
                list[#list + 1] = record
                session.made = session.made + 1
                session.last = point
                touch(current)
                -- Persisted on every point, deliberately: a paint pass is
                -- exactly the situation in which somebody else's save reloads
                -- this VM halfway through, and the carried bag is what survives
                -- it. The database write is queued, not awaited.
                persist(current)
                reply(source, raw, true, ("%s #%d (%s) painted at %.1f %.1f %.1f")
                    :format(session.entry.label, #list, record.key, point.x, point.y, point.z))
            end)
            if not ok then
                stopPaint(source, "error")
                warn("paint loop failed: " .. tostring(err))
            end
        end
    end)
end


-- ------------------------------------------------------------ grid verbs --

local function cmdOrigin(source, raw)
    local map = editable(source, raw)
    if map == nil then return end
    local point, failure = callerPosition(source)
    if point == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end
    map.grid.origin = point
    -- Set together, because `K.recomputeSurveyed()` demands both and an operator
    -- who sets one and not the other has a map that refuses to stage for a
    -- reason nothing names. `ground` overrides it per cell later.
    if map.grid.groundDefault == nil then map.grid.groundDefault = point.z end
    touch(map)
    persist(map)
    reply(source, raw, true, ("grid origin = %.2f %.2f %.2f (SW corner of block 1,1); groundDefault=%.2f. " ..
        "Grid covers %.0f x %.0f m from here, +X east, +Y north.")
        :format(point.x, point.y, point.z, map.grid.groundDefault,
            map.grid.cols * map.grid.blockMetres, map.grid.rows * map.grid.blockMetres))
end

local function cmdGrid(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local cols = math.floor(tonumber(argAt(args, 1)) or 0)
    local rows = math.floor(tonumber(argAt(args, 2)) or 0)
    if cols < 1 or cols > 64 or rows < 1 or rows > 64 then
        return reply(source, raw, false, "usage: /br.map grid <cols> <rows> [blockMetres]  (1..64 each)")
    end
    local block = finite(argAt(args, 3)) or map.grid.blockMetres
    if block < 10.0 or block > 500.0 then
        return reply(source, raw, false, "blockMetres must be between 10 and 500")
    end
    map.grid.cols, map.grid.rows, map.grid.blockMetres = cols, rows, block
    -- A cell key that is now out of bounds is not a warning but a silent
    -- inconsistency: `C.begin` would whitelist a final block the grid does not
    -- contain and the cordon would close on nothing.
    map.finalBlocks = normalizeCellKeys(map.finalBlocks, map.grid)
    map.excluded = normalizeCellKeys(map.excluded, map.grid)
    touch(map)
    persist(map)
    reply(source, raw, true, ("grid = %dx%d at %.0f m (%.0f x %.0f m total); final=%d excluded=%d after re-bounding")
        :format(cols, rows, block, cols * block, rows * block, #map.finalBlocks, #map.excluded))
end

local function cmdGround(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local token = tostring(argAt(args, 1) or ""):lower()

    if token == "cell" then
        local point, failure = callerPosition(source)
        if point == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end
        local col, row = Grid.cellOf(map.grid, point.x, point.y)
        if col == nil then return reply(source, raw, false, "you are outside the grid") end
        local key = Grid.key(col, row)
        map.grid.ground[key] = point.z
        touch(map)
        persist(map)
        return reply(source, raw, true, ("ground override for cell %s = %.2f (default %.2f)")
            :format(key, point.z, tonumber(map.grid.groundDefault) or 0.0))
    end

    if token == "clear" then
        local point, failure = callerPosition(source)
        if point == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end
        local col, row = Grid.cellOf(map.grid, point.x, point.y)
        if col == nil then return reply(source, raw, false, "you are outside the grid") end
        local key = Grid.key(col, row)
        map.grid.ground[key] = nil
        touch(map)
        persist(map)
        return reply(source, raw, true, ("ground override for cell %s cleared"):format(key))
    end

    local z = finite(token)
    if z == nil then
        local point = callerPosition(source)
        if point == nil then
            return reply(source, raw, false, "usage: /br.map ground [<z>|cell|clear]")
        end
        z = point.z
    end
    map.grid.groundDefault = z
    touch(map)
    persist(map)
    reply(source, raw, true, ("groundDefault = %.2f. Prefer the MEDIAN of the walked points, not the first: " ..
        "a default across a cliff buries or drops a player."):format(z))
end

--- `final` and `exclude` share a body: both are lists of cell keys and both are
--- addressed by the cell the operator is standing in.
local function cellListVerb(source, raw, args, field, what)
    local map = editable(source, raw)
    if map == nil then return end
    local action = tostring(argAt(args, 1) or "list"):lower()
    map[field] = map[field] or {}

    if action == "list" then
        return reply(source, raw, true, ("%s (%d): %s"):format(what, #map[field],
            #map[field] > 0 and table.concat(map[field], " ") or "none"))
    end

    local key = argAt(args, 2)
    if key == nil then
        local point, failure = callerPosition(source)
        if point == nil then return reply(source, raw, false, "no position: " .. tostring(failure)) end
        local col, row = Grid.cellOf(map.grid, point.x, point.y)
        if col == nil then return reply(source, raw, false, "you are outside the grid; pass a cell key instead") end
        key = Grid.key(col, row)
    else
        local col, row = Grid.parse(key)
        if col == nil or not Grid.inBounds(map.grid, col, row) then
            return reply(source, raw, false, ("%q is not a cell in this grid (1,1 .. %d,%d)")
                :format(tostring(key), map.grid.cols, map.grid.rows))
        end
        key = Grid.key(col, row)
    end

    if action == "add" then
        for _, existing in ipairs(map[field]) do
            if existing == key then
                return reply(source, raw, false, ("%s already contains %s"):format(what, key))
            end
        end
        map[field][#map[field] + 1] = key
    elseif action == "del" or action == "remove" then
        local found = nil
        for index, existing in ipairs(map[field]) do
            if existing == key then found = index break end
        end
        if found == nil then return reply(source, raw, false, ("%s does not contain %s"):format(what, key)) end
        table.remove(map[field], found)
    else
        return reply(source, raw, false, ("usage: /br.map %s add|del|list [cell]")
            :format(field == "finalBlocks" and "final" or "exclude"))
    end
    touch(map)
    persist(map)
    reply(source, raw, true, ("%s (%d): %s"):format(what, #map[field],
        #map[field] > 0 and table.concat(map[field], " ") or "none"))
end


-- ---------------------------------------------------------------- the map --

local function cmdList(source, raw)
    reply(source, raw, true, ("%d map(s) -- %s"):format(#mapNames(), storageLine()))
    for _, name in ipairs(mapNames()) do
        local map = store[name]
        local total = 0
        for _, entry in ipairs(KINDS) do
            if not entry.singleton then total = total + #(map[entry.field] or {}) end
        end
        reply(source, raw, true, ("%s %-16s %-8s %-28s points=%d landings=%d loot=%d"):format(
            name == activeName and ">" or " ", name,
            builtin[name] and "built-in" or "runtime",
            tostring(map.title or map.name), total,
            #(map.landings or {}), #(map.lootClusters or {})))
    end
end

local function cmdNew(source, raw, args)
    local name = cleanName(argAt(args, 1), 32)
    if name == nil then
        return reply(source, raw, false, "usage: /br.map new <name> [title]  (name is lowercase a-z0-9_-)")
    end
    if store[name] ~= nil then
        return reply(source, raw, false, ("'%s' already exists"):format(name))
    end
    if #mapNames() >= math.floor(number("maxMaps")) then
        return reply(source, raw, false, ("the store holds at most %d maps"):format(math.floor(number("maxMaps"))))
    end
    local map = blankMap(name, cleanLabel(argRest(args, 2), 64), active())
    rebuildProgress(map)
    store[name] = map
    persist(map)
    reply(source, raw, true, ("map '%s' created (grid inherited from '%s'). " ..
        "Next: /br.map select %s  then  /br.map origin"):format(
        name, tostring(active() and active().name), name))
end

local function cmdCopy(source, raw, args)
    local from = cleanName(argAt(args, 1), 32)
    local to = cleanName(argAt(args, 2), 32)
    if from == nil or to == nil or store[from] == nil then
        return reply(source, raw, false, ("usage: /br.map copy <from> <to> -- have: %s"):format(nameList()))
    end
    if store[to] ~= nil then return reply(source, raw, false, ("'%s' already exists"):format(to)) end
    local copy = normalizeMap(serialize(store[from]), to)
    copy.title = (store[from].title or from) .. " (copy)"
    store[to] = copy
    persist(copy)
    reply(source, raw, true, ("'%s' copied to '%s'. /br.map select %s to play it"):format(from, to, to))
end

local function cmdSelect(source, raw, args)
    local name = cleanName(argAt(args, 1), 32)
    if name == nil or store[name] == nil then
        return reply(source, raw, false, ("usage: /br.map select <name> -- have: %s"):format(nameList()))
    end
    -- REFUSED MID-MATCH, and it is not caution. `apply` replaces the geometry
    -- every consumer reads at the point of use: `C.begin` has already built a
    -- closure schedule from the old grid, squads hold pins into the old landing
    -- list and the loot on the ground was seeded from the old anchors. Swapping
    -- under that is not a map change, it is a match nobody can finish.
    if M ~= nil and type(M.phase) == "function" and M.phase() ~= "staging" then
        return reply(source, raw, false, ("refused: the match is in phase '%s'. /br.end first")
            :format(tostring(M.phase())))
    end
    apply(store[name])
    local ok, reason = persistActiveName(name)
    reply(source, raw, true, ("active map = '%s' (%s) surveyed=%s%s"):format(
        name, tostring(store[name].title), tostring(K.map.surveyed),
        ok and "" or (" -- NOT PERSISTED: " .. tostring(reason) ..
            ", so a restart reverts to the tunable's value")))
end

local function cmdRename(source, raw, args)
    local from = cleanName(argAt(args, 1), 32)
    local to = cleanName(argAt(args, 2), 32)
    if from == nil or to == nil or store[from] == nil then
        return reply(source, raw, false, ("usage: /br.map rename <from> <to> -- have: %s"):format(nameList()))
    end
    if builtin[from] then return reply(source, raw, false, "a built-in cannot be renamed; copy it instead") end
    if store[to] ~= nil then return reply(source, raw, false, ("'%s' already exists"):format(to)) end
    local map = store[from]
    store[from] = nil
    K.builtinMaps[from] = nil
    map.name = to
    store[to] = map
    if activeName == from then
        apply(map)
        persistActiveName(to)
    end
    persist(map, from)
    reply(source, raw, true, ("'%s' renamed to '%s'"):format(from, to))
end

local function cmdTitle(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    local title = cleanLabel(argRest(args, 1), 64)
    if title == nil then return reply(source, raw, false, "usage: /br.map title <text>") end
    map.title = title
    touch(map)
    persist(map)
    reply(source, raw, true, ("'%s' is now titled %q"):format(map.name, title))
end

local function cmdDeleteMap(source, raw, args)
    local name = cleanName(argAt(args, 1), 32)
    if name == nil or store[name] == nil then
        return reply(source, raw, false, ("usage: /br.map delete <name> -- have: %s"):format(nameList()))
    end
    if builtin[name] then return reply(source, raw, false, "a built-in cannot be deleted") end
    if name == activeName then
        return reply(source, raw, false, "that is the active map; /br.map select something else first")
    end
    store[name] = nil
    K.builtinMaps[name] = nil
    persist(nil, name)
    reply(source, raw, true, ("'%s' deleted"):format(name))
end

local function cmdProbed(source, raw, args)
    local map = editable(source, raw)
    if map == nil then return end
    map.provisional = not truthy(argAt(args, 1) or "1")
    touch(map)
    persist(map)
    reply(source, raw, true, ("'%s' provisional=%s. Provisional means the coordinates are derived rather " ..
        "than walked; a provisional map runs and says so in every readout.")
        :format(map.name, tostring(map.provisional)))
end


-- ------------------------------------------------------------------ check --
--
-- The five things `K.recomputeSurveyed()` demands, NAMED. A bare false is what
-- this verb exists to replace: the mode used to start, log "map is NOT
-- surveyed", refuse to place anybody, and never say which of the five was
-- missing.

local function cmdCheck(source, raw)
    local map = active()
    if map == nil then return reply(source, raw, false, "no active map") end
    local grid = map.grid or {}

    reply(source, raw, true, ("check '%s' (%s) -- %s"):format(map.name,
        builtin[map.name] and "built-in" or "runtime", storageLine()))

    local blocking = {}
    if grid.origin == nil then
        blocking[#blocking + 1] = "grid.origin -- stand at the SW corner and run /br.map origin"
    end
    if grid.groundDefault == nil then
        blocking[#blocking + 1] = "grid.groundDefault -- /br.map ground <z>, the MEDIAN of the walked points"
    end
    if map.staging == nil or map.staging.position == nil then
        blocking[#blocking + 1] = "staging anchor -- stand in the lobby and run /br.map add stage"
    end
    if #(map.landings or {}) == 0 then
        blocking[#blocking + 1] = "at least one landing zone -- /br.map add land <label>"
    end
    if #(map.finalBlocks or {}) == 0 then
        blocking[#blocking + 1] = "at least one final block -- stand in it and run /br.map final add"
    end

    if #blocking == 0 then
        reply(source, raw, true, "SURVEYED: staging and deploy will run. The five hard requirements are met.")
    else
        reply(source, raw, false, ("NOT SURVEYED -- staging and deploy will REFUSE. %d missing:"):format(#blocking))
        for _, item in ipairs(blocking) do reply(source, raw, false, "  missing: " .. item) end
    end

    -- Soft findings: the map runs, but it will not play the way somebody expects.
    local notes = {}
    if #(map.lootClusters or {}) == 0 then
        notes[#notes + 1] = "no loot points: the district will be EMPTY (L.seed warns and seeds nothing)"
    end
    local tiers = #tierList()
    for index, point in ipairs(map.lootClusters or {}) do
        local tier = math.floor(tonumber(point.tier) or 1)
        if tiers > 0 and (tier < 1 or tier > tiers) then
            notes[#notes + 1] = ("loot #%d has tier %d, outside 1..%d -- L.seed will clamp it")
                :format(index, tier, tiers)
        end
    end

    -- Every point that is outside the grid. A landing zone out there drops a
    -- squad into permanent cordon damage; a loot point out there is unreachable.
    local outside, checked = 0, 0
    for _, entry in ipairs(KINDS) do
        if not entry.singleton then
            for index, point in ipairs(map[entry.field] or {}) do
                checked = checked + 1
                local col = Grid.cellOf(grid, point.position.x, point.position.y)
                if col == nil then
                    outside = outside + 1
                    if outside <= 8 then
                        notes[#notes + 1] = ("%s #%d (%s) is OUTSIDE the grid at %.1f %.1f")
                            :format(entry.key, index, tostring(point.key),
                                point.position.x, point.position.y)
                    end
                end
            end
        end
    end
    if outside > 8 then
        notes[#notes + 1] = ("...and %d more points outside the grid"):format(outside - 8)
    end

    -- The staging anchor is SUPPOSED to be off the map: it runs in its own
    -- routing bucket. Say so rather than reporting it as an error.
    if map.staging ~= nil and map.staging.position ~= nil then
        local col = Grid.cellOf(grid, map.staging.position.x, map.staging.position.y)
        reply(source, raw, true, ("staging: %.1f %.1f %.1f (%s -- it runs in its own bucket, so either is fine)")
            :format(map.staging.position.x, map.staging.position.y, map.staging.position.z,
                col ~= nil and "inside the grid" or "off the grid"))
    end

    -- LANDING SPREAD AGAINST THE LOBBY THIS SERVER ACTUALLY STARTS WITH.
    -- `M.landingFor` picks a landing zone at random per squad, so with twelve
    -- zones and two squads the whole match can be two people at opposite ends of
    -- the district. `Config.match.minPlayers` is 2 here and `startAtPlayers` 5.
    local landings = map.landings or {}
    if #landings >= 2 then
        local widest = 0.0
        for i = 1, #landings do
            for j = i + 1, #landings do
                local gap = distance2D(landings[i].position, landings[j].position)
                if gap > widest then widest = gap end
            end
        end
        local floor = math.floor(tonumber(type(Config) == "table" and Config.match
            and Config.match.minPlayers) or 2)
        reply(source, raw, true, ("landings: %d, widest separation %.0f m, minPlayers=%d")
            :format(#landings, widest, floor))
        if floor <= 8 and #landings > 4 and widest > 250.0 then
            notes[#notes + 1] = ("%d landing zones %.0f m apart for a lobby that starts at %d: a small match " ..
                "will scatter and nobody will find anybody. Delete down to 2-3 zones for test matches, " ..
                "or pod them with /br.map spread land 2 40"):format(#landings, widest, floor)
        end
    end

    for _, entry in ipairs(KINDS) do
        if entry.live == false and not entry.singleton and #(map[entry.field] or {}) > 0 then
            notes[#notes + 1] = ("%d %s(s) captured but %s"):format(
                #(map[entry.field] or {}), entry.key, tostring(entry.liveNote))
        end
    end

    for index, point in ipairs(map.vehicles or {}) do
        if point.record == nil then
            notes[#notes + 1] = ("vehicle #%d (%s) has no record -- /br.map set veh %d record <TweakDB id>")
                :format(index, tostring(point.key), index)
        end
    end

    reply(source, raw, true, ("%d point(s) checked, %d outside the grid, %d note(s)")
        :format(checked, outside, #notes))
    for _, note in ipairs(notes) do reply(source, raw, true, "  note: " .. note) end
end


-- ----------------------------------------------------------------- export --
--
-- The promotion path back into source control, and the only real answer to a
-- volatile store: `export` prints the active map as a complete map file, in the
-- exact shape `shared/watson.lua` has, so a finished runtime map is pasted in,
-- becomes a BUILT-IN, and stops depending on any store at all.

local function luaPoint(point)
    return ("{ x = %.3f, y = %.3f, z = %.3f }"):format(
        point.x, point.y, point.z)
end

local function cmdExport(source, raw, args)
    local name = cleanName(argAt(args, 1), 32) or activeName
    local map = name ~= nil and store[name] or nil
    if map == nil then
        return reply(source, raw, false, ("unknown map %q -- have: %s")
            :format(tostring(argAt(args, 1) or ""), nameList()))
    end
    -- `Watson` / `Pacifica`: the global a map file declares is its name with the
    -- first letter capitalised, and `K.builtinMaps` keys it by the lowercase.
    local globalName = map.name:sub(1, 1):upper() .. map.name:sub(2):gsub("[^%w]", "")

    local lines = {}
    local function emit(text) lines[#lines + 1] = text or "" end

    emit(("-- ==== /br.map export %s ================================"):format(map.name))
    emit("-- Captured from Open77.players.position on the server, in-world.")
    emit(("-- Save as resources/gamemodes/open77_cordon/shared/%s.lua, add"):format(map.name))
    emit(("--   shared_script \"shared/%s.lua\""):format(map.name))
    emit("-- to open77.lua (before the server scripts), and add it to K.builtinMaps")
    emit("-- in server/main.lua:")
    emit(("--   K.builtinMaps = { pacifica = Pacifica, watson = Watson, %s = %s }")
        :format(map.name, globalName))
    emit("")
    emit(("%s = %s or {}"):format(globalName, globalName))
    emit("")
    emit(("%s.name = %q"):format(globalName, map.name))
    emit(("%s.title = %q"):format(globalName, tostring(map.title or map.name)))
    emit(("-- Recomputed by K.recomputeSurveyed() on every load; the value here is a hint."))
    emit(("%s.surveyed = %s"):format(globalName, tostring(map.surveyed == true)))
    emit(("%s.provisional = %s"):format(globalName, tostring(map.provisional == true)))
    emit("")

    emit(("%s.grid = {"):format(globalName))
    emit(("    origin = %s,"):format(map.grid.origin and luaPoint(map.grid.origin) or "nil,  -- TODO"))
    emit(("    blockMetres = %.1f,"):format(map.grid.blockMetres))
    emit(("    cols = %d,"):format(map.grid.cols))
    emit(("    rows = %d,"):format(map.grid.rows))
    emit(("    floorMargin = %.1f,"):format(map.grid.floorMargin))
    emit(("    ceilingMargin = %.1f,"):format(map.grid.ceilingMargin))
    if map.grid.groundDefault ~= nil then
        emit(("    groundDefault = %.3f,"):format(map.grid.groundDefault))
    else
        emit("    groundDefault = nil,  -- TODO: REQUIRED, the map refuses to stage without it")
    end
    emit("    ground = {")
    local cells = {}
    for key in pairs(map.grid.ground or {}) do cells[#cells + 1] = key end
    table.sort(cells)
    for _, key in ipairs(cells) do
        emit(("        [%q] = %.3f,"):format(key, map.grid.ground[key]))
    end
    emit("    },")
    emit("}")
    emit("")

    if map.staging ~= nil and map.staging.position ~= nil then
        emit(("%s.staging = { position = %s, heading = %.1f, radius = %.1f }"):format(
            globalName, luaPoint(map.staging.position),
            tonumber(map.staging.heading) or 0.0, tonumber(map.staging.radius) or 12.0))
    else
        emit(("%s.staging = nil  -- TODO: REQUIRED"):format(globalName))
    end
    emit("")

    for _, entry in ipairs(KINDS) do
        if not entry.singleton then
            emit(("%s.%s = {"):format(globalName, entry.field))
            for _, point in ipairs(map[entry.field] or {}) do
                local extras = {}
                for _, option in ipairs(entry.options or {}) do
                    local value = point[option.name]
                    if value ~= nil then
                        if option.kind == "text" then
                            extras[#extras + 1] = ("%s = %q"):format(option.name, tostring(value))
                        elseif option.kind == "bool" then
                            extras[#extras + 1] = ("%s = %s"):format(option.name, tostring(value))
                        elseif option.kind == "int" or option.kind == "tier" then
                            extras[#extras + 1] = ("%s = %d"):format(option.name, math.floor(value))
                        else
                            extras[#extras + 1] = ("%s = %.1f"):format(option.name, value)
                        end
                    end
                end
                extras[#extras + 1] = ("probed = %s"):format(tostring(point.probed == true))
                if point.grounded == true then extras[#extras + 1] = "grounded = true" end
                emit(("    { key = %q, position = %s, %s },%s"):format(
                    tostring(point.key), luaPoint(point.position), table.concat(extras, ", "),
                    point.headingKnown == false and "  -- heading not captured" or ""))
            end
            emit("}")
        end
    end
    emit("")

    local function keyList(list)
        local parts = {}
        for index, key in ipairs(list or {}) do parts[index] = ("%q"):format(key) end
        return table.concat(parts, ", ")
    end
    emit(("%s.finalBlocks = { %s }"):format(globalName, keyList(map.finalBlocks)))
    emit(("%s.excluded = { %s }"):format(globalName, keyList(map.excluded)))
    emit("")
    emit(("%s.progress = {"):format(globalName))
    for _, item in ipairs(map.progress or {}) do
        emit(("    { key = %q, need = %d, what = %q },"):format(item.key, item.need, item.what))
    end
    emit("}")
    emit("")
    emit(("return %s"):format(globalName))
    emit("-- ==== end of export ===================================")

    for _, line in ipairs(lines) do reply(source, raw, true, line) end
end


-- ------------------------------------------------------------ store verbs --

local function cmdStore(source, raw)
    reply(source, raw, true, ("store: %s"):format(storageLine()))
    reply(source, raw, true, ("maps=%d active=%s"):format(#mapNames(), tostring(activeName)))
    reply(source, raw, true, ("  files    %-4s data/%s/   %s"):format(
        fsReady == true and "on" or "OFF", mapDirectory(), fsReason))
    reply(source, raw, true, ("  database %-4s %s   %s"):format(
        dbReady == true and "on" or "OFF", tableName(), dbReason))
    reply(source, raw, true, ("  bridge   %-4s carried bag (survives a reload, not a restart)"):format(
        (type(Open77.state) == "table" and type(Open77.state.save) == "function") and "on" or "OFF"))
    reply(source, raw, true, ("  tunable  %-4s activeMap (which map this server plays)"):format(
        (type(Open77.tunables) == "table" and type(Open77.tunables.set) == "function") and "on" or "OFF"))
    if fsReady ~= true and dbReady ~= true then
        reply(source, raw, false, "NO DURABLE TIER. The geometry survives a HOT RELOAD (carried bag) " ..
            "but NOT a server restart. /br.map export and paste it into shared/<name>.lua.")
    end
end

local function cmdSave(source, raw)
    local map = active()
    if map == nil then return reply(source, raw, false, "no active map") end
    if builtin[map.name] then return reply(source, raw, false, "a built-in has nothing to save") end
    persist(map)
    reply(source, raw, true, ("'%s' queued for save -- %s"):format(map.name, storageLine()))
end

--- Re-read a durable tier, REPLACING what this VM holds.
---
--- That is the one difference from the load-time read, and it is the whole
--- point of the verb: at load each tier only fills the gaps the previous one
--- left, because the carried bag is newer than any store. An operator running
--- `reload` is explicitly asking for the stored version to win instead.
---
--- The active map is re-applied afterwards because a replace swaps the RECORD
--- OBJECT in the store, and `K.map` would otherwise still point at the table
--- that was just superseded.
local function cmdReload(source, raw, args)
    local which = tostring(argAt(args, 1) or "all"):lower()
    if which == "database" then which = "db" end
    if which ~= "all" and which ~= "files" and which ~= "db" then
        return reply(source, raw, false, "usage: /br.map reload [all|files|db]")
    end

    if which == "all" or which == "files" then
        local loaded = readFiles(true)
        if activeName ~= nil and store[activeName] ~= nil then apply(store[activeName]) end
        reply(source, raw, true, ("files: %d map(s) re-read from data/%s/")
            :format(loaded, mapDirectory()))
    end
    if which == "all" or which == "db" then
        enqueue(function()
            local loaded = readAll(true)
            if activeName ~= nil and store[activeName] ~= nil then apply(store[activeName]) end
            reply(source, raw, true, ("database: %d map(s) re-read -- %s")
                :format(loaded, storageLine()))
        end)
        reply(source, raw, true, "database re-read queued")
    end
end


-- -------------------------------------------------------------------- help --

local HELP = {
    "/br.map -- the Cordon map editor. RESTRICTED (command.br.map).",
    "  MAPS    list | show | new <name> [title] | copy <from> <to> | select <name>",
    "          rename <from> <to> | title <text> | delete <name> | probed [0|1]",
    "  POINTS  add <kind> [opts] | move <kind> <ref> | del <kind> <ref|all>",
    "          set <kind> <ref> <field> <value> | points [kind] | near [kind] | count",
    "  BULK    paint <kind> [everyM] [opts] | paint off | spread <kind> <n> [radius]",
    "  GRID    origin | grid <cols> <rows> [blockM] | ground [<z>|cell|clear]",
    "          final add|del|list [cell] | exclude add|del|list [cell]",
    "  STATE   check | export [name] | store | save | reload [all|files|db]",
    "  Kinds:  spawn land loot veh stage mark supply hold exit",
    "  add loot rare 1 0   -- one rare crate here.  add loot street 12 18 -- a cluster.",
    "  add land \"Market\" | add veh v_standard2_villefort_cortes_dcaf5c 90 | add stage 0 12",
    "  Every capture reads YOUR position on the server; heading is a trailing argument.",
}

local function cmdHelp(source, raw)
    for _, line in ipairs(HELP) do reply(source, raw, true, line) end
end

local function cmdShow(source, raw, args)
    local name = cleanName(argAt(args, 1), 32) or activeName
    local map = name ~= nil and store[name] or nil
    if map == nil then
        return reply(source, raw, false, ("unknown map -- have: %s"):format(nameList()))
    end
    reply(source, raw, true, ("'%s' (%s) title=%q active=%s surveyed=%s provisional=%s"):format(
        map.name, builtin[map.name] and "built-in" or "runtime", tostring(map.title),
        tostring(map.name == activeName), tostring(map.surveyed), tostring(map.provisional)))
    reply(source, raw, true, ("grid %dx%d at %.0f m, origin=%s, groundDefault=%s, %d cell override(s)"):format(
        map.grid.cols, map.grid.rows, map.grid.blockMetres,
        map.grid.origin and ("%.1f,%.1f,%.1f"):format(map.grid.origin.x, map.grid.origin.y, map.grid.origin.z)
            or "MISSING",
        tostring(map.grid.groundDefault),
        (function() local n = 0 for _ in pairs(map.grid.ground or {}) do n = n + 1 end return n end)()))
    cmdCount(source, raw)
end


-- ---------------------------------------------------------------- dispatch --

-- The verbs that read the CALLER'S OWN POSITION. They are the only ones a
-- console cannot answer, because the console is not standing anywhere -- and
-- refusing them by name is better than letting `K.position(0)` decide what that
-- means.
local CAPTURES = {
    add = true, move = true, origin = true, ground = true,
    paint = true, near = true, final = true, exclude = true,
}

local DISPATCH = {
    help = cmdHelp,
    list = cmdList,
    show = cmdShow,
    new = cmdNew,
    copy = cmdCopy,
    select = cmdSelect,
    rename = cmdRename,
    title = cmdTitle,
    delete = cmdDeleteMap,
    probed = cmdProbed,

    add = cmdAdd,
    move = cmdMove,
    del = cmdDelete,
    remove = cmdDelete,
    set = cmdSet,
    points = cmdPoints,
    near = cmdNear,
    count = cmdCount,

    paint = cmdPaint,
    spread = cmdSpread,

    origin = cmdOrigin,
    grid = cmdGrid,
    ground = cmdGround,
    final = function(source, raw, args) cellListVerb(source, raw, args, "finalBlocks", "final blocks") end,
    exclude = function(source, raw, args) cellListVerb(source, raw, args, "excluded", "excluded cells") end,

    check = cmdCheck,
    export = cmdExport,
    store = cmdStore,
    save = cmdSave,
    reload = cmdReload,
}

-- RESTRICTED. The third argument of RegisterCommand IS the gate, and nothing
-- inside re-checks it, so nothing inside can forget to. See the header.
RegisterCommand("br.map", function(source, args, raw)
    local caller = tonumber(source) or 0
    local verb = tostring((args and args[1]) or ""):lower()
    if verb == "" then return cmdHelp(caller, raw) end

    local handler = DISPATCH[verb]
    if handler == nil then
        return reply(caller, raw, false, ("unknown verb %q -- /br.map for the list"):format(verb))
    end
    if CAPTURES[verb] and caller <= 0 then
        return reply(0, raw, false, verb .. " reads your own position and cannot answer for the console")
    end

    -- Hand the subcommand its own arguments, one-based, so each reads as if it
    -- were the whole command.
    local count = tonumber(args and args.n) or #(args or {})
    local rest = { n = math.max(0, count - 1) }
    for index = 2, count do rest[index - 1] = args[index] end
    handler(caller, raw, rest)
end, true)


-- =========================================================== hand-placed cars

-- The one list this file CONSUMES rather than merely stores, because nothing
-- else does yet: `map.vehicles` has been in both shipped maps since they were
-- written and no code has ever read it.
--
-- Spawned when the match goes live and removed when it leaves, in the match
-- bucket, so a car cannot appear in the staging dimension. `Open77.vehicles.remove`
-- is owner-scoped by the host, so this can only ever remove its own.
--
-- COOPERATIVE, and deliberately easy to switch off: if a proper vehicle module
-- lands in this resource (`Cordon.vehicles`), this stands down on its own rather
-- than double-spawning, and `editor.spawnVehicles = false` stops it by hand.

local spawnedVehicles = {}

local function clearVehicles()
    if #spawnedVehicles == 0 then return end
    if type(Open77.vehicles) ~= "table" or type(Open77.vehicles.remove) ~= "function" then
        spawnedVehicles = {}
        return
    end
    local removed = 0
    for _, id in ipairs(spawnedVehicles) do
        local ok, gone = pcall(Open77.vehicles.remove, id)
        if ok and gone ~= false then removed = removed + 1 end
    end
    spawnedVehicles = {}
    if removed > 0 then log(("removed %d hand-placed vehicle(s)"):format(removed)) end
end

local function spawnVehicles()
    clearVehicles()
    if setting("spawnVehicles") == false then return end
    if K.vehicles ~= nil then
        log("a Cordon.vehicles module exists, so the editor is standing down from spawning cars")
        return
    end
    local map = K.map
    local list = (type(map) == "table" and map.vehicles) or {}
    if #list == 0 then return end
    if type(Open77.vehicles) ~= "table" or type(Open77.vehicles.create) ~= "function" then
        return warn("this server exposes no vehicle binding; hand-placed cars are stored but not spawned")
    end

    local made, failed = 0, 0
    for _, point in ipairs(list) do
        if point.record ~= nil and point.position ~= nil then
            local ok, id = pcall(Open77.vehicles.create, {
                record = point.record,
                position = point.position,
                yaw = tonumber(point.heading) or 0.0,
                bucket = K.matchBucket(),
            })
            if ok and id ~= nil then
                spawnedVehicles[#spawnedVehicles + 1] = id
                made = made + 1
            else
                failed = failed + 1
            end
        else
            failed = failed + 1
        end
    end
    log(("hand-placed vehicles: %d spawned, %d refused (missing record, or the create was rejected)")
        :format(made, failed))
end

AddEventHandler("cordon:phase", function(target)
    if target == "live" then
        local ok, err = pcall(spawnVehicles)
        if not ok then warn("vehicle spawn failed: " .. tostring(err)) end
    elseif target == "staging" then
        pcall(clearVehicles)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local id = tonumber(playerIdStr)
    if id ~= nil then stopPaint(id, "disconnect") end
end)


-- ================================================================= startup ==
--
-- Order matters and it is the reverse of intuition. The carried bag is adopted
-- SYNCHRONOUSLY, before anything else can read `K.map`, so a hot reload comes
-- back up on the authored map rather than on the built-in and then flipping.
-- The database read is a coroutine and necessarily lands later; it fills in maps
-- the bag could not carry and re-selects the active one if only the database had
-- it.

local adopted = adoptCarried()
-- FILES SECOND, and gaps only: the bag is this VM's predecessor's memory and is
-- therefore newer than anything on disk. This read is SYNCHRONOUS -- `Open77.io`
-- does not yield -- so a map that exists only on disk is already in the store by
-- the time the `activeMap` tunable is resolved below, and can be selected on the
-- first tick rather than after a coroutine lands.
local fromFiles = readFiles(false)
-- Carried/file edits win synchronously. An existing database draft may replace
-- this untouched seed when its asynchronous read returns.
if store.dogtown == nil and type(Dogtown) == "table" then
    store.dogtown = normalizeMap(Dogtown, "dogtown")
    starterSeeds.dogtown = store.dogtown
end
activeName = type(K.map) == "table" and K.map.name or nil

local wanted = cleanName(K.tune("activeMap", nil), 32)
if wanted ~= nil and store[wanted] ~= nil then
    apply(store[wanted])
elseif type(K.map) == "table" then
    -- Whatever main.lua resolved stays. Registered so `select` and `list` can
    -- see it under its own name.
    activeName = K.map.name
    store[K.map.name] = K.map
end

CreateThread(function() enqueue(readAll) end)

AddEventHandler("onTunableChanged", function(key, value)
    if tostring(key) ~= "activeMap" then return end
    local name = cleanName(value, 32)
    if name == nil or store[name] == nil or name == activeName then return end
    if M ~= nil and type(M.phase) == "function" and M.phase() ~= "staging" then
        return warn(("the tunables panel selected '%s' during phase '%s' -- ignored until staging")
            :format(name, tostring(M.phase())))
    end
    apply(store[name])
    log(("active map changed to '%s' from the tunables panel"):format(name))
end)

log(("ready -- /br.map (restricted). %d map(s), active '%s', surveyed=%s%s%s. %s"):format(
    #mapNames(), tostring(activeName), tostring(K.map and K.map.surveyed),
    adopted > 0 and (", %d adopted across a reload"):format(adopted) or "",
    fromFiles > 0 and (", %d read from disk"):format(fromFiles) or "",
    storageLine()))
