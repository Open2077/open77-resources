-- Pure state machine: all time, player positions and elevator states are
-- supplied by the server adapter. No client controls state, bucket or revision.
DoorAuthority = {}

-- Keep the immediate threshold clear without rejecting a player standing
-- within ordinary interaction reach on either side of a manual door.
local manualCloseClearance = 0.6

-- Door actions (review F10). Force Open, Pay and the door hack exist only on a
-- door whose owning resource declared them; nothing is allowed by default.
-- The client's Body stat, wallet and RAM are not evidence: the policy (and,
-- for an owner-approved action, the owner's verdict) decides.
local ACTION_KINDS = {force=true, pay=true, hack=true}
local ACTION_RANGE = 6            -- metres, same as an ordinary manual request
local HACK_RANGE = 30             -- metres, default remote reach of a door hack
local TICKET_TTL = 5              -- seconds an owner has to approve an action
local MAX_TICKETS = 256
local PASS_SECONDS = 10           -- granted player holds the door like an authorized one

-- NPC passage (I7). A network NPC's native AI asks its door to open on the
-- client that simulates it; that client forwards the intent FOR the NPC. The
-- server admits the NPC, never the sender: the sender must be the NPC's
-- current authority (lease live, same epoch), the NPC alive, in the door's
-- bucket and within reach, and the door's `npcPassage` rule must let it in.
--   public   (default) unlocked, unsealed doors open to everyone
--   resource the owning resource's NPCs also pass locked or private doors
--   always   any network NPC passes locked or private doors
--   never    no NPC opens this door
-- A lock lifted for an NPC returns when the door shuts, like a granted action.
local NPC_PASSAGE = {public=true, resource=true, always=true, never=true}
local NPC_RANGE = 6               -- metres, NPC canonical position to the door
local NPC_PASS_SECONDS = 10       -- an admitted NPC holds the doorway at most this long
local NPC_RATE = 2                -- admitted-authority intents per NPC per second
local NPC_SENDER_RATE = 12        -- NPC intents per simulating client per second
local NPC_MAX_PASSERS = 8         -- NPCs holding one door at once

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) <= 1000000
end
local function integer(n, lo, hi)
    return finite(n) and n % 1 == 0 and n >= lo and n <= hi
end
-- An integral id beyond `finite`'s 1e6 magnitude (NPC ids, authority epochs).
local function wideInteger(n, lo, hi)
    return type(n) == "number" and n == n and n >= lo and n <= hi and n % 1 == 0
end
local function identity(id)
    if type(id) ~= "string" or not id:match("^0[xX]%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then return nil end
    id = "0x" .. id:sub(3):upper()
    return id ~= "0x0000000000000000" and id or nil
end
local function position(p)
    return type(p) == "table" and finite(p.x) and finite(p.y) and finite(p.z)
end
local function distance(a, b)
    return (a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2
end
local function copy(t)
    local result = {}
    for k, v in pairs(t) do result[k] = type(v) == "table" and copy(v) or v end
    return result
end
local function key(id, bucket) return tostring(bucket) .. ":" .. id end
local CELL_SIZE = 128 -- proximity scans reach 110 m; avoid 81 empty-cell probes per player
local function cell(bucket, x, y) return bucket .. ":" .. math.floor(x/CELL_SIZE) .. ":" .. math.floor(y/CELL_SIZE) end

-- Validate an owner's action declaration. nil/{} clears every action.
local function normalizeActions(spec)
    if spec == nil then return {} end
    if type(spec) ~= "table" then return nil, "invalid_actions" end
    local out = {}
    for kind, value in pairs(spec) do
        if not ACTION_KINDS[kind] then return nil, "unknown_action:" .. tostring(kind) end
        if value ~= false then
            local rule = {approval = kind == "pay" and "owner" or "auto", keepUnlocked = false}
            if kind == "hack" then rule.range = HACK_RANGE end
            if type(value) == "table" then
                for field, v in pairs(value) do
                    if field == "approval" then
                        if v ~= "auto" and v ~= "owner" then return nil, "invalid_approval" end
                        rule.approval = v
                    elseif field == "keepUnlocked" then
                        if type(v) ~= "boolean" then return nil, "invalid_boolean" end
                        rule.keepUnlocked = v
                    elseif field == "price" and kind == "pay" then
                        if not integer(v, 1, 1000000000) then return nil, "invalid_price" end
                        rule.price = v
                    elseif field == "range" and kind == "hack" then
                        if not finite(v) or v < 1 or v > 60 then return nil, "invalid_range" end
                        rule.range = v
                    else return nil, "unknown_field:" .. tostring(field) end
                end
            elseif value ~= true then return nil, "invalid_actions" end
            -- Only the owner holds the ledger: a payment is always its verdict.
            if kind == "pay" and not rule.price then return nil, "pay_requires_price" end
            if kind == "pay" and rule.approval ~= "owner" then return nil, "pay_requires_owner" end
            out[kind] = rule
        end
    end
    return out
end

function DoorAuthority.new(api)
    local S = { doors = {}, cells = {}, peers = {}, count = 0, revision = 0,
        discovery = true, sweepAt = 0, tickets = {}, ticketCount = 0, nextTicket = 0,
        playerTickets = {},
        -- NPC passage (I7): doors an admitted NPC is holding, per-NPC windows
        -- (touched only after the sender proved it is the NPC's authority) and
        -- bounded counters for the operator (`npcStats`).
        npcHeld = {}, npcWindows = {}, npcStats = {accepted=0, refused={}} }
    local function bump(d, reason)
        S.revision = S.revision + 1
        d.revision = S.revision
        api.event("changed", copy(d), reason)
    end
    local function opened(d, value, reason)
        value = value and not d.locked and not d.sealed
        if d.open ~= value then
            d.open = value
            -- A granted passage restores the owner's lock once the door shuts.
            if not value and d.relock then d.relock = false; d.locked = true end
            bump(d, reason)
        end
    end
    local function lookup(id, bucket)
        id = identity(id)
        if not id or not integer(bucket, 0, 1000000) then return nil end
        return S.doors[key(id, bucket)]
    end
    local function query(p, bucket, radius, yield)
        local values, distances = {}, {}
        if S.count == 0 then return values end
        for x = math.floor((p.x-radius)/CELL_SIZE), math.floor((p.x+radius)/CELL_SIZE) do
            for y = math.floor((p.y-radius)/CELL_SIZE), math.floor((p.y+radius)/CELL_SIZE) do
                local cell = S.cells[bucket .. ":" .. x .. ":" .. y]
                if cell then
                    for _, d in pairs(cell) do
                        local ds = distance(p, d.position)
                        if ds <= radius*radius then
                            values[#values+1] = d
                            distances[d] = ds
                        end
                    end
                end
            end
        end
        -- A registry-sized local query needs its own slice. Do not yield from
        -- the sort comparator (a C boundary); isolate the bounded sort instead.
        local large = #values > 256 and yield
        if large then yield() end
        table.sort(values, function(a,b)
            local da, db = distances[a], distances[b]
            return da == db and a.id < b.id or da < db
        end)
        if large then yield() end
        return values
    end
    local function peer(player, p)
        local v = S.peers[player]
        if not v or v.bucket ~= p.bucket then
            v = {bucket=p.bucket, seen={}, windows={}}
            S.peers[player] = v
            v.resetPending = api.send(player, "reset", p.bucket)==false
        end
        return v
    end
    local function playerPosition(player)
        local p = api.position(player)
        if not position(p) or not integer(p.bucket,0,1000000) then return nil end
        return p
    end
    local function rate(v, kind, limit)
        local now = api.now()
        local w = v.windows[kind]
        if not w or now-w.at >= 1 then w={at=now,count=0}; v.windows[kind]=w end
        w.count=w.count+1
        return w.count<=limit
    end
    local function linkValid(liftId, floor, bucket, p)
        if not integer(liftId,1,1000000) or not integer(floor,0,1024) then return false end
        local lift = api.elevator(liftId)
        -- Tall shafts can span hundreds of metres vertically. Bound horizontal
        -- distance, use the authoritative topology to validate the floor.
        return lift and lift.bucket == bucket and floor < lift.floorCount
            and (p.x-lift.x)^2+(p.y-lift.y)^2 <= 40^2
    end
    local function insert(desc, bucket, owner, generation)
        local id = identity(desc.id)
        if not id or not position(desc.position) or not integer(bucket,0,1000000) then return nil,"invalid_descriptor" end
        local k = key(id,bucket)
        if S.doors[k] then return nil,"already_registered" end
        if S.count >= 4096 then return nil,"registry_full" end
        local d = {id=id,bucket=bucket,position={x=desc.position.x,y=desc.position.y,z=desc.position.z},open=false,locked=false,sealed=false,
            automatic=desc.automatic==true,autoClose=desc.autoClose~=false,
            lift=desc.lift==true,elevatorId=0,elevatorFloor=-1,
            openRadius=3.5,closeRadius=5.0,closeDelay=1.2,
            defaultAccess=true,access={},owner=owner,generation=generation,
            lastSeen=api.now(),holdUntil=0,actions={},passes={},relock=false,
            npcPassage="public",npcPassers={}}
        if d.lift and linkValid(desc.elevatorId,desc.elevatorFloor,bucket,d.position) then
            d.elevatorId=desc.elevatorId;d.elevatorFloor=desc.elevatorFloor
        end
        S.doors[k]=d;S.count=S.count+1
        local c = cell(bucket,d.position.x,d.position.y)
        S.cells[c]=S.cells[c] or {};S.cells[c][k]=d
        bump(d,"registered")
        return d
    end
    local function remove(d, reason)
        local k = key(d.id,d.bucket)
        S.doors[k]=nil;S.count=S.count-1
        local c=cell(d.bucket,d.position.x,d.position.y)
        S.cells[c][k]=nil
        if next(S.cells[c])==nil then S.cells[c]=nil end
        api.event("removed", copy(d), reason)
    end
    local function owns(d, owner, generation)
        return d and owner and d.owner==owner and d.generation==generation
    end
    local function allowed(d,player)
        local decision=d.access[tostring(player)]
        if decision==nil then return d.defaultAccess end
        return decision
    end
    local function denied(d,player) return d.access[tostring(player)]==false end
    -- What this recipient may attempt. An explicit per-player denial is never
    -- bypassed by an action, so such a player is offered nothing.
    local function offered(d,player)
        if d.lift or d.sealed or denied(d,player) or next(d.actions)==nil then return nil end
        local out={}
        if d.actions.force then out.force=true end
        if d.actions.hack then out.hack=true end
        if d.actions.pay then out.pay=d.actions.pay.price end
        return out
    end
    local function public(d,player)
        -- Do not send resource-internal ACLs/ownership tokens to clients.
        return {id=d.id,bucket=d.bucket,position=copy(d.position),revision=d.revision,
            open=d.open,locked=d.locked,sealed=d.sealed,automatic=d.automatic,
            autoClose=d.autoClose,lift=d.lift,elevatorId=d.elevatorId,elevatorFloor=d.elevatorFloor,
            canOpen=allowed(d,player),actions=offered(d,player),
            -- The rule token, not who holds a key: its presence also tells a
            -- client that this server admits NPC intents at all (I7).
            npcPassage=d.npcPassage}
    end
    local function action(stage,d,player,info)
        info.stage=stage;info.player=player;info.id=d.id;info.bucket=d.bucket;info.owner=d.owner
        api.event("action",copy(d),player,info)
        if api.action then api.action(copy(info)) end
    end
    local function reply(player,id,ok,reason,requestId)
        if api.reply then api.reply(player,id,ok,reason,requestId) end
    end
    local function actionRange(kind,rule)
        return kind=="hack" and (rule and rule.range or HACK_RANGE) or ACTION_RANGE
    end
    -- Mirror vanilla (unlock, then open) without handing the lock away: unless
    -- the owner asked to keep it unlocked, the lock returns when the door shuts.
    local function grant(d,kind,rule,player)
        local now=api.now()
        if d.locked and not rule.keepUnlocked then d.relock=true end
        local wasLocked=d.locked
        d.locked=false
        d.holdUntil=now+d.closeDelay
        d.passes[tostring(player)]=now+PASS_SECONDS
        if not d.open then opened(d,true,"action_"..kind)
        elseif wasLocked then bump(d,"action_"..kind) end
    end
    local function dropTicket(t)
        if S.tickets[t.id]~=t then return end
        S.tickets[t.id]=nil;S.ticketCount=S.ticketCount-1
        if S.playerTickets[t.player]==t.id then S.playerTickets[t.player]=nil end
    end
    -- Re-validate what may have changed between the request and the verdict.
    local function actionState(d,player,kind,rule)
        local p=playerPosition(player)
        if not p or p.bucket~=d.bucket then return "no_position" end
        if distance(p,d.position)>actionRange(kind,rule)^2 then return "too_far" end
        if d.lift then return "elevator_controlled" end
        if d.sealed then return "sealed" end
        if denied(d,player) then return "access_denied" end
        return nil
    end
    -- The server's own reading of a network NPC: canonical position, bucket,
    -- life and lease. Anything malformed reads as unknown, never as a pass.
    local function npcPresence(npcId)
        local n=api.npc and api.npc(npcId)
        if type(n)~="table" or not position(n) or not integer(n.bucket,0,1000000) then return nil end
        return n
    end
    -- Is any admitted NPC standing within `radius` of this door right now?
    local function npcNear(d,radius)
        for npcId,untilAt in pairs(d.npcPassers) do
            if untilAt>api.now() then
                local n=npcPresence(npcId)
                if n and n.alive==true and n.bucket==d.bucket and distance(n,d.position)<=radius*radius then return true end
            end
        end
        return false
    end
    local function npcRefused(reason)
        local refused=S.npcStats.refused
        refused[reason]=(refused[reason] or 0)+1
        return false,reason
    end

    function S.discover(player, desc)
        local p=playerPosition(player)
        if not p or type(desc)~="table" then return false,"no_position" end
        local v=peer(player,p)
        if not rate(v,"discover",20) then return false,"rate_limited" end
        local id=identity(desc.id)
        if not id or not position(desc.position) or distance(p,desc.position)>80^2
            or type(desc.lift)~="boolean" or not integer(desc.doorType,-1,4)
            or not integer(desc.sideOne,-1,4) or not integer(desc.sideTwo,-1,4) then
            return false,"invalid_discovery"
        end
        local d=lookup(id,p.bucket)
        if not d then
            if not S.discovery then return false,"discovery_disabled" end
            d=insert({id=id,position=desc.position,lift=desc.lift,elevatorId=desc.elevatorId,
                elevatorFloor=desc.elevatorFloor,automatic=desc.doorType==2 or desc.sideOne==2 or desc.sideTwo==2,
                autoClose=desc.automaticClose~=false},p.bucket)
            if not d then return false,"registry_full" end
        elseif distance(d.position,desc.position)>4 then
            return false,"topology_conflict"
        end
        d.lastSeen=api.now()
        -- Link only once, after the independent elevator registry has adopted
        -- the lift. Clients cannot replace an existing link or a resource rule.
        if d.lift and d.elevatorId==0 and not d.owner
            and linkValid(desc.elevatorId,desc.elevatorFloor,p.bucket,d.position) then
            d.elevatorId=desc.elevatorId;d.elevatorFloor=desc.elevatorFloor;bump(d,"lift_linked")
        end
        return true
    end

    -- An action request (kind = force/pay/hack) opens a door the plain request
    -- cannot: locked, or closed to this player by defaultAccess. Returns
    -- true (applied), false+reason, or nil,"pending" while the owner decides.
    local function requestAction(player,p,d,kind,requestId)
        if d.lift then return false,"elevator_controlled" end
        if d.sealed then return false,"sealed" end
        if denied(d,player) then return false,"access_denied" end
        local rule=d.actions[kind]
        -- Nothing to bypass: an ordinary opening, never charged or approved.
        if not d.locked and allowed(d,player) then
            if distance(p,d.position)>ACTION_RANGE^2 then return false,"too_far" end
            if d.automatic then return false,"proximity_controlled" end
            d.holdUntil=api.now()+d.closeDelay
            opened(d,true,"player_request")
            api.event("request",copy(d),player,true)
            return true
        end
        if not rule then return false,"action_not_allowed" end
        if distance(p,d.position)>actionRange(kind,rule)^2 then return false,"too_far" end
        if rule.approval=="auto" then
            grant(d,kind,rule,player)
            action("accepted",d,player,{kind=kind,reason="auto"})
            return true
        end
        if not d.owner then return false,"action_not_allowed" end
        if S.playerTickets[player] then return false,"action_pending" end
        if S.ticketCount>=MAX_TICKETS then return false,"action_busy" end
        S.nextTicket=S.nextTicket+1
        local t={id=S.nextTicket,player=player,key=key(d.id,d.bucket),door=d,kind=kind,
            price=rule.price,requestId=requestId,expires=api.now()+TICKET_TTL}
        S.tickets[t.id]=t;S.ticketCount=S.ticketCount+1;S.playerTickets[player]=t.id
        action("requested",d,player,{kind=kind,price=rule.price,ticket=t.id})
        return nil,"pending"
    end

    function S.request(player,id,wantOpen,kind,requestId)
        local p=playerPosition(player)
        if not p then return false,"no_position" end
        local v=peer(player,p)
        if not rate(v,"request",6) then return false,"rate_limited" end
        local d=lookup(id,p.bucket)
        if not d or type(wantOpen)~="boolean" then return false,"unknown_door" end
        if kind~=nil then
            if not ACTION_KINDS[kind] or wantOpen~=true then return false,"invalid_action" end
            return requestAction(player,p,d,kind,requestId)
        end
        if distance(p,d.position)>6^2 then return false,"too_far" end
        if d.lift then return false,"elevator_controlled" end
        if d.automatic then return false,"proximity_controlled" end
        if d.locked or d.sealed or not allowed(d,player) then return false,"access_denied" end
        if not wantOpen then
            for _,other in ipairs(api.players()) do
                local q=playerPosition(other)
                if q and q.bucket==d.bucket and distance(q,d.position)<=manualCloseClearance^2 then return false,"doorway_occupied" end
            end
            -- An NPC this door admitted is still in the threshold (I7).
            if next(d.npcPassers)~=nil and npcNear(d,manualCloseClearance) then return false,"doorway_occupied" end
        end
        d.holdUntil=api.now()+d.closeDelay
        opened(d,wantOpen,"player_request")
        api.event("request",copy(d),player,wantOpen)
        return true
    end

    -- I7: `player` asks to open door `id` for network NPC `npcId`, whose
    -- authority epoch it believes is `epoch`. Only an opening exists: closing
    -- is the door's own timer once no admitted NPC stands in it. A refusal
    -- changes nothing (no reply, no revision), so the door stays shut without
    -- jitter; the reason is counted in `npcStats`.
    function S.npcRequest(player,id,wantOpen,npcId,epoch)
        local p=playerPosition(player)
        if not p then return npcRefused("no_position") end
        local v=peer(player,p)
        if not rate(v,"npc",NPC_SENDER_RATE) then return npcRefused("rate_limited") end
        if wantOpen~=true or not wideInteger(npcId,1,9007199254740991) or not wideInteger(epoch,1,4294967295) then
            return npcRefused("invalid_npc_request")
        end
        local n=npcPresence(npcId)
        if not n then return npcRefused("unknown_npc") end
        -- Authority first: nothing below, the per-NPC window included, may be
        -- touched by a client that does not simulate this NPC right now.
        if n.authorityPlayerId~=player or n.epoch~=epoch or not finite(n.leaseMs) or n.leaseMs<=0 then
            return npcRefused("not_npc_authority")
        end
        local now=api.now()
        local w=S.npcWindows[npcId]
        if not w or now-w.at>=1 then w={at=now,count=0};S.npcWindows[npcId]=w end
        w.count=w.count+1
        if w.count>NPC_RATE then return npcRefused("rate_limited") end
        if n.alive~=true then return npcRefused("npc_not_alive") end
        if n.bucket~=p.bucket then return npcRefused("wrong_bucket") end
        local d=lookup(id,n.bucket)
        if not d then return npcRefused("unknown_door") end
        if distance(n,d.position)>NPC_RANGE^2 then return npcRefused("too_far") end
        if d.lift then return npcRefused("elevator_controlled") end
        if d.sealed then return npcRefused("sealed") end
        local rule=d.npcPassage
        if rule=="never" then return npcRefused("npc_passage_denied") end
        -- A key: the rule lets this NPC through a lock or a private door.
        local holdsKey=rule=="always" or (rule=="resource" and d.owner~=nil and n.resource==d.owner)
        if d.locked and not holdsKey then return npcRefused("locked") end
        if not d.defaultAccess and not holdsKey then return npcRefused("access_denied") end
        local count=0
        for other,untilAt in pairs(d.npcPassers) do
            if untilAt<=now then d.npcPassers[other]=nil else count=count+1 end
        end
        -- Beyond the cap the door still opens; that NPC just does not hold it.
        if d.npcPassers[npcId] or count<NPC_MAX_PASSERS then
            d.npcPassers[npcId]=now+NPC_PASS_SECONDS
            S.npcHeld[key(d.id,d.bucket)]=d
        end
        d.holdUntil=math.max(d.holdUntil,now+d.closeDelay)
        local wasLocked=d.locked
        if wasLocked then d.relock=true;d.locked=false end
        if not d.open then opened(d,true,"npc_request")
        elseif wasLocked then bump(d,"npc_request") end
        api.event("npc_request",copy(d),npcId,player)
        S.npcStats.accepted=S.npcStats.accepted+1
        return true
    end

    function S.register(owner,generation,desc)
        if type(owner)~="string" or not generation or type(desc)~="table" then return nil,"invalid_owner" end
        local bucket=desc.bucket or 0
        local d=lookup(desc.id,bucket)
        if d then
            if d.owner and not owns(d,owner,generation) then return nil,"owned_by_other_resource" end
            d.owner=owner;d.generation=generation;bump(d,"claimed")
        else
            local reason;d,reason=insert(desc,bucket,owner,generation)
            if not d then return nil,reason end
        end
        return copy(d)
    end

    local function configure(d,patch)
        if type(patch)~="table" then return false,"invalid_patch" end
        local nextState=copy(d)
        for field,value in pairs(patch) do
            if field=="open" or field=="locked" or field=="sealed" or field=="automatic" or field=="autoClose" or field=="defaultAccess" then
                if type(value)~="boolean" then return false,"invalid_boolean" end
            elseif field=="openRadius" or field=="closeRadius" then
                if not finite(value) or value<1 or value>12 then return false,"invalid_radius" end
            elseif field=="closeDelay" then
                if not finite(value) or value<0.2 or value>60 then return false,"invalid_delay" end
            elseif field=="npcPassage" then
                if not NPC_PASSAGE[value] then return false,"invalid_npc_passage" end
            else return false,"unknown_field:"..tostring(field) end
            nextState[field]=value
        end
        if nextState.closeRadius < nextState.openRadius then return false,"invalid_hysteresis" end
        if d.lift and (patch.open~=nil or patch.automatic~=nil) then return false,"elevator_controlled" end
        if nextState.locked or nextState.sealed then nextState.open=false end
        local changed=false
        for field in pairs(patch) do if d[field]~=nextState[field] then changed=true end;d[field]=nextState[field] end
        if d.open~=nextState.open then d.open=nextState.open;changed=true end
        -- An explicit lock decision supersedes a pending relock; a door that
        -- this patch shut takes back the lock its granted passage lifted.
        if patch.locked~=nil then d.relock=false
        elseif d.relock and not d.open then d.relock=false;d.locked=true;changed=true end
        if changed then d.holdUntil=api.now()+d.closeDelay;bump(d,"configured") end
        return true
    end

    function S.configure(owner,generation,id,bucket,patch)
        local d=lookup(id,bucket)
        if not owns(d,owner,generation) then return false,"not_owner" end
        return configure(d,patch)
    end
    function S.npcCounters()
        return {accepted=S.npcStats.accepted,refused=copy(S.npcStats.refused)}
    end

    -- Called only by the trusted server adapter below its ACL check. Preserve
    -- the owning resource and all elevator constraints; never claim the door.
    function S.adminConfigure(player,id,patch)
        local p=api.position(player)
        if not position(p) then return false,"no_position" end
        local d=lookup(id,p.bucket or 0)
        if not d then return false,"door_not_discovered" end
        if distance(p,d.position)>12*12 then return false,"door_out_of_range" end
        return configure(d,patch)
    end

    function S.setActions(owner,generation,id,bucket,spec)
        local d=lookup(id,bucket)
        if not owns(d,owner,generation) then return false,"not_owner" end
        local actions,reason=normalizeActions(spec)
        if not actions then return false,reason end
        if d.lift and next(actions)~=nil then return false,"elevator_controlled" end
        d.actions=actions
        bump(d,"actions_changed")
        return true
    end

    -- The owner's verdict on a pending action. true means the action was
    -- applied (charge now); false means nothing happened (charge nothing).
    function S.resolve(owner,generation,ticket,accept,reason)
        if not integer(ticket,1,9007199254740991) or type(accept)~="boolean" then return false,"invalid_ticket" end
        local t=S.tickets[ticket]
        if not t then return false,"unknown_ticket" end
        local d=S.doors[t.key]
        if d~=t.door then
            dropTicket(t);reply(t.player,t.door.id,false,"unknown_door",t.requestId)
            return false,"unknown_door"
        end
        if not owns(d,owner,generation) then return false,"not_owner" end
        dropTicket(t)
        if not accept then
            if type(reason)~="string" or #reason>48 or not reason:match("^[%w_%.:%-]+$") then reason="action_refused" end
            reply(t.player,d.id,false,reason,t.requestId)
            action("refused",d,t.player,{kind=t.kind,price=t.price,ticket=t.id,reason=reason})
            -- true means only "the door opened": a refusal never answers true,
            -- so an owner that charges on true cannot charge a refused player.
            return false,"refused_by_owner"
        end
        local rule=d.actions[t.kind]
        local failure=actionState(d,t.player,t.kind,rule)
        if not failure and not rule then failure="action_not_allowed" end
        if not failure and t.kind=="pay" and rule.price~=t.price then failure="price_changed" end
        if failure then
            reply(t.player,d.id,false,failure,t.requestId)
            action("refused",d,t.player,{kind=t.kind,price=t.price,ticket=t.id,reason=failure})
            return false,failure
        end
        grant(d,t.kind,rule,t.player)
        reply(t.player,d.id,true,"accepted",t.requestId)
        action("accepted",d,t.player,{kind=t.kind,price=t.price,ticket=t.id,reason="owner"})
        return true
    end

    function S.access(owner,generation,id,bucket,player,decision)
        local d=lookup(id,bucket)
        if not owns(d,owner,generation) then return false,"not_owner" end
        if not integer(player,1,1000000) or (decision~=nil and type(decision)~="boolean") then return false,"invalid_access" end
        if decision~=nil then
            local connected=false
            for _,id in ipairs(api.players()) do if id==player then connected=true;break end end
            if not connected then return false,"player_not_connected" end
        end
        local k=tostring(player)
        if d.access[k]~=decision then d.access[k]=decision;bump(d,"access_changed") end
        return true
    end
    function S.link(owner,generation,id,bucket,liftId,floor)
        local d=lookup(id,bucket)
        if not owns(d,owner,generation) then return false,"not_owner" end
        if not d.lift or not linkValid(liftId,floor,bucket,d.position) then return false,"invalid_lift" end
        d.elevatorId=liftId;d.elevatorFloor=floor;d.open=false;bump(d,"lift_linked")
        return true
    end
    function S.remove(owner,generation,id,bucket)
        local d=lookup(id,bucket)
        if not owns(d,owner,generation) then return false,"not_owner" end
        remove(d,"resource_removed")
        return true
    end
    function S.get(id,bucket) local d=lookup(id,bucket);return d and copy(d) or nil end
    function S.all(bucket)
        local out={}
        for _,d in pairs(S.doors) do if bucket==nil or bucket==d.bucket then out[#out+1]=copy(d) end end
        table.sort(out,function(a,b) return key(a.id,a.bucket)<key(b.id,b.bucket) end)
        return out
    end
    function S.list(bucket,offset,limit)
        offset,limit=offset or 0,limit or 16
        if not integer(offset,0,4096) or not integer(limit,1,16)
            or (bucket~=nil and not integer(bucket,0,1000000)) then return nil,"invalid_page" end
        local values={}
        for _,d in pairs(S.doors) do if bucket==nil or bucket==d.bucket then values[#values+1]=d end end
        table.sort(values,function(a,b) return key(a.id,a.bucket)<key(b.id,b.bucket) end)
        local out={}
        for i=offset+1,math.min(#values,offset+limit) do out[#out+1]=copy(values[i]) end
        return {doors=out,total=#values,nextOffset=offset+#out<#values and offset+#out or nil}
    end
    function S.near(p,bucket,radius)
        if not position(p) or not integer(bucket,0,1000000) or not finite(radius) or radius<=0 or radius>120 then return {} end
        return copy(query(p,bucket,radius))
    end
    function S.hello(player)
        local p=playerPosition(player)
        if not p then return end
        local v=peer(player,p)
        if rate(v,"hello",1) then
            v.seen={};v.resetPending=api.send(player,"reset",p.bucket)==false
        end
    end
    function S.drop(player)
        if type(player)~="number" then return end
        S.peers[player]=nil
        local pending=S.playerTickets[player]
        if pending and S.tickets[pending] then dropTicket(S.tickets[pending]) end
        S.playerTickets[player]=nil
        for _,d in pairs(S.doors) do
            d.passes[tostring(player)]=nil
            if d.access[tostring(player)]~=nil then
                d.access[tostring(player)]=nil
                bump(d,"player_dropped")
            end
        end
    end

    function S.tick()
        local now=api.now()
        local present, observers, relevant={},{},{}
        for index,player in ipairs(api.players()) do
            -- Nearby observers can each select and serialize 256 doors. The
            -- old 128-player slice exhausted the VM quota in a dense crowd,
            -- permanently killing this coroutine while requests still worked.
            if api.yield and index % 8 == 0 then api.yield();now=api.now() end
            present[player]=true
            local p=playerPosition(player)
            if p then
                local v=peer(player,p)
                if v.resetPending then v.resetPending=api.send(player,"reset",p.bucket)==false end
                local near=query(p,p.bucket,110,api.yield)
                local selected={}
                for i,d in ipairs(near) do
                    if i>256 then break end
                    if S.doors[key(d.id,d.bucket)]==d then
                    selected[key(d.id,d.bucket)]=d
                    relevant[key(d.id,d.bucket)]=d
                    local ds=distance(p,d.position)
                    if (allowed(d,player) or (next(d.passes)~=nil and (d.passes[tostring(player)] or 0)>now))
                        and ds<=(d.open and d.closeRadius or d.openRadius)^2 then
                        d.holdUntil=now+d.closeDelay
                        if d.automatic and not d.lift then opened(d,true,"proximity") end
                    end
                    d.lastSeen=now
                    end
                end
                if not v.resetPending then observers[#observers+1]={player=player,peer=v,selected=selected} end
            else
                -- A stale/dead player snapshot must not keep doors open.
                local v=S.peers[player]
                if v and next(v.seen) then
                    v.resetPending=api.send(player,"reset",v.bucket)==false;v.seen={}
                end
            end
        end
        for player in pairs(S.peers) do if not present[player] then S.drop(player) end end
        for k,d in pairs(S.doors) do
            if d.open then relevant[k]=d end
            if d.owner and api.generation(d.owner)~=d.generation then
                remove(d,"owner_stopped");relevant[k]=nil
            end
        end
        -- An owner that never answers (stopped, busy, absent) refuses by timeout.
        for _,t in pairs(S.tickets) do
            local d=S.doors[t.key]
            if d~=t.door or now>=t.expires then
                local reason=d~=t.door and "unknown_door" or "action_timeout"
                dropTicket(t);reply(t.player,t.door.id,false,reason,t.requestId)
                if d==t.door then action("refused",d,t.player,{kind=t.kind,price=t.price,ticket=t.id,reason=reason}) end
            end
        end
        -- An admitted NPC holds its doorway like a nearby player, from its
        -- canonical position, until it leaves or its pass runs out (I7). Only
        -- doors an NPC was admitted to are visited, at most 8 NPCs each. The
        -- keys are taken first: a request may admit a new door while this
        -- slice is yielded, and `next` must never see a key added mid-walk.
        local held={}
        for k,d in pairs(S.npcHeld) do held[#held+1]={k,d} end
        for index,entry in ipairs(held) do
            if api.yield and index % 64 == 0 then api.yield();now=api.now() end
            local k,d=entry[1],entry[2]
            if S.doors[k]~=d then
                if S.npcHeld[k]==d then S.npcHeld[k]=nil end
            else
                local any=false
                for npcId,untilAt in pairs(d.npcPassers) do
                    if untilAt<=now then d.npcPassers[npcId]=nil
                    else
                        any=true
                        local n=npcPresence(npcId)
                        if n and n.alive==true and n.bucket==d.bucket
                            and distance(n,d.position)<=d.closeRadius*d.closeRadius then
                            d.holdUntil=math.max(d.holdUntil,now+d.closeDelay)
                        end
                    end
                end
                if not any then S.npcHeld[k]=nil end
            end
        end
        for _,d in pairs(relevant) do
            if d.lift then
                local lift=d.elevatorId>0 and api.elevator(d.elevatorId) or nil
                local safe=lift and lift.bucket==d.bucket and lift.phase=="idle"
                    and lift.activeFloor==d.elevatorFloor and (lift.flags & 1)~=0 and (lift.flags & 8)==0
                opened(d,safe==true,"elevator")
            elseif d.open and d.autoClose and now>=d.holdUntil then
                opened(d,false,"clear")
            end
        end
        for index,o in ipairs(observers) do
            if api.yield and index % 8 == 0 then api.yield() end
            if S.peers[o.player] == o.peer then
            for k in pairs(o.peer.seen) do
                if not o.selected[k] or not S.doors[k] then
                    if api.send(o.player,"remove",k:sub(k:find(":")+1))~=false then o.peer.seen[k]=nil end
                end
            end
            for k,d in pairs(o.selected) do
                if S.doors[k]==d and o.peer.seen[k]~=d.revision then
                    -- Mark delivered only if the reliable event queue accepted it.
                    if api.send(o.player,"state",public(d,o.player))~=false then o.peer.seen[k]=d.revision end
                end
            end
            end
        end
        if now>=S.sweepAt then
            S.sweepAt=now+30
            for npcId,w in pairs(S.npcWindows) do if now-w.at>=1 then S.npcWindows[npcId]=nil end end
            for _,d in pairs(S.doors) do
                if not d.owner and not d.open and now-d.lastSeen>600 then remove(d,"expired")
                elseif next(d.passes)~=nil then
                    for player,untilAt in pairs(d.passes) do if untilAt<=now then d.passes[player]=nil end end
                end
            end
        end
    end
    return S
end
