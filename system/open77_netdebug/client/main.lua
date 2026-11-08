-- open77_netdebug client: /netdebug.npc draws, over each of the nearest network NPCs, what the
-- network says about it, refreshed four times a second:
--
--   #<id> <record>              <- line 1
--   OWNER <name>(<id>) e<epoch>  |  YOU = this client simulates it
--   gap 1.2 m  hp 80/100  task 42  TP 3
--
-- gap: this client's body against the canonical position it holds (its own last sample when it
-- simulates the NPC, the last replicated sample otherwise). TP: jumps of this client's body of more
-- than TP_METRES in one refresh that the canonical position did not make -- a teleport on this
-- screen. Colours: green = simulated here, cyan = a copy, orange = gap > 1.5 m, red = gap > 3 m.
-- Labels are open77_uikit 3D texts, which allows eight per resource: the nearest eight are shown.

local REFRESH_MS = 250
local RANGE = 60.0
local MAX_LABELS = 8
local TP_METRES = 3.0
local TP_FLASH_MS = 1500

local active = false
local names = {}
local labels = {}   -- npcId -> { handle, text, sublabel, color }
local tracks = {}   -- npcId -> { body, canonical, tps, flashUntil }

local function uikit() return exports.open77_uikit end

local function localId()
    local ok, id = pcall(Open77.players.localId)
    return ok and tonumber(id) or nil
end

local function dist(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function flat(a, b)
    if not a or not b then return nil end
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function bodyOf(entity)
    if not entity or entity == 0 then return nil end
    local ok, x, y, z = pcall(Open77.character.position, entity)
    if not ok or type(x) ~= "number" then return nil end
    return { x = x, y = y, z = z }
end

local function shortRecord(npc)
    local r = tostring(npc.record or npc.template or "?"):gsub("^Character%.", "")
    if #r > 40 then r = r:sub(1, 40) end
    return r
end

local function ownerText(npc, me)
    local owner = tonumber(npc.authorityPlayerId) or 0
    if owner == 0 then return "OWNER none" end
    if npc.locallyAuthoritative or (me and owner == me) then
        return ("OWNER YOU(%d) e%d"):format(owner, tonumber(npc.authorityEpoch) or 0)
    end
    local name = names[tostring(owner)] or ("player " .. owner)
    if #name > 20 then name = name:sub(1, 20) end
    return ("OWNER %s(%d) e%d"):format(name, owner, tonumber(npc.authorityEpoch) or 0)
end

local function clearAll()
    for id, label in pairs(labels) do
        pcall(uikit().clearText3D, label.handle)
        labels[id] = nil
    end
    tracks = {}
end

local function show(id, npc, text, sublabel, color)
    local label = labels[id]
    if label then
        if label.text ~= text or label.sublabel ~= sublabel or label.color ~= color then
            local ok = pcall(uikit().updateText3D, label.handle, { text = text, sublabel = sublabel, color = color })
            if ok then label.text, label.sublabel, label.color = text, sublabel, color end
        end
        return
    end
    local ok, handle = pcall(uikit().drawText3D, {
        entity = npc.entity, offset = { x = 0, y = 0, z = 2.15 },
        text = text, sublabel = sublabel, color = color,
        background = "#0A1220C8", scale = 0.85, maxDistance = RANGE,
    })
    if ok and handle then labels[id] = { handle = handle, text = text, sublabel = sublabel, color = color } end
end

local function refresh(now)
    local me = localId()
    local x, y, z = Open77.character.position()
    if type(x) ~= "number" then return end
    local here = { x = x, y = y, z = z }
    local ok, list = pcall(Open77.npcs.all)
    if not ok or type(list) ~= "table" then return end

    local near = {}
    for _, npc in ipairs(list) do
        local id = tonumber(npc.id)
        if id and npc.streamed and npc.entity and npc.entity ~= 0 then
            local body = bodyOf(npc.entity)
            local d = dist(body, here)
            if d and d <= RANGE then near[#near + 1] = { id = id, npc = npc, body = body, d = d } end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)

    local keep = {}
    for i = 1, math.min(#near, MAX_LABELS) do
        local e = near[i]
        local npc, body = e.npc, e.body
        local canonical = type(npc.position) == "table" and npc.position or nil
        local gap = flat(body, canonical)

        -- A teleport on this screen: the body jumped, the canonical did not move as much.
        local t = tracks[e.id] or { tps = 0, flashUntil = 0 }
        if t.body then
            local jump = dist(body, t.body) or 0
            local moved = dist(canonical, t.canonical) or 0
            if jump > TP_METRES and jump > moved + TP_METRES then
                t.tps = t.tps + 1
                t.flashUntil = now + TP_FLASH_MS
            end
        end
        t.body, t.canonical = body, canonical
        tracks[e.id] = t

        local text = ("#%d %s"):format(e.id, shortRecord(npc))
        local hp = ("hp %d/%d"):format(math.floor((tonumber(npc.health) or 0) + 0.5), math.floor((tonumber(npc.maxHealth) or 0) + 0.5))
        local sub = ("%s | gap %s | %s | task %s | TP %d"):format(ownerText(npc, me),
            gap and ("%.1fm"):format(gap) or "?", hp, tostring(npc.currentTaskId or 0), t.tps)
        if #sub > 96 then sub = sub:sub(1, 96) end

        local color = npc.locallyAuthoritative and "#3CFF8A" or "#22D8E2"
        if gap and gap > 3.0 then color = "#FF4D4D" elseif gap and gap > 1.5 then color = "#FFB020" end
        if now < t.flashUntil then color = "#FF2BD6" end   -- a teleport just happened
        if (tonumber(npc.health) or 0) <= 0 then color = "#8A8F98" end

        show(e.id, npc, text, sub, color)
        keep[e.id] = true
    end
    for id, label in pairs(labels) do
        if not keep[id] then pcall(uikit().clearText3D, label.handle); labels[id] = nil end
    end
    for id in pairs(tracks) do if not keep[id] then tracks[id] = nil end end
end

local function loop()
    while active do
        local ok, err = pcall(refresh, GetGameTimer())
        if not ok then print("[open77_netdebug] refresh failed: " .. tostring(err)) end
        Wait(REFRESH_MS)
    end
    clearAll()
end

RegisterNetEvent("open77_netdebug:npc", function(on, list)
    if type(list) == "table" then names = list end
    if on and not active then
        active = true
        CreateThread(loop)
    elseif not on then
        active = false
    end
end)

RegisterNetEvent("open77_netdebug:names", function(list)
    if type(list) == "table" then names = list end
end)

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then active = false; clearAll() end
end)
