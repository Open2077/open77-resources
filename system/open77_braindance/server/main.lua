-- open77_braindance server: drive a player's braindance launch / transition
-- from server scripts and react to its phases.
--
-- Exports (server):
--   start(playerId, options) -> id | nil, reason
--   resume(playerId, id) / exit(playerId, id, options?) / cancel(playerId, id)
--   state(playerId) -> { id, phase, leg, tag, ... } | nil
--
-- Server events (AddEventHandler):
--   open77_braindance:phase (playerId, id, phase, tag)   -- every phase, server- or client-started
--   open77_braindance:black (playerId, id, tag)           -- the player's screen is black now
--
-- options.teleport = { x, y, z, heading?, bucket? }: the resource moves the
-- player itself while the screen is black (Open77.players.teleport, no extra
-- fade), then resumes once the body has settled. options.exitTeleport does the
-- same on the way out of an overlay braindance.

local MAX_PER_PLAYER = 2
local nextId = 0
local byPlayer = {} -- playerId -> { [id] = { phase, tag, options, server = bool } }

local function log(fmt, ...) print(("[open77_braindance] " .. fmt):format(...)) end

local function playerId(src)
    local n = tonumber(src)
    if n == nil or n < 1 or n ~= math.floor(n) then return nil end
    return n
end

local function validPosition(p)
    return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
        and p.x == p.x and p.y == p.y and p.z == p.z and math.abs(p.x) < 100000 and math.abs(p.y) < 100000
        and math.abs(p.z) < 10000
end

local function entries(pid)
    local t = byPlayer[pid]
    if not t then t = {} byPlayer[pid] = t end
    return t
end

local function clientOptions(options)
    -- Everything except the server-only keys travels to the client, which
    -- validates it again (Sequence.normalize) before running anything.
    local copy = {}
    for k, v in pairs(options or {}) do
        if k ~= "teleport" and k ~= "exitTeleport" then copy[k] = v end
    end
    return copy
end

local function teleportThenResume(pid, id, destination)
    CreateThread(function()
        local promise, reason = Open77.players.teleport(pid, { x = destination.x, y = destination.y, z = destination.z }, {
            heading = destination.heading, bucket = destination.bucket, fade = false,
        })
        if not promise then
            log("player %d %s teleport refused: %s", pid, id, tostring(reason))
        else
            local placed, why = promise:await()
            if placed then
                log("player %d %s teleported (%s) %.1f %.1f %.1f", pid, id, tostring(placed.state), placed.x, placed.y, placed.z)
            else
                log("player %d %s teleport failed: %s", pid, id, tostring(why))
            end
        end
        TriggerClientEvent("open77_braindance:resume", pid, id)
    end)
end

local function start(pid, options)
    pid = playerId(pid)
    if not pid then return nil, "invalid_player" end
    if options ~= nil and type(options) ~= "table" then return nil, "options_must_be_a_table" end
    options = options or {}
    if options.teleport ~= nil and not validPosition(options.teleport) then return nil, "invalid_teleport" end
    if options.exitTeleport ~= nil and not validPosition(options.exitTeleport) then return nil, "invalid_exitTeleport" end
    local mine = entries(pid)
    local live = 0
    for _ in pairs(mine) do live = live + 1 end
    if live >= MAX_PER_PLAYER then return nil, "too_many_sequences" end
    local copy = clientOptions(options)
    -- A teleport needs the screen to stay black until the body has arrived.
    if options.teleport then copy.hold = true end
    if options.exitTeleport then copy.holdOnExit = true end
    local normalized, reason = BraindanceSequence.normalize(copy)
    if not normalized then return nil, reason end
    nextId = nextId + 1
    local id = "s" .. nextId
    mine[id] = { phase = "requested", tag = options.tag, options = options, server = true, leg = "enter" }
    TriggerClientEvent("open77_braindance:start", pid, id, copy)
    return id
end

local api = { start = start }
exports("start", start)
api.resume = function(pid, id)
    pid = playerId(pid)
    if not pid or not (byPlayer[pid] or {})[id] then return false, "not_found" end
    TriggerClientEvent("open77_braindance:resume", pid, id)
    return true
end
exports("resume", api.resume)
api.exit = function(pid, id, options)
    pid = playerId(pid)
    local entry = pid and (byPlayer[pid] or {})[id]
    if not entry then return false, "not_found" end
    if options ~= nil and type(options) ~= "table" then return false, "options_must_be_a_table" end
    local forward = {}
    if options and options.hold ~= nil then forward.hold = options.hold == true end
    if options and options.teleport ~= nil then
        if not validPosition(options.teleport) then return false, "invalid_teleport" end
        entry.options.exitTeleport = options.teleport
        forward.hold = true
    end
    TriggerClientEvent("open77_braindance:exit", pid, id, forward)
    return true
end
exports("exit", api.exit)
api.cancel = function(pid, id)
    pid = playerId(pid)
    if not pid or not (byPlayer[pid] or {})[id] then return false, "not_found" end
    TriggerClientEvent("open77_braindance:cancel", pid, id)
    return true
end
exports("cancel", api.cancel)
-- One authored player effect on that player's screen, outside any sequence
-- (names: BraindanceSequence.EFFECTS, or any effect authored on the player).
exports("playEffect", function(pid, name, durationMs)
    pid = playerId(pid)
    if not pid then return false, "invalid_player" end
    if type(name) ~= "string" or not name:match("^[%w_]+$") or #name > 64 then return false, "invalid_effect" end
    if durationMs ~= nil and (type(durationMs) ~= "number" or durationMs < 0 or durationMs > 600000) then return false, "invalid_duration" end
    TriggerClientEvent("open77_braindance:effect", pid, name, durationMs or 0)
    return true
end)
exports("stopEffects", function(pid)
    pid = playerId(pid)
    if not pid then return false, "invalid_player" end
    TriggerClientEvent("open77_braindance:stopEffects", pid)
    return true
end)
exports("state", function(pid)
    pid = playerId(pid)
    local list = {}
    for id, entry in pairs(byPlayer[pid] or {}) do
        list[#list + 1] = { id = id, phase = entry.phase, leg = entry.leg, tag = entry.tag, server = entry.server }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end)

local KNOWN = {}
for _, phase in ipairs(BraindanceSequence.PHASES) do KNOWN[phase] = true end
KNOWN.refused = true

-- Every phase of every sequence on that client (server- or client-started).
-- Rate-limited: a sequence has at most ~12 phases.
local budget = {}
RegisterNetEvent("open77_braindance:report", function(id, phase, tag)
    local pid = playerId(source)
    if not pid or type(id) ~= "string" or #id > 16 or not id:match("^[cs]%d+$") or not KNOWN[phase] then return end
    local now = GetGameTimer()
    local b = budget[pid]
    if not b or now - b.since > 10000 then b = { since = now, count = 0 } budget[pid] = b end
    b.count = b.count + 1
    if b.count > 60 then return end

    local mine = entries(pid)
    local entry = mine[id]
    if entry == nil then
        if id:sub(1, 1) == "s" then return end -- a server id we never issued
        entry = { tag = type(tag) == "string" and tag:sub(1, 64) or nil, options = {}, server = false, leg = "enter" }
        mine[id] = entry
    end
    if phase == "exiting" then entry.leg = "exit" end
    entry.phase = phase
    TriggerEvent("open77_braindance:phase", pid, id, phase, entry.tag)
    if phase == "black" then
        TriggerEvent("open77_braindance:black", pid, id, entry.tag)
        local destination = entry.leg == "exit" and entry.options.exitTeleport or entry.options.teleport
        if entry.server and destination then teleportThenResume(pid, id, destination) end
    end
    if phase == "finished" or phase == "cancelled" or phase == "refused" then mine[id] = nil end
end)

AddEventHandler("playerDropped", function()
    local pid = playerId(source)
    if pid then byPlayer[pid] = nil budget[pid] = nil end
end)

-- Console: braindance <playerId> <preset|exit|resume|cancel> [id|hold|x y z]
--          braindance <playerId> effect <name|stop> [durationMs]
RegisterCommand("braindance", function(_, args)
    local pid = tonumber(args[1])
    local verb = args[2] or "braindance"
    if not pid then return log("usage: braindance <playerId> <preset|exit|resume|cancel> [id|hold|x y z]") end
    if verb == "exit" or verb == "resume" or verb == "cancel" then
        local id = args[3]
        if not id then for k in pairs(byPlayer[pid] or {}) do id = k end end
        local ok, reason = api[verb](pid, id)
        return log("%s %d %s -> %s %s", verb, pid, tostring(id), tostring(ok), tostring(reason or ""))
    end
    if verb == "effect" then
        if args[3] == "stop" then TriggerClientEvent("open77_braindance:stopEffects", pid) return log("effects stopped for %d", pid) end
        TriggerClientEvent("open77_braindance:effect", pid, args[3] or "braindance_fpp", tonumber(args[4]) or 0)
        return log("effect %s for %d", tostring(args[3]), pid)
    end
    local options = { preset = verb }
    if args[3] == "hold" then options.hold = true
    elseif tonumber(args[3]) and tonumber(args[4]) and tonumber(args[5]) then
        options.teleport = { x = tonumber(args[3]), y = tonumber(args[4]), z = tonumber(args[5]), heading = tonumber(args[6]) }
    end
    local id, reason = start(pid, options)
    log("start %s for %d -> %s %s", verb, pid, tostring(id), tostring(reason or ""))
end, true)
