-- =============================================================================
-- open77_transactions -- server/kvp_store.lua
-- =============================================================================
-- The `lab_kvp` store: a DISPOSABLE lab store over Open77.kvp (contract
-- section 4.1, decision 4). It is chosen once at boot, only when every switch
-- in server/main.lua agrees, and it is never a fallback for `sql`.
--
-- Shape: the in-memory store (server/memory_store.lua, non-deferred, with
-- exactly the plan semantics the SQL builder encodes) hydrated from the
-- resource's KVP file at boot, plus a write-through of every row a call
-- changed. One row per key: `c|<container>`, `w|<wallet>`, `i|<instance>`,
-- `o|<opId>`, and `j|<opId>` for the journal of one operation.
--
-- Limits it inherits and does not hide: the KVP quotas (4,096 entries, 1 MiB,
-- 64 KiB per value) and KVP's own durability (writes are coalesced onto the
-- tick and flushed as one file, so a hard kill loses at most that tick). No
-- data migrates out of it. Global: Open77TxKvpStore.
-- =============================================================================

Open77TxKvpStore = {}
local M = Open77TxModel

local PREFIX = { c = "containers", w = "wallets", i = "instances", o = "ops" }

function Open77TxKvpStore.new(kvp, options)
    options = options or {}
    local encode = options.encode or M.encode
    local decode = assert(options.decode, "decode required")
    local log = options.log or function() end
    local mem = Open77TxMemoryStore.new({ deferred = false })
    local store = { kind = "lab_kvp", memory = mem, problems = {} }

    local function hydrate(kind)
        local target = mem[PREFIX[kind]]
        local entries = kvp.find(kind .. "|", 4096) or {}
        for _, entry in ipairs(entries) do
            local ok, row = pcall(decode, entry.value)
            if ok and type(row) == "table" then
                target[entry.key:sub(#kind + 2)] = row
            else
                store.problems[#store.problems + 1] = "unreadable:" .. tostring(entry.key)
            end
        end
        return #entries
    end
    store.hydrated = hydrate("c") + hydrate("w") + hydrate("i") + hydrate("o")
    -- JSON has no integer type of its own; restore the integer fields the
    -- arithmetic relies on.
    local function ints(row, fields)
        for _, f in ipairs(fields) do
            if row[f] ~= nil then row[f] = math.tointeger(row[f]) or row[f] end
        end
    end
    for _, c in pairs(mem.containers) do
        ints(c, { "capacityG", "weightG", "version", "expiresAt" })
        c.stacks = c.stacks or {}
        for item, n in pairs(c.stacks) do c.stacks[item] = math.tointeger(n) or n end
    end
    for _, w in pairs(mem.wallets) do ints(w, { "balance", "version" }) end
    for _, i in pairs(mem.instances) do ints(i, { "version" }) end

    -- History survives a lab restart: the journal rows are hydrated too.
    for _, entry in ipairs(kvp.find("j|", 4096) or {}) do
        local ok, rows = pcall(decode, entry.value)
        if ok and type(rows) == "table" then
            for _, e in ipairs(rows) do
                if type(e) == "table" then
                    e.delta, e.line, e.at = math.tointeger(e.delta) or e.delta, math.tointeger(e.line) or e.line,
                        math.tointeger(e.at) or e.at
                    mem.journal[#mem.journal + 1] = e
                end
            end
        end
    end
    table.sort(mem.journal, function(x, y)
        if (x.at or 0) ~= (y.at or 0) then return (x.at or 0) < (y.at or 0) end
        if x.opId ~= y.opId then return x.opId < y.opId end
        return (x.line or 0) < (y.line or 0)
    end)
    store.persistedJournal = #mem.journal

    local dirty = {}
    mem.onTouched = function(kind, id) dirty[kind .. "|" .. id] = { kind, id } end

    local function flush()
        for key, d in pairs(dirty) do
            local row = mem[PREFIX[d[1]]][d[2]]
            if row == nil then
                kvp.delete(key)
            else
                local ok, why = kvp.set(key, encode(row))
                if not ok then
                    store.problems[#store.problems + 1] = "write_failed:" .. key .. ":" .. tostring(why)
                    log("ERR", "lab_kvp write of " .. key .. " failed: " .. tostring(why))
                end
            end
        end
        dirty = {}
        if #mem.journal > store.persistedJournal then
            local byOp = {}
            for i = store.persistedJournal + 1, #mem.journal do
                local e = mem.journal[i]
                byOp[e.opId] = byOp[e.opId] or {}
                local rows = byOp[e.opId]
                rows[#rows + 1] = e
            end
            for opId, rows in pairs(byOp) do kvp.set("j|" .. opId, encode(rows)) end
            -- The lab keeps a bounded history in memory (newest 4,096 rows).
            if #mem.journal > 4096 then
                local keep = {}
                for i = #mem.journal - 4095, #mem.journal do keep[#keep + 1] = mem.journal[i] end
                mem.journal = keep
            end
            store.persistedJournal = #mem.journal
        end
    end

    -- Every call answers through the memory store, then persists what moved
    -- BEFORE the coordinator hears the answer.
    local function wrap(name)
        store[name] = function(_, ...)
            local args = table.pack(...)
            local cb = args[args.n]
            args[args.n] = function(...)
                flush()
                return cb(...)
            end
            return mem[name](mem, table.unpack(args, 1, args.n))
        end
    end
    for _, name in ipairs({ "load", "openContainer", "setMeta", "closeContainer", "listContainers",
        "commit", "fence", "readOp", "probe", "migrate", "mintHistory", "purge", "history" }) do
        wrap(name)
    end
    function store:selfTest(_, cb) cb(true) end

    return store
end

return Open77TxKvpStore
