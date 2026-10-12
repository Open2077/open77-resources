-- Optional open-access implant workshop. All changes are validated by the
-- server and use the public cyberware API; this file only owns the UI surface.
local RESOURCE = GetCurrentResourceName()
local CHANNEL = "open77:cyberlab:panel:"
local page, snapshot, target
local ready, open = false, false
local openedAt, lastRequestAt = 0, 0

local function now() return Open77.time.monotonic() end

local function send(event, payload)
    if not page or not ready then return end
    local ok, reason = page:send("cyberlab:" .. event, payload or {})
    if ok == false then Open77.log.warn("cyberlab panel: " .. event .. " refused: " .. tostring(reason)) end
end

local function close()
    open = false
    if page then page:setFocus(false, false) end
    send("close")
end

local function request()
    if not open then return end
    lastRequestAt = now()
    TriggerServerEvent("open77:cyberlab:slam:request", {target=target})
    TriggerServerEvent("open77:cyberlab:reflex:request", {target=target})
    local ok, reason = TriggerServerEvent(CHANNEL .. "request", {target = target})
    if ok == false then send("result", {ok=false, phase="failed", target=target, message=tostring(reason)}) end
end

local function show()
    if not open or not ready then return end
    send("open", snapshot)
    local ok, reason = page:setFocus(true, true)
    if ok == false then
        Open77.log.warn("cyberlab panel: focus refused: " .. tostring(reason))
        close()
    end
end

local function createPage()
    if page then return true end
    local reason
    -- Native hidden surfaces currently fail to upload their first frame after
    -- being shown. Keep this lazy surface visible, with CSS-transparent chrome
    -- until the page receives its open message (same convention as /admin).
    page, reason = WebUI.create({entry="web/index.html", layer="menu", width=1920,
        height=1080, fps=30, zIndex=725, transparent=true, visible=true})
    if not page then
        Open77.log.error("cyberlab panel: WebUI failed: " .. tostring(reason))
        return false
    end
    page:on("cyberlab:ready", function() ready = true; show() end)
    page:on("cyberlab:close", close)
    page:on("cyberlab:refresh", request)
    page:on("cyberlab:target", function(payload)
        if not open or type(payload) ~= "table" then return end
        local id = tonumber(payload.target)
        if not id or id < 1 or id % 1 ~= 0 then return end
        target = id
        request()
    end)
    page:on("cyberlab:action", function(payload)
        if not open or type(payload) ~= "table" or payload.target ~= target then return end
        if payload.slot == "dash" then
            if payload.action ~= "install" and payload.action ~= "remove" and payload.action ~= "inspect" and payload.action ~= "test" then return end
            if payload.action == "install" and (payload.preset ~= "basic" and payload.preset ~= "advanced"
                or payload.mode ~= "ground" and payload.mode ~= "air" and payload.mode ~= "combined") then return end
            local ok, why = TriggerServerEvent(CHANNEL .. "action", {
                target=target, slot="dash", action=payload.action,
                preset=payload.action=="install" and payload.preset or nil,
                mode=payload.action=="install" and payload.mode or nil,
            })
            if ok == false then send("result", {slot="dash",ok=false,phase="failed",target=target,message=tostring(why)}) end
            return
        end
        if payload.slot ~= "arms" and payload.slot ~= "legs" then return end
        if payload.action ~= "install" and payload.action ~= "remove" then return end
        if payload.action == "install" and (type(payload.grade) ~= "string" or #payload.grade > 64) then return end
        local ok, why = TriggerServerEvent(CHANNEL .. "action", {
            target=target, slot=payload.slot, action=payload.action, grade=payload.grade,
        })
        if ok == false then send("result", {ok=false, phase="failed", target=target, message=tostring(why)}) end
    end)
    page:on("cyberlab:slamAction", function(payload)
        if not open or type(payload)~="table" or payload.target~=target then return end
        if payload.action~="grant" and payload.action~="revoke" and payload.action~="cancel" then return end
        if payload.action=="grant" and (type(payload.preset)~="string" or #payload.preset>32) then return end
        local ok,reason=TriggerServerEvent("open77:cyberlab:slam:action",
            {target=target,action=payload.action,preset=payload.preset})
        if ok==false then send("slamResult",{target=target,ok=false,message=tostring(reason)}) end
    end)
    page:on("cyberlab:reflexAction", function(payload)
        if not open or type(payload)~="table" or payload.target~=target then return end
        if payload.action~="grant" and payload.action~="revoke" and payload.action~="cancel" then return end
        if payload.action=="grant" and (type(payload.preset)~="string" or #payload.preset>32) then return end
        local ok,reason=TriggerServerEvent("open77:cyberlab:reflex:action",
            {target=target,action=payload.action,preset=payload.preset})
        if ok==false then send("reflexResult",{target=target,ok=false,message=tostring(reason)}) end
    end)
    page:on("cyberlab:diag", function(payload)
        if type(payload) == "table" then
            Open77.log.warn("cyberlab panel: " .. tostring(payload.message or "unknown page error"):sub(1, 500))
        end
    end)
    CreateThread(function()
        while page do
            Wait(500)
            if open then
                if now() - openedAt > 15 * 60 then close()
                elseif now() - lastRequestAt >= 1.5 then request() end
            end
        end
    end)
    return true
end

RegisterNetEvent(CHANNEL .. "open", function(payload)
    if type(payload) ~= "table" or type(payload.target) ~= "table" then return end
    snapshot, target = payload, payload.target.id
    open, openedAt, lastRequestAt = true, now(), now()
    if not createPage() then close(); return end
    show()
    TriggerServerEvent("open77:cyberlab:slam:request", {target=target})
    TriggerServerEvent("open77:cyberlab:reflex:request", {target=target})
end)
RegisterNetEvent(CHANNEL .. "data", function(payload)
    if not open or type(payload) ~= "table" or type(payload.target) ~= "table" then return end
    if payload.target.id ~= target then return end -- late response from an old selection
    snapshot = payload
    send("data", payload)
end)
RegisterNetEvent(CHANNEL .. "result", function(payload)
    if type(payload) ~= "table" then return end
    send("result", payload)
    if open and payload.phase ~= "pending" then request() end
end)
RegisterNetEvent(CHANNEL .. "close", close)
AddEventHandler("open77:pauseKey", function() if open then close() end end)
AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    close()
    page, snapshot, target, ready = nil, nil, nil, false
end)

RegisterNetEvent("open77:cyberlab:slam:data",function(payload)
    if open and type(payload)=="table" and payload.target==target then send("slamData",payload) end
end)
RegisterNetEvent("open77:cyberlab:slam:result",function(payload)
    if open and type(payload)=="table" and payload.target==target then send("slamResult",payload) end
end)
RegisterNetEvent("open77:cyberlab:reflex:data",function(payload)
    if open and type(payload)=="table" and payload.target==target then send("reflexData",payload) end
end)
RegisterNetEvent("open77:cyberlab:reflex:result",function(payload)
    if open and type(payload)=="table" and payload.target==target then send("reflexResult",payload) end
end)
