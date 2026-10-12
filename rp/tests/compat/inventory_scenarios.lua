-- tests/compat/inventory_scenarios.lua: rp_inventory B1 (definitions) and B2 (the facade over
-- open77_transactions), offline.
--
-- Loaded after fakehost.lua. The runner sets REPO (pack root), HARNESS (tests/compat) and
-- TX_DIR (the vendored final open77_transactions). Each scenario runs the REAL
-- rp_inventory server scripts against the REAL A13 coordinator and its memory store, and
-- returns a flat table the Python side asserts on. Nothing here is in-game evidence.

dofile(HARNESS .. "/txhost.lua")

local A, B = 7, 8
local CHAR_A, CHAR_B = "char:acct-a", "char:acct-b"

local function players(extra)
    local p = {
        [A] = { identifier = "acct-a", name = "Alice", pos = { x = 0, y = 0, z = 0, bucket = 0 } },
        [B] = { identifier = "acct-b", name = "Bob", pos = { x = 1, y = 0, z = 0, bucket = 0 } },
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end

local function bootTx(opts)
    opts = opts or {}
    if not TX.co or opts.freshCoordinator then TX.start({ storeMode = opts.storeMode }) end
    return H.bootInventory({ backend = "transactions", players = opts.players or players(), config = opts.config,
        settle = opts.settle })
end

local function bootLegacy(opts)
    opts = opts or {}
    return H.bootInventory({ backend = "legacy", players = opts.players or players(), config = opts.config,
        settle = opts.settle })
end

-- Runs an export (or any function) as a managed task and drives the clock until it finishes.
local function await(fn, maxSeconds)
    local box = H.task(fn)
    local waited = 0
    while not box.done and waited < (maxSeconds or 120) do
        H.run(0.5)
        waited = waited + 0.5
    end
    if not box.done then return "timeout" end
    return box[1], box[2], box[3]
end

local function str(v)
    if v == nil then return "nil" end
    if type(v) == "table" then
        local ok, enc = pcall(RpItemSchema.encode, v)
        return ok and enc or tostring(v)
    end
    return tostring(v)
end

-- "value" or "nil:reason"
local function res(v, reason)
    if v == nil or v == false then return (v == false and "false" or "nil") .. ":" .. tostring(reason) end
    if type(v) == "table" then return "table" end
    return tostring(v)
end

local function changedEvents(filter)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.name == "rp_inventory:changed" and (not filter or e.args[1] == filter) then
            out[#out + 1] = ("%s:%s:%s"):format(e.args[1], e.args[2], e.args[3])
        end
    end
    return table.concat(out, ",")
end

local function journalBalanced()
    local sums = {}
    for _, e in ipairs(TX.store.journal) do
        local k = e.opId .. "|" .. e.asset
        sums[k] = (sums[k] or 0) + e.delta
    end
    for _, v in pairs(sums) do if v ~= 0 then return false end end
    return true
end

-- Seeds a container through the coordinator (a journaled credit from sys:seed).
local function seed(account, item, count, capacityG)
    TX.store:openContainer(account, { capacityG = capacityG or 40000 }, function() end)
    local box = { }
    TX.co:transfer({ opId = "seed-" .. account .. "-" .. item .. "-" .. count .. "-" .. tostring(#TX.store.journal),
        kind = "seed", lines = { { item = item, count = count, from = "sys:seed", to = account } } }, "compat_seed",
        function(r, reason) box.r, box.reason = r, reason end)
    TX.store:flush()
    return box.r ~= nil, box.reason
end

-- A transfer by ANOTHER resource straight on the coordinator (a foreign writer). The coordinator
-- runs store answers on its work queue: its own scheduler is pumped (no clock time passes) until
-- the operation holds its goods or has answered, so it is "first" in the scenario's sense.
local function foreign(spec)
    local box = {}
    TX.co:transfer(spec, "rp_other", function(r, reason) box.done, box.r, box.reason = true, r, reason end)
    for _ = 1, 32 do
        if box.done or TX.co:operation(spec.opId) then break end
        TXS.step()
    end
    return box
end

local scenarios = {}

-- ===========================================================================
-- B1: definitions
-- ===========================================================================

-- Loads a definer's shared config in a private environment and returns the table it defines.
local function definerItems(resource, file, pick)
    local env = setmetatable({}, { __index = _G })
    local chunk = assert(loadfile(REPO .. "/" .. resource .. "/" .. file, "t", env))
    chunk()
    return pick(env)
end

local function packDefinitions()
    local defs = {}
    defs.rp_crime = definerItems("rp_crime", "shared/config.lua", function(e) return e.RpCrimeConfig.items end)
    -- rp_fixer 2.0 defines no item (its crate is an open77_actions carry prop, retrievals ask for
    -- other resources' items): it is no longer a definer.
    defs.rp_gangs = definerItems("rp_gangs", "shared/config.lua", function(e) return e.RpGangsConfig.items end)
    defs.rp_mecano = definerItems("rp_mecano", "shared/items.lua", function(e) return e.RpMecanoItems end)
    defs.rp_netrunner = definerItems("rp_netrunner", "shared/config.lua", function(e) return e.Config.items end)
    defs.rp_nomade = definerItems("rp_nomade", "server/config.lua", function(e) return e.NomadConfig.items end)
    defs.rp_ripperdoc = definerItems("rp_ripperdoc", "shared/config.lua", function(e) return e.RpRipperConfig.items end)
    defs.rp_ferrailleur = definerItems("rp_ferrailleur", "shared/config.lua", function(e)
        local c = e.RpFerrailleurConfig.crowbar
        return { [c.id] = { label = c.label, weight = c.weight, usable = false, illegal = false } }
    end)
    -- rp_bar's itemDefinitions(): only the fields rp_inventory knows.
    defs.rp_bar = definerItems("rp_bar", "shared/config.lua", function(e)
        local out = {}
        for id, d in pairs(e.RpBarConfig.drinks) do
            out[id] = { label = d.label, weight = d.weight, usable = d.usable ~= false, illegal = d.illegal == true, effect = d.effect }
        end
        for id, d in pairs(e.RpBarConfig.ingredients) do
            out[id] = { label = d.label, weight = d.weight, usable = false, illegal = d.illegal == true }
        end
        return out
    end)
    return defs
end

function scenarios.b1_definitions()
    dofile(REPO .. "/rp_inventory/shared/items.lua")
    dofile(REPO .. "/rp_inventory/shared/schema.lua")
    local S = RpItemSchema
    local raw = {}
    for id, def in pairs(RpInventoryItems) do raw[id] = S.copy(def) end
    local reg = S.newRegistry(RpInventoryItems, {})
    local rejectedBuiltins = reg:importBuiltins()
    local out = { builtins = reg.count, builtin_rejected = next(rejectedBuiltins) and "some" or "none" }
    -- Legacy fields survive normalisation unchanged.
    local same = true
    for id, def in pairs(raw) do
        local n = RpInventoryItems[id]
        for _, f in ipairs({ "label", "weight", "usable", "illegal", "permit", "category" }) do
            if n[f] ~= def[f] and not (f == "usable" and def[f] == nil and n[f] == false)
                and not (f == "illegal" and def[f] == nil and n[f] == false) then
                same = false
            end
        end
        if (def.effect ~= nil) ~= (n.effect ~= nil) or n.definedBy ~= nil then same = false end
    end
    out.builtin_fields_unchanged = same
    out.chip_weightG = RpInventoryItems.chip.weightG

    local total = reg.count
    for _, definer in ipairs({ "rp_bar", "rp_crime", "rp_ferrailleur", "rp_gangs", "rp_mecano",
        "rp_netrunner", "rp_nomade", "rp_ripperdoc" }) do
        local items = packDefinitions()[definer]
        local r, j = reg:define(items, definer)
        out["def_" .. definer] = r .. "/" .. j
        total = total + r
    end
    out.registry_count = reg.count
    out.registry_total_matches = reg.count == total
    -- rp_selftest's check: one registered, one rejected (counts, not lists).
    local r, j = reg:define({ crowbar_test = { label = "Crowbar (selftest)", weight = 1.5 }, ["BAD ID"] = { label = "x", weight = 1 } }, "rp_selftest")
    out.selftest = r .. "/" .. j
    -- The definer handshake: the same definer may define again (rp_inventory restarted).
    r, j = reg:define(packDefinitions().rp_crime, "rp_crime")
    out.redefine_same_definer = r .. "/" .. j
    -- A collision is refused, never overwritten (B8 R5).
    local d
    r, j, d = reg:define({ water = { label = "Fixer water", weight = 0.5 }, stolen_parts = { label = "x", weight = 1 } }, "rp_fixer")
    out.collision = r .. "/" .. j .. ":" .. table.concat(d.collisions, ",")
    out.water_label_kept = RpInventoryItems.water.label
    -- Id rules: <= 32 bytes (VARCHAR(32)), no "__" (variant separator), lower case.
    r, j, d = reg:define({
        ["a_very_long_item_identifier_over_32"] = { label = "Long", weight = 1 },
        ["two__parts"] = { label = "Reserved", weight = 1 },
        ["Upper"] = { label = "Upper", weight = 1 },
        heavy = { label = "Heavy", weight = 101 },
        nolabel = { weight = 1 },
    }, "compat_rules")
    out.id_rules = r .. "/" .. j
    out.reason_long = d.reasons["a_very_long_item_identifier_over_32"]
    out.reason_reserved = d.reasons["two__parts"]
    out.reason_upper = d.reasons["Upper"]
    out.reason_heavy = d.reasons.heavy
    out.reason_nolabel = d.reasons.nolabel

    -- v1 fields: metadata, quality (stack variants), durability + serial (instances).
    r, j, d = reg:define({
        ore = { label = "Ore", weight = 1.0, quality = { min = 1, max = 3 } },
        tool = { label = "Tool", weight = 1.5, durability = 20, serial = true, hand = { model = "tool.crowbar", bone = "RightHand" } },
        paint = { label = "Paint", weight = 1.0, metadata = { colour = { type = "enum", values = { "red", "blue" }, default = "red", stack = true } } },
        note = { label = "Note", weight = 0.1, metadata = { text = { type = "string", maxLen = 32 } } },
        badtype = { label = "Bad", weight = 1, metadata = { colour = { type = "rgb" } } },
        badstack = { label = "Bad", weight = 1, metadata = { n = { type = "integer", stack = true, default = 1 } } },
        contradiction = { label = "Bad", weight = 1, unique = false, durability = 5 },
        reserved = { label = "Bad", weight = 1, metadata = { durability = { type = "integer" } } },
        badprop = { label = "Bad", weight = 1, prop = { model = "bad model!" } },
    }, "c1_test")
    out.v1 = r .. "/" .. j
    out.v1_badtype = d.reasons.badtype
    out.v1_badstack = d.reasons.badstack
    out.v1_contradiction = d.reasons.contradiction
    out.v1_reserved = d.reasons.reserved
    out.v1_badprop = d.reasons.badprop
    out.tool_unique = RpInventoryItems.tool.unique
    out.note_unique = RpInventoryItems.note.unique
    out.ore_unique = RpInventoryItems.ore.unique

    local function asset(item, meta) local a, b = reg:assetFor(item, meta); return a or ("nil:" .. tostring(b)) end
    out.asset_ore_plain = asset("ore", nil)
    out.asset_ore_q1 = asset("ore", { quality = 1 })
    out.asset_ore_q3 = asset("ore", { quality = 3 })
    out.asset_ore_q3_again = asset("ore", { quality = 3 })
    out.asset_ore_q9 = asset("ore", { quality = 9 })
    out.asset_ore_unknown = asset("ore", { shiny = true })
    out.asset_paint_blue = asset("paint", { colour = "blue" })
    out.asset_tool = asset("tool", nil)
    out.asset_tool_serial = asset("tool", { serial = "x" })
    out.asset_tool_wear = asset("tool", { durability = 25 })
    out.asset_note_long = asset("note", { text = string.rep("x", 40) })
    local _, toolMeta = reg:assetFor("tool", nil)
    out.tool_default_meta = str(toolMeta)
    local item, meta = reg:decodeAsset("ore__quality_3")
    out.decode_q3 = tostring(item) .. ":" .. str(meta)
    out.decode_bogus = tostring(reg:decodeAsset("ore__quality_9"))
    local tx = reg:txDefinitions()
    out.tx_variants = (tx["ore__quality_2"] and tx["ore__quality_3"] and tx.ore and not tx["ore__quality_1"]) and "ok" or "bad"
    out.tx_tool_unique = tostring(tx.tool.unique)

    -- Shape freeze (transactions backend): a weight change under live containers is refused.
    local frozen = S.newRegistry({}, { freezeShape = true })
    frozen:define({ x = { label = "X", weight = 1 } }, "r")
    r, j, d = frozen:define({ x = { label = "X", weight = 2 } }, "r")
    out.freeze_weight = r .. "/" .. j .. ":" .. tostring(d.reasons.x)
    r, j = frozen:define({ x = { label = "X renamed", weight = 1 } }, "r")
    out.freeze_label = r .. "/" .. j

    -- Catalogue: bounded pages, a version that moves only on a visible change, a verified hash.
    local head, pages = reg:catalogue()
    out.cat_items = head.items
    out.cat_pages = head.pages
    local maxBytes, maxItems = 0, 0
    for _, p in ipairs(pages) do
        maxBytes = math.max(maxBytes, #S.encode(p))
        maxItems = math.max(maxItems, #p.items)
    end
    out.cat_page_bytes_ok = maxBytes <= S.LIMITS.pageBytes + 64
    out.cat_page_items_ok = maxItems <= S.LIMITS.pageItems
    local byId = S.assemble(head, pages)
    out.cat_assemble = byId and (byId.ore and byId.tool and "ok") or "bad"
    out.cat_no_effect = byId and byId.beer and byId.beer.effect == nil
    local v1 = head.version
    reg:define(packDefinitions().rp_crime, "rp_crime")
    out.cat_version_stable = reg:catalogue().version == v1
    reg:define({ crowbar_test = { label = "Crowbar (selftest v2)", weight = 1.5 } }, "rp_selftest")
    out.cat_version_bumped = reg:catalogue().version == v1 + 1
    local tampered = S.copy(pages)
    tampered[1].items[1].label = "tampered"
    local _, why = S.assemble(head, tampered)
    out.cat_tamper = why
    local _, why2 = S.assemble(head, {})
    out.cat_missing = why2

    -- Bounds: 4096 definitions at most, and their catalogue stays within the page budget.
    local big = S.newRegistry({}, {})
    local items = {}
    for i = 1, 4096 do items[("it_%04d"):format(i)] = { label = ("Item %d with a long enough label"):format(i), weight = 0.1 } end
    r, j = big:define(items, "bulk")
    out.bulk = r .. "/" .. j
    r, j, d = big:define({ one_more = { label = "Over", weight = 1 } }, "bulk2")
    out.bulk_full = d.reasons.one_more
    local bh = big:catalogue()
    out.bulk_pages = bh.pages
    return out
end

-- ===========================================================================
-- B2: existing export compatibility, same calls on both backends
-- ===========================================================================
local function compatScript(ex, backend)
    local out = {}
    out.has_empty = tostring(ex.has(A, "water", 1))
    out.count_empty = tostring(ex.count(A, "water"))
    out.add_water = res(ex.add(A, "water", 2))
    out.count_water = tostring(ex.count(A, "water"))
    out.has_2 = tostring(ex.has(A, "water", 2))
    out.has_3 = tostring(ex.has(A, "water", 3))
    out.add_crate = res(ex.add(A, "crate", 1))
    out.add_crate_again = res(ex.add(A, "crate", 1))
    out.remove_too_many = res(ex.remove(A, "water", 5))
    out.remove_one = res(ex.remove(A, "water", 1))
    out.count_after = tostring(ex.count(A, "water"))
    out.unknown_player = res(ex.add(99, "water", 1))
    out.bad_player = res(ex.add("x", "water", 1))
    out.unknown_item = res(ex.add(A, "nope", 1))
    out.zero = res(ex.add(A, "water", 0))
    out.fraction = res(ex.add(A, "water", 1.5))
    out.has_unknown_player = tostring(ex.has(99, "water", 1))
    out.count_unknown_player = tostring(ex.count(99, "water"))
    local entries, weight, capacity = ex.list(A)
    out.list_n = #entries
    out.list_first = entries[1] and (entries[1].id .. ":" .. entries[1].count .. ":" .. entries[1].label) or "none"
    out.list_weight = string.format("%.1f", weight)
    out.list_capacity = tostring(capacity)
    out.list_unknown = res(ex.list(99))
    out.selftest_define = table.concat({ H.as("rp_selftest", ex.define, {
        crowbar_test = { label = "Crowbar (selftest)", weight = 1.5 }, ["BAD ID"] = { label = "x", weight = 1 } }) }, "/", 1, 2)
    out.define_not_table = res(ex.define("nope"))
    out.stash_bad = res(ex.openStash(A, "bad id!", 50))
    out.stash_cap = res(ex.openStash(A, "home:12", 0))
    out.stash_ok = res(ex.openStash(A, "home:12", 50))
    out.meta_unknown = res(ex.add(A, "water", 1, { colour = "red" }))
    -- The command paths: /use (bar, effect, debit), /give (reach + weight checks, then the move).
    ex.add(A, "burrito", 2)
    await(function() H.commands.use(A, { "burrito" }) end)
    out.after_use = tostring(ex.count(A, "burrito"))
    await(function() H.commands.give(A, { tostring(B), "burrito", "1" }) end)
    out.after_give = ex.count(A, "burrito") .. "+" .. ex.count(B, "burrito")
    H.players[B].pos = { x = 9, y = 0, z = 0, bucket = 0 }
    ex.add(A, "burrito", 1)
    await(function() H.commands.give(A, { tostring(B), "burrito", "1" }) end)
    out.give_too_far = ex.count(A, "burrito") .. "+" .. ex.count(B, "burrito")
    out.give_too_far_said = tostring(H.chat[#H.chat] and H.chat[#H.chat].text)
    await(function() H.commands.giveitem(0, { tostring(A), "water", "1" }) end)
    out.after_giveitem = tostring(ex.count(A, "water"))
    out.events = changedEvents(A)
    return out
end

local function compat(backend)
    local ex
    if backend == "transactions" then ex = bootTx() else ex = bootLegacy() end
    local out = compatScript(ex, backend)
    H.run(5)
    if backend == "transactions" then
        out.persisted_water = tostring(TX.count(CHAR_A, "water"))
        out.sys_accounts = (function()
            local seen = {}
            for _, e in ipairs(TX.store.journal) do
                if e.account:match("^sys:") then seen[e.account] = true end
            end
            local list = {}
            for k in pairs(seen) do list[#list + 1] = k end
            table.sort(list)
            return table.concat(list, ",")
        end)()
        out.persisted_crate = tostring(TX.count(CHAR_A, "crate"))
        ex = bootTx()
    else
        local db = H.inventoryDb()
        out.persisted_water = tostring(db.items["acct-a"] and db.items["acct-a"].water or 0)
        out.persisted_crate = tostring(db.items["acct-a"] and db.items["acct-a"].crate or 0)
        ex = bootLegacy()
    end
    out.after_restart_water = tostring(ex.count(A, "water"))
    out.after_restart_burrito = ex.count(A, "burrito") .. "+" .. ex.count(B, "burrito")
    out.after_restart_crate = tostring(ex.count(A, "crate"))
    out.backend = ex.backend()
    out.kvp_keys = tostring(#Open77.kvp.keys(""))
    return out
end

function scenarios.b2_compat_legacy() return compat("legacy") end
function scenarios.b2_compat_transactions() return compat("transactions") end

-- ===========================================================================
-- B2: concurrent pickup, one winner
-- ===========================================================================
function scenarios.b2_concurrent_pickup()
    local ex = bootTx()
    local out = {}
    local w = await(function() return ex.createWorld(100) end)
    local world = w.account
    seed(world, "crate", 1, 100000)
    H.run(1)
    -- 1. Two players through the inventory, commits held back (deferred store).
    TX.store.deferred = true
    local t1 = H.task(function() return ex.worldTakeAsync(A, w.worldId, "crate", 1) end)
    local t2 = H.task(function() return ex.worldTakeAsync(B, w.worldId, "crate", 1) end)
    H.run(1)
    out.loser_before_commit = t2.done and res(t2[1], t2[2]) or "pending"
    TX.store.deferred = false
    TX.store:flush()
    H.run(2)
    out.winner = t1.done and res(t1[1], t1[2]) or "pending"
    out.a_crates = tostring(ex.count(A, "crate"))
    out.b_crates = tostring(ex.count(B, "crate"))
    out.store_total = tostring(TX.total("crate"))
    out.world_left = tostring(TX.count(world, "crate"))
    -- 2. A foreign resource reserves the crate first: the inventory's take loses at the coordinator.
    seed(world, "crate", 1, 100000)
    H.run(1)
    TX.store:openContainer("char:acct-other", { capacityG = 40000 }, function() end)
    TX.store.deferred = true
    local f = foreign({ opId = "foreign-take-0001", kind = "rp_other", lines = {
        { item = "crate", count = 1, from = world, to = "char:acct-other" } } })
    local t3 = H.task(function() return ex.worldTakeAsync(B, w.worldId, "crate", 1) end)
    H.run(1)
    TX.store.deferred = false
    TX.store:flush()
    H.run(2)
    out.foreign_first = f.done and res(f.r, f.reason) or "pending"
    out.inventory_second = t3.done and res(t3[1], t3[2]) or "pending"
    out.store_total_after = tostring(TX.total("crate"))
    out.b_crates_after = tostring(ex.count(B, "crate"))
    out.journal_balanced = tostring(journalBalanced())
    return out
end

-- ===========================================================================
-- B2: a full inventory refuses and conserves
-- ===========================================================================
function scenarios.b2_full_inventory()
    local ex = bootTx()
    local out = {}
    ex.add(A, "scrap", 14)          -- 14 kg
    ex.add(B, "crate", 1)           -- 25 kg
    ex.add(B, "scrap", 14)          -- 39 kg
    H.run(2)
    local w = await(function() return ex.createWorld(100) end)
    seed(w.account, "crate", 1, 100000)
    H.run(1)
    local opsBefore = TX.ops()
    -- Local refusal: B cannot carry a second crate.
    out.b_take = res(await(function() return ex.worldTakeAsync(B, w.worldId, "crate", 1) end))
    -- Coordinator refusal: a foreign credit lands on A between A's view and A's take.
    TX.store:openContainer(CHAR_A, { capacityG = 40000 }, function() end)
    local f = foreign({ opId = "foreign-credit-01", kind = "rp_other", lines = {
        { item = "crate", count = 1, from = "sys:rp_other", to = CHAR_A } } })
    out.foreign_credit = res(f.r, f.reason)
    local t1, t2, t3 = await(function() return ex.worldTakeAsync(A, w.worldId, "crate", 1) end)
    out.a_take = res(t1, t2)
    out.a_take_decided_by = tostring(t3 and t3.coordinator or "local")
    out.world_crates = tostring(TX.count(w.account, "crate"))
    out.a_store_crates = tostring(TX.count(CHAR_A, "crate"))
    -- Give to a full player, store into a full stash.
    out.give_full = res(await(function() return ex.giveAsync(A, B, "scrap", 2) end))
    out.store_full = res(await(function() return ex.storeAsync(A, "box:small", "scrap", 10, { capacity = 5 }) end))
    out.a_scrap = tostring(TX.count(CHAR_A, "scrap"))
    out.b_scrap = tostring(TX.count(CHAR_B, "scrap"))
    out.ops_added = tostring(TX.ops() - opsBefore)  -- only the foreign credit
    out.crates_total = tostring(TX.total("crate"))
    H.run(3)
    out.a_view_crates = tostring(ex.count(A, "crate"))  -- the foreign credit reached the view (event)
    out.journal_balanced = tostring(journalBalanced())
    return out
end

-- ===========================================================================
-- B2: give between players is atomic
-- ===========================================================================
function scenarios.b2_give_atomic()
    local ex = bootTx()
    local out = {}
    ex.add(A, "burrito", 4)
    ex.add(A, "crate", 1)
    ex.add(B, "scrap", 30)
    H.run(2)
    H.events = {}
    local r = await(function() return ex.giveAsync(A, B, "burrito", 2) end)
    out.give = res(r)
    out.give_opId = type(r) == "table" and (r.opId ~= nil and "yes" or "no") or "no"
    out.a_burrito = tostring(ex.count(A, "burrito")) .. "/" .. tostring(TX.count(CHAR_A, "burrito"))
    out.b_burrito = tostring(ex.count(B, "burrito")) .. "/" .. tostring(TX.count(CHAR_B, "burrito"))
    out.events = changedEvents()
    -- Receiver full: refused, nothing moves.
    out.give_heavy = res(await(function() return ex.giveAsync(A, B, "crate", 1) end))
    out.a_crate = tostring(TX.count(CHAR_A, "crate"))
    -- Lost acknowledgement: the coordinator fences, finds the commit, applies it once.
    TX.store.faults = { "lost_ack" }
    out.give_lost_ack = res(await(function() return ex.giveAsync(A, B, "burrito", 1) end))
    out.after_lost_ack = TX.count(CHAR_A, "burrito") .. "+" .. TX.count(CHAR_B, "burrito")
    -- Connection lost before COMMIT: fenced as aborted, nothing moved, a retry succeeds.
    TX.store.faults = { "unreachable_before" }
    local f1, f2 = await(function() return ex.giveAsync(A, B, "burrito", 1) end)
    out.give_unreachable = res(f1, f2)
    out.after_unreachable = TX.count(CHAR_A, "burrito") .. "+" .. TX.count(CHAR_B, "burrito")
    out.give_retry = res(await(function() return ex.giveAsync(A, B, "burrito", 1) end))
    out.after_retry = TX.count(CHAR_A, "burrito") .. "+" .. TX.count(CHAR_B, "burrito")
    -- Idempotent business id: the same opId twice moves once.
    ex.add(A, "water", 2)
    H.run(2)
    local o1 = await(function() return ex.giveAsync(A, B, "water", 1, { opId = "bar:serve:42:nonce-1" }) end)
    local o2 = await(function() return ex.giveAsync(A, B, "water", 1, { opId = "bar:serve:42:nonce-1" }) end)
    out.same_opid = res(o1) .. "," .. (type(o2) == "table" and tostring(o2.replay) or res(o2))
    out.water = TX.count(CHAR_A, "water") .. "+" .. TX.count(CHAR_B, "water")
    out.total_burrito = tostring(TX.total("burrito"))
    out.journal_balanced = tostring(journalBalanced())
    return out
end

-- ===========================================================================
-- B2: crash between steps -- every fault window conserves
-- ===========================================================================
local function conservationRun(flow, fault)
    TX.start()
    H.stores.sql.inv = nil
    local ex = bootTx()
    ex.add(A, "scrap", 4)
    H.run(2)
    if flow ~= "give" then
        await(function() return ex.storeAsync(A, "home:3", "scrap", 2, { capacity = 50 }) end)
    end
    local initial = TX.total("scrap")
    local box
    if fault == "coordinator_crash" or fault == "inventory_restart" then
        TX.store.deferred = true
    elseif fault ~= "none" then
        TX.store.faults = { fault }
    end
    box = H.task(function()
        if flow == "give" then return ex.giveAsync(A, B, "scrap", 1) end
        if flow == "store" then return ex.storeAsync(A, "home:3", "scrap", 1) end
        return ex.takeAsync(A, "home:3", "scrap", 1)
    end)
    H.run(1)
    if fault == "coordinator_crash" then
        TX.store.deferred = false
        TX.crash()
        H.emit("onResourceStop", "open77_transactions")
        H.emit("onResourceStart", "open77_transactions")
        H.run(40)
    elseif fault == "inventory_restart" then
        ex = bootTx({ settle = 1 })
        TX.store.deferred = false
        TX.store:flush()
        ex = bootTx()
    end
    H.run(40)
    local outcome = box.done and res(box[1], box[2]) or "dropped"
    local viewA, storeA = ex.count(A, "scrap"), TX.count(CHAR_A, "scrap")
    local ok = TX.total("scrap") == initial and viewA == storeA and journalBalanced()
    return ok, outcome, ("%s/%s total %d->%d"):format(viewA, storeA, initial, TX.total("scrap"))
end

function scenarios.b2_crash_between_steps()
    local out = {}
    for _, flow in ipairs({ "give", "store", "take" }) do
        for _, fault in ipairs({ "none", "unreachable_before", "lost_ack", "failed", "refused",
            "coordinator_crash", "inventory_restart" }) do
            local ok, outcome, detail = conservationRun(flow, fault)
            out[flow .. "_" .. fault] = tostring(ok) .. " " .. outcome .. " " .. detail
        end
    end
    return out
end

-- ===========================================================================
-- B2: write-behind (legacy synchronous exports)
-- ===========================================================================
function scenarios.b2_write_behind()
    local ex = bootTx()
    local out = {}
    -- Ordering: commits held back, the queue submits one operation at a time per account.
    TX.store.deferred = true
    ex.add(A, "water", 3)
    ex.remove(A, "water", 2)
    ex.add(A, "water", 1)
    out.view_now = tostring(ex.count(A, "water"))
    out.store_now = tostring(TX.count(CHAR_A, "water"))
    for _ = 1, 10 do TX.store:flush(); H.run(1) end
    TX.store.deferred = false
    H.run(2)
    out.store_after = tostring(TX.count(CHAR_A, "water"))
    out.ops = tostring(TX.ops("inv.add") + TX.ops("inv.remove"))
    -- A foreign writer drains the stock under a pending remove: the write-behind is lost,
    -- reported, and the view resyncs to the coordinator's truth.
    H.events = {}
    TX.store.deferred = true
    local f = foreign({ opId = "foreign-drain-0001", kind = "rp_other", lines = {
        { item = "water", count = 2, from = CHAR_A, to = "sys:thief" } } })
    ex.remove(A, "water", 2)
    TX.store.deferred = false
    TX.store:flush()
    H.run(5)
    out.foreign_drain = res(f.r, f.reason)
    out.after_drain_view = tostring(ex.count(A, "water"))
    out.after_drain_store = tostring(TX.count(CHAR_A, "water"))
    out.drain_events = changedEvents(A)
    -- The coordinator stops: mutations refuse, nothing is written anywhere else.
    ex.add(A, "water", 1)
    H.run(2)
    TX.stop()
    H.emit("onResourceStop", "open77_transactions")
    H.run(1)
    out.add_while_down = res(ex.add(A, "water", 1))
    out.remove_while_down = res(ex.remove(A, "water", 1))
    out.reads_while_down = tostring(ex.count(A, "water")) .. "/" .. tostring(ex.has(A, "water", 1))
    out.kvp_keys = tostring(#Open77.kvp.keys(""))
    -- It comes back: the facade shakes hands again (new opId prefix, definitions pushed).
    TX.start({ keepStore = true })
    H.emit("onResourceStart", "open77_transactions")
    H.run(5)
    out.add_after_restart = res(ex.add(A, "water", 1))
    H.run(2)
    out.store_final = tostring(TX.count(CHAR_A, "water"))
    -- An accepted write that is still queued when rp_inventory restarts is lost: the restarted
    -- view shows the coordinator's truth, never a phantom (no stronger than the old write-through).
    TX.stop()
    out.add_queued = res(ex.add(A, "water", 1))
    TX.start({ keepStore = true })
    ex = bootTx()
    out.after_inventory_restart = tostring(ex.count(A, "water")) .. "/" .. tostring(TX.count(CHAR_A, "water"))
    -- Disconnect with a write still in flight, reconnect before it lands: the view is reused,
    -- and later writes still reach the coordinator.
    TX.store.deferred = true
    out.add_before_disconnect = res(ex.add(A, "water", 1))
    H.run(1)
    H.emit("onPlayerDisconnected", A)
    H.run(1)
    H.emit("onPlayerReady", A)
    H.run(1)
    TX.store.deferred = false
    TX.store:flush()
    H.run(3)
    out.add_after_reconnect = res(ex.add(A, "water", 1))
    H.run(3)
    out.reconnect = tostring(ex.count(A, "water")) .. "/" .. tostring(TX.count(CHAR_A, "water"))
    out.journal_balanced = tostring(journalBalanced())
    return out
end

-- ===========================================================================
-- B2: metadata, stacks, instances and wear
-- ===========================================================================
function scenarios.b2_meta_and_wear()
    local ex = bootTx()
    local out = {}
    out.define = table.concat({ H.as("c1_test", ex.define, {
        ore = { label = "Ore", weight = 1.0, quality = { min = 1, max = 3 } },
        tool = { label = "Tool", weight = 1.5, durability = 3, serial = true },
    }) }, "/", 1, 2)
    H.run(2)
    out.add_plain = res(ex.add(A, "ore", 2))
    out.add_q3 = res(ex.add(A, "ore", 3, { quality = 3 }))
    out.add_q9 = res(ex.add(A, "ore", 1, { quality = 9 }))
    out.add_unknown_meta = res(ex.add(A, "ore", 1, { shiny = true }))
    H.run(2)
    out.count_ore = tostring(ex.count(A, "ore"))
    out.store_plain = tostring(TX.count(CHAR_A, "ore"))
    out.store_q3 = tostring(TX.count(CHAR_A, "ore__quality_3"))
    -- Legacy remove order: the plain stack first, then the variants.
    out.remove3 = res(ex.remove(A, "ore", 3))
    H.run(2)
    out.after_remove = TX.count(CHAR_A, "ore") .. "+" .. TX.count(CHAR_A, "ore__quality_3")
    -- Instances: a durable unit with its own serial and wear.
    local r = await(function() return ex.addAsync(A, "tool", 1) end)
    out.add_tool = res(r)
    local iid, inst
    for id, i in pairs(TX.store.instances) do if i.item == "tool" then iid, inst = id, i end end
    out.tool_meta = inst and ("dur=" .. tostring(inst.meta.durability) .. " serial=" .. tostring(inst.meta.serial == iid)) or "none"
    local w1 = await(function() return ex.wearAsync(A, "tool", 1) end)
    out.wear1 = type(w1) == "table" and ("dur=" .. w1.durability .. " broken=" .. tostring(w1.broken)) or res(w1)
    out.store_wear = tostring(TX.store.instances[iid].meta.durability)
    out.wear_keeps_serial = tostring(TX.store.instances[iid].meta.serial == iid)
    local seen = await(function() return ex.read(CHAR_A) end)
    local unit = type(seen) == "table" and seen.instances[iid]
    out.wear_view = unit and (tostring(unit.meta.durability) .. " serial=" .. tostring(unit.meta.serial == iid)) or "none"
    -- Wear persists across an rp_inventory restart (it lives on the instance row). The definer
    -- re-defines on rp_inventory's start, as every definer of the pack does.
    ex = bootTx()
    H.as("c1_test", ex.define, {
        ore = { label = "Ore", weight = 1.0, quality = { min = 1, max = 3 } },
        tool = { label = "Tool", weight = 1.5, durability = 3, serial = true },
    })
    H.run(1)
    out.after_restart = tostring(ex.count(A, "tool")) .. " dur=" .. tostring(TX.store.instances[iid].meta.durability)
    local w2, w2why = await(function() return ex.wearAsync(A, "tool", 5) end)
    out.wear2 = type(w2) == "table" and ("dur=" .. w2.durability .. " broken=" .. tostring(w2.broken)) or res(w2, w2why)
    out.tool_after_break = tostring(ex.count(A, "tool")) .. " in=" .. tostring(TX.store.instances[iid].container)
    -- A legacy add of a unique item makes instances; a legacy remove destroys the most worn.
    out.legacy_add_tool = res(ex.add(A, "tool", 2))
    H.run(2)
    out.tool_instances = tostring(TX.instancesOf("tool"))
    out.legacy_remove_tool = res(ex.remove(A, "tool", 1))
    H.run(2)
    out.tool_instances_after = tostring(TX.instancesOf("tool"))
    out.journal_balanced = tostring(journalBalanced())
    -- The legacy backend validates metadata but cannot store it.
    local lex = bootLegacy()
    H.as("c1_test", lex.define, { ore = { label = "Ore", weight = 1.0, quality = { min = 1, max = 3 } } })
    out.legacy_meta_variant = res(lex.add(A, "ore", 1, { quality = 3 }))
    out.legacy_meta_default = res(lex.add(A, "ore", 1, { quality = 1 }))
    out.legacy_meta_unknown = res(lex.add(A, "ore", 1, { shiny = true }))
    return out
end

-- ===========================================================================
-- B2: durable keys and authorization hooks
-- ===========================================================================
function scenarios.b2_keys_and_auth()
    local ex = bootTx()
    local out = {}
    out.stash_digits = res(ex.openStash(A, "12", 50))
    out.stash_session = res(ex.openStash(A, "session:3", 50))
    out.stash_runtime = res(ex.openStash(A, "trunk:4711", 50))
    out.stash_home = res(ex.openStash(A, "home:12", 50))
    out.veh_digits = res(ex.vehicleAccount("4711", "trunk"))
    out.veh_plate = res(ex.vehicleAccount("nc-1234", "trunk"))
    out.veh_part = res(ex.vehicleAccount("NC-1234", "Trunk!"))
    out.world_digits = res(ex.worldAccount("12345678"))
    out.account_of = res(ex.accountOf(A))
    out.move_digit_char = res(await(function() return ex.moveAsync({ { item = "water", count = 1, from = "sys:x", to = "char:7" } }) end))
    out.move_session_char = res(await(function() return ex.moveAsync({ { item = "water", count = 1, from = "sys:x", to = "char:session-3" } }) end))
    ex.add(A, "scrap", 3)
    ex.add(B, "scrap", 3)
    H.run(2)
    -- Vehicles fail closed until the key owner (A9) registers its authorizer.
    out.veh_before_open = res(await(function() return ex.vehicleStoreAsync(A, "NC-1234", "trunk", "scrap", 1) end))
    out.open_vehicle = res(await(function() return ex.openVehicle("NC-1234", "trunk", 100) end))
    out.veh_no_authorizer = res(await(function() return ex.vehicleStoreAsync(A, "NC-1234", "trunk", "scrap", 1) end))
    local seen
    H.resources.rp_keys_test = { canUseTrunk = function(req)
        seen = req
        if req.subject == CHAR_A then return true end
        return false, "no_key"
    end }
    out.register = res(H.as("rp_keys_test", ex.registerAuthorizer, "veh", "canUseTrunk"))
    out.register_taken = res(H.as("rp_other", ex.registerAuthorizer, "veh", "mine"))
    out.register_bad_scope = res(H.as("rp_keys_test", ex.registerAuthorizer, "char", "x"))
    out.veh_owner = res(await(function() return ex.vehicleStoreAsync(A, "NC-1234", "trunk", "scrap", 2) end))
    out.request = seen and (seen.action .. ":" .. seen.account .. ":" .. tostring(seen.plate)) or "none"
    out.veh_stranger = res(await(function() return ex.vehicleTakeAsync(B, "NC-1234", "trunk", "scrap", 1) end))
    out.veh_untracked = res(await(function() return ex.vehicleStoreAsync(A, "NC-9999", "trunk", "scrap", 1) end))
    out.veh_owner_take = res(await(function() return ex.vehicleTakeAsync(A, "NC-1234", "trunk", "scrap", 1) end))
    out.trunk = tostring(TX.count("veh:NC-1234:trunk", "scrap"))
    -- The authorizer's resource stops: the scope is released, vehicles fail closed again.
    H.emit("onResourceStop", "rp_keys_test")
    H.run(1)
    out.after_stop = res(await(function() return ex.vehicleTakeAsync(A, "NC-1234", "trunk", "scrap", 1) end))
    -- A stash authorizer is asked on every move (a revoked key stops the next take).
    local allowed = true
    H.resources.rp_housing_test = { canUseStash = function(req) return allowed, "revoked" end }
    H.as("rp_housing_test", ex.registerAuthorizer, "stash:home", "canUseStash")
    out.stash_store = res(await(function() return ex.storeAsync(A, "home:12", "scrap", 1, { capacity = 50 }) end))
    allowed = false
    out.stash_take_revoked = res(await(function() return ex.takeAsync(A, "home:12", "scrap", 1) end))
    out.other_prefix = res(await(function() return ex.storeAsync(A, "garage:1", "scrap", 1, { capacity = 50 }) end))
    out.journal_balanced = tostring(journalBalanced())
    return out
end

-- ===========================================================================
-- B2: /drop through a world container
-- ===========================================================================
function scenarios.b2_drop_pickup()
    local ex = bootTx({ players = players({ [9] = { identifier = "acct-c", name = "Cid", pos = { x = 50, y = 50, z = 0, bucket = 0 } } }) })
    local out = {}
    ex.add(A, "crate", 1)
    ex.add(B, "crate", 1)
    ex.add(B, "scrap", 14)    -- 39 kg: B cannot lift a second crate
    H.run(2)
    await(function() H.commands.drop(A, { "crate", "1" }) end)
    local dropId
    for id in pairs(H.loot.drops) do dropId = id end
    local world
    for id in pairs(TX.store.containers) do if id:match("^world:") then world = id end end
    out.after_drop = TX.count(CHAR_A, "crate") .. "/" .. tostring(world and TX.count(world, "crate"))
    out.drop_record = tostring(H.loot.drops[dropId] and H.loot.drops[dropId].item)
    -- B is too full: the drop comes back where it lay, the goods never left the world container.
    H.nativePickup(B, dropId)
    H.run(3)
    local again, againPos
    for id, d in pairs(H.loot.drops) do again, againPos = id, d.position end
    out.refused_pickup = TX.count(CHAR_B, "crate") .. "/" .. TX.count(world, "crate")
    out.reprojected_at_origin = tostring(again ~= nil and againPos.x == 0 and againPos.y == 0)
    -- Cid picks it up.
    H.nativePickup(9, again)
    H.run(3)
    out.picked = TX.count("char:acct-c", "crate") .. "/" .. TX.count(world, "crate")
    out.crates_total = tostring(TX.total("crate"))
    -- A drop that expires evaporates through a journaled operation.
    ex.add(A, "water", 2)
    H.run(2)
    await(function() H.commands.drop(A, { "water", "2" }) end)
    local waterDrop
    for id, d in pairs(H.loot.drops) do waterDrop = id end
    H.expireDrop(waterDrop)
    H.run(3)
    out.expired = tostring(TX.total("water")) .. " ops=" .. tostring(TX.ops("inv.expire"))
    -- Emptied world: containers are closed (the crate after its pickup, the water after expiry).
    out.closed_after_pickup = tostring(TX.store.containers[world] == nil)
    -- An rp_inventory restart loses the projection (the platform removes a stopped resource's
    -- loot), never the goods: the coordinator keeps the drop's metadata and expiry, and the next
    -- start lists it (listWorld) and projects it again where it lay.
    ex.add(A, "scrap", 2)
    H.run(2)
    await(function() H.commands.drop(A, { "scrap", "2" }) end)
    local scrapWorld
    for id, c in pairs(TX.store.containers) do
        if id:match("^world:") and (c.stacks.scrap or 0) > 0 then scrapWorld = id end
    end
    local m = scrapWorld and TX.store.containers[scrapWorld].meta or {}
    out.drop_meta = ("%s:%s:%s:%s"):format(tostring(m.owner), tostring(m.kind), tostring(m.item), tostring(m.count))
    out.drop_id_minted = tostring(scrapWorld ~= nil and scrapWorld:match("^world:lab%.") ~= nil)
    out.drop_expires = tostring(scrapWorld ~= nil and TX.store.containers[scrapWorld].expiresAt ~= nil)
    for id, d in pairs(H.loot.drops) do if d.owner == "rp_inventory" then H.loot.drops[id] = nil end end
    ex = bootTx()
    out.after_restart_scrap_total = tostring(TX.total("scrap"))
    local again2
    for id, d in pairs(H.loot.drops) do if d.owner == "rp_inventory" and d.quantity == 2 then again2 = id end end
    out.reprojected_after_restart = tostring(again2 ~= nil)
    out.reprojected_where = again2 and (H.loot.drops[again2].position.x .. "," .. H.loot.drops[again2].position.y) or "none"
    if again2 then H.nativePickup(A, again2) end
    H.run(3)
    out.picked_after_restart = TX.count(CHAR_A, "scrap") .. " closed=" .. tostring(TX.store.containers[scrapWorld] == nil)
    local left = 0
    for id in pairs(TX.store.containers) do if id:match("^world:") then left = left + 1 end end
    out.world_rows_left = tostring(left)
    out.journal_balanced = tostring(journalBalanced())
    return out
end

-- ===========================================================================
-- B2: a drop or a pickup answered in_doubt decides its projection when it settles
-- ===========================================================================
local function ownLoot(quantity)
    local list = {}
    for id, d in pairs(H.loot.drops) do
        if d.owner == "rp_inventory" and (not quantity or d.quantity == quantity) then list[#list + 1] = id end
    end
    table.sort(list)
    return list
end

local function settledEvents()
    local out = {}
    for _, e in ipairs(H.events) do
        if e.name == "rp_inventory:settled" then out[#out + 1] = tostring(e.args[2]) end
    end
    return table.concat(out, ",")
end

-- The commit is queued, lands (or not), and its acknowledgement is lost while the store stays
-- unreachable for the fence: the facade stops waiting (its 20 s deadline, checked between status
-- polls) and answers in_doubt; then the store comes back and the fence settles the outcome.
local function inDoubt(fault, start)
    TX.store.deferred = true
    TX.store.faults = { fault }
    local box = H.task(start)
    for _ = 1, 40 do
        if TX.store:pending() > 0 then break end
        H.run(0.25)
    end
    TX.store:step()          -- the commit (applied for lost_ack, not for unreachable_before)
    for _ = 1, 8 do TXS.step() end   -- the coordinator reads the ambiguous answer, sends its fence
    TX.store.down = true
    TX.store:flush()         -- the fence cannot reach the database
    H.run(35)
    local during = box.done and "answered" or "waiting"
    TX.store.down = false
    TX.store.deferred = false
    TX.store:flush()
    H.run(40)
    return box, during
end

function scenarios.b2_drop_in_doubt()
    TX.start()
    H.stores.sql.inv = nil
    local ex = bootTx()
    local out = {}
    H.events = {}
    ex.add(A, "scrap", 4)
    H.run(2)
    -- 1. The drop committed, its answer was lost: projected once it settles, where it was dropped.
    local _, during = inDoubt("lost_ack", function() H.commands.drop(A, { "scrap", "2" }) end)
    out.drop_committed = during .. " " .. TX.count(CHAR_A, "scrap") .. " loot=" .. #ownLoot(2)
    local first = ownLoot(2)[1]
    out.drop_projected_at = first and (H.loot.drops[first].position.x .. "," .. H.loot.drops[first].position.y) or "none"
    -- 2. A pickup committed with its answer lost: not re-projected (the goods are in the pockets).
    local loot = ownLoot(2)[1]
    inDoubt("lost_ack", function() H.nativePickup(B, loot) end)
    out.pickup_committed = TX.count(CHAR_B, "scrap") .. " loot=" .. #ownLoot(2)
    -- 3. A drop that never reached the database: fenced, nothing moved, no projection, closed.
    inDoubt("unreachable_before", function() H.commands.drop(A, { "scrap", "1" }) end)
    local open = 0
    for id in pairs(TX.store.containers) do if id:match("^world:") then open = open + 1 end end
    out.drop_fenced = TX.count(CHAR_A, "scrap") .. " loot=" .. #ownLoot(1) .. " world_rows=" .. open
    out.settled_events = settledEvents()
    out.total = tostring(TX.total("scrap"))
    out.journal_balanced = tostring(journalBalanced())
    return out
end

-- ===========================================================================
-- B2: the final coordinator API (697e9e2f): subject provider, mint rules, per-part writers,
-- lazy reads, minted world ids, failed vs fenced operation ids, the ready handshake
-- ===========================================================================
function scenarios.b2_final_api()
    local out = {}
    -- Subject provider: one override (a character layer) decides the pockets' key; a refusal is
    -- passed through, never replaced by the account identifier.
    TX.start()
    H.stores.sql.inv = nil
    H.resources.rp_identity_test = { characterOf = function(who)
        if who == A then return "acct-a~2" end
        return nil, "no_character"
    end }
    out.provider = res(TXS.callSync("rp_identity_test", "registerSubjectProvider", "characterOf"))
    out.provider_second = res(TXS.callSync("rp_other", "registerSubjectProvider", "mine"))
    local ex = bootTx()
    out.subject_a = res(ex.accountOf(A))
    out.subject_b = res(ex.accountOf(B))
    out.add_a = res(ex.add(A, "water", 1))
    out.add_b = res(ex.add(B, "water", 1))
    H.run(2)
    out.subject_store = TX.count("char:acct-a~2", "water") .. "/" .. TX.count(CHAR_A, "water")
    H.resources.rp_identity_test = nil

    -- Mint rules (nothing mints by default): an unlisted sys: source is refused at once, a burn
    -- never is; a cap the hour has used up refuses the next credit at the coordinator.
    TX.start({ tunables = { mint1 = "rp_inventory sys:rp_bar * 3; rp_inventory sys:admin * 100", mint2 = "" } })
    ex = bootTx()
    out.mint_listed = res(H.as("rp_bar", ex.add, A, "water", 3))
    out.mint_unlisted = res(H.as("rp_crime", ex.add, A, "water", 1))
    out.burn_unlisted = res(H.as("rp_crime", ex.remove, A, "water", 1))
    H.run(2)
    H.events = {}
    out.mint_over_cap = res(H.as("rp_bar", ex.add, A, "water", 1))
    H.run(3)
    out.mint_over_cap_store = tostring(TX.count(CHAR_A, "water"))
    out.mint_over_cap_events = changedEvents(A)
    out.allowed_money = tostring((TXS.callSync("compat_test", "allowed", "rp_inventory", "sys:rp_bar", "money")))

    -- Per-part writers: rp_inventory may write vehicle trunks, not cargo beds (rp_cargo's).
    TX.start({ tunables = { writers = "rp_inventory:char+stash+world+veh/trunk, compat_seed, rp_other" } })
    ex = bootTx()
    out.part_trunk = res(await(function() return ex.openVehicle("NC-7777", "trunk", 50) end))
    out.part_cargo = res(await(function() return ex.openVehicle("NC-7777", "cargo", 50) end))
    out.allowed_cargo = res(TXS.callSync("compat_test", "allowed", "rp_inventory", "veh:NC-7777:cargo"))

    -- A job without the char right credits the pockets in ONE granted operation (C1 salvage).
    TX.start({ tunables = { writers = "rp_inventory:char+stash+world+veh/trunk, rp_salvage_test:world",
        mint2 = "rp_salvage_test sys:salvage * 100" } })
    ex = bootTx({ config = { pocketGrantees = { rp_salvage_test = true } } })
    local function jobCredit(opId)
        local box
        TXS.call("rp_salvage_test", "transfer", function(_, r, why) box = { r = r, why = why } end,
            { opId = opId, kind = "salvage.credit", lines = { { item = "scrap", count = 2, from = "sys:salvage", to = CHAR_A } } })
        for _ = 1, 40 do
            if box then break end
            H.run(0.25)
        end
        return box and res(box.r, box.why) or "timeout"
    end
    out.job_without_grant = jobCredit("salvage:credit:0001")
    out.grant_pockets = res(H.as("rp_salvage_test", ex.grantPockets, "salvage:credit:0002", A))
    out.grant_not_allowed = res(H.as("rp_crime", ex.grantPockets, "salvage:credit:0003", A))
    out.job_with_grant = jobCredit("salvage:credit:0002")
    H.run(2)
    out.job_view = tostring(ex.count(A, "scrap"))

    -- Lazy read: a container never opened reads as absent and is not created by the read.
    TX.start()
    ex = bootTx()
    local snap = await(function() return ex.read("stash:never-opened") end)
    out.lazy_read = type(snap) == "table" and tostring(snap.exists) or res(snap)
    out.lazy_read_created = tostring(TX.store.containers["stash:never-opened"] ~= nil)

    -- World ids are minted by the coordinator, with the caller's metadata.
    out.world_chosen_id = res(await(function() return ex.createWorld(10, { worldId = "mycrate01" }) end))
    local w = await(function() return ex.createWorld(10, { meta = { model = "crate", x = 1 } }) end)
    out.world_minted = tostring(type(w) == "table" and w.account:match("^world:lab%.") ~= nil)
    out.world_meta = type(w) == "table" and tostring(TX.store.containers[w.account].meta.model) or "none"

    -- A failed operation id is a fresh attempt; a fenced one is aborted for ever.
    ex.add(A, "water", 4)
    H.run(2)
    TX.store.faults = { "refused" }
    out.failed_first = res(await(function() return ex.giveAsync(A, B, "water", 1, { opId = "bar:serve:77:n1" }) end))
    out.failed_same_id = res(await(function() return ex.giveAsync(A, B, "water", 1, { opId = "bar:serve:77:n1" }) end))
    TX.store.faults = { "unreachable_before" }
    local f1, f2, f3 = await(function() return ex.giveAsync(A, B, "water", 1, { opId = "bar:serve:77:n2" }) end)
    out.fenced_first = res(f1, f2) .. ":" .. tostring(type(f3) == "table" and f3.state)
    out.fenced_same_id = res(await(function() return ex.giveAsync(A, B, "water", 1, { opId = "bar:serve:77:n2" }) end))
    H.run(3)
    out.fenced_new_id = res(await(function() return ex.giveAsync(A, B, "water", 1, { opId = "bar:serve:77:n3" }) end))
    out.water = TX.count(CHAR_A, "water") .. "+" .. TX.count(CHAR_B, "water")

    -- The handshake waits for info().ready: a coordinator whose database has not answered yet
    -- refuses every mutation (store_unavailable), then serves once it is ready.
    TX.start({ dbMode = "late" })
    local logsFrom = 0
    ex = bootTx({ settle = 5 })
    local function readyLines()
        local n = 0
        for i = logsFrom + 1, #H.logs do if H.logs[i]:find("transactions backend ready", 1, true) then n = n + 1 end end
        return n
    end
    out.late_info = tostring(TXS.callSync("compat_test", "info").phase)
    out.late_ready_lines = tostring(readyLines())
    out.late_create = res(ex.createWorld(10))
    TXS.dbMode = "sql"
    H.run(40)
    out.late_ready_after = tostring(readyLines())
    out.late_create_after = res(await(function() return ex.createWorld(10) end))
    out.journal_balanced = tostring(journalBalanced())
    out.kvp_keys = tostring(#Open77.kvp.keys(""))
    return out
end

-- ===========================================================================
-- B2: one-shot migration of the legacy tables (golden fixture)
-- ===========================================================================
local FIXTURE = HARNESS .. "/fixtures/inventory_legacy_5dcdad2.lua"

local function installLegacy(fx)
    local db = H.inventoryDb()
    db.tables.rp_inventory_items, db.tables.rp_inventory_stashes = true, true
    for identifier, items in pairs(fx.items) do
        db.items[identifier] = {}
        for item, n in pairs(items) do db.items[identifier][item] = n end
    end
    for stashId, items in pairs(fx.stashes) do
        db.stashes[stashId] = {}
        for item, n in pairs(items) do db.stashes[stashId][item] = n end
    end
end

local function defineFixtureItems(ex)
    H.as("rp_ferrailleur", ex.define, { crowbar = { label = "Crowbar", weight = 1.5, usable = false, illegal = false } })
    local bulk = {}
    for i = 1, 45 do bulk[("bulk_%02d"):format(i)] = { label = "Bulk " .. i, weight = 0.1 } end
    H.as("compat_bulk", ex.define, bulk)
    H.run(2)
end

-- Runs the console command (source 0: its answers go to the server log) and returns them.
local function invmigrate(...)
    local args = { ... }
    local from = #H.logs
    await(function() H.commands.invmigrate(0, args) end)
    local lines = {}
    for i = from + 1, #H.logs do
        local text = H.logs[i]:match("%[invmigrate%] (.*)$")
        if text then lines[#lines + 1] = text end
    end
    return table.concat(lines, " | ")
end

local function compareGolden(fx)
    local bad = {}
    for account, want in pairs(fx.expected) do
        local c = TX.store.containers[account]
        if not c then
            bad[#bad + 1] = account .. ":missing"
        else
            if c.weightG ~= want.weightG then bad[#bad + 1] = account .. ":weight " .. c.weightG end
            if c.capacityG ~= want.capacityG then bad[#bad + 1] = account .. ":capacity " .. c.capacityG end
            for item, n in pairs(want.stacks) do
                if (c.stacks[item] or 0) ~= n then bad[#bad + 1] = account .. ":" .. item end
            end
            for item in pairs(c.stacks) do
                if not want.stacks[item] then bad[#bad + 1] = account .. ":extra " .. item end
            end
        end
    end
    table.sort(bad)
    return #bad == 0 and "ok" or table.concat(bad, ",")
end

function scenarios.b2_migration()
    local fx = dofile(FIXTURE)
    TX.start()
    installLegacy(fx)
    local ex = bootTx({ players = {} })
    defineFixtureItems(ex)
    local out = {}
    out.first_run = invmigrate("all")
    out.golden = compareGolden(fx)
    local m = H.inventoryDb().markers
    out.markers = tostring(m["char:acct-a"] ~= nil) .. "," .. tostring(m["char:acct-b"] ~= nil) .. ","
        .. tostring(m["char:acct-c"] ~= nil) .. "," .. tostring(m["char:acct-e"] ~= nil) .. ","
        .. tostring(m["char:acct-z"] ~= nil) .. "," .. tostring(m["stash:home:12"] ~= nil) .. ","
        .. tostring(m["stash:12"] ~= nil)
    out.marker_version = tostring(m["char:acct-a"] and m["char:acct-a"].version)
    out.chunks_acct_e = tostring((function()
        local n = 0
        for id, op in pairs(TX.store.ops) do if id:find("char:acct-e", 1, true) and op.state == "committed" then n = n + 1 end end
        return n
    end)())
    out.migrate_ops = tostring(TX.ops("migrate"))
    out.journal_balanced = tostring(journalBalanced())
    out.legacy_untouched = tostring(H.inventoryDb().items["acct-a"].water == 3 and H.inventoryDb().stashes["home:12"].scrap == 10)
    -- Idempotent: a second run imports nothing more.
    local opsBefore, journalBefore = TX.ops(), #TX.store.journal
    out.second_run = invmigrate("all")
    out.second_run_ops = tostring(TX.ops() - opsBefore) .. "/" .. tostring(#TX.store.journal - journalBefore)
    out.golden_after_rerun = compareGolden(fx)
    -- Unknown ids: refused by default, imported (flagged, weight 0) on request.
    out.acct_c_default = invmigrate("char", "acct-c")
    -- Crash between the import commit and the marker: the rerun finds the commit (status), writes
    -- the marker, imports nothing twice -- even across a coordinator restart.
    local db = H.inventoryDb()
    db.items["acct-f"] = { water = 2, scrap = 1 }
    H.sqlFail["INSERT INTO rp_inventory_migrations"] = "database_unreachable"
    out.crash_marker = invmigrate("char", "acct-f")
    out.crash_store = tostring(TX.count("char:acct-f", "water"))
    TX.start({ keepStore = true })
    H.emit("onResourceStart", "open77_transactions")
    H.run(3)
    out.crash_rerun = invmigrate("char", "acct-f")
    out.crash_store_after = tostring(TX.count("char:acct-f", "water")) .. " marker=" .. tostring(db.markers["char:acct-f"] ~= nil)
    -- Unique items import as instances whose ids derive from the subject, item and index.
    H.as("c1_test", ex.define, { tool_u = { label = "Tool U", weight = 1.0, durability = 5, serial = true } })
    H.run(1)
    db.items["acct-u"] = { tool_u = 3 }
    out.unique_import = invmigrate("char", "acct-u")
    local ids = {}
    for iid, i in pairs(TX.store.instances) do
        if i.container == "char:acct-u" then
            ids[#ids + 1] = iid:gsub("%.[0-9a-f]+%.", ".<h>.", 1) .. "=" .. tostring(i.meta.durability) .. (i.meta.serial == iid and "s" or "")
        end
    end
    table.sort(ids)
    out.unique_instances = table.concat(ids, ",")
    -- A transient failure fences the first attempt (aborted, never committable): the same run
    -- moves on to the next attempt id of the deterministic sequence and imports once.
    db.items["acct-v"] = { water = 2 }
    TX.store.faults = { "unreachable_before" }
    out.fenced_first_attempt = invmigrate("char", "acct-v")
    out.fenced_ops = tostring(TX.store.ops["mig1:char:acct-v:c1"] and TX.store.ops["mig1:char:acct-v:c1"].state)
        .. "," .. tostring(TX.store.ops["mig1:char:acct-v:c1.a2"] and TX.store.ops["mig1:char:acct-v:c1.a2"].state)
    -- A definitive store failure stops the run; the rerun walks past the failed attempt.
    db.items["acct-w"] = { water = 1 }
    TX.store.faults = { "failed" }
    out.failed_first_run = invmigrate("char", "acct-w")
    out.failed_rerun = invmigrate("char", "acct-w")
    -- A lost marker: the rerun walks the same sequence, finds the commit, imports nothing twice.
    db.markers["char:acct-u"], db.markers["char:acct-v"] = nil, nil
    local opsBeforeLoss = TX.ops()
    invmigrate("char", "acct-u")
    invmigrate("char", "acct-v")
    out.after_marker_loss = TX.instancesOf("tool_u") .. "," .. TX.count("char:acct-v", "water") .. "," .. (TX.ops() - opsBeforeLoss)
        .. "," .. TX.count("char:acct-w", "water")
    -- A player whose rows were imported loads from the coordinator.
    ex = bootTx({ players = { [A] = { identifier = "acct-a", name = "Alice", pos = { x = 0, y = 0, z = 0 } } } })
    defineFixtureItems(ex)
    out.load_a = tostring(ex.count(A, "water")) .. "/" .. tostring(ex.count(A, "crowbar"))
    -- Over capacity after import: the pockets reopen at 40 kg and can only be emptied.
    ex = bootTx({ players = { [B] = { identifier = "acct-b", name = "Bob", pos = { x = 1, y = 0, z = 0 } } } })
    defineFixtureItems(ex)
    out.load_b = tostring(ex.count(B, "crate")) .. " capacity=" .. tostring(TX.store.containers["char:acct-b"].capacityG)
    out.b_add = res(ex.add(B, "water", 1))
    out.b_remove = res(ex.remove(B, "crate", 1))
    H.run(2)
    -- The legacy rows change after the import (a rollback ran the legacy backend): refused until
    -- an operator accepts the imported state.
    db.items["acct-a"].water = 9
    ex = bootTx({ players = { [A] = { identifier = "acct-a", name = "Alice", pos = { x = 0, y = 0, z = 0 } } }, settle = 30 })
    out.diverged = tostring(ex.count(A, "water")) .. " " .. res(ex.add(A, "water", 1))
    for _, line in ipairs(H.logs) do
        local why = line:match("char:acct%-a not loaded: ([%w_]+)")
        if why then out.diverged_reason = why end
    end
    out.accept = invmigrate("accept", "char", "acct-a")
    ex = bootTx({ players = { [A] = { identifier = "acct-a", name = "Alice", pos = { x = 0, y = 0, z = 0 } } } })
    out.after_accept = tostring(ex.count(A, "water"))
    -- A marker written by a newer format version is an explicit refusal, never a re-import.
    db.markers["char:acct-a"].version = 2
    out.version_mismatch = invmigrate("char", "acct-a")
    db.markers["char:acct-a"].version = 1
    -- A disposable coordinator store is refused: the marker would outlive the data.
    db.items["acct-g"] = { water = 1 }
    TX.start({ keepStore = true, storeMode = "lab_kvp" })
    out.lab_store_reported = tostring(TXS.callSync("compat_test", "info").store)
    ex = bootTx({ players = {} })
    out.not_durable = invmigrate("char", "acct-g")
    TX.start({ keepStore = true })
    ex = bootTx({ players = {} })
    -- A legacy layout that is not the 5dcdad2 one is refused before any read.
    db.columns = { rp_inventory_items = { { name = "identifier", type = "varchar(64)" }, { name = "item", type = "varchar(64)" } } }
    ex = bootTx({ players = {} })
    out.schema_mismatch = invmigrate("char", "acct-h")
    db.columns = nil
    -- importUnknownItems: imported with a placeholder definition and reported.
    ex = bootTx({ players = {}, config = { importUnknownItems = true } })
    defineFixtureItems(ex)
    out.acct_c_import_unknown = invmigrate("char", "acct-c")
    out.ghost_store = tostring(TX.count("char:acct-c", "ghost_item"))
    -- No mint rule for sys:migration: refused before any chunk, nothing imported, no marker.
    db.items["acct-m"] = { water = 1 }
    TX.start({ keepStore = true, tunables = { mint1 = "rp_inventory sys:rp_bar * 5", mint2 = "" } })
    ex = bootTx({ players = {} })
    out.no_mint_rule = invmigrate("char", "acct-m")
    out.no_mint_rule_store = TX.count("char:acct-m", "water") .. " marker=" .. tostring(db.markers["char:acct-m"] ~= nil)
    TX.start({ keepStore = true })
    out.kvp_keys = tostring(#Open77.kvp.keys(""))
    return out
end

-- ===========================================================================
-- B1: the client catalogue transfer
-- ===========================================================================
function scenarios.b1_catalogue_transfer()
    local ex = bootTx()
    local out = {}
    local heads = 0
    for _, e in ipairs(H.client) do if e.name == "rp_inventory:catalogue" and e.target == A then heads = heads + 1 end end
    out.head_on_join = tostring(heads >= 1)
    local head = ex.catalogueVersion()
    out.head_items = tostring(head.items)
    -- A definer adds items: one coalesced broadcast with the next version.
    H.client = {}
    H.as("c1_test", ex.define, { ore = { label = "Ore", weight = 1 } })
    H.as("c1_test", ex.define, { ingot = { label = "Ingot", weight = 2 } })
    H.run(3)
    local broadcasts, last = 0, nil
    for _, e in ipairs(H.client) do
        if e.name == "rp_inventory:catalogue" and e.target == -1 then broadcasts = broadcasts + 1; last = e.args[1] end
    end
    out.broadcasts = tostring(broadcasts)
    out.broadcast_version = tostring(last and last.version == head.version + 2)
    -- The client fetches every page and verifies the hash.
    head = ex.catalogueVersion()
    H.client = {}
    local handler = H.handlers["rp_inventory:catalogueRequest"][1]
    local pages = {}
    for i = 1, head.pages do
        source = A
        handler(head.version, i)
    end
    for _, e in ipairs(H.client) do
        if e.name == "rp_inventory:cataloguePage" then pages[e.args[1].i] = e.args[1] end
    end
    local byId, why = RpItemSchema.assemble(head, pages)
    out.client_assemble = byId and "ok" or tostring(why)
    out.client_has_ore = tostring(byId and byId.ore ~= nil)
    -- A stale version gets the current head back, not a page.
    H.client = {}
    source = A
    handler(head.version - 1, 1)
    out.stale = H.client[1] and H.client[1].name or "none"
    -- Bounded: a client hammering one page is cut off.
    H.client = {}
    for _ = 1, 50 do source = B; handler(head.version, 1) end
    local served = 0
    for _, e in ipairs(H.client) do if e.name == "rp_inventory:cataloguePage" then served = served + 1 end end
    out.served_of_50 = tostring(served)
    out.page_bounds = tostring(#RpItemSchema.encode(pages[1]) <= RpItemSchema.LIMITS.pageBytes + 64)
    return out
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    local result = scenario()
    local lines = {}
    for k, v in pairs(result) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
