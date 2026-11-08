local page,ready,state
local sequence=0
local active=false
local panel
local hidden={"minimap","compass","clock","health","stamina","weapon","questTracker","crosshair","vanillaNotifications"}
local blocked={"Attack","Melee","WeaponWheel","Hub"}
local function presentation(enabled)
    if enabled==active then return end
    active=enabled
    for _,name in ipairs(hidden) do Open77.hud.setVisible(name,not enabled) end
    for _,name in ipairs(blocked) do
        local ok,reason=Open77.input.setActionBlocked(name,enabled)
        if not ok then print("[aetherfall] input "..name.." "..tostring(reason)) end
    end
    if enabled then
        local ok,reason=Open77.camera.configureThirdPerson({style="shoulder",transition=0.35,
            hip={distance=3.0,offset={x=0.65,y=0,z=0.05},fov=72},
            explore={distance=3.0,offset={x=0.65,y=0,z=0.05},fov=72}})
        if not ok then print("[aetherfall] camera "..tostring(reason)) end
        Open77.perspective.setThirdPerson(true,true)
    else
        panel=nil
        if ready and page then page:send("aetherfall:panel",{id=false}); page:setFocus(false,false) end
        Open77.camera.resetThirdPerson(); Open77.perspective.clearThirdPersonOverride()
    end
end
-- The Conclave menu (duel queue, start, training dummies): the page takes keyboard and mouse
-- while it is open, and gives them back when it closes (its button, Escape or the menu key).
local function closeMenu()
    if panel~="menu" then return end
    panel=nil
    if ready and page then page:send("aetherfall:panel",{id=false}); page:setFocus(false,false) end
end
local function openMenu()
    if not active or not ready or not page then return end
    panel="menu"
    page:send("aetherfall:panel",{id="menu"})
    local ok,reason=page:setFocus(true,true)
    if not ok then print("[aetherfall] menu focus "..tostring(reason)) end
end
local function push()
    if not ready or not page then return end
    page:send("aetherfall:state",state or {phase="off",roster={}})
end
local function cast(id)
    if panel or not state or not state.self or not state.self.alive or (state.phase~="active" and not state.practice) then return end
    local view=Open77.camera.view()
    if not view or not view.forward then return end
    sequence=math.max(sequence,state.self.sequence or 0)+1
    TriggerServerEvent("aetherfall:cast",id,view.forward,sequence)
end
for _,entry in ipairs({{id="spellbook",key="H",label="Aetherfall: spellbook"},
    {id="standings",key="K",label="Aetherfall: standings"}}) do
    RegisterKeyMapping("aetherfall."..entry.id,entry.label,entry.key,function()
        if not active or not ready or not page or panel=="menu" then return end
        panel=panel~=entry.id and entry.id or nil
        page:send("aetherfall:panel",{id=panel or false})
    end)
end
RegisterKeyMapping("aetherfall.menu","Aetherfall: Conclave menu",Aetherfall.lobby.menuKey,function()
    if panel=="menu" then closeMenu() else openMenu() end
end)
for _,id in ipairs(Aetherfall.order) do
    local spell=Aetherfall.spells[id]
    local ok,reason=RegisterKeyMapping("aetherfall."..id,spell.name,spell.key,function() cast(id) end)
    if not ok then print("[aetherfall] binding "..id.." "..tostring(reason)) end
end
RegisterNetEvent("aetherfall:state",function(payload)
    if type(payload)~="table" then return end
    state=payload; presentation(payload.self~=nil); push()
end)
RegisterNetEvent("aetherfall:event",function(event)
    if ready and page then page:send("aetherfall:event",event) end
end)
RegisterNetEvent("aetherfall:notice",function(payload)
    if ready and page then page:send("aetherfall:notice",payload) end
end)
RegisterNetEvent("aetherfall:refused",function(payload)
    if ready and page then page:send("aetherfall:refused",payload) end
end)
AddEventHandler("onClientResourceStart",function(name)
    if name~=GetCurrentResourceName() then return end
    local reason
    page,reason=WebUI.create({entry="web/index.html",layer="hud",width=1920,height=1080,
        fps=30,zIndex=730,transparent=true,visible=true})
    if not page then print("[aetherfall] HUD "..tostring(reason)); return end
    page:on("ui:ready",function()
        ready=true
        local spells={}
        for _,id in ipairs(Aetherfall.order) do
            local s=Aetherfall.spells[id]
            spells[#spells+1]={id=id,name=s.name,key=Open77.input.keyFor("aetherfall."..id) or s.key,
                icon=s.icon,color=s.color,cost=s.cost,cooldownMs=s.cooldownMs,description=s.description}
        end
        page:send("aetherfall:config",{title=Aetherfall.title,subtitle=Aetherfall.subtitle,spells=spells,arena=Aetherfall.arena,
            panels={spellbook=Open77.input.keyFor("aetherfall.spellbook") or "H",
                standings=Open77.input.keyFor("aetherfall.standings") or "K",
                menu=Open77.input.keyFor("aetherfall.menu") or Aetherfall.lobby.menuKey}})
        TriggerServerEvent("aetherfall:request"); push()
    end)
    page:on("aetherfall:menu:close",function() closeMenu() end)
    page:on("aetherfall:menu:action",function(payload)
        if panel=="menu" and type(payload)=="table" and type(payload.action)=="string" then
            TriggerServerEvent("aetherfall:menu",payload.action)
            if payload.action=="start" or payload.action=="forfeit" then closeMenu() end
        end
    end)
end)
AddEventHandler("onClientResourceStop",function(name)
    if name==GetCurrentResourceName() then presentation(false) end
end)
