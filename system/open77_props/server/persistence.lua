-- Optional persistence for command-created world props. OFF by default.
--
-- The server owner's use case: decorating a world with `prop.here` / the admin
-- panel and wanting the decoration to survive a reboot. The registry is
-- in-memory and `resource_stopped` removes everything a resource created, so
-- without this file every reboot empties the world.
--
-- Scope is deliberate: **this resource persists only the props its own
-- commands create.** Props spawned programmatically by a gamemode are the
-- gamemode's business -- it recreates its own scene on start, so persisting
-- them here would double-spawn every one of them on reboot. Resources are
-- isolated on this platform (no exports between server resources, one VM
-- each), so this file could not see another resource's creates anyway; the
-- limitation and the design agree.
--
-- Ownership across restart, reasoned through rather than left to luck:
-- restored props are recreated *by this resource* at boot, so they carry the
-- same owner as the originals. When this resource stops, the host removes its
-- live props (`resource_stopped`) -- but the rows stay, and the next start
-- recreates them from the rows. A restart therefore neither wipes persisted
-- props nor double-spawns them: the live set dies with the VM, the durable set
-- is re-read, and the two never coexist. The row->live-id map is rebuilt at
-- restore time and lives only in this VM.
--
-- The OFF state costs nothing: no schema probe, no connection attempt, one
-- log line at boot. Flipping the tunable ON starts persisting props created
-- from then on; rows are only restored at boot, so a mid-run flip never
-- spawns anything by itself. Flipping OFF stops the writes but deletes
-- nothing -- turning it back on resumes where the owner left off, the same
-- contract as open77_playerstate's master switch.

local Tune = Open77.tunables.declare({
    persist = {
        value = false, apply = "live",
        label = "Persist props across restarts", group = "Persistence", order = 1,
        description =
            "Save every prop and light created by the prop.* / light.* commands to the " ..
            "database, and recreate them when the server boots. Off means nothing is " ..
            "written and nothing is restored; already-saved props are kept, not deleted, " ..
            "so switching back on resumes where you left off. Needs the server's " ..
            "database bridge; without one this stays off and says so once.",
    },
})

local function log(text)
    print("[open77_props] " .. text)
end

-- ---------------------------------------------------------------- database --

local SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS open77_props_persisted (
    row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    model VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    kind VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'prop',
    pos_x DOUBLE NOT NULL,
    pos_y DOUBLE NOT NULL,
    pos_z DOUBLE NOT NULL,
    yaw DOUBLE NOT NULL DEFAULT 0,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    light_json TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL,
    extra_json TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (row_id)
) ENGINE=InnoDB
]]

local INSERT_SQL = [[
INSERT INTO open77_props_persisted
    (model, kind, pos_x, pos_y, pos_z, yaw, bucket, light_json, extra_json)
VALUES
    (@model, @kind, @x, @y, @z, @yaw, @bucket, @light, @extra)
]]

local SELECT_SQL = [[
SELECT row_id, model, kind, pos_x, pos_y, pos_z, yaw, bucket, light_json, extra_json
  FROM open77_props_persisted
 ORDER BY row_id
]]

local TRANSFORM_SQL = [[
UPDATE open77_props_persisted
   SET pos_x = @x, pos_y = @y, pos_z = @z, yaw = @yaw
 WHERE row_id = @row
]]

local LIGHT_SQL = [[
UPDATE open77_props_persisted
   SET light_json = @light
 WHERE row_id = @row
]]

local DELETE_SQL = [[
DELETE FROM open77_props_persisted WHERE row_id = @row
]]

local DELETE_ALL_SQL = [[
DELETE FROM open77_props_persisted
]]

-- nil until probed, then true/false for the run. The probe only ever runs when
-- the tunable is ON: an owner who never turns persistence on never opens a
-- database conversation at all.
local dbReady = nil
local dbReason = "not probed"

-- `MySQL` is installed whether or not the server's bridge is enabled, so the
-- first real statement is the probe -- the open77_playerstate pattern.
-- Coroutine only: `.await` yields.
local function ensureSchema()
    if dbReady ~= nil then return dbReady end
    local ok, reason = pcall(function() MySQL.update.await(SCHEMA_SQL) end)
    if not ok then
        dbReady = false
        dbReason = tostring(reason)
        log("prop persistence is ON but no database is available -- nothing will be " ..
            "saved or restored this run (" .. dbReason .. ")")
        return false
    end
    dbReady = true
    dbReason = "ready"
    return true
end

local function enabled()
    return Tune.persist == true
end

-- live prop id (as a string) -> row_id. Rebuilt by restore() at boot; a prop
-- with no entry here was never persisted and every save call ignores it.
local rows = {}

local function rowOf(id)
    return rows[tostring(id)]
end

-- --------------------------------------------------------------- save paths --

-- Called with the exact definition table the command handed to
-- `Open77.props.create`, after the create succeeded. Persisting the input
-- rather than re-reading the registry keeps this a pure recreate contract:
-- what went in is what comes back.
local function saveCreated(id, definition)
    if not enabled() then return end
    if not ensureSchema() then return end
    local extra = {}
    for _, key in ipairs({ "scale", "appearance", "physics", "collision",
                           "streamingRadius", "streamingHysteresis" }) do
        if definition[key] ~= nil then extra[key] = definition[key] end
    end
    local ok, result = pcall(function()
        return MySQL.insert.await(INSERT_SQL, {
            model = tostring(definition.model),
            kind = tostring(definition.kind or "prop"),
            x = definition.position.x, y = definition.position.y, z = definition.position.z,
            yaw = tonumber(definition.yaw) or 0.0,
            bucket = math.floor(tonumber(definition.bucket) or 0),
            light = definition.light ~= nil and json.encode(definition.light) or nil,
            extra = next(extra) ~= nil and json.encode(extra) or nil,
        })
    end)
    if not ok or type(result) ~= "number" then
        log(string.format("failed to persist prop %s: %s", tostring(id), tostring(result)))
        return
    end
    rows[tostring(id)] = result
end

local function saveTransform(id, x, y, z, yaw)
    local row = rowOf(id)
    if row == nil or not enabled() or not ensureSchema() then return end
    local ok, err = pcall(function()
        MySQL.update.await(TRANSFORM_SQL, {
            row = row, x = x, y = y, z = z, yaw = tonumber(yaw) or 0.0,
        })
    end)
    if not ok then
        log(string.format("failed to persist transform of prop %s: %s", tostring(id), tostring(err)))
    end
end

local function saveLight(id, light)
    local row = rowOf(id)
    if row == nil or not enabled() or not ensureSchema() then return end
    local ok, err = pcall(function()
        MySQL.update.await(LIGHT_SQL, { row = row, light = json.encode(light) })
    end)
    if not ok then
        log(string.format("failed to persist light state of prop %s: %s", tostring(id), tostring(err)))
    end
end

-- Deletion must persist too, or a removed prop resurrects at the next boot.
-- Rows are deleted whenever the *live* prop is removed through this resource's
-- commands, whatever the tunable currently says: a row whose prop the owner
-- deliberately deleted is stale data, not a saved decoration.
local function forget(id)
    local row = rowOf(id)
    if row == nil then return end
    rows[tostring(id)] = nil
    if not ensureSchema() then return end
    local ok, err = pcall(function() MySQL.update.await(DELETE_SQL, { row = row }) end)
    if not ok then
        log(string.format("failed to delete persisted prop %s: %s", tostring(id), tostring(err)))
    end
end

local function forgetAll()
    rows = {}
    -- `prop.clear` must also wipe the saved scene, including rows this run has
    -- never touched (a clear issued at boot, before the restore pass, is the
    -- measured case: with only a `dbReady == true` guard here it deleted
    -- nothing and the scene resurrected). Probe when the tunable is on, or
    -- when a probe already succeeded this run; with persistence OFF and no
    -- probe, saved rows are deliberately left alone -- the master switch
    -- promises that OFF deletes nothing already saved.
    if not (enabled() or dbReady == true) then return end
    if not ensureSchema() then return end
    local ok, err = pcall(function() MySQL.update.await(DELETE_ALL_SQL) end)
    if not ok then
        log("failed to clear persisted props: " .. tostring(err))
    end
end

-- ------------------------------------------------------------------ restore --

local function restoreRow(row)
    local definition = {
        model = row.model,
        kind = row.kind ~= "" and row.kind or "prop",
        position = { x = tonumber(row.pos_x), y = tonumber(row.pos_y), z = tonumber(row.pos_z) },
        yaw = tonumber(row.yaw) or 0.0,
        bucket = math.floor(tonumber(row.bucket) or 0),
    }
    if type(row.light_json) == "string" and row.light_json ~= "" then
        local light = json.decode(row.light_json)
        if type(light) == "table" then definition.light = light end
    end
    if type(row.extra_json) == "string" and row.extra_json ~= "" then
        local extra = json.decode(row.extra_json)
        if type(extra) == "table" then
            for key, value in pairs(extra) do definition[key] = value end
        end
    end
    return Open77.props.create(definition)
end

local function restore()
    local ok, result = pcall(function() return MySQL.query.await(SELECT_SQL) end)
    if not ok then
        log("could not read persisted props: " .. tostring(result))
        return
    end
    if type(result) ~= "table" or #result == 0 then
        log("prop persistence is on; nothing saved yet")
        return
    end
    -- Rows whose prop is already live must not be restored again. The restore
    -- pass runs a beat after resource start, and startup.commands run in that
    -- window: a `prop.create` there inserts its row *before* this SELECT reads
    -- the table, so without this check the same boot creates the prop and then
    -- "restores" its own row as a duplicate. Measured, not hypothetical -- the
    -- first ON run ended with six props for three rows.
    local live = {}
    for _, rowId in pairs(rows) do live[rowId] = true end
    local restored, failed, skipped = 0, 0, 0
    for _, row in ipairs(result) do
        if live[row.row_id] then
            skipped = skipped + 1
            goto continue
        end
        -- A row that no longer creates (an alias dropped from the catalogue, a
        -- registry quota) is kept and named rather than deleted: the failure
        -- may be transient, and silently discarding an owner's saved scene is
        -- worse than a log line per boot.
        local id, reason = restoreRow(row)
        if id ~= nil then
            rows[tostring(id)] = row.row_id
            restored = restored + 1
            -- One line per prop, with the live id the registry assigned: this is
            -- the operator's (and the test loop's) proof of what came back and
            -- where, without needing a client to ask.
            log(string.format(
                "restored prop %s from row %s: model=%s kind=%s pos=%.2f,%.2f,%.2f yaw=%.1f bucket=%d",
                tostring(id), tostring(row.row_id), tostring(row.model),
                tostring(row.kind), tonumber(row.pos_x) or 0.0, tonumber(row.pos_y) or 0.0,
                tonumber(row.pos_z) or 0.0, tonumber(row.yaw) or 0.0,
                math.floor(tonumber(row.bucket) or 0)))
        else
            failed = failed + 1
            log(string.format("could not restore persisted prop row=%s model=%s: %s",
                tostring(row.row_id), tostring(row.model), tostring(reason)))
        end
        ::continue::
    end
    log(string.format("restored %d persisted prop(s)%s%s", restored,
        failed > 0 and string.format(" (%d failed, rows kept)", failed) or "",
        skipped > 0 and string.format(" (%d already live, skipped)", skipped) or ""))
end

CreateThread(function()
    -- Give the registry and the rest of the resource set a beat to come up;
    -- restoring into a half-started server would fail every row once per boot.
    Wait(1000)
    if not enabled() then
        log("prop persistence is off (default); props will not survive a restart. " ..
            "Enable the `persist` tunable to change that.")
        return
    end
    if not ensureSchema() then return end
    restore()
end)

-- The mutation hooks main.lua calls. Kept as one global because server
-- resources share a VM per resource, not per file, and the manifest loads this
-- file first.
PropsPersistence = {
    saveCreated = saveCreated,
    saveTransform = saveTransform,
    saveLight = saveLight,
    forget = forget,
    forgetAll = forgetAll,
}
