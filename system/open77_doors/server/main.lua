local epoch = GetCurrentResourceGeneration()
local sequence, journalSequence, journal = 0, 0, {}
local function sendResult(player, id, ok, reason, requestId)
    if requestId then
        TriggerClientEvent("open77:doors:requestResult",player,id,ok,reason or "accepted",requestId)
    else
        TriggerClientEvent("open77:doors:requestResult",player,id,ok,reason or "accepted")
    end
end
local authority = DoorAuthority.new({
    now = Open77.time.monotonic,
    position = Open77.players.position,
    players = GetPlayers,
    elevator = Open77.elevators.get,
    -- I7: one O(1) read of where a network NPC is and who simulates it. An
    -- older host without it (or without the NPC service) admits no NPC.
    npc = function(npcId)
        local presence = Open77.npcs and Open77.npcs.presence
        if type(presence) ~= "function" then return nil end
        local value = presence(npcId)
        return type(value) == "table" and value or nil
    end,
    generation = Open77.resource.generation,
    yield = function() Wait(0) end,
    send = function(player, kind, payload)
        sequence = sequence + 1
        return TriggerClientEvent("open77:doors:sync", player, epoch, sequence, kind, payload)
    end,
    event = function(kind, door, reason, value)
        journalSequence = journalSequence + 1
        journal[#journal+1] = {cursor=journalSequence,kind=kind,door=door,reason=reason,value=value}
        if #journal>512 then table.remove(journal,1) end
    end,
    -- Door actions (force/pay/hack) are also published host-wide so the owning
    -- resource can approve a pending one at once instead of polling `changes`.
    -- A forged copy of this event is harmless: resolveAction checks the ticket.
    action = function(info)
        if TriggerEvent then TriggerEvent("open77:doors:action", info) end
    end,
    -- Deferred verdicts (owner approval, timeout) reuse the ordinary reply.
    reply = sendResult,
})

RegisterNetEvent("open77:doors:hello",function() authority.hello(tonumber(source)) end)
RegisterNetEvent("open77:doors:discover",function(desc) authority.discover(tonumber(source),desc) end)
RegisterNetEvent("open77:doors:request",function(id,open,requestId,action,npcId,npcEpoch)
    -- Optional correlation for reversible client presentation. A delayed refusal
    -- must not cancel a later opening of the same door. Legacy requests omit it.
    -- This is an echo on the existing reply, never an authority input or ledger.
    if requestId~=nil and (type(requestId)~="number" or requestId~=requestId
        or requestId<1 or requestId>9007199254740991 or requestId%1~=0) then return end
    -- Optional action kind (force/pay/hack); older clients never send one.
    if action~=nil and (type(action)~="string" or #action>8) then return end
    local player=tonumber(source)
    -- I7: an intent FOR a network NPC, sent by the client simulating it. It
    -- rides this event as the kind "npc" (an older server refuses that kind as
    -- invalid_action instead of crediting the sender) and is never answered:
    -- nothing on the client waits for it, and a refusal must not move the door.
    if action=="npc" then
        if type(id)=="string" and #id<=18 then
            authority.npcRequest(player,id,open,math.tointeger(npcId),math.tointeger(npcEpoch))
        end
        return
    end
    local ok,reason=authority.request(player,id,open,action,requestId)
    -- The owner answers later through resolveAction, or the ticket times out.
    if reason=="pending" then return end
    -- Do not amplify malformed/spam traffic with an unbounded error stream.
    if reason~="rate_limited" and reason~="no_position" and type(id)=="string" and #id<=18 then
        sendResult(player,id,ok,reason,requestId)
    end
end)
AddEventHandler("playerDropped",function() authority.drop(tonumber(source)) end)

exports("get",function(id,bucket) return authority.get(id,bucket or 0) end)
-- Narrow cooperative admin endpoint, NOT a client event or a general ownership
-- bypass. Every call verifies the invoking resource and the operator's ACL.
exports("adminControl",function(player,id,action)
    if GetInvokingResource()~="open77_admin" then return false,"forbidden_resource" end
    if type(player)~="number" or player<1 or player%1~=0
        or not Open77.acl.isAllowed(player,"command.admin.dev.doors.control") then
        return false,"permission_denied"
    end
    local patches={open={open=true,automatic=false},close={open=false,automatic=false},
        lock={locked=true},unlock={locked=false},seal={sealed=true},unseal={sealed=false},
        automatic={automatic=true}}
    local patch=patches[action]
    if not patch then return false,"invalid_action" end
    return authority.adminConfigure(player,id,patch)
end)
exports("list",authority.list)
exports("near",function(p,bucket,radius)
    local values=authority.near(p,bucket,radius)
    local out={};for i=1,math.min(#values,16) do out[i]=values[i] end
    return {doors=out,total=#values,truncated=#values>16}
end)
exports("register",function(desc)
    return authority.register(GetInvokingResource(),GetInvokingResourceGeneration(),desc)
end)
exports("configure",function(id,bucket,patch)
    return authority.configure(GetInvokingResource(),GetInvokingResourceGeneration(),id,bucket or 0,patch)
end)
for _,field in ipairs({"open","locked","sealed","automatic"}) do
    local name="set" .. field:sub(1,1):upper() .. field:sub(2)
    exports(name,function(id,bucket,value)
        if type(value)~="boolean" then return false,"invalid_boolean" end
        return authority.configure(GetInvokingResource(),GetInvokingResourceGeneration(),id,bucket or 0,{[field]=value})
    end)
end
exports("setAccess",function(id,bucket,player,allow)
    return authority.access(GetInvokingResource(),GetInvokingResourceGeneration(),id,bucket or 0,player,allow)
end)
-- Declare which door actions (force, pay, hack) this owned door accepts.
-- nil or {} withdraws them all, the default for every door.
exports("setActions",function(id,bucket,actions)
    return authority.setActions(GetInvokingResource(),GetInvokingResourceGeneration(),id,bucket or 0,actions)
end)
-- Owner verdict on a pending action ticket. true = the door opened, charge the
-- player; false = nothing opened (including the owner's own refusal, answered
-- as false,"refused_by_owner"): charge nothing, refund if already debited.
exports("resolveAction",function(ticket,accept,reason)
    return authority.resolve(GetInvokingResource(),GetInvokingResourceGeneration(),ticket,accept,reason)
end)
-- Which network NPCs may open this owned door (I7): "public" (the default:
-- unlocked doors open to everyone), "resource" (this resource's own NPCs also
-- pass its locked or private doors), "always", or "never". nil restores
-- "public". The same field is accepted by configure as `npcPassage`.
exports("setNpcPassage",function(id,bucket,mode)
    if mode==nil then mode="public" end
    return authority.configure(GetInvokingResource(),GetInvokingResourceGeneration(),id,bucket or 0,{npcPassage=mode})
end)
-- Operator diagnostics: NPC intents admitted, and refusals by reason.
exports("npcStats",function() return authority.npcCounters() end)
exports("linkElevator",function(id,bucket,liftId,floor)
    return authority.link(GetInvokingResource(),GetInvokingResourceGeneration(),id,bucket or 0,liftId,floor)
end)
exports("remove",function(id,bucket)
    return authority.remove(GetInvokingResource(),GetInvokingResourceGeneration(),id,bucket or 0)
end)
exports("setDiscoveryEnabled",function(enabled)
    if type(enabled)~="boolean" then return false,"invalid_boolean" end
    authority.discovery=enabled
    return true
end)
-- Server exports are asynchronous and data-only. A bounded change cursor is
-- usable by every resource without inventing a cross-resource callback bus.
exports("changes",function(since)
    if type(since)~="number" or since~=since or since<0 or since%1~=0 then return nil,"invalid_cursor" end
    local out={}
    for _,entry in ipairs(journal) do
        if entry.cursor>since then out[#out+1]=entry;if #out==8 then break end end
    end
    return {cursor=#out>0 and out[#out].cursor or journalSequence,
        reset=since>journalSequence or since<journalSequence-#journal,events=out}
end)

CreateThread(function()
    while true do authority.tick();Wait(200) end
end)
print("[open77_doors] server-authoritative discovery, proximity and lift-door projection ready")
