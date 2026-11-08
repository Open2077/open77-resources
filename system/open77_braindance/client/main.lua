-- open77_braindance client runtime: plays the braindance launch on the local
-- player (the game's own authored effects), fades the native screen, and tells
-- every script -- local and on the server -- which phase it is in.
--
-- Exports (client):        start(options) -> id | nil, reason
--                          resume(id), exit(id, options?), cancel(id), state(id), active()
--                          effects(), presets(), playEffect(name, durationMs?), stopEffect(handle)
-- Local events:            open77_braindance:phase (id, phase, info)
--                          open77_braindance:black (id, info)    -- the screen is black now
-- Server is told:          open77_braindance:report (id, phase, tag)

local Sequence = BraindanceSequence
local TICK_MS = 50
local sequences = {}  -- id -> { seq, owner = "client"|"server", fadeId, handles = {name -> handle} }
local nextId = 0
local lockedBy, hudHiddenBy = {}, {}

local function now() return GetGameTimer() end -- milliseconds (Open77.time.monotonic is seconds)
local function log(fmt, ...) print(("[open77_braindance] " .. fmt):format(...)) end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local function applyLock(id, locked)
    lockedBy[id] = locked or nil
    local want = next(lockedBy) ~= nil
    local ok, reason = Open77.input.setActionBlocked("Movement", want)
    if not ok and reason ~= "action_already_enforced" then log("movement lock %s: %s", tostring(want), tostring(reason)) end
end

-- The vanilla HUD and every resource interface (LightRP's HUD is a WebUI)
-- go away with the cinematic claim; the bars are as thin as allowed unless the
-- caller asks for a letterbox.
local function applyHud(id, hidden, letterbox)
    hudHiddenBy[id] = hidden and (letterbox or 0.01) or nil
    local height
    for _, h in pairs(hudHiddenBy) do height = math.max(height or 0, h) end
    if Open77.hud.setCinematic then
        local ok, reason
        if height then ok, reason = Open77.hud.setCinematic(true, height) else ok, reason = Open77.hud.setCinematic(false) end
        if not ok then log("cinematic: %s", tostring(reason)) end
    else
        local ok, reason = Open77.hud.setVisible("all", height == nil)
        if not ok then log("hud: %s", tostring(reason)) end
    end
end

local function stopHandle(entry, name)
    local handle = entry.handles[name]
    if handle then pcall(Open77.vfx.stop, handle) end
    entry.handles[name] = nil
end

local function playEffect(name, durationMs)
    local options = { entity = "1", breakAllLoops = false }
    if durationMs and durationMs > 0 then options.duration = durationMs / 1000 end
    return Open77.vfx.playEntity(name, options)
end

local function report(entry, phase, info)
    local seq = entry.seq
    TriggerEvent("open77_braindance:phase", seq.id, phase, info or {})
    if phase == "black" then TriggerEvent("open77_braindance:black", seq.id, info or {}) end
    pcall(TriggerServerEvent, "open77_braindance:report", seq.id, phase, seq.options.tag)
end

local function perform(entry, action)
    local seq = entry.seq
    if action.kind == "phase" then
        log("%s %s%s", seq.id, action.phase, action.leg == "exit" and " (exit)" or "")
        report(entry, action.phase, action.info)
    elseif action.kind == "effect" then
        stopHandle(entry, action.name)
        local handle, reason = playEffect(action.name, action.durationMs)
        if handle then entry.handles[action.name] = handle
        else log("%s effect %s refused: %s", seq.id, action.name, tostring(reason)) end
    elseif action.kind == "stopEffect" then
        stopHandle(entry, action.name)
    elseif action.kind == "sound" then
        local ok, reason = Open77.sfx.play2d(action.name)
        if not ok then log("%s sound %s: %s", seq.id, action.name, tostring(reason)) end
    elseif action.kind == "lock" then
        applyLock(seq.id, action.locked)
    elseif action.kind == "hud" then
        applyHud(seq.id, action.hidden, action.letterbox)
    elseif action.kind == "fadeOut" then
        local options = { durationMs = action.durationMs, timeoutMs = 60000 }
        if action.color then options.color = { r = action.color.r or 0, g = action.color.g or 0, b = action.color.b or 0, a = 255 } end
        local fadeId, promise = Open77.screen.fadeOut(options)
        if not fadeId then
            -- Another resource (or the engine) owns the fade. If the screen is
            -- black anyway, carry on; otherwise go on without a fade.
            log("%s fadeOut refused: %s", seq.id, tostring(promise))
            seq:covered()
            return
        end
        entry.fadeId = fadeId
        CreateThread(function()
            local covered, reason = promise:await()
            if not covered then log("%s fade ended early: %s", seq.id, tostring(reason)) end
            seq:covered()
        end)
    elseif action.kind == "fadeIn" then
        if not entry.fadeId then seq:revealed() return end
        local ok, promise = Open77.screen.fadeIn(entry.fadeId, { durationMs = action.durationMs })
        if not ok then
            log("%s fadeIn refused: %s", seq.id, tostring(promise))
            pcall(Open77.screen.cancel, entry.fadeId)
            entry.fadeId = nil
            seq:revealed()
            return
        end
        CreateThread(function()
            promise:await()
            entry.fadeId = nil
            seq:revealed()
        end)
    elseif action.kind == "perspective" then
        if action.firstPerson then
            local ok, reason = Open77.perspective.setThirdPerson(false, true)
            if not ok then log("%s first person refused: %s", seq.id, tostring(reason)) end
        else
            pcall(Open77.perspective.clearThirdPersonOverride)
        end
    elseif action.kind == "restore" then
        if entry.fadeId then pcall(Open77.screen.cancel, entry.fadeId) entry.fadeId = nil end
    end
end

-- The game's loading cycle (a far teleport opens one). A state whose revision
-- has not moved for STALE_LOADING_MS is treated as over: the client does not
-- always observe the end of a cycle it did not start.
local STALE_LOADING_MS = 6000
local loadingSeen = { revision = nil, changedAt = 0 }
local function loadingActive(t)
    if not (Open77.screen and Open77.screen.loadingState) then return false end
    local ok, state = pcall(Open77.screen.loadingState)
    if not ok or type(state) ~= "table" then return false end
    if state.revision ~= loadingSeen.revision then loadingSeen.revision = state.revision loadingSeen.changedAt = t end
    return state.active == true and t - loadingSeen.changedAt < STALE_LOADING_MS
end

local function run(entry)
    CreateThread(function()
        while true do
            local t = now()
            if entry.seq.phase == "black" then entry.seq:setLoading(loadingActive(t), t) end
            for _, action in ipairs(entry.seq:tick(t)) do
                local ok, err = pcall(perform, entry, action)
                if not ok then log("%s action %s failed: %s", entry.seq.id, tostring(action.kind), tostring(err)) end
            end
            if entry.seq.done then
                for name in pairs(entry.handles) do stopHandle(entry, name) end
                sequences[entry.seq.id] = nil
                return
            end
            Wait(TICK_MS)
        end
    end)
end

local function begin(id, options, owner)
    if sequences[id] then return nil, "duplicate_id" end
    if count(sequences) >= 4 then return nil, "too_many_sequences" end
    local seq, reason = Sequence.new(id, options, now())
    if not seq then return nil, reason end
    local entry = { seq = seq, owner = owner, handles = {} }
    sequences[id] = entry
    run(entry)
    return id
end

local function start(options)
    nextId = nextId + 1
    return begin("c" .. nextId, options, "client")
end

local function find(id)
    local entry = type(id) == "string" and sequences[id] or nil
    return entry
end

exports("start", start)
exports("resume", function(id)
    local entry = find(id)
    if not entry then return false, "not_found" end
    return entry.seq:resume() or false, nil
end)
exports("exit", function(id, options)
    local entry = find(id)
    if not entry then return false, "not_found" end
    if not entry.seq:exit(options) then return false, "not_exitable" end
    return true
end)
exports("cancel", function(id)
    local entry = find(id)
    if not entry then return false, "not_found" end
    for _, action in ipairs(entry.seq:cancel(now(), "cancelled")) do pcall(perform, entry, action) end
    return true
end)
exports("state", function(id)
    local entry = find(id)
    if not entry then return nil, "not_found" end
    return entry.seq:snapshot()
end)
exports("active", function()
    local list = {}
    for _, entry in pairs(sequences) do list[#list + 1] = entry.seq:snapshot() end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end)
exports("effects", function()
    local list = {}
    for name, description in pairs(Sequence.EFFECTS) do list[#list + 1] = { name = name, description = description } end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end)
exports("presets", function()
    local out = {}
    for name, preset in pairs(Sequence.PRESETS) do
        local copy = {}
        for k, v in pairs(preset) do copy[k] = v end
        out[name] = copy
    end
    return out
end)
-- A single authored player effect, outside any sequence (e.g. braindance_fpp
-- while a custom scene runs). Returns the Open77.vfx handle.
exports("playEffect", function(name, durationMs)
    if type(name) ~= "string" or not name:match("^[%w_]+$") or #name > 64 then return nil, "invalid_effect" end
    if durationMs ~= nil and (type(durationMs) ~= "number" or durationMs < 0 or durationMs > 600000) then return nil, "invalid_duration" end
    return playEffect(name, durationMs)
end)
exports("stopEffect", function(handle) return Open77.vfx.stop(handle) end)

-- Server-driven sequences. The server picks the id ("s<n>") so its own
-- resume/exit/cancel can name it.
RegisterNetEvent("open77_braindance:start", function(id, options)
    if type(id) ~= "string" or not id:match("^s%d+$") then return end
    local ok, reason = begin(id, options, "server")
    if not ok then pcall(TriggerServerEvent, "open77_braindance:report", id, "refused", reason) end
end)
RegisterNetEvent("open77_braindance:resume", function(id) local e = find(id) if e then e.seq:resume() end end)
RegisterNetEvent("open77_braindance:exit", function(id, options) local e = find(id) if e then e.seq:exit(options) end end)
RegisterNetEvent("open77_braindance:cancel", function(id)
    local e = find(id)
    if e then for _, action in ipairs(e.seq:cancel(now(), "server_cancelled")) do pcall(perform, e, action) end end
end)

-- One authored effect on demand from the server (exports.playEffect / stopEffects).
local served = {}
RegisterNetEvent("open77_braindance:effect", function(name, durationMs)
    if type(name) ~= "string" or not name:match("^[%w_]+$") or #name > 64 then return end
    if type(durationMs) ~= "number" or durationMs < 0 or durationMs > 600000 then durationMs = 0 end
    if served[name] then pcall(Open77.vfx.stop, served[name]) end
    local handle, reason = playEffect(name, durationMs)
    served[name] = handle
    log("effect %s %s", name, handle and "playing" or ("refused: " .. tostring(reason)))
end)
RegisterNetEvent("open77_braindance:stopEffects", function()
    for name, handle in pairs(served) do pcall(Open77.vfx.stop, handle) served[name] = nil end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, entry in pairs(sequences) do
        for _, action in ipairs(entry.seq:cancel(now(), "resource_stopped")) do pcall(perform, entry, action) end
        for n in pairs(entry.handles) do stopHandle(entry, n) end
    end
    pcall(Open77.input.setActionBlocked, "Movement", false)
    if Open77.hud.setCinematic then pcall(Open77.hud.setCinematic, false) else pcall(Open77.hud.setVisible, "all", true) end
    pcall(Open77.perspective.clearThirdPersonOverride)
end)

-- Developer console: `bd <preset|exit|resume|cancel> [id]`.
RegisterCommand("bd", function(_, args)
    local verb = args[1] or "braindance"
    if verb == "exit" or verb == "resume" or verb == "cancel" then
        local id = args[2]
        if not id then for k in pairs(sequences) do id = k end end
        local fn = verb == "exit" and function(i) return sequences[i] and sequences[i].seq:exit() end
            or verb == "resume" and function(i) return sequences[i] and sequences[i].seq:resume() end
            or function(i)
                local e = sequences[i]
                if not e then return false end
                for _, action in ipairs(e.seq:cancel(now(), "command")) do pcall(perform, e, action) end
                return true
            end
        log("%s %s -> %s", verb, tostring(id), tostring(id and fn(id)))
        return
    end
    log("start %s -> %s", verb, tostring((start({ preset = verb, hold = args[2] == "hold" }))))
end, false)
