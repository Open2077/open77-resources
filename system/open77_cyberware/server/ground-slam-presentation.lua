-- Public, server-local native phase notification. Canonical damage is reported
-- separately by onAbilityImpact once collision evidence and policies accept it.
local seen={}
local stopped=false
local function token(value) return type(value)=="string" and #value==32 and value:match("^%x+$") end
AddEventHandler("onAbilityPhase",function(player,encoded)
    local ok,event=pcall(json.decode,encoded)
    if stopped or not ok or type(event)~="table" or event.phase~="impact" or not token(event.activation)
        or not token(event.incarnation) or tonumber(player)~=event.player
        or type(event.config)~="table" or seen[event.activation] then return end
    local t=GetGameTimer()
    local count=0
    for id,expiry in pairs(seen) do if t>=expiry then seen[id]=nil else count=count+1 end end
    if count>=4096 then return end
    local life=Open77.players.getLifeState(tonumber(player))
    if not life or life.bucket~=event.bucket or life.phase~="alive" then return end
    seen[event.activation]=t+60000
    local sound=event.config.impactSound
    if type(sound)~="string" or sound=="" then return end
    local excluded={}
    if event.config.soundOnOwner~=true then excluded[1]=tostring(player) end
    local accepted,reason=Open77.effects.sound({kind="player",id=tostring(player)},sound,
        {duration=3,actionId="slam:"..event.activation,excludePlayers=excluded})
    if not accepted then Open77.log.warn("slam impact sound refused: "..tostring(reason)) end
end)

-- Sounds are bounded one-shots owned by the existing effects service. This Lua
-- API returns a dispatch boolean, not a stoppable sound handle.
AddEventHandler("onResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    stopped=true;seen={}
end)
