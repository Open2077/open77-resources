-- Optional ACL-controlled laboratory. All installation uses the public CAS service.
local ready=false
local profiles={attacker={"hack","operating_system","cyberdeck"},
    protected={"ice","self_ice","self_ice"},ally={"purge","purge","active_purge"}}
local function reply(player,raw,ok,reason)
    local message=type(reason)=="table" and json.encode(reason) or tostring(reason or "applied")
    if tonumber(player) and tonumber(player)>0 then
        TriggerClientEvent("open77:command:result",player,raw,ok==true,message)
    end
    print("[hacking lab] "..raw.." accepted="..tostring(ok==true).." reason="..message)
end
CreateThread(function()
    for _, entry in ipairs({{"hack","define"},{"ice","defineIce"},{"purge","definePurge"}}) do
        local ok,why=Open77.hacking[entry[2]](HackingLab[entry[1]])
        if not ok then print("[hacking lab] definition failed "..tostring(why)); return end
    end
    for _, profile in pairs(profiles) do
        local source=HackingLab[profile[1]]
        local grades={}
        for _, grade in ipairs(source.grades) do
            grades[#grades+1]={id=grade.id,normalDamage=0,chargedDamage=0,knockbackMeters=0,cooldownMs=100,chargeMs=100}
        end
        local ok,why=Open77.cyberware.define({id=source.id,version=1,slot=profile[2],profile=profile[3],grades=grades})
        if not ok then print("[hacking lab] implant definition failed "..tostring(why)); return end
    end
    ready=true
end)
RegisterCommand("hacklab",function(player,args,raw)
    local action,target=args[1],tonumber(args[2])
    if not ready then reply(player,raw,false,"definitions_unavailable"); return end
    if action=="scope" then
        local bucket=target
        if not bucket or bucket<0 or bucket>4294967295 or bucket%1~=0 or #args<4 or #args>34 then
            reply(player,raw,false,"scope BUCKET PLAYER PLAYER [up to 32 players]"); return
        end
        local players,seen={},{}
        for index=3,#args do
            local id=tonumber(args[index])
            if not id or id<1 or id>9007199254740991 or id%1~=0 or seen[id] then
                reply(player,raw,false,"distinct positive player IDs required"); return
            end
            seen[id]=true; players[#players+1]=id
        end
        local id,why=Open77.combat.createScope({bucket=bucket,players=players})
        reply(player,raw,id~=nil,id or why); return
    elseif action=="unscope" then
        local ok,why=Open77.combat.removeScope(args[2])
        reply(player,raw,ok==true,why); return
    end
    if not target or target<1 or target%1~=0 then reply(player,raw,false,"positive player ID required"); return end
    if action=="allyfixture" then
        local recipient=tonumber(args[3])
        if #args~=3 or target>9007199254740991 or not recipient or recipient<1
            or recipient>9007199254740991 or recipient%1~=0 or recipient==target then
            reply(player,raw,false,"allyfixture ACTOR TARGET; distinct positive player IDs required"); return
        end
        if not Open77.ready.isReady(target) or not Open77.ready.isReady(recipient) then
            reply(player,raw,false,"players_not_ready"); return
        end
        local neutralA=Open77.combat.setTeam(target,0)
        local neutralB=Open77.combat.setTeam(recipient,0)
        print("[hacking lab] allyfixture neutral actor="..target.." target="..recipient..
            " actorOk="..tostring(neutralA).." targetOk="..tostring(neutralB))
        if not neutralA or not neutralB then reply(player,raw,false,"neutral_team_setup_failed"); return end
        local result,why=Open77.statuses.apply(target,recipient,HackingLab.hack.id,"ally_status")
        if not (type(result)=="table" and result.ok==true or result==true) then
            reply(player,raw,false,why or result); return
        end
        local allyA=Open77.combat.setTeam(target,7)
        local allyB=Open77.combat.setTeam(recipient,7)
        print("[hacking lab] allyfixture allied actor="..target.." target="..recipient..
            " actorOk="..tostring(allyA).." targetOk="..tostring(allyB).." status="..json.encode(result))
        reply(player,raw,allyA==true and allyB==true,allyA and allyB and result or "ally_team_setup_failed"); return
    elseif action=="status" then
        local recipient=tonumber(args[3])
        if #args~=4 or target>9007199254740991 or not recipient or recipient<1
            or recipient>9007199254740991 or recipient%1~=0 then
            reply(player,raw,false,"status ACTOR TARGET GRADE; positive player IDs required"); return
        end
        local configured=false
        for _,grade in ipairs(HackingLab.hack.grades) do
            -- Overheat/Malfunction carry their own status (the burn / the suppression).
            if grade.id==args[4] and ((grade.statusMs and grade.statusMs>0) or (grade.kind and grade.kind~="short_circuit")) then configured=true; break end
        end
        if not configured then reply(player,raw,false,"configured status grade required"); return end
        local result,why=Open77.statuses.apply(target,recipient,HackingLab.hack.id,args[4])
        reply(player,raw,type(result)=="table" and result.ok==true or result==true,result or why); return
    elseif action=="purge" then
        -- Server-side purge through the public API: the same authority path as the
        -- INSERT/DELETE keys (entitlement, cooldown, stamina, team/range policy), for
        -- rigs where the defender's key steals window focus from the attacker's held
        -- F8 (measured 2026-09-14: the upload cancels 340 ms after upload_started,
        -- before the purge key lands). `purge ACTOR` purges the actor itself,
        -- `purge ACTOR ALLY` purges the aimed ally instead. Also an RP hook.
        local recipient=tonumber(args[3])
        if #args<2 or #args>3 or target>9007199254740991 or (args[3] and (not recipient or recipient<1
            or recipient>9007199254740991 or recipient%1~=0)) then
            reply(player,raw,false,"purge ACTOR [ALLY]; positive player IDs required"); return
        end
        local operation="hacklab-purge-"..tostring(target).."-"..tostring(GetGameTimer())
        local result,why=Open77.hacking.purge(target,recipient or target,HackingLab.purge.id,HackingLab.purge.grades[1].id,
            {operationId=operation})
        reply(player,raw,type(result)=="table" and result.ok==true,result or why); return
    elseif action=="place" then
        local x,y,z,heading=tonumber(args[3]),tonumber(args[4]),tonumber(args[5]),tonumber(args[6])
        local function finite(v,limit) return v and v==v and math.abs(v)<=limit end
        if #args~=6 or not finite(x,1000000) or not finite(y,1000000) or not finite(z,1000000)
            or not finite(heading,360000) then
            reply(player,raw,false,"place PLAYER X Y Z HEADING_DEGREES; finite bounded coordinates required"); return
        end
        if not Open77.ready.isReady(target) then reply(player,raw,false,"player_not_ready"); return end
        local life=Open77.players.getLifeState(target)
        local health=Open77.stats.getHealth(target)
        if not life or not health then reply(player,raw,false,"player_unavailable"); return end
        if life.phase~="alive" then reply(player,raw,false,"alive_player_required"); return end
        local fraction=health.fraction
        if not finite(fraction,1) or fraction<=0 then reply(player,raw,false,"positive_health_required"); return end
        -- Setup only: use the existing canonical kill/respawn transaction, preserving health.
        -- This cancels transient actions and waits for the normal native recovery acknowledgement.
        local ok,why=Open77.players.kill(target,{cause="script",weapon="hacklab:place"})
        if not ok then reply(player,raw,false,why); return end
        ok,why=Open77.players.respawn(target,{position={x=x,y=y,z=z},heading=heading%360,
            bucket=life.bucket or 0,health=fraction,graceMs=0})
        reply(player,raw,ok==true,why or "placement requested; await alive recovery acknowledgement"); return
    elseif action=="protection" then
        local resistance=tonumber(args[4])
        if (args[3]~="on" and args[3]~="off") or not resistance or resistance<0 or resistance>1 then
            reply(player,raw,false,"protection PLAYER on|off RESISTANCE_0_TO_1"); return
        end
        local ok,why=Open77.hacking.configureProtection(target,{safeArea=args[3]=="on",resistance=resistance})
        reply(player,raw,ok~=nil,ok or why); return
    elseif action=="clearprotection" then
        local ok,why=Open77.hacking.clearProtection(target)
        reply(player,raw,ok~=nil,ok or why); return
    end
    if action=="state" then
        local value,why=Open77.hacking.state(target)
        reply(player,raw,value~=nil,value or why); return
    end
    if action=="team" then
        local team=tonumber(args[3])
        if not team or team<0 or team%1~=0 then reply(player,raw,false,"nonnegative team required"); return end
        reply(player,raw,Open77.combat.setTeam(target,team)); return
    end
    local profile=profiles[action]
    local removing=action=="remove" or action=="unprotected"
    if not profile and not removing then
        reply(player,raw,false,"attacker|protected|ally PLAYER GRADE OPERATION; unprotected PLAYER OPERATION; remove PLAYER SLOT OPERATION; state PLAYER; team PLAYER TEAM; purge ACTOR [ALLY]"); return
    end
    local record,why=Open77.cyberware.current(target)
    if not record then reply(player,raw,false,why); return end
    local operation=action=="unprotected" and args[3] or args[4]
    if type(operation)~="string" or operation=="" then reply(player,raw,false,"explicit operation ID required"); return end
    local expected=record.operationId==operation and record.revision-1 or record.revision
    local result
    if removing then
        local slot=action=="unprotected" and "self_ice" or args[3]
        if slot~="operating_system" and slot~="self_ice" and slot~="purge" then reply(player,raw,false,"invalid hacking slot"); return end
        result,why=Open77.cyberware.remove(target,{expectedRevision=expected,operationId=operation,slot=slot})
    else
        result,why=Open77.cyberware.install(target,HackingLab[profile[1]].id,args[3],{expectedRevision=expected,operationId=operation})
    end
    reply(player,raw,type(result)=="table" and result.ok==true or result==true,result or why)
end,true)
AddEventHandler("onHackingTransition",function(encoded)
    print("[hacking lab] transition="..tostring(encoded))
end)
