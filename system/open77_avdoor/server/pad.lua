-- =============================================================================
-- open77_avdoor -- server/pad.lua
-- =============================================================================
-- The landing pad under an AV a resource flies: which players are told to draw
-- it, for the records the client does not pad itself.
--
-- WHY THIS EXISTS. Asked for on XyberRP, 2026-10-07: "make sure the trauma
-- team av has the red warning laser underneath like maxtac av does". The red
-- lasers are the Open77 client's own landing pad (`ApplyLandingLaser`,
-- client/src/api/Vehicles.cpp): twelve `laser.mine` beams on a ring on the
-- ground under the hull, one more running round inside it and the OPEN77 sign
-- in dots, drawn while the hull is within six metres of the ground and coming
-- down or sitting there -- and with it the dust under the hull and the
-- engine's hover voice. The client draws them only under a hull whose record
-- it flies as an AV: `Vehicle.av_*` and `Vehicle.max_tac_av`
-- (`VehicleFlight::IsAvRecord`). The Trauma Team's airframes
-- (`Vehicle.q001_trauma_av` and the like) are not, so they came down bare and
-- silent beside the MaxTac AV's red ring.
--
-- So a resource that flies a hull names it here (`exports.open77_avdoor:pad`),
-- and every player in the hull's bucket within `PADS.METRES` is told which hull
-- to draw the pad under (`M.Event.PAD`) -- a player who comes near later is
-- told on the next pass. Each client draws the pad itself (`client/pad.lua`)
-- from what it sees of the hull: centred on the hull's own mesh, on the ground
-- under it.
--
-- A RECORD THE CLIENT PADS ITSELF (`PADS.PLATFORM`) is named to the clients as
-- well, but only so each one writes down how far that hull's mesh centre is
-- from the point the client's own pad is drawn round. Nothing more is drawn
-- under it: two pads under one hull is worse than one.
-- =============================================================================

local M = AvDoor

M.Pads = {}
local Pads = M.Pads

-- Hulls with a pad, by id as text: `{ id, record, bucket, platform, told,
-- since, why, owner }`. `told` is the set of players sent the pad.
local live = {}

-- Reasons already said once.
local said = {}

local function sayOnce(key, line)
    if said[key] then return end
    said[key] = true
    Open77.log.warn(line)
end

--- The PADS block, each number inside a band; nil when it is off.
-- @return table|nil
function Pads.Settings()
    -- Read in two steps: `a and false or nil` is nil, and `false` is the switch.
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.PADS end
    if declared == false then return nil end
    local block = type(declared) == 'table' and declared or {}
    local platform = {}
    for _, pattern in ipairs(type(block.PLATFORM) == 'table' and block.PLATFORM or {}) do
        if type(pattern) == 'string' and pattern ~= '' then platform[#platform + 1] = pattern end
    end
    if type(block.PLATFORM) ~= 'table' then
        platform = { '^vehicle%.av_', '^vehicle%.max_tac_av$' }
    end
    return {
        metres = M.Number(block.METRES, 20.0, 1000.0, 300.0),
        tellMs = math.floor(M.Number(block.TELL_MS, 250, 10000, 1000)),
        platform = platform,
    }
end

--- Whether the client pads a record's hull itself (`PADS.PLATFORM`): the rule
--- the client flies an AV by, `Vehicle.av_*` or `Vehicle.max_tac_av`.
-- @param record any
-- @param cfg table|nil `Pads.Settings()`
-- @return boolean
function Pads.Platform(record, cfg)
    if type(record) ~= 'string' or record == '' then return false end
    cfg = cfg or Pads.Settings()
    if cfg == nil then return false end
    local lowered = record:lower()
    for _, pattern in ipairs(cfg.platform) do
        local read, found = pcall(string.find, lowered, pattern)
        if read and found ~= nil then return true end
    end
    return false
end

--- Where a hull is and its bucket, as the host reads it, or nil when it is gone.
local function hullAt(id)
    local api = type(Open77) == 'table' and Open77.vehicles or nil
    if type(api) ~= 'table' or type(api.get) ~= 'function' or id == nil then return nil, 0 end
    local read, snapshot = pcall(api.get, id)
    if (not read or type(snapshot) ~= 'table') and tonumber(id) ~= nil then
        read, snapshot = pcall(api.get, tonumber(id))
    end
    if not read or type(snapshot) ~= 'table' then return nil, 0 end
    local at = type(snapshot.position) == 'table' and snapshot.position or snapshot
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z then return nil, 0 end
    return { x = x, y = y, z = z }, tonumber(snapshot.bucket) or 0, snapshot.record
end

--- The payload one player is sent for a hull.
local function payload(entry, on)
    return { id = entry.key, on = on, record = entry.record, platform = entry.platform }
end

local function send(playerId, entry, on)
    local ran = pcall(TriggerClientEvent, M.Event.PAD, playerId, payload(entry, on))
    return ran
end

--- Tells the players near one hull who have not been told yet. Answers how
--- many were told this pass, nil when the hull is gone.
local function tell(entry, cfg)
    local at, bucket = hullAt(entry.id)
    if at == nil then return nil end
    local players = type(Open77) == 'table' and Open77.players or nil
    if type(players) ~= 'table' or type(players.all) ~= 'function' or type(players.position) ~= 'function' then
        return 0
    end
    local listed, list = pcall(players.all)
    local count = 0
    for _, playerId in ipairs(listed and type(list) == 'table' and list or {}) do
        local id = tonumber(playerId)
        -- The host's player reads throw on an id under 1: checked before any read.
        if id ~= nil and id >= 1 and id == math.floor(id) and not entry.told[id] then
            local read, where = pcall(players.position, id)
            if read and type(where) == 'table' and tonumber(where.x) ~= nil and tonumber(where.y) ~= nil
                and (tonumber(where.bucket) or 0) == bucket then
                local dx, dy = tonumber(where.x) - at.x, tonumber(where.y) - at.y
                if dx * dx + dy * dy <= cfg.metres * cfg.metres and send(id, entry, true) then
                    entry.told[id] = true
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- Puts a pad under a hull: every player near it is told now, and anybody who
--- comes near on a later pass. A second call for the same hull is the same pad.
-- @param id any the hull, as the host knows it
-- @param options table|nil `{ record, bucket, why }`
-- @return boolean|nil true when the hull has a pad
-- @return string|nil why not, `'platform'` when the client pads it itself
function Pads.Start(id, options)
    local cfg = Pads.Settings()
    if cfg == nil then return nil, 'pads_off' end
    if id == nil then return nil, 'no_hull' end
    local key = M.KeyOf(id)
    local opts = type(options) == 'table' and options or {}
    local entry = live[key]
    if entry == nil then
        local at, bucket, record = hullAt(id)
        if at == nil and not (type(opts.record) == 'string' and opts.record ~= '') then
            return nil, 'no_hull'
        end
        record = type(opts.record) == 'string' and opts.record ~= '' and opts.record or record
        entry = {
            id = id, key = key, record = record, bucket = tonumber(opts.bucket) or bucket or 0,
            platform = Pads.Platform(record, cfg), told = {}, since = M.Now(),
            why = type(opts.why) == 'string' and opts.why:sub(1, 80) or nil, owner = opts.owner,
        }
        live[key] = entry
        Open77.log.info(('landing pad for %s (%s)%s%s: %s'):format(key, tostring(record),
            entry.why and (' for ' .. entry.why) or '',
            entry.owner and (' asked by ' .. tostring(entry.owner)) or '',
            entry.platform and 'the client draws its own, so the games only measure it'
                or ('drawn by every game within %.0f m'):format(cfg.metres)))
    end
    tell(entry, cfg)
    if entry.platform then return nil, 'platform' end
    return true
end

--- Takes a hull's pad away on every game that was told about it.
-- @param id any
-- @param why string|nil for the journal
-- @return boolean whether the hull had one
function Pads.Stop(id, why)
    if id == nil then return false end
    local key = M.KeyOf(id)
    local entry = live[key]
    if entry == nil then return false end
    live[key] = nil
    local count = 0
    for playerId in pairs(entry.told) do
        if send(playerId, entry, false) then count = count + 1 end
    end
    Open77.log.info(('landing pad for %s taken away (%s): %d game(s) told, after %.1fs')
        :format(key, tostring(why or 'done'), count, (M.Now() - entry.since) / 1000.0))
    return true
end

--- Whether a hull has a pad now.
function Pads.Has(id)
    if id == nil then return false end
    return live[M.KeyOf(id)] ~= nil
end

--- What the pads are, for the suite and the console.
-- @return table[] `{ id, record, platform, told }`
function Pads.Status()
    local out = {}
    for key, entry in pairs(live) do
        local told = 0
        for _ in pairs(entry.told) do told = told + 1 end
        out[#out + 1] = { id = key, record = entry.record, platform = entry.platform, told = told }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- One pass: newcomers near each hull are told, and a hull that is gone takes
--- its pad with it.
function Pads.Tend()
    local cfg = Pads.Settings()
    if cfg == nil then return end
    local gone = {}
    for key, entry in pairs(live) do
        local ran, count = pcall(tell, entry, cfg)
        if not ran then
            sayOnce('tell:' .. key, ('the landing pad for %s could not be sent: %s')
                :format(key, tostring(count)))
        elseif count == nil then
            gone[#gone + 1] = key
        end
    end
    for _, key in ipairs(gone) do Pads.Stop(key, 'the hull is gone') end
end

--- A player who left is nobody to tell anything.
function Pads.Forget(playerId)
    local id = tonumber(playerId)
    if id == nil then return end
    for _, entry in pairs(live) do entry.told[id] = nil end
end

--- Takes every pad away a resource put up, when that resource stops.
-- @param owner string the resource
-- @return integer how many were taken away
function Pads.StopOwnedBy(owner, why)
    if type(owner) ~= 'string' then return 0 end
    local keys = {}
    for key, entry in pairs(live) do
        if entry.owner == owner then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do Pads.Stop(key, why) end
    return #keys
end

--- Takes every pad away: the resource is stopping.
function Pads.StopAll(why)
    local keys = {}
    for key in pairs(live) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do Pads.Stop(key, why) end
end

--- Forgets everything, without touching the host: a restart starts clean.
function Pads.Reset()
    live, said = {}, {}
end
