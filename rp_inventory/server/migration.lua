-- rp_inventory / server/migration.lua: one-shot, journaled import of the legacy tables into
-- open77_transactions accounts (rows B2/B8). Global table: RpInvMigration.
--
-- Per subject (`char:<identifier>` or `stash:<stashId>`):
--   1. rp_inventory_migrations says whether the subject was imported, by which format version
--      and from which legacy rows (FNV-1a 64 of the sorted rows). A version this code does not
--      know is an explicit refusal (`migration_version_mismatch`), never a re-import.
--   2. Otherwise the legacy rows (rp_inventory_items / rp_inventory_stashes, schema of 5dcdad2)
--      become coordinator lines from `sys:migration`, committed under DETERMINISTIC opIds
--      `mig1:<account>:c<k>`: a crash or a retry replays the same receipt (status first, so a
--      restarted coordinator never re-applies), and changed rows under the same opId are an
--      `op_id_conflict`, not a second import. The coordinator must allow the mint
--      (`rp_inventory sys:migration * <cap>` in its mint rules), else `mint_denied` before any
--      chunk.
--   3. Then the marker row. The legacy rows are never modified or deleted: they stay the
--      rollback source. If they change after the import (the legacy backend ran again), the
--      next load refuses with `legacy_diverged` until an operator accepts one side.
--
-- Refused without importing: unknown item ids (unless importUnknown), a legacy schema that is
-- not the 5dcdad2 one, a coordinator whose store is not durable SQL (info().store), no mint rule
-- for sys:migration (allowed()), an invalid durable key.
-- KVP data is never read here (A13 3.1.1: only through an explicit admin step).
--
-- Dependencies are injected: db(method, sql, params) -> value, reason (yields);
-- call(name, ...) -> open77_transactions export (yields); registry; facade; log; now().

RpInvMigration = {}
local Mig = {}
Mig.__index = Mig

RpInvMigration.VERSION = 1

-- The legacy layout this code knows how to import (tests/compat/schema-snapshot.json, 5dcdad2).
local SOURCE = {
    rp_inventory_items = { { "identifier", "varchar(64)" }, { "item_id", "varchar(32)" }, { "count", "int" } },
    rp_inventory_stashes = { { "stash_id", "varchar(64)" }, { "item_id", "varchar(32)" }, { "count", "int" } },
}

local MARKER_DDL = [[
        CREATE TABLE IF NOT EXISTS rp_inventory_migrations (
            account VARCHAR(96) NOT NULL,
            version INT NOT NULL,
            op_id VARCHAR(96) NOT NULL,
            source_rows INT NOT NULL,
            source_hash CHAR(16) NOT NULL,
            weight_g BIGINT NOT NULL,
            capacity_g BIGINT NOT NULL,
            report TEXT NOT NULL,
            migrated_at BIGINT NOT NULL,
            PRIMARY KEY (account)
        )
    ]]

local STATEMENT_BUDGET = 56   -- of the coordinator's 64 per transaction, with margin

function RpInvMigration.new(deps)
    return setmetatable({
        db = deps.db, call = deps.call, registry = deps.registry, facade = deps.facade,
        log = deps.log or function() end, now = deps.now or function() return 0 end,
        importUnknown = deps.importUnknown == true,
        requireStoreInfo = deps.requireStoreInfo ~= false,
        sourceChecked = nil,   -- nil | { ok, absent = { [table] = true }, reason }
        tableReady = false,
    }, Mig)
end

local function normType(t)
    t = tostring(t or ""):lower():gsub("%s+", "")
    t = t:gsub("^int%(%d+%)", "int")
    return t
end

function Mig:ensureTable()
    if self.tableReady then return true end
    local _, reason = self.db("update", MARKER_DDL, {})
    if reason then return nil, "marker_table_failed:" .. tostring(reason) end
    self.tableReady = true
    return true
end

-- The legacy tables must be absent (nothing to import) or exactly the 5dcdad2 layout.
function Mig:checkSource()
    if self.sourceChecked then return self.sourceChecked.ok, self.sourceChecked.reason end
    local result = { ok = true, absent = {} }
    for tableName, expected in pairs(SOURCE) do
        local rows, reason = self.db("query",
            "SELECT COLUMN_NAME AS name, COLUMN_TYPE AS type FROM information_schema.COLUMNS "
            .. "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION", { tableName })
        if type(rows) ~= "table" then return nil, "store_unavailable" end -- not cached: retry later
        if #rows == 0 then
            result.absent[tableName] = true
        else
            local same = #rows == #expected
            for i, col in ipairs(expected) do
                local row = rows[i]
                if not row or tostring(row.name):lower() ~= col[1] or normType(row.type) ~= col[2] then same = false end
            end
            if not same then
                result.ok, result.reason = false, "source_schema_mismatch"
                self.log("migration refused: %s is not the 5dcdad2 layout", tableName)
            end
        end
    end
    self.sourceChecked = result
    return result.ok, result.reason
end

-- The coordinator must persist to SQL: importing into a disposable store and stamping the
-- marker would lose the subject once the lab store is wiped. Asked at every import (the
-- coordinator may have restarted in another mode); info() never yields.
function Mig:checkStore()
    local info, reason = self.call("info")
    if type(info) == "table" then
        if info.store ~= "sql" then return nil, "store_not_durable" end
        if info.ready ~= true then return nil, "store_unavailable" end
        return true
    end
    if self.requireStoreInfo then return nil, "coordinator_info_unavailable", reason end
    return true
end

local function rowsHash(rows)
    local list = {}
    for _, r in ipairs(rows) do list[#list + 1] = { r.item, r.count } end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    return RpItemSchema.fnv1a64(RpItemSchema.encode(list))
end

-- Reads the legacy rows of one subject: { { item, count }... } sorted, or nil, reason.
function Mig:legacyRows(kind, key)
    local tableName = kind == "char" and "rp_inventory_items" or "rp_inventory_stashes"
    if self.sourceChecked and self.sourceChecked.absent[tableName] then return {} end
    local column = kind == "char" and "identifier" or "stash_id"
    local rows, reason = self.db("query",
        ("SELECT item_id, count FROM %s WHERE %s = ?"):format(tableName, column), { key })
    if type(rows) ~= "table" then return nil, reason or "store_unavailable" end
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = { item = tostring(row.item_id), count = math.tointeger(tonumber(row.count)) or 0 }
    end
    table.sort(out, function(a, b) return a.item < b.item end)
    return out
end

function Mig:marker(account)
    local rows, reason = self.db("query",
        "SELECT version, op_id, source_rows, source_hash FROM rp_inventory_migrations WHERE account = ?", { account })
    if type(rows) ~= "table" then return nil, reason or "store_unavailable" end
    return rows[1] or false
end

local function lineCost(line)
    return line.instance and 2 or 1
end

-- Splits the import lines into chunks within the coordinator's statement budget.
local function chunk(lines)
    local chunks, current, cost = {}, {}, 3
    for _, line in ipairs(lines) do
        local c = lineCost(line)
        local journal = math.ceil((#current + 1) * 2 / 12)
        if #current > 0 and (cost + c + journal > STATEMENT_BUDGET or #current >= 40) then
            chunks[#chunks + 1] = current
            current, cost = {}, 3
        end
        current[#current + 1] = line
        cost = cost + c
    end
    if #current > 0 then chunks[#chunks + 1] = current end
    return chunks
end

-- An opId takes [A-Za-z0-9_.:@-] (no `~`, which a later character's subject may carry) and at
-- most 96 bytes; anything else is named by the hash of the account.
local function opIdFor(account, k)
    local id = "mig" .. RpInvMigration.VERSION .. ":" .. account .. ":c" .. k
    if #id > 96 or not id:match("^[A-Za-z0-9_.:@%-]+$") then
        id = "mig" .. RpInvMigration.VERSION .. ":h" .. RpItemSchema.fnv1a64(account) .. ":c" .. k
    end
    return id
end

-- Commits one chunk, or finds it already committed. Returns receipt | nil, reason.
--
-- The final coordinator's rule (contract 13.5): a FAILED attempt (refused, conflict, a store that
-- answered no, expired, cancelled) left nothing and no row, so the SAME opId is a fresh attempt;
-- a FENCED one (`aborted`) is a tombstone and can never commit. So each chunk walks a
-- DETERMINISTIC sequence `<base>`, `<base>.a2`, `<base>.a3`... and moves to the next id only once
-- the current one is fenced: at most one id of a chunk can ever commit, and a rerun -- on any VM
-- -- finds it by walking the same sequence (status of each, in order).
local MAX_ATTEMPTS = 8   -- fenced ids per chunk
local MAX_RETRIES = 3    -- fresh attempts of one id within one run

function Mig:commitChunk(baseOpId, lines)
    local attempt, retries = 1, 0
    while attempt <= MAX_ATTEMPTS do
        local opId = attempt == 1 and baseOpId or (baseOpId .. ".a" .. attempt)
        local st, sreason = self.call("status", opId)
        if type(st) ~= "table" then return nil, sreason or "store_unavailable" end
        local state = st.state
        if state == "committed" then return st.receipt or { opId = opId, replay = true } end
        if state == "in_doubt" or state == "committing" or state == "reserved" then
            local settled, settledState = self.facade:settle(opId, 30000)
            if settled then return settled end
            if settledState == "busy" then return nil, "in_doubt" end
            state = settledState
        end
        if state == "aborted" then
            attempt, retries = attempt + 1, 0
        else
            -- unknown / failed / expired / cancelled: nothing committed under this id; try it.
            local receipt, reason, info = self.call("transfer", { opId = opId, kind = "migrate", lines = lines })
            if type(receipt) == "table" then return receipt end
            if reason == "in_doubt" or reason == "busy" or (info and info.ambiguous) then
                -- May commit: settle THIS id, never start the next one before knowing.
                local settled, settledState = self.facade:settle(opId, 30000)
                if settled then return settled end
                if settledState == "busy" then return nil, "in_doubt" end
                if settledState == "aborted" then attempt, retries = attempt + 1, 0 else retries = retries + 1 end
            elseif reason == "aborted" or (info and info.state == "aborted") then
                attempt, retries = attempt + 1, 0            -- fenced: never this id again
            elseif reason == "coordinator_unavailable" then
                return nil, "store_unavailable"              -- never dispatched: the rerun tries this id
            elseif reason == "store_unavailable" or reason == "conflict" then
                retries = retries + 1                        -- not committed, not fenced: same id again
                if retries > MAX_RETRIES then return nil, reason end
            else
                return nil, reason   -- definitive: op_id_conflict, capacity_exceeded, store_failed, mint_*...
            end
        end
        if retries > MAX_RETRIES then return nil, "store_unavailable" end
    end
    return nil, "store_unavailable"
end

-- ensure(account, kind, key, capacityG) -> { state = "migrated"|"done"|"empty", report } | nil, reason, report
-- Yields. kind is "char" (key = identifier) or "stash" (key = stash id).
function Mig:ensure(account, kind, key, capacityG)
    capacityG = math.tointeger(capacityG) or 0
    local ok, why = self:ensureTable()
    if not ok then return nil, why end
    ok, why = self:checkSource()
    if not ok then return nil, why end
    local marker, mreason = self:marker(account)
    if marker == nil then return nil, mreason end
    if marker then
        local version = math.tointeger(tonumber(marker.version))
        if version ~= RpInvMigration.VERSION then
            return nil, "migration_version_mismatch", { account = account, marker = version, code = RpInvMigration.VERSION }
        end
        local rows, rreason = self:legacyRows(kind, key)
        if not rows then return nil, rreason end
        if rowsHash(rows) ~= tostring(marker.source_hash) then
            return nil, "legacy_diverged", { account = account, rows = #rows }
        end
        return { state = "done" }
    end

    local rows, rreason = self:legacyRows(kind, key)
    if not rows then return nil, rreason end
    local report = { rows = #rows, skipped = {}, unknown = {}, instances = 0 }
    local lines, weightG = {}, 0
    local placeholders = {}
    for _, row in ipairs(rows) do
        local def = self.registry:get(row.item)
        if row.count < 1 then
            report.skipped[#report.skipped + 1] = row.item
        elseif not def then
            report.unknown[#report.unknown + 1] = row.item
            if self.importUnknown and RpItemSchema.itemIdProblem(row.item) == nil then
                placeholders[row.item] = { weightG = 0 }
                lines[#lines + 1] = { item = row.item, count = row.count, from = "sys:migration", to = account }
            end
        elseif def.unique then
            -- Instance ids are DERIVED from the subject, the item and the unit index, so a rerun
            -- builds the very same lines under the same deterministic opId.
            local _, canonical = self.registry:assetFor(row.item, nil)
            if not canonical then return nil, "invalid_row", { account = account, item = row.item } end
            local tag = RpItemSchema.fnv1a64(account)
            for k = 1, row.count do
                local iid = ("mig%d.%s.%s.%d"):format(RpInvMigration.VERSION, tag, row.item, k):sub(1, 64)
                local meta = RpItemSchema.copy(canonical)
                if def.serial then meta.serial = iid end
                lines[#lines + 1] = { instance = iid, from = "sys:migration", to = account, item = row.item, meta = meta }
            end
        else
            -- Legacy rows hold plain stacks: the default variant, whose asset id is the item id.
            lines[#lines + 1] = { item = row.item, count = row.count, from = "sys:migration", to = account }
        end
        if def and row.count >= 1 then
            if def.unique then report.instances = report.instances + row.count end
            weightG = weightG + def.weightG * row.count
        end
    end
    if #report.unknown > 0 and not self.importUnknown then
        return nil, "unknown_items", { account = account, unknown = report.unknown }
    end
    local sourceHash = rowsHash(rows)
    if #lines == 0 then
        local _, ireason = self.db("update",
            "INSERT INTO rp_inventory_migrations (account, version, op_id, source_rows, source_hash, weight_g, capacity_g, report, migrated_at) "
            .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            { account, RpInvMigration.VERSION, "", #rows, sourceHash, 0, capacityG, RpItemSchema.encode(report), math.floor(self.now()) })
        if ireason then
            local again = self:marker(account)
            if not again then return nil, "marker_write_failed" end
        end
        return { state = "empty", report = report }
    end

    ok, why = self:checkStore()
    if not ok then return nil, why end
    -- The import creates value out of sys:migration: the operator's mint rules must allow it,
    -- checked before any chunk so a refusal never leaves a half-imported subject.
    local mint, mintWhy = self.facade:mayMint("sys:migration", nil)
    if not mint then return nil, mintWhy, { account = account, needs = "mint rule: rp_inventory sys:migration *" } end
    if next(placeholders) then
        local registered = self.call("define", placeholders)
        if type(registered) ~= "number" then return nil, "store_unavailable" end
    end
    -- The import adds weight: open the container large enough for it. The next load reopens it
    -- at its configured capacity; an over-capacity container can only be emptied (A13 3.5).
    local openCapacity = math.max(capacityG, weightG)
    if openCapacity > capacityG then report.capacityRaised = { configured = capacityG, needed = weightG } end
    local snap, oreason = self.call("open", account, { capacityG = openCapacity })
    if type(snap) ~= "table" then return nil, oreason or "store_unavailable" end

    local chunks = chunk(lines)
    local firstOp
    for k, part in ipairs(chunks) do
        local opId = opIdFor(account, k)
        firstOp = firstOp or opId
        local receipt, creason = self:commitChunk(opId, part)
        if not receipt then
            self.log("migration of %s stopped at chunk %d/%d: %s (rerun is safe)", account, k, #chunks, tostring(creason))
            return nil, creason == "op_id_conflict" and "legacy_changed_during_migration" or creason,
                { account = account, chunk = k }
        end
    end
    report.chunks = #chunks
    local _, ireason = self.db("update",
        "INSERT INTO rp_inventory_migrations (account, version, op_id, source_rows, source_hash, weight_g, capacity_g, report, migrated_at) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        { account, RpInvMigration.VERSION, firstOp, #rows, sourceHash, weightG, capacityG,
          RpItemSchema.encode(report), math.floor(self.now()) })
    if ireason then
        local again = self:marker(account)
        if not again then
            -- The import committed; only the marker is missing. The next ensure replays the
            -- same opIds (status: committed) and writes it.
            return nil, "marker_write_failed", { account = account }
        end
    end
    self.log("migrated %s: %d row(s), %d chunk(s), %d g%s%s", account, #rows, #chunks, weightG,
        #report.unknown > 0 and (", unknown imported: " .. table.concat(report.unknown, ",")) or "",
        report.capacityRaised and ", capacity raised for the import" or "")
    return { state = "migrated", report = report }
end

-- Operator decision after `legacy_diverged`: keep the coordinator's state and stamp the current
-- legacy rows as seen. Never moves an item.
function Mig:accept(account, kind, key)
    local marker = self:marker(account)
    if not marker then return nil, "not_migrated" end
    local rows, reason = self:legacyRows(kind, key)
    if not rows then return nil, reason end
    local _, ureason = self.db("update", "UPDATE rp_inventory_migrations SET source_hash = ?, source_rows = ? WHERE account = ?",
        { rowsHash(rows), #rows, account })
    if ureason then return nil, ureason end
    return true
end

-- Every legacy subject, in pages (keyset pagination stays far below database.maxRows).
-- visit(kind, key) is called for each. Returns the number of subjects visited | nil, reason.
function Mig:eachLegacySubject(visit)
    local ok, why = self:checkSource()
    if not ok then return nil, why end
    local visited = 0
    for _, spec in ipairs({ { "char", "rp_inventory_items", "identifier" }, { "stash", "rp_inventory_stashes", "stash_id" } }) do
        local kind, tableName, column = spec[1], spec[2], spec[3]
        if not self.sourceChecked.absent[tableName] then
            local after = ""
            while true do
                local rows, reason = self.db("query",
                    ("SELECT DISTINCT %s AS k FROM %s WHERE %s > ? ORDER BY %s LIMIT 200"):format(column, tableName, column, column),
                    { after })
                if type(rows) ~= "table" then return nil, reason or "store_unavailable" end
                for _, row in ipairs(rows) do
                    visit(kind, tostring(row.k))
                    visited = visited + 1
                    after = tostring(row.k)
                end
                if #rows < 200 then break end
            end
        end
    end
    return visited
end

return RpInvMigration
