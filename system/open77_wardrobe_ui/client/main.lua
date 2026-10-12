-- A local fitting room. Preview writes are suppressed by the replication
-- resources; only an explicit atomic server commit makes a look persistent.
local page, ready, opened, opening, closing = nil, false, false, false, false
local appearanceHeld, equipmentHeld, wardrobeHeld = false, false, false
local baseline, lastPreview, waiting = nil, nil, nil
local sequence, generation = 0, 0
local favoriteKey, favorites = nil, nil
local pendingOpen, readyProbeAt, pendingOpenAt = false, -1000, 0
local savedPerspective, orbit, orbitPending = nil, 180, false
local lastActivity, requestAt = 0, 0
local function now() return Open77.time.monotonic() end
local function send(name, value) if page then page:send(name, value or {}) end end
local function status(message, kind) send("wardrobe:status", {message=message, kind=kind or "error"}) end
local function call(resource, name)
    local promise, reason = Open77.exports.call(resource, name)
    if not promise then return nil, reason end
    return promise:await()
end
local function notify(text)
    print("[open77_wardrobe_ui] " .. tostring(text))
    TriggerEvent("chat:addMessage", {author="WARDROBE",text=text})
end
local function playable()
    local b = Open77.session.characterBootstrap()
    local c = Open77.character.state()
    local life = Open77.players.getLifeState()
    return type(b) == "table" and b.phase == "ready" and b.playerReset == "complete"
        and type(c) == "table" and c.alive == true and not (c.vehicle and c.vehicle.mounted)
        and type(life) == "table" and (life.phase == "alive" or life.phase == "recovering")
end
local function release()
    if closing then return end
    closing = true
    if page then page:setFocus(false, false) end
    send("wardrobe:closed")
    opened, opening = false, false
    TriggerEvent("open77:wardrobe:visibility", false)
    generation = generation + 1
    if type(Open77.camera.clearOrbit) == "function" then Open77.camera.clearOrbit() end
    if savedPerspective then Open77.perspective.set(savedPerspective); savedPerspective = nil end
    -- Restoration is performed by the owners from their newest committed
    -- records, including records received while the fitting room was open.
    if wardrobeHeld then call("open77_wardrobe", "endPreview"); wardrobeHeld = false end
    if equipmentHeld then call("open77_equipment", "endPreview"); equipmentHeld = false end
    if appearanceHeld then call("open77_appearance", "endPreview"); appearanceHeld = false end
    baseline, lastPreview, waiting = nil, nil, nil
    favoriteKey, favorites = nil, nil
    closing = false
end
local function close()
    pendingOpen=false
    if opening and not opened then
        -- An export may be awaiting its owner. Cancel the generation, then
        -- let that single acquisition coroutine release any acquired lease.
        opening=false;generation=generation+1
        if page then page:setFocus(false,false) end
        return
    end
    if waiting then
        status("Save is pending. Closing restores the last confirmed look; a completed save will still arrive.", "info")
    end
    release()
end
local function openMenu()
    if opened or opening or closing then
        print("[open77_wardrobe_ui] open ignored: modal transition in progress")
        return
    end
    if not ready or not page then
        pendingOpen=true;pendingOpenAt=now()
        print("[open77_wardrobe_ui] waiting for page handshake")
        return
    end
    if not playable() then
        TriggerEvent("chat:addMessage", {author="WARDROBE",text="Enter the world and leave your vehicle before opening the wardrobe."})
        return
    end
    if Open77.input.isCaptured() then
        -- Slash commands briefly retain the chat's focus until their handler
        -- completes. Wait one scheduler turn; never steal another modal.
        Wait(100)
        if Open77.input.isCaptured() then
            print("[open77_wardrobe_ui] open refused: another menu owns input")
            return
        end
    end
    print("[open77_wardrobe_ui] requesting authoritative wardrobe")
    opening, requestAt = true, now()
    TriggerServerEvent("open77:presentation:uiRequest")
end
RegisterNetEvent("open77:wardrobe_ui:open", openMenu)
RegisterNetEvent("open77:presentation:uiState", function(value)
    if not opening then return end
    if type(value) ~= "table" or value.available ~= true then
        opening = false
        TriggerEvent("chat:addMessage", {author="WARDROBE",text="Wardrobe unavailable: " .. tostring(value and value.error or "no_response")})
        return
    end
    local token = generation
    local ok, reason = call("open77_appearance", "beginPreview")
    if not ok then opening=false; notify("Your appearance is still settling. Try the wardrobe again in a moment."); return end
    appearanceHeld=true
    if token ~= generation or not opening then release(); return end
    ok, reason = call("open77_equipment", "beginPreview")
    if not ok then release(); notify("Your clothing is still loading. Try the wardrobe again in a moment."); return end
    equipmentHeld = true
    if token ~= generation or not opening then release(); return end
    ok, reason = call("open77_wardrobe", "beginPreview")
    if ok then wardrobeHeld = true end
    if not ok or token ~= generation or not playable() then release(); return end
    baseline = value
    value.orbitAvailable = type(Open77.camera.orbit) == "function"
    local perspective = Open77.perspective.state()
    savedPerspective = perspective and perspective.requested or Open77.perspective.get()
    Open77.perspective.set("tps")
    orbit, orbitPending = 180, true
    opened, opening, lastActivity = true, false, now()
    send("wardrobe:open", value)
    local focused = page:setFocus(true, true)
    if not focused then release();return end
    TriggerEvent("open77:wardrobe:visibility", true)
    -- Each resume has a separate instruction budget as well as the 1024-value
    -- event limit. Yield between compact batches; a full catalogue is roughly
    -- two thousand records and must never monopolize one resource callback.
    CreateThread(function()
        Wait(0)
        if token ~= generation or not opened then return end
        local key, keyError = WardrobeFavorites.key(Open77.network.identity())
        if key then
            local stored, readError = Open77.kvp.get(key, "")
            local values, decodeError = WardrobeFavorites.decode(stored, Open77.equipment.info, function() Wait(0) end)
            if token ~= generation or not opened then return end
            if not readError and values then favoriteKey=key;favorites=values
            else keyError=readError or decodeError end
        end
        send("wardrobe:favorites",{items=WardrobeFavorites.list(favorites or {}),available=favoriteKey ~= nil,error=keyError})
        local records, catalogError = Open77.equipment.records({family=value.family, restricted=false, limit=2000})
        if not records then status("Clothing catalogue unavailable: " .. tostring(catalogError));return end
        local chunk = {}
        for _, item in ipairs(records) do
            if token ~= generation or not opened or not page then return end
            chunk[#chunk+1]={record=item.record,slot=item.slot,tweakDbId=item.tweakDbId,nonvisual=item.nonvisual == true}
            if #chunk==64 then
                send("wardrobe:catalogue",{items=chunk})
                chunk={}
                Wait(0)
            end
        end
        if token == generation and opened and page then
            send("wardrobe:catalogue",{items=chunk,complete=true})
        end
    end)
end)
local function applyPreview(value)
    if type(value) ~= "table" or type(value.equipment) ~= "table" or type(value.wardrobe) ~= "table"
        or type(value.wardrobe.outfits) ~= "table" then return nil, "invalid_preview" end
    -- Wardrobe first keeps underlying equipment changes visually covered.
    for index=0,6 do
        local items = value.wardrobe.outfits[tostring(index)] or value.wardrobe.outfits[index] or {}
        local ok, reason = Open77.wardrobe.outfit(index).apply(items, {replace=true})
        if not ok then return nil, reason end
    end
    local ok, reason = Open77.wardrobe.activate(value.wardrobe.active)
    if not ok then return nil, reason end
    return Open77.equipment.apply(value.equipment, {replace=true,allowRestricted=true})
end
RegisterNetEvent("open77:presentation:commitResult", function(id, ok, reason, value)
    if not opened or not waiting or waiting.id ~= id then return end
    waiting = nil
    if type(value) == "table" and value.available ~= false then
        baseline = value
        lastPreview = nil
        send("wardrobe:committed", {ok=ok == true, reason=reason, state=value})
        -- Release and reacquire via close/reopen only when the player leaves;
        -- the server record handlers retain current committed restoration.
        applyPreview(value)
    else send("wardrobe:saveFailed", {reason=reason or "save_failed"}) end
end)
AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    page = WebUI.create({entry="web/index.html",layer="menu",zIndex=710,width=1920,height=1080,fps=30,transparent=true,visible=true})
    if not page then print("[open77_wardrobe_ui] WebUI unavailable"); return end
    page:on("wardrobe:ready", function()
        if not ready then print("[open77_wardrobe_ui] page handshake complete") end
        ready=true
    end)
    page:on("wardrobe:close", close)
    page:on("wardrobe:activity", function()
        if opened then lastActivity=now() end
    end)
    page:on("wardrobe:favorite", function(value)
        if not opened or not favoriteKey or not favorites or type(value) ~= "table" then return end
        local key=WardrobeFavorites.key(Open77.network.identity())
        if key ~= favoriteKey then return end
        local record=WardrobeFavorites.record(value.record, Open77.equipment.info)
        if not record or type(value.enabled) ~= "boolean" then return end
        local token=generation
        local function current() return opened and token==generation and key==favoriteKey end
        local values, reason=WardrobeFavorites.update(Open77.kvp,key,record,value.enabled,
            Open77.equipment.info,function() Wait(0) end,current)
        if not current() then return end
        if values then favorites=values end
        send("wardrobe:favorites",{items=WardrobeFavorites.list(favorites),available=true,error=reason})
    end)
    page:on("wardrobe:preview", function(value)
        if not opened or waiting or not playable() then return end
        lastActivity = now()
        local ok, reason = applyPreview(value)
        if not ok then
            applyPreview(lastPreview or baseline)
            send("wardrobe:previewResult", {ok=false,reason=reason})
        else
            lastPreview=value
            send("wardrobe:previewResult", {ok=true})
        end
    end)
    page:on("wardrobe:save", function(value)
        if not opened or waiting or type(value) ~= "table" or not playable() then return end
        sequence=sequence+1
        local id="wardrobe-" .. tostring(sequence)
        value.expectedRevision=baseline.revision
        value.characterKey=baseline.characterKey
        waiting={id=id,at=now()}
        local ok, reason=TriggerServerEvent("open77:presentation:commit",id,value)
        if not ok then waiting=nil; send("wardrobe:saveFailed",{reason=reason or "network_unavailable"}) end
    end)
    page:on("wardrobe:orbit", function(value)
        if not opened or type(value) ~= "table" or type(value.degrees) ~= "number" then return end
        orbit=math.max(-180,math.min(180,value.degrees));orbitPending=true;lastActivity=now()
        if type(Open77.camera.orbit)=="function" then
            local ok, reason=Open77.camera.orbit(orbit)
            orbitPending=not ok
            if not ok then status("Camera: " .. tostring(reason),"info") end
        end
    end)
    page:on("wardrobe:appearance", function(value)
        if not opened or waiting then return end
        local command=type(value)=="table" and value.mode=="barber" and "barber" or "appearance"
        release()
        -- Appearance publication stays blocked until restored clothing has
        -- actually attached. Do not race that barrier with editor entry.
        local handoffGeneration=generation
        for _=1,40 do
            if generation ~= handoffGeneration or opened or opening or not playable() then return end
            local settled=call("open77_appearance","previewReady")
            if settled then TriggerServerEvent("open77:command:execute",command);return end
            Wait(250)
        end
        notify("Your clothing is still settling. Open the appearance editor again in a moment.")
    end)
    if type(RegisterKeyMapping)=="function" then
        RegisterKeyMapping("wardrobe.open","Open wardrobe","F2",function() openMenu() end)
    end
    CreateThread(function()
        while page do
            -- The first page-ready event can race resource event registration.
            -- A native-to-page probe makes the handshake repeatable without
            -- recreating the surface or requiring another keypress.
            if not ready and now()-readyProbeAt>=1 then
                readyProbeAt=now();send("wardrobe:probe")
            end
            if pendingOpen then
                if ready then pendingOpen=false;openMenu()
                elseif now()-pendingOpenAt>10 then
                    pendingOpen=false;notify("The wardrobe page is still loading. Try again in a moment.")
                end
            end
            if opened then
                if not playable() then release()
                elseif now()-lastActivity>600 then release()
                elseif waiting and now()-waiting.at>15 then
                    waiting=nil
                    send("wardrobe:saveFailed",{reason="save_timeout"})
                    -- Keep the draft; retry is revision-checked by authority.
                elseif type(Open77.camera.orbit)=="function" then
                    -- Idempotent while owned. A temporary engine-camera takeover
                    -- can reset the native rig after the initial request succeeds.
                    local ok=Open77.camera.orbit(orbit)
                    orbitPending=not ok
                end
            elseif opening and now()-requestAt>10 then
                opening=false
                TriggerEvent("chat:addMessage",{author="WARDROBE",text="The wardrobe did not respond. Try opening it again."})
            end
            Wait(250)
        end
    end)
end)
AddEventHandler("open77:pauseKey", function() if opened or opening then close() end end)
AddEventHandler("open77:worldReady", function() if opened or opening then close() end end)
AddEventHandler("onClientResourceStop", function(name)
    if name==GetCurrentResourceName() then release();page=nil;ready=false end
end)
exports("isOpen",function() return opened end)
exports("state",function()
    return {ready=ready,opened=opened,opening=opening,closing=closing,pendingOpen=pendingOpen,
        captured=Open77.input.isCaptured(),generation=generation}
end)
