-- rp_cargo/server/layout.lua: cargo layouts as data (row A9 of the world-interaction plan).
--
-- Pure Lua, no native: validation of data/layouts.json, slot offsets in the vehicle frame,
-- slot allocation and stacking, projection placements, and the JSON the lab prints for pasting
-- back into the data file. Global table RpCargoLayout.
--
-- Vehicle frame of Open77.props.attach with a root binding ("" bone): +x right, +y forward
-- (towards the cab), +z up, yaw in degrees around z. A slot holds up to `maxStack` objects, each
-- layer `stackHeight` metres above the previous one. Every shipped number is a starting guess
-- (`measured = false`) until someone measured it in game.

RpCargoLayout = {}
local L = RpCargoLayout

L.LIMITS = {
    offset = 20.0,        -- Open77.props.attach: each offset component within +-20 m
    yaw = 360.0,          -- rotation components within +-360 degrees
    stackHeight = 3.0,
    maxStack = 8,
    maxSlots = 32,
    -- A vehicle parent takes at most 32 attached props across ALL resources (wiki/attachments.md);
    -- a layout keeps 8 for the others (lights, signs, carried tools).
    maxObjects = 24,
    capacityKg = 100000,
}

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function integer(v)
    return finite(v) and v % 1 == 0
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
L.copy = copy

-- One layout entry -> normalized layout | nil, { problems }. `defaults` fills missing slot fields.
function L.normalize(record, raw, defaults)
    defaults = defaults or {}
    local problems = {}
    local function bad(fmt, ...) problems[#problems + 1] = (fmt):format(...) end
    if type(record) ~= "string" or not record:match("^Vehicle%.[%w_]+$") then bad("invalid record id %s", tostring(record)) end
    if type(raw) ~= "table" then
        bad("layout is not an object")
        return nil, problems
    end
    local layout = {
        record = record,
        label = type(raw.label) == "string" and raw.label or record,
        part = raw.part or defaults.part or "cargo",
        model = raw.model or defaults.model or "crate.small",
        capacityKg = raw.capacityKg,
        measured = raw.measured == true,
        basis = type(raw.basis) == "string" and raw.basis or "",
        entityTemplate = type(raw.entityTemplate) == "string" and raw.entityTemplate or "",
        aliases = {},
        slots = {},
        slotById = {},
    }
    if type(layout.part) ~= "string" or not layout.part:match("^[a-z]+$") then bad("invalid part %s", tostring(layout.part)) end
    if type(layout.model) ~= "string" or layout.model == "" then bad("invalid model") end
    if not finite(layout.capacityKg) or layout.capacityKg <= 0 or layout.capacityKg > L.LIMITS.capacityKg then
        bad("capacityKg must be a number in (0, %d]", L.LIMITS.capacityKg)
    end
    for _, alias in ipairs(type(raw.aliases) == "table" and raw.aliases or {}) do
        if type(alias) == "string" and alias:match("^Vehicle%.[%w_]+$") then
            layout.aliases[#layout.aliases + 1] = alias
        else
            bad("invalid alias %s", tostring(alias))
        end
    end
    if type(raw.slots) ~= "table" or #raw.slots == 0 then bad("no slots") end
    local objects, allMeasured = 0, true
    for i, s in ipairs(type(raw.slots) == "table" and raw.slots or {}) do
        local slot = {
            id = s.id,
            x = s.x, y = s.y, z = s.z,
            yaw = s.yaw == nil and 0.0 or s.yaw,
            stackHeight = s.stackHeight == nil and defaults.stackHeight or s.stackHeight,
            maxStack = s.maxStack == nil and defaults.maxStack or s.maxStack,
            measured = s.measured == true,
        }
        if not integer(slot.id) or slot.id < 1 then bad("slot %d: id must be a positive integer", i)
        elseif layout.slotById[slot.id] then bad("slot %d: duplicate id %s", i, tostring(slot.id)) end
        for _, axis in ipairs({ "x", "y", "z" }) do
            if not finite(slot[axis]) or math.abs(slot[axis]) > L.LIMITS.offset then
                bad("slot %s: %s must be a number within +-%g m", tostring(slot.id), axis, L.LIMITS.offset)
            end
        end
        if not finite(slot.yaw) or math.abs(slot.yaw) > L.LIMITS.yaw then bad("slot %s: yaw out of range", tostring(slot.id)) end
        if not finite(slot.stackHeight) or slot.stackHeight <= 0 or slot.stackHeight > L.LIMITS.stackHeight then
            bad("slot %s: stackHeight must be in (0, %g]", tostring(slot.id), L.LIMITS.stackHeight)
        end
        if not integer(slot.maxStack) or slot.maxStack < 1 or slot.maxStack > L.LIMITS.maxStack then
            bad("slot %s: maxStack must be an integer in [1, %d]", tostring(slot.id), L.LIMITS.maxStack)
        else
            objects = objects + slot.maxStack
        end
        if not slot.measured then allMeasured = false end
        if integer(slot.id) then layout.slotById[slot.id] = slot end
        layout.slots[#layout.slots + 1] = slot
    end
    if #layout.slots > L.LIMITS.maxSlots then bad("more than %d slots", L.LIMITS.maxSlots) end
    if objects > L.LIMITS.maxObjects then
        bad("%d objects (slots x maxStack) exceed %d: a vehicle carries at most 32 attached props across resources", objects, L.LIMITS.maxObjects)
    end
    if layout.measured and not allMeasured then bad("measured is true but some slots are not measured") end
    if #problems > 0 then return nil, problems end
    layout.objects = objects
    return layout
end

-- The decoded data file -> registry { layouts = { [record] = layout }, aliases = { [alias] = record },
-- problems = { "record: problem", ... } }. A layout with a problem is left out, never half-loaded.
function L.load(doc)
    local registry = { layouts = {}, aliases = {}, problems = {} }
    if type(doc) ~= "table" or type(doc.layouts) ~= "table" then
        registry.problems[1] = "data file: no `layouts` object"
        return registry
    end
    if doc.schema ~= 1 then registry.problems[#registry.problems + 1] = "data file: unknown schema " .. tostring(doc.schema) end
    local records = {}
    for record in pairs(doc.layouts) do records[#records + 1] = record end
    table.sort(records)
    for _, record in ipairs(records) do
        local layout, problems = L.normalize(record, doc.layouts[record], doc.defaults)
        if layout then
            registry.layouts[record] = layout
        else
            for _, p in ipairs(problems) do registry.problems[#registry.problems + 1] = record .. ": " .. p end
        end
    end
    for _, record in ipairs(records) do
        local layout = registry.layouts[record]
        for _, alias in ipairs(layout and layout.aliases or {}) do
            if registry.layouts[alias] or registry.aliases[alias] then
                registry.problems[#registry.problems + 1] = record .. ": alias " .. alias .. " is already a layout"
            else
                registry.aliases[alias] = record
            end
        end
    end
    return registry
end

-- The layout of a record (directly or through an alias), or nil.
function L.find(registry, record)
    if type(record) ~= "string" then return nil end
    local layout = registry.layouts[record]
    if layout then return layout end
    local base = registry.aliases[record]
    return base and registry.layouts[base] or nil
end

-- Attachment offset and rotation of the object at `rank` (1 = on the bed floor) of a slot.
function L.offset(layout, slotId, rank)
    local s = layout.slotById[slotId]
    if not s then return nil end
    rank = rank or 1
    return { x = s.x, y = s.y, z = s.z + (rank - 1) * s.stackHeight }, { x = 0.0, y = 0.0, z = s.yaw }
end

local function bySlot(layout, occupants)
    local slots, loose = {}, {}
    for _, o in ipairs(occupants) do
        if o.slot ~= nil and layout.slotById[o.slot] then
            slots[o.slot] = slots[o.slot] or {}
            table.insert(slots[o.slot], o)
        else
            loose[#loose + 1] = o
        end
    end
    for _, list in pairs(slots) do
        table.sort(list, function(a, b)
            local la, lb = tonumber(a.layer) or 0, tonumber(b.layer) or 0
            if la ~= lb then return la < lb end
            return tostring(a.instance or "") < tostring(b.instance or "")
        end)
    end
    return slots, loose
end

-- The least-filled slot with room, ties in layout order: the bed floor fills first, then the
-- second layer (as rp_nomade wraps crates over its bed slots). `count` = { [slotId] = n }.
local function floorFirst(layout, count)
    local best
    for _, s in ipairs(layout.slots) do
        local n = count[s.id] or 0
        if n < s.maxStack and (best == nil or n < (count[best.id] or 0)) then best = s end
    end
    return best
end

-- Picks where the next object goes. `occupants` = { { slot, layer }, ... } including claims still
-- in flight. Returns slotId, layer | nil, reason (cargo_full | slot_full | invalid_slot).
-- The stored `layer` only orders a stack (max + 1); the projection uses the rank, so a gap left
-- by an unloaded bottom crate never leaves a floating crate.
function L.allocate(layout, occupants, wantSlot)
    local slots = bySlot(layout, occupants)
    local function top(id)
        local t = 0
        for _, o in ipairs(slots[id] or {}) do t = math.max(t, tonumber(o.layer) or 0) end
        return t
    end
    if wantSlot ~= nil then
        local s = layout.slotById[tonumber(wantSlot) or -1]
        if not s then return nil, "invalid_slot" end
        if #(slots[s.id] or {}) >= s.maxStack then return nil, "slot_full" end
        return s.id, top(s.id) + 1
    end
    local count = {}
    for id, list in pairs(slots) do count[id] = #list end
    local s = floorFirst(layout, count)
    if not s then return nil, "cargo_full" end
    return s.id, top(s.id) + 1
end

-- Where every occupant is drawn. occupants = { { instance, slot?, layer? }, ... }.
-- Returns placements { [instance] = { slot, rank, offset, rotation } } and the instances that do
-- not fit (more objects than the layout holds: they stay in the account, undrawn).
-- Deterministic: stacks ordered by (layer, instance); slotless or overflowing objects take the
-- least-filled slot (floor first, layout order), by instance id.
-- `heights` (optional): model alias -> the height a box of that model takes in a stack. A slot's
-- `stackHeight` was measured with one model (crate.small); a shorter box stacked at that height
-- floats above the one under it. A stack then rises by the heights of the boxes below.
-- `seats` (optional): model alias -> how far that model's origin sits from a crate.small's when both
-- rest on the same floor (a slot's z is measured with crate.small). Without it, a box whose origin
-- is at its base hangs above the bed by the difference.
function L.placements(layout, occupants, heights, seats)
    local slots, loose = bySlot(layout, occupants)
    local placements, count, hidden, top = {}, {}, {}, {}
    local function place(s, o, reassigned)
        count[s.id] = count[s.id] + 1
        local offset, rotation = L.offset(layout, s.id, 1)
        local model = o.model or layout.model or ""
        local seat = type(seats) == "table" and tonumber(seats[model]) or 0.0
        offset.z = s.z + seat + (top[s.id] or 0.0)
        local h = type(heights) == "table" and tonumber(heights[model]) or nil
        top[s.id] = (top[s.id] or 0.0) + (h or s.stackHeight)
        placements[o.instance] = { slot = s.id, rank = count[s.id], offset = offset, rotation = rotation,
            reassigned = reassigned or nil }
    end
    for _, s in ipairs(layout.slots) do
        count[s.id] = 0
        for _, o in ipairs(slots[s.id] or {}) do
            if count[s.id] < s.maxStack then
                place(s, o)
            else
                loose[#loose + 1] = o
            end
        end
    end
    table.sort(loose, function(a, b) return tostring(a.instance or "") < tostring(b.instance or "") end)
    for _, o in ipairs(loose) do
        local s = floorFirst(layout, count)
        if s then
            place(s, o, true)
        else
            hidden[#hidden + 1] = o.instance
        end
    end
    return placements, hidden
end

-- Lab: moves one slot. Returns true | nil, reason. The slot stays `measured = false`: a tuned
-- number is a candidate, a person confirms it on both clients before flipping the flag.
function L.tune(layout, slotId, x, y, z, yaw)
    local s = layout.slotById[tonumber(slotId) or -1]
    if not s then return nil, "invalid_slot" end
    for _, v in ipairs({ x, y, z }) do
        if not finite(v) or math.abs(v) > L.LIMITS.offset then return nil, "invalid_offset" end
    end
    if yaw ~= nil and (not finite(yaw) or math.abs(yaw) > L.LIMITS.yaw) then return nil, "invalid_yaw" end
    s.x, s.y, s.z = x, y, z
    if yaw ~= nil then s.yaw = yaw end
    -- A tuned slot is a new guess until it is checked again on both clients, and a layout is
    -- only measured while every one of its slots is.
    s.measured = false
    layout.measured = false
    return true
end

-- ---------------------------------------------------------------------------------------------
-- JSON for pasting back into data/layouts.json: one `"<record>": { ... }` entry, fixed key
-- order, one slot per line.
-- ---------------------------------------------------------------------------------------------

local function jsonString(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or ("\\u%04x"):format(c:byte())
    end) .. '"'
end
L.jsonString = jsonString

-- Metres / degrees: at most 3 decimals, at least one ("0.9", "-2.4", "0.0").
function L.jsonNumber(n)
    local s = ("%.3f"):format(n):gsub("0+$", "")
    if s:sub(-1) == "." then s = s .. "0" end
    if s == "-0.0" then s = "0.0" end
    return s
end

local function jsonInt(n) return ("%d"):format(math.floor(n + 0.5)) end

function L.toJson(layout)
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add(jsonString(layout.record) .. ": {")
    add('  "label": ' .. jsonString(layout.label) .. ",")
    add('  "part": ' .. jsonString(layout.part) .. ",")
    if layout.model ~= "crate.small" then add('  "model": ' .. jsonString(layout.model) .. ",") end
    add('  "capacityKg": ' .. (layout.capacityKg % 1 == 0 and jsonInt(layout.capacityKg) or L.jsonNumber(layout.capacityKg)) .. ",")
    add('  "measured": ' .. tostring(layout.measured == true) .. ",")
    add('  "entityTemplate": ' .. jsonString(layout.entityTemplate or "") .. ",")
    add('  "basis": ' .. jsonString(layout.basis or "") .. ",")
    local aliases = {}
    for _, a in ipairs(layout.aliases or {}) do aliases[#aliases + 1] = jsonString(a) end
    add('  "aliases": [' .. table.concat(aliases, ", ") .. "],")
    add('  "slots": [')
    for i, s in ipairs(layout.slots) do
        add(('    { "id": %s, "x": %s, "y": %s, "z": %s, "yaw": %s, "stackHeight": %s, "maxStack": %s, "measured": %s }%s'):format(
            jsonInt(s.id), L.jsonNumber(s.x), L.jsonNumber(s.y), L.jsonNumber(s.z), L.jsonNumber(s.yaw),
            L.jsonNumber(s.stackHeight), jsonInt(s.maxStack), tostring(s.measured == true), i < #layout.slots and "," or ""))
    end
    add("  ]")
    add("}")
    return table.concat(lines, "\n")
end

return L
