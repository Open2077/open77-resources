-- =============================================================================
-- open77_containers -- server/store.lua
-- =============================================================================
-- The container registry's durable store: one row per container, keyed by its
-- `world:` id, holding what the A13 coordinator does NOT hold -- policy,
-- presentation, public/private metadata, node charges, grants and, once
-- closed, the tombstone. Contents, capacity, expiry and the placement (model,
-- position, yaw, bucket) live in the coordinator's world row and its metadata
-- (`open77_transactions` `openWorld` / `setMeta` / `listWorld`); a restart
-- joins the two (service `start`). Owner, kind and the optional caller key are
-- copied here as immutable index columns: (owner, key) is unique, so a keyed
-- create is idempotent and a closed key is never reused.
--
-- Three modes, chosen once at boot and never switched (the A13 rule, contract
-- §4.1): `sql` (default, MySQL bridge), `lab_kvp` (explicit disposable lab,
-- Open77.kvp), `memory` (offline tests, with fault injection).
--
-- Interface (callback style; every callback may run later):
--   store:loadOpen(cb(rows | nil, err))
--   store:get(id, cb(row | false, err))
--   store:getByKey(owner, key, cb(row | false, err))
--   store:insert(row, cb(true | nil, err))          err "exists" on a duplicate id or (owner, key)
--   store:update(row, expectVersion, cb(true | nil, err))  err "conflict" when the
--                                                    stored version is not expectVersion
-- A row is a plain table (Model.registryRecord); `version` is bumped by the
-- caller before update. Writes for one container are serialized by the
-- service, so the bridge's unordered request execution (A13 fact D1) cannot
-- reorder them.
--
-- Global: Open77ContainersStore.
-- =============================================================================

Open77ContainersStore = {}
local Model = Open77ContainersModel

local function keyIndex(owner, key) return tostring(owner) .. "/" .. tostring(key) end

-- ---------------------------------------------------------------------------
-- memory (tests)
-- ---------------------------------------------------------------------------
function Open77ContainersStore.memory(options)
    options = options or {}
    local store = { rows = {}, down = false, faults = {}, writes = 0 }

    local function copy(row) return Model.deepCopy(row) end

    local function fault()
        if store.down then return "store_unavailable" end
        local next = table.remove(store.faults, 1)
        return next
    end

    function store:loadOpen(cb)
        if self.down then return cb(nil, "store_unavailable") end
        local out = {}
        for _, row in pairs(self.rows) do
            if row.state == "open" then out[#out + 1] = copy(row) end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        cb(out)
    end

    function store:get(id, cb)
        if self.down then return cb(nil, "store_unavailable") end
        local row = self.rows[id]
        cb(row and copy(row) or false)
    end

    function store:getByKey(owner, key, cb)
        if self.down then return cb(nil, "store_unavailable") end
        for _, row in pairs(self.rows) do
            if row.owner == owner and row.key == key then return cb(copy(row)) end
        end
        cb(false)
    end

    function store:insert(row, cb)
        local why = fault()
        if why then return cb(nil, why) end
        if self.rows[row.id] then return cb(nil, "exists") end
        if row.key ~= nil then
            for _, other in pairs(self.rows) do
                if other.owner == row.owner and other.key == row.key then return cb(nil, "exists") end
            end
        end
        self.rows[row.id] = copy(row)
        self.writes = self.writes + 1
        cb(true)
    end

    function store:update(row, expectVersion, cb)
        local why = fault()
        if why then return cb(nil, why) end
        local current = self.rows[row.id]
        if not current then return cb(nil, "conflict") end
        if current.version ~= expectVersion then return cb(nil, "conflict") end
        self.rows[row.id] = copy(row)
        self.writes = self.writes + 1
        cb(true)
    end

    return store
end

-- ---------------------------------------------------------------------------
-- Row <-> JSON body. The indexed columns are duplicated out of the body.
-- ---------------------------------------------------------------------------
local function encodeRow(row, encode)
    return (encode or Model.encode)(row)
end

-- ---------------------------------------------------------------------------
-- lab_kvp (explicit disposable lab only; Open77.kvp, 64 KiB values, 4096 keys)
-- `container:<id>` holds the row, `containerkey:<owner>/<key>` the id of a
-- keyed container (written before the row, so a row never exists unindexed).
-- ---------------------------------------------------------------------------
function Open77ContainersStore.kvp(kvp, options)
    options = options or {}
    local decode = options.decode
    local encode = options.encode
    local prefix = "container:"
    local keyPrefix = "containerkey:"
    local store = {}

    local function read(id)
        local raw, why = kvp.get(prefix .. id)
        if why then return nil, why end
        if type(raw) ~= "string" then return false end
        local row = decode(raw)
        if type(row) ~= "table" then return nil, "store_corrupt" end
        return row
    end

    function store:loadOpen(cb)
        local entries, why = kvp.find(prefix, 4096)
        if not entries then return cb(nil, why or "store_unavailable") end
        local out = {}
        for _, entry in ipairs(entries) do
            local row = type(entry.value) == "string" and decode(entry.value) or nil
            if type(row) == "table" and row.state == "open" then out[#out + 1] = row end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        cb(out)
    end

    function store:get(id, cb)
        local row, why = read(id)
        if row == nil then return cb(nil, why or "store_unavailable") end
        cb(row)
    end

    function store:getByKey(owner, key, cb)
        local id, why = kvp.get(keyPrefix .. keyIndex(owner, key))
        if why then return cb(nil, why) end
        if type(id) ~= "string" then return cb(false) end
        local row, readWhy = read(id)
        if row == nil then return cb(nil, readWhy or "store_unavailable") end
        if row and (row.owner ~= owner or row.key ~= key) then return cb(false) end
        cb(row)
    end

    function store:insert(row, cb)
        local existing, why = read(row.id)
        if existing == nil then return cb(nil, why or "store_unavailable") end
        if existing then return cb(nil, "exists") end
        if row.key ~= nil then
            local index = keyPrefix .. keyIndex(row.owner, row.key)
            local taken, takenWhy = kvp.get(index)
            if takenWhy then return cb(nil, takenWhy) end
            if type(taken) == "string" and taken ~= row.id then
                local other = read(taken)
                if other then return cb(nil, "exists") end
            end
            local okIndex, indexWhy = kvp.set(index, row.id)
            if not okIndex then return cb(nil, indexWhy or "store_unavailable") end
        end
        local ok, reason = kvp.set(prefix .. row.id, encodeRow(row, encode))
        if not ok then return cb(nil, reason or "store_unavailable") end
        cb(true)
    end

    function store:update(row, expectVersion, cb)
        local existing, why = read(row.id)
        if existing == nil then return cb(nil, why or "store_unavailable") end
        if not existing or existing.version ~= expectVersion then return cb(nil, "conflict") end
        local ok, reason = kvp.set(prefix .. row.id, encodeRow(row, encode))
        if not ok then return cb(nil, reason or "store_unavailable") end
        cb(true)
    end

    return store
end

-- ---------------------------------------------------------------------------
-- sql (MySQL bridge, callback forms)
-- ---------------------------------------------------------------------------
-- Schema v1 was amended on 2026-10-12, before any deployment (the A6 wave-1
-- registry had never run against MariaDB): `expires_at` left the table
-- (expiry is the coordinator's `expiresAt`) and `ckey` with the unique
-- (owner, ckey) index arrived. A database that ran the earlier DDL must drop
-- `open77_containers` and `open77_containers_schema` once.
Open77ContainersStore.SCHEMA_VERSION = 1
Open77ContainersStore.DDL = {
    [[CREATE TABLE IF NOT EXISTS open77_containers_schema (
  k          TINYINT NOT NULL PRIMARY KEY,
  version    INT     NOT NULL,
  updated_at BIGINT  NOT NULL
) ENGINE=InnoDB]],
    [[CREATE TABLE IF NOT EXISTS open77_containers (
  container_id VARCHAR(96) NOT NULL PRIMARY KEY,
  owner        VARCHAR(64) NOT NULL,
  ckey         VARCHAR(64) NULL,
  state        VARCHAR(12) NOT NULL,
  version      BIGINT      NOT NULL,
  body         TEXT        NOT NULL,
  updated_at   BIGINT      NOT NULL,
  UNIQUE KEY uq_open77_containers_key (owner, ckey),
  INDEX idx_open77_containers_state (state)
) ENGINE=InnoDB]],
}

local function affected(result)
    if type(result) == "table" then
        return tonumber(result.affectedRows or result.affected_rows or result.changedRows) or 0
    end
    return tonumber(result) or 0
end

function Open77ContainersStore.sql(db, options)
    options = options or {}
    local decode = options.decode
    local encode = options.encode
    local now = options.now or function() return 0 end
    local maxOpen = options.maxOpen or 4096
    local store = {}

    local function fromRow(raw)
        if type(raw) ~= "table" or type(raw.body) ~= "string" then return nil end
        local row = decode(raw.body)
        if type(row) ~= "table" then return nil end
        return row
    end

    -- Bounded and paged by the caller's limit: a boot load stays far below the
    -- bridge's silent maxRows truncation (A13 fact D8).
    function store:loadOpen(cb)
        db.query("SELECT body FROM open77_containers WHERE state = 'open' ORDER BY container_id LIMIT ?",
            { maxOpen + 1 }, function(rows, err)
                if err then return cb(nil, err) end
                rows = rows or {}
                if #rows > maxOpen then return cb(nil, "too_many_open_containers") end
                local out = {}
                for _, raw in ipairs(rows) do
                    local row = fromRow(raw)
                    if row then out[#out + 1] = row end
                end
                cb(out)
            end)
    end

    function store:get(id, cb)
        db.single("SELECT body FROM open77_containers WHERE container_id = ?", { id }, function(raw, err)
            if err then return cb(nil, err) end
            if not raw then return cb(false) end
            local row = fromRow(raw)
            if not row then return cb(nil, "store_corrupt") end
            cb(row)
        end)
    end

    function store:getByKey(owner, key, cb)
        db.single("SELECT body FROM open77_containers WHERE owner = ? AND ckey = ?", { owner, key },
            function(raw, err)
                if err then return cb(nil, err) end
                if not raw then return cb(false) end
                local row = fromRow(raw)
                if not row then return cb(nil, "store_corrupt") end
                cb(row)
            end)
    end

    -- A nil parameter would leave a hole in the argument array, so an unkeyed
    -- row simply omits `ckey` (NULL; the unique index ignores NULLs).
    function store:insert(row, cb)
        local columns, values = "container_id, owner, state, version, body, updated_at", "?, ?, ?, ?, ?, ?"
        local params = { row.id, row.owner, row.state, row.version, encodeRow(row, encode), now() }
        if row.key ~= nil then
            columns, values = columns .. ", ckey", values .. ", ?"
            params[#params + 1] = row.key
        end
        db.update("INSERT INTO open77_containers (" .. columns .. ") VALUES (" .. values .. ")", params,
            function(result, err)
                if err then
                    if tostring(err):find("database_conflict", 1, true) then return cb(nil, "exists") end
                    return cb(nil, err)
                end
                cb(true)
            end)
    end

    -- Compare-and-set on `version`: zero affected rows means somebody else
    -- (another server on the same database, a late write) moved the row.
    -- Owner and key never change, so only state, version and body are written.
    function store:update(row, expectVersion, cb)
        db.update("UPDATE open77_containers SET state = ?, version = ?, body = ?, updated_at = ? "
            .. "WHERE container_id = ? AND version = ?",
            { row.state, row.version, encodeRow(row, encode), now(), row.id, expectVersion },
            function(result, err)
                if err then return cb(nil, err) end
                if affected(result) ~= 1 then return cb(nil, "conflict") end
                cb(true)
            end)
    end

    -- Creates the schema once the database answers; refuses a newer schema.
    function store:migrate(cb)
        local statements = Open77ContainersStore.DDL
        local index = 0
        local function step()
            index = index + 1
            if index > #statements then
                db.single("SELECT version FROM open77_containers_schema WHERE k = 1", {}, function(raw, err)
                    if err then return cb(nil, err) end
                    local version = raw and tonumber(raw.version) or nil
                    if version and version > Open77ContainersStore.SCHEMA_VERSION then
                        return cb(nil, "schema_newer_than_resource")
                    end
                    if version then return cb(true) end
                    db.update("INSERT INTO open77_containers_schema (k, version, updated_at) VALUES (1, ?, ?)",
                        { Open77ContainersStore.SCHEMA_VERSION, now() }, function(_, err2)
                            if err2 then return cb(nil, err2) end
                            cb(true)
                        end)
                end)
                return
            end
            db.update(statements[index], {}, function(_, err)
                if err then return cb(nil, err) end
                step()
            end)
        end
        step()
    end

    return store
end

return Open77ContainersStore
