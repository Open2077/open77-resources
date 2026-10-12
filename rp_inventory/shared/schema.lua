-- rp_inventory / shared/schema.lua: item definitions and item instances (world-interaction row B1).
--
-- Pure Lua, loaded on both runtimes, no native touched: the offline suites load it in a bare
-- Lua 5.4 state. Global table: RpItemSchema.
--
--   Definition schema v1   the legacy shape of shared/items.lua and `define` (label, weight,
--                          usable, illegal, permit, effect, record, visual, category) imports
--                          unchanged; v1 adds weightG, maxStack, unique, metadata, durability,
--                          serial, quality, prop, hand and loot.
--   Registry               `define` with collision refusal (last writer never wins), id rules,
--                          a shape freeze for the transactions backend, a version counter.
--   Metadata               typed fields; unknown or invalid metadata is refused. "Stack" fields
--                          (bounded enum / boolean / small integer) select a stack VARIANT, so
--                          two stacks merge only when their metadata is equal; any other field
--                          makes the item unique (one instance per unit, A13 instances).
--   Catalogue              a bounded, versioned client transfer: pages of <= 64 entries and
--                          <= 24 KiB, a version counter and an FNV-1a 64 hash, never one big
--                          state bag.
--
-- Status: offline-tested only (tests/test_inventory_b1b2.py). Nothing here claims in-game behaviour.

RpItemSchema = {}
local S = RpItemSchema

S.VERSION = 1

S.LIMITS = {
    maxDefinitions = 4096,
    maxIdLen = 32,          -- rp_inventory_items.item_id is VARCHAR(32) (B8 5.1)
    maxAssetLen = 64,       -- open77_transactions item ids: ^[a-z0-9_]{1,64}$
    maxLabel = 48,
    maxWeightKg = 100,
    maxStack = 1000000,
    maxMetaFields = 16,
    maxMetaBytes = 1024,    -- canonical JSON of one instance's metadata (the coordinator caps 2 KiB)
    maxVariants = 64,       -- per item: product of the stack fields' domains
    maxEnumValues = 32,
    maxStringLen = 64,
    maxEntryBytes = 2048,   -- one catalogue entry
    pageItems = 64,
    pageBytes = 24 * 1024,  -- well under the 48 KiB event envelope
    maxPages = 512,         -- 4096 entries of <= 2 KiB fit in <= 342 pages of 24 KiB
}

local LEGACY_FIELDS = {
    label = true, weight = true, usable = true, illegal = true, permit = true, effect = true,
    record = true, visual = true, category = true,
}
local V1_FIELDS = {
    weightG = true, maxStack = true, stack = true, unique = true, metadata = true, durability = true,
    serial = true, quality = true, prop = true, hand = true, loot = true, schema = true,
}
local RESERVED_META = { durability = true, serial = true, quality = true }

-- ---------------------------------------------------------------------------
-- Canonical JSON (sorted keys) and FNV-1a 64: catalogue hashes, metadata sizes, row hashes.
-- Same algorithm as open77_transactions' model (Lua 5.4 integer arithmetic wraps mod 2^64).
-- ---------------------------------------------------------------------------
local function escape(s)
    return (s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format("\\u%04x", c:byte())
    end))
end

local function encodeValue(v, depth, out)
    if depth > 16 then error("encode: too deep", 0) end
    local t = type(v)
    if v == nil then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        if math.type(v) == "integer" then out[#out + 1] = string.format("%d", v)
        elseif v ~= v or v == math.huge or v == -math.huge then error("encode: non-finite number", 0)
        elseif v % 1 == 0 and math.abs(v) < 2 ^ 53 then out[#out + 1] = string.format("%d", math.tointeger(v))
        else out[#out + 1] = string.format("%.17g", v) end
    elseif t == "string" then out[#out + 1] = '"' .. escape(v) .. '"'
    elseif t == "table" then
        local n, count = #v, 0
        for _ in pairs(v) do count = count + 1 end
        if count == n and (n > 0 or next(v) == nil) then
            out[#out + 1] = "["
            for i = 1, n do
                if i > 1 then out[#out + 1] = "," end
                encodeValue(v[i], depth + 1, out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" then error("encode: non-string key", 0) end
                keys[#keys + 1] = k
            end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = '"' .. escape(k) .. '":'
                encodeValue(v[k], depth + 1, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("encode: unsupported type " .. t, 0)
    end
end

function S.encode(v)
    local out = {}
    encodeValue(v, 0, out)
    return table.concat(out)
end

function S.fnv1a64(s)
    local h = -3750763034362895579
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = h * 1099511628211
    end
    return string.format("%016x", h)
end

local function copy(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return v end
    if depth > 16 then error("copy: too deep", 0) end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x, depth + 1) end
    return out
end
S.copy = copy

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function isInteger(n)
    return type(n) == "number" and math.tointeger(n) ~= nil
end

local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- ---------------------------------------------------------------------------
-- Ids
-- ---------------------------------------------------------------------------
-- Item ids keep the legacy pattern ^[a-z0-9_]+$, at most 32 bytes, and never contain "__":
-- the double underscore separates an item id from its stack-variant suffix.
function S.itemIdProblem(id)
    if type(id) ~= "string" or id == "" or not id:match("^[%l%d_]+$") then return "invalid_id" end
    if #id > S.LIMITS.maxIdLen then return "id_too_long" end
    if id:find("__", 1, true) then return "reserved_id" end
    return nil
end

local FIELD_NAME = "^[%l][%l%d]*$" -- no underscore: variant suffixes stay decodable

-- ---------------------------------------------------------------------------
-- Metadata field descriptors
--   { type = "integer"|"number"|"string"|"boolean"|"enum", default?, required?, min?, max?,
--     maxLen?, pattern?, values? (enum), stack? }
-- ---------------------------------------------------------------------------
local function normalizeField(name, d)
    if type(name) ~= "string" or #name > 24 or not name:match(FIELD_NAME) then return nil, "invalid_meta_field_name" end
    if type(d) ~= "table" then return nil, "invalid_meta_field" end
    local f = { type = d.type, required = d.required == true, stack = d.stack == true }
    if f.type == "integer" or f.type == "number" then
        if d.min ~= nil and not finite(d.min) then return nil, "invalid_meta_field" end
        if d.max ~= nil and not finite(d.max) then return nil, "invalid_meta_field" end
        if f.type == "integer" and ((d.min ~= nil and not isInteger(d.min)) or (d.max ~= nil and not isInteger(d.max))) then
            return nil, "invalid_meta_field"
        end
        if d.min ~= nil and d.max ~= nil and d.min > d.max then return nil, "invalid_meta_field" end
        f.min = f.type == "integer" and d.min and math.tointeger(d.min) or d.min
        f.max = f.type == "integer" and d.max and math.tointeger(d.max) or d.max
    elseif f.type == "string" then
        local maxLen = d.maxLen or S.LIMITS.maxStringLen
        if not isInteger(maxLen) or maxLen < 1 or maxLen > S.LIMITS.maxStringLen then return nil, "invalid_meta_field" end
        f.maxLen = math.tointeger(maxLen)
        if d.pattern ~= nil then
            if type(d.pattern) ~= "string" or #d.pattern > 64 or not pcall(string.find, "", d.pattern) then
                return nil, "invalid_meta_field"
            end
            f.pattern = d.pattern
        end
    elseif f.type == "enum" then
        if type(d.values) ~= "table" or #d.values < 1 or #d.values > S.LIMITS.maxEnumValues then return nil, "invalid_meta_field" end
        f.values, f.index = {}, {}
        for i, v in ipairs(d.values) do
            if type(v) ~= "string" or #v > 16 or not v:match("^[%l%d]+$") or f.index[v] then return nil, "invalid_meta_field" end
            f.values[i], f.index[v] = v, i
        end
    elseif f.type ~= "boolean" then
        return nil, "invalid_meta_field"
    end
    if d.default ~= nil then
        local ok = S.checkValue(f, d.default)
        if ok == nil then return nil, "invalid_meta_default" end
        f.default = ok
    end
    if f.stack then
        -- A stack field keys a variant: bounded domain and a default, so `add` with no metadata
        -- still lands on the plain item id.
        if f.default == nil then return nil, "stack_field_needs_default" end
        if f.type == "integer" then
            if f.min == nil or f.max == nil or f.max - f.min + 1 > S.LIMITS.maxEnumValues then
                return nil, "stack_field_unbounded"
            end
        elseif f.type ~= "enum" and f.type ~= "boolean" then
            return nil, "stack_field_type"
        end
    end
    return f
end

-- Value check against one descriptor: canonical value | nil.
function S.checkValue(f, v)
    if f.type == "integer" then
        if not isInteger(v) then return nil end
        v = math.tointeger(v)
        if (f.min and v < f.min) or (f.max and v > f.max) then return nil end
        return v
    elseif f.type == "number" then
        if not finite(v) then return nil end
        if (f.min and v < f.min) or (f.max and v > f.max) then return nil end
        return v
    elseif f.type == "string" then
        if type(v) ~= "string" or #v > f.maxLen then return nil end
        if v:find("[%c]") then return nil end
        if f.pattern and not v:match(f.pattern) then return nil end
        return v
    elseif f.type == "boolean" then
        if type(v) ~= "boolean" then return nil end
        return v
    elseif f.type == "enum" then
        if type(v) ~= "string" or not f.index[v] then return nil end
        return v
    end
    return nil
end

local function domainOf(f)
    if f.type == "boolean" then return { false, true } end
    if f.type == "enum" then return f.values end
    local out = {}
    for n = f.min, f.max do out[#out + 1] = n end
    return out
end

local function encodeStackValue(f, v)
    if f.type == "boolean" then return v and "1" or "0" end
    if f.type == "integer" then return v < 0 and ("m" .. tostring(-v)) or tostring(v) end
    return v
end

-- ---------------------------------------------------------------------------
-- Optional presentation mappings (validated, never interpreted here)
-- ---------------------------------------------------------------------------
local function vec3(v)
    if v == nil then return nil, true end
    if type(v) ~= "table" then return nil, false end
    local out = {}
    for _, k in ipairs({ "x", "y", "z" }) do
        local n = v[k] or 0
        if not finite(n) or math.abs(n) > 10 then return nil, false end
        out[k] = n
    end
    return out, true
end

local function shortString(v, maxLen, pattern)
    return type(v) == "string" and #v > 0 and #v <= maxLen and (not pattern or v:match(pattern)) and true or false
end

local RECORD = "^[%w_%.]+$"
local ALIAS = "^[%w_%.%-]+$"

local function normalizeMapping(kind, v)
    if v == nil then return nil, true end
    if type(v) ~= "table" then return nil, false end
    local out = {}
    if kind == "loot" then
        if v.record ~= nil and not shortString(v.record, 96, RECORD) then return nil, false end
        if v.visual ~= nil and not shortString(v.visual, 96, RECORD) then return nil, false end
        out.record, out.visual = v.record, v.visual
        return out, true
    end
    -- prop / hand: a curated alias or a record, an attachment bone and a local offset.
    if v.model ~= nil and not shortString(v.model, 96, ALIAS) then return nil, false end
    if v.item ~= nil and not shortString(v.item, 96, RECORD) then return nil, false end
    if v.profile ~= nil and not shortString(v.profile, 64, ALIAS) then return nil, false end
    if v.bone ~= nil and not (v.bone == "" or shortString(v.bone, 32, "^[%w_]+$")) then return nil, false end
    local offset, okO = vec3(v.offset)
    local rotation = v.rotation
    if rotation ~= nil then
        if type(rotation) ~= "table" then return nil, false end
        for _, k in ipairs({ "x", "y", "z" }) do
            local n = rotation[k] or 0
            if not finite(n) or math.abs(n) > 360 then return nil, false end
        end
        rotation = { x = rotation.x or 0, y = rotation.y or 0, z = rotation.z or 0 }
    end
    if not okO then return nil, false end
    out.model, out.item, out.profile, out.bone, out.offset, out.rotation = v.model, v.item, v.profile, v.bone, offset, rotation
    if next(out) == nil then return nil, false end
    return out, true
end

-- ---------------------------------------------------------------------------
-- Definition normalisation
-- ---------------------------------------------------------------------------
-- Returns the normalised definition, or nil, reason. Legacy fields keep their legacy names and
-- meaning, so code that reads Items[id].label / .weight / .usable / .effect is unchanged.
-- `warnings` (optional table) collects ignored unknown top-level fields: they are not refused,
-- because the legacy `define` ignored them and community definers may pass extra keys.
function S.normalize(id, def, warnings)
    local idProblem = S.itemIdProblem(id)
    if idProblem then return nil, idProblem end
    if type(def) ~= "table" then return nil, "invalid_definition" end
    if def.schema ~= nil and def.schema ~= S.VERSION then return nil, "schema_version_mismatch" end
    if type(def.label) ~= "string" or #def.label == 0 or #def.label > S.LIMITS.maxLabel then return nil, "invalid_label" end

    local weightG
    if def.weightG ~= nil then
        if not isInteger(def.weightG) or def.weightG < 0 or def.weightG > S.LIMITS.maxWeightKg * 1000 then
            return nil, "invalid_weight"
        end
        weightG = math.tointeger(def.weightG)
        if def.weight ~= nil and (not finite(def.weight) or math.floor(def.weight * 1000 + 0.5) ~= weightG) then
            return nil, "weight_mismatch"
        end
    else
        if not finite(def.weight) or def.weight < 0 or def.weight > S.LIMITS.maxWeightKg then return nil, "invalid_weight" end
        weightG = math.floor(def.weight * 1000 + 0.5)
    end

    local out = {
        schema = S.VERSION,
        id = id,
        label = def.label,
        weight = weightG / 1000,
        weightG = weightG,
        usable = def.usable == true,
        illegal = def.illegal == true,
        permit = type(def.permit) == "string" and def.permit or nil,
        effect = type(def.effect) == "table" and def.effect or nil,
        record = type(def.record) == "string" and def.record or nil,
        visual = type(def.visual) == "string" and def.visual or nil,
        category = (type(def.category) == "string" and def.category:match("^%l+$")) and def.category or nil,
    }
    if def.weight ~= nil and finite(def.weight) and def.weightG == nil then out.weight = def.weight end

    -- maxStack (alias `stack`): the most units of one stack (asset) a single container holds.
    if def.stack ~= nil and not isInteger(def.stack) then return nil, "invalid_max_stack" end
    local maxStack = def.maxStack
    if maxStack == nil then maxStack = def.stack end
    if maxStack ~= nil then
        if not isInteger(maxStack) or maxStack < 1 or maxStack > S.LIMITS.maxStack then return nil, "invalid_max_stack" end
        out.maxStack = math.tointeger(maxStack)
    end

    -- Metadata schema: declared fields plus the reserved durability / serial / quality.
    local fields, count = {}, 0
    if def.metadata ~= nil then
        if type(def.metadata) ~= "table" then return nil, "invalid_metadata_schema" end
        for name, d in pairs(def.metadata) do
            if RESERVED_META[name] then return nil, "reserved_meta_field" end
            local f, why = normalizeField(name, d)
            if not f then return nil, why end
            fields[name] = f
            count = count + 1
        end
    end
    if def.durability ~= nil then
        local d = def.durability
        if isInteger(d) then d = { max = d } end
        if type(d) ~= "table" or not isInteger(d.max) or d.max < 1 or d.max > S.LIMITS.maxStack then
            return nil, "invalid_durability"
        end
        local start = d.start == nil and d.max or d.start
        if not isInteger(start) or start < 1 or start > d.max then return nil, "invalid_durability" end
        out.durability = { max = math.tointeger(d.max), start = math.tointeger(start), breaks = d.breaks ~= false }
        fields.durability = { type = "integer", min = 0, max = out.durability.max, default = out.durability.start }
        count = count + 1
    end
    if def.serial ~= nil and def.serial ~= false then
        if def.serial ~= true then return nil, "invalid_serial" end
        out.serial = true
        fields.serial = { type = "string", maxLen = 64, pattern = "^[%w_.:%-]+$", auto = true }
        count = count + 1
    end
    if def.quality ~= nil then
        local q = def.quality
        local f, why
        if type(q) == "table" and q.values ~= nil then
            f, why = normalizeField("quality", { type = "enum", values = q.values, default = q.default or q.values[1], stack = true })
        elseif type(q) == "table" then
            f, why = normalizeField("quality", { type = "integer", min = q.min or 1, max = q.max or 5,
                default = q.default or q.min or 1, stack = true })
        else
            why = "invalid_quality"
        end
        if not f then return nil, why == "stack_field_unbounded" and "invalid_quality" or why end
        fields.quality = f
        count = count + 1
    end
    if count > S.LIMITS.maxMetaFields then return nil, "too_many_meta_fields" end

    -- Uniqueness: any per-unit field (durability, serial, a non-stack field) means one instance
    -- per unit. An explicit unique = false with such a field is a contradiction, not a hint.
    local needsUnique = false
    for _, f in pairs(fields) do
        if not f.stack then needsUnique = true end
    end
    if def.unique == false and needsUnique then return nil, "unique_required" end
    out.unique = def.unique == true or needsUnique
    if out.unique then
        -- Stack fields of a unique item are plain metadata: an instance never merges.
        for _, f in pairs(fields) do f.stack = false end
        if out.maxStack and out.maxStack ~= 1 then out.maxStack = nil end
    end
    out.metadata = next(fields) and fields or nil

    -- Variants of a stackable item: every combination of its stack fields.
    local stackNames = {}
    for name, f in pairs(fields) do if f.stack then stackNames[#stackNames + 1] = name end end
    table.sort(stackNames)
    out.stackFields = #stackNames > 0 and stackNames or nil
    if #stackNames > 0 then
        local variants, product = {}, 1
        for _, name in ipairs(stackNames) do product = product * #domainOf(fields[name]) end
        if product > S.LIMITS.maxVariants then return nil, "too_many_variants" end
        local combos = { {} }
        for _, name in ipairs(stackNames) do
            local next_ = {}
            for _, combo in ipairs(combos) do
                for _, value in ipairs(domainOf(fields[name])) do
                    local c = copy(combo)
                    c[name] = value
                    next_[#next_ + 1] = c
                end
            end
            combos = next_
        end
        for _, meta in ipairs(combos) do
            local asset = S.variantId(out, meta)
            if #asset > S.LIMITS.maxAssetLen then return nil, "variant_id_too_long" end
            variants[asset] = meta
        end
        out.variants = variants
    end

    for _, kind in ipairs({ "prop", "hand", "loot" }) do
        local mapped, ok = normalizeMapping(kind, def[kind])
        if not ok then return nil, "invalid_" .. kind end
        out[kind] = mapped
    end
    if not out.loot and (out.record or out.visual) then out.loot = { record = out.record, visual = out.visual } end

    if warnings then
        for k in pairs(def) do
            if not LEGACY_FIELDS[k] and not V1_FIELDS[k] then warnings[#warnings + 1] = id .. "." .. tostring(k) end
        end
    end

    local ok, encoded = pcall(S.encode, S.catalogueEntry(out))
    if not ok then return nil, "invalid_definition" end
    if #encoded > S.LIMITS.maxEntryBytes then return nil, "definition_too_large" end
    return out
end

-- The variant (asset) id of a stackable item for canonical stack metadata. Default values are
-- omitted, so the all-default variant is the plain item id: legacy stacks keep their id.
function S.variantId(def, meta)
    if not def.stackFields then return def.id end
    local parts = {}
    for _, name in ipairs(def.stackFields) do
        local f = def.metadata[name]
        local v = meta[name]
        if v == nil then v = f.default end
        if v ~= f.default then parts[#parts + 1] = name .. "_" .. encodeStackValue(f, v) end
    end
    if #parts == 0 then return def.id end
    return def.id .. "__" .. table.concat(parts, "__")
end

-- Splits an asset id into (itemId, suffix). The suffix is decoded by Registry:decodeAsset.
function S.splitAsset(asset)
    if type(asset) ~= "string" then return nil end
    local at = asset:find("__", 1, true)
    if not at then return asset, nil end
    return asset:sub(1, at - 1), asset:sub(at + 2)
end

-- Shape fields that the transactions backend must never change under live containers: the
-- coordinator keeps running weight totals, and persisted variant ids must stay decodable.
function S.shapeOf(def)
    local meta = {}
    for name, f in pairs(def.metadata or {}) do
        meta[name] = { t = f.type, s = f.stack and 1 or 0, lo = f.min, hi = f.max,
            v = f.values and table.concat(f.values, ",") or nil, d = f.default == nil and "" or tostring(f.default) }
    end
    return S.encode({ w = def.weightG, u = def.unique and 1 or 0, m = meta })
end

-- What a client needs to render an item: no effect, no permit, no validation internals.
function S.catalogueEntry(def)
    local meta
    if def.metadata then
        meta = {}
        for name, f in pairs(def.metadata) do
            meta[name] = { type = f.type, min = f.min, max = f.max, values = f.values and copy(f.values) or nil,
                default = f.default, stack = f.stack or nil }
        end
    end
    return {
        id = def.id, label = def.label, weightG = def.weightG, category = def.category,
        usable = def.usable or nil, illegal = def.illegal or nil, unique = def.unique or nil,
        maxStack = def.maxStack, metadata = meta, prop = def.prop and copy(def.prop) or nil,
        hand = def.hand and copy(def.hand) or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Metadata validation for one unit or one stack
-- ---------------------------------------------------------------------------
-- validateMeta(def, meta, { creating = true, allowSerial = false }) -> canonical meta | nil, reason
-- Unknown fields are refused; defaults are filled; `serial` is assigned by the inventory, never
-- supplied by a caller.
function S.validateMeta(def, meta, opts)
    opts = opts or {}
    if meta ~= nil and type(meta) ~= "table" then return nil, "invalid_meta" end
    meta = meta or {}
    local fields = def.metadata or {}
    for k in pairs(meta) do
        if type(k) ~= "string" or not fields[k] then return nil, "unknown_meta_field" end
    end
    local out = {}
    for name, f in pairs(fields) do
        local v = meta[name]
        if f.auto then
            if v ~= nil and not opts.allowSerial then return nil, "serial_reserved" end
            if v ~= nil then
                local checked = S.checkValue(f, v)
                if checked == nil then return nil, "invalid_meta" end
                out[name] = checked
            end
        elseif v == nil then
            if f.default ~= nil then out[name] = f.default
            elseif f.required then return nil, "meta_required" end
        else
            local checked = S.checkValue(f, v)
            if checked == nil then return nil, "invalid_meta" end
            out[name] = checked
        end
    end
    local ok, encoded = pcall(S.encode, out)
    if not ok or #encoded > S.LIMITS.maxMetaBytes then return nil, "meta_too_large" end
    return out
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------
local Registry = {}
Registry.__index = Registry

-- items: the table that holds the definitions (RpInventoryItems), updated in place so that
--        every Items[id] reader sees the normalised definition.
-- options.freezeShape: refuse a same-definer redefinition that changes the shape (weight,
--        uniqueness, metadata); the transactions backend sets it.
function S.newRegistry(items, options)
    options = options or {}
    local self = setmetatable({
        items = items or {},
        definers = {},        -- [id] = resource that owns the definition ("rp_inventory" = built-in)
        shapes = {},          -- [id] = shape string
        version = 0,
        count = 0,
        freezeShape = options.freezeShape == true,
        builtin = options.builtin or "rp_inventory",
        cache = nil,
    }, Registry)
    return self
end

-- Imports the built-in table of shared/items.lua (definer = the inventory itself). Invalid
-- built-ins are dropped from the table and reported, never half-registered.
function Registry:importBuiltins()
    local raw = self.items
    local rejected = {}
    for _, id in ipairs(sortedKeys(raw)) do
        local def = raw[id]
        if type(def) == "table" and def.schema == S.VERSION and def.weightG and self.definers[id] then
            -- already normalised
        else
            local normalized, why = S.normalize(id, def)
            if normalized then
                raw[id] = normalized
                self.definers[id] = self.builtin
                self.shapes[id] = S.shapeOf(normalized)
                self.count = self.count + 1
            else
                raw[id] = nil
                rejected[id] = why
            end
        end
    end
    self.version = self.version + 1
    self.cache = nil
    return rejected
end

-- define(items, definer) -> registered, rejected, details
-- details = { collisions = { id... }, reasons = { [id] = reason }, warnings = { "id.field"... } }
function Registry:define(items, definer)
    local details = { collisions = {}, reasons = {}, warnings = {} }
    if type(items) ~= "table" then return nil, "invalid_items" end
    definer = definer or "unknown"
    local registered, rejected, changed = 0, 0, false
    for _, id in ipairs(sortedKeys(items)) do
        local def = items[id]
        local normalized, why
        if type(id) ~= "string" then
            why = "invalid_id"
        else
            normalized, why = S.normalize(id, def, details.warnings)
        end
        if normalized then
            local owner = self.definers[id]
            if owner and owner ~= definer then
                normalized, why = nil, "collision"
                details.collisions[#details.collisions + 1] = id
            elseif not owner and self.count >= S.LIMITS.maxDefinitions then
                normalized, why = nil, "registry_full"
            elseif owner and self.freezeShape and S.shapeOf(normalized) ~= self.shapes[id] then
                normalized, why = nil, "definition_changed"
            end
        end
        if normalized then
            if definer ~= self.builtin then normalized.definedBy = definer end
            if not self.definers[id] then self.count = self.count + 1 end
            local before = self.items[id] and S.encode(S.catalogueEntry(self.items[id])) or nil
            self.items[id] = normalized
            self.definers[id] = definer
            self.shapes[id] = S.shapeOf(normalized)
            if before ~= S.encode(S.catalogueEntry(normalized)) then changed = true end
            registered = registered + 1
        else
            rejected = rejected + 1
            details.reasons[tostring(id)] = why
        end
    end
    table.sort(details.collisions)
    if changed then
        self.version = self.version + 1
        self.cache = nil
    end
    details.version = self.version
    return registered, rejected, details
end

function Registry:get(id) return self.items[id] end
function Registry:definerOf(id) return self.definers[id] end

-- Asset (stack key) for an item and caller metadata: assetId, canonicalMeta | nil, reason.
-- Unique items have no asset: they are instances (assetId is the item id, `unique` = true).
function Registry:assetFor(itemId, meta, opts)
    local def = self.items[itemId]
    if not def or not self.definers[itemId] then return nil, "unknown_item" end
    local canonical, why = S.validateMeta(def, meta, opts)
    if not canonical then return nil, why end
    if def.unique then return itemId, canonical, true end
    return S.variantId(def, canonical), canonical, false
end

-- Decodes a persisted asset id: itemId, stackMeta | nil when the item or variant is unknown.
function Registry:decodeAsset(asset)
    local itemId, suffix = S.splitAsset(asset)
    local def = itemId and self.items[itemId]
    if not def or not self.definers[itemId] then return nil end
    if not suffix then
        if def.stackFields then
            local meta = {}
            for _, name in ipairs(def.stackFields) do meta[name] = def.metadata[name].default end
            return itemId, meta
        end
        return itemId, {}
    end
    local meta = def.variants and def.variants[asset]
    if not meta then return nil end
    return itemId, copy(meta)
end

-- Weight in grams of one unit of an asset (variants weigh what their item weighs).
function Registry:weightG(asset)
    local itemId = S.splitAsset(asset)
    local def = itemId and self.items[itemId]
    return def and def.weightG or nil
end

-- Definitions handed to open77_transactions:define: every asset id with its weight.
function Registry:txDefinitions()
    local out = {}
    for id, def in pairs(self.items) do
        if self.definers[id] then
            out[id] = { weightG = def.weightG, unique = def.unique or nil }
            for asset in pairs(def.variants or {}) do
                if asset ~= id then out[asset] = { weightG = def.weightG } end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Catalogue: bounded, versioned pages
-- ---------------------------------------------------------------------------
-- head = { schema, version, hash, pages, items }; pages[i] = { v = version, i = i, items = {...} }
function Registry:catalogue()
    if self.cache and self.cache.head.version == self.version then return self.cache.head, self.cache.pages end
    local entries = {}
    for _, id in ipairs(sortedKeys(self.items)) do
        if self.definers[id] then entries[#entries + 1] = S.catalogueEntry(self.items[id]) end
    end
    local pages, page, bytes = {}, {}, 2
    for _, entry in ipairs(entries) do
        local size = #S.encode(entry) + 1
        if #page >= S.LIMITS.pageItems or (#page > 0 and bytes + size > S.LIMITS.pageBytes) then
            pages[#pages + 1] = page
            page, bytes = {}, 2
        end
        page[#page + 1] = entry
        bytes = bytes + size
    end
    if #page > 0 then pages[#pages + 1] = page end
    if #pages > S.LIMITS.maxPages then
        -- Cannot happen within maxDefinitions x maxEntryBytes; refuse loudly rather than truncate.
        error("rp_inventory catalogue exceeds " .. S.LIMITS.maxPages .. " pages", 0)
    end
    local head = {
        schema = S.VERSION, version = self.version, hash = S.fnv1a64(S.encode(entries)),
        pages = #pages, items = #entries,
    }
    local out = {}
    for i, p in ipairs(pages) do out[i] = { v = self.version, i = i, items = p } end
    self.cache = { head = head, pages = out }
    return head, out
end

-- Client side: rebuilds and verifies the catalogue from its head and every page.
-- Returns { [id] = entry } | nil, reason.
function S.assemble(head, pages)
    if type(head) ~= "table" or head.schema ~= S.VERSION then return nil, "schema_mismatch" end
    if not isInteger(head.pages) or head.pages < 0 or head.pages > S.LIMITS.maxPages then return nil, "invalid_head" end
    local entries = {}
    for i = 1, head.pages do
        local p = pages[i]
        if type(p) ~= "table" or p.v ~= head.version or p.i ~= i or type(p.items) ~= "table" then
            return nil, "missing_page"
        end
        for _, entry in ipairs(p.items) do entries[#entries + 1] = entry end
    end
    if #entries ~= head.items then return nil, "count_mismatch" end
    if S.fnv1a64(S.encode(entries)) ~= head.hash then return nil, "hash_mismatch" end
    local byId = {}
    for _, entry in ipairs(entries) do byId[entry.id] = entry end
    return byId
end

return S
