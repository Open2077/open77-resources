-- Run from the open77_admin directory with Lua 5.4. No live server/DB touched.
dofile("shared/config.lua")
local handlers, commands, threads = {}, {}, {}
local players, vehicles, moves, removed, exits, messages, audits = {}, {}, {}, {}, {}, {}, {}
local now, allowed, ejectWorks = 0, true, true
function AddEventHandler(name, fn) handlers[name] = fn end
function CreateThread(fn) threads[#threads + 1] = { co = coroutine.create(fn), at = now } end
function Wait(ms) coroutine.yield(ms) end
local function tick(ms)
    now = now + (ms or 0)
    for _, thread in ipairs(threads) do
        if thread.at <= now and coroutine.status(thread.co) ~= "dead" then
            local ok, delay = coroutine.resume(thread.co); assert(ok, delay)
            thread.at = now + (delay or 0)
        end
    end
end
local function drain() for _ = 1, 400 do tick(100) end end
local function reset()
    now = now + 20000; allowed = true; ejectWorks = true
    for id in pairs(players) do handlers.onPlayerDisconnected(tostring(id)) end
    players, vehicles, moves, removed, exits, messages = {}, {}, {}, {}, {}, {}
    for id = 1, 32 do players[id] = { ready = true, phase = "alive", x = id*100, y = 20, z = 30, bucket = id } end
end
Admin = {
    Config = Open77AdminConfig,
    nowMs = function() return now end,
    register = function(name, spec) commands[name] = spec end,
    allowed = function() return allowed end,
    finiteNumber = tonumber,
    placeable = function(id) return players[id] ~= nil, players[id] end,
    placeAt = function(id, position, _, bucket)
        moves[#moves+1] = { id = id, position = position, bucket = bucket, at = now }; return true
    end,
    output = function(_, _, ok, message) messages[#messages+1] = message; return ok end,
    log = function(message) error(message) end,
    record = function(...) audits[#audits+1] = {...} end,
    announce = function() end,
    vehicles = { ledgerDrop = function() end, governor = { instance = {} } },
}
Open77 = {
    ready = { isReady = function(id) return players[id] and players[id].ready end },
    players = {
        name = function(id) return players[id] and ("Player " .. id) end,
        position = function(id) return players[id] end,
        all = function() local ids = {}; for id in pairs(players) do ids[#ids+1] = id end; return ids end,
    },
    vehicles = {
        all = function() local list = {}; for _, v in pairs(vehicles) do list[#list+1] = v end; return list end,
        get = function(id) return vehicles[id] end,
        getPlayerSeat = function(id) return players[id] and players[id].seat end,
        forcePlayerOutOfVehicle = function(id, vehicle)
            exits[#exits+1] = { id, vehicle }
            if ejectWorks then vehicles[vehicle].occupants = {} end
            return true
        end,
        remove = function(id)
            assert(#(vehicles[id].occupants or {}) == 0, "never delete occupied")
            removed[#removed+1] = id; vehicles[id] = nil; return true
        end,
    },
}
dofile("server/bulk.lua")
local function command(name, confirm, alias)
    local args = confirm and { n = 1, "confirm" } or { n = 0 }
    return commands["admin.bulk." .. name].handler(1, args, name, nil, alias or ("admin.bulk." .. name))
end
reset()
assert(not command("tpall", false)); assert(#moves == 0)
players[2].ready = false; players[3].phase = "dead"; players[4].phase = "respawnpending"
assert(command("tpall", true)); assert(not command("tpall", true), "single batch")
tick(); assert(#moves == 1 and moves[1].id == 5)
players[1].x = 900 -- frozen rendezvous
tick(749); assert(#moves == 1); tick(1); assert(#moves == 2)
players[7].ready = false
handlers.onPlayerDisconnected('8'); players[8] = nil
handlers.onPlayerDisconnected('9'); players[9] = { ready=true, phase='alive', x=0,y=0,z=0 }
drain(); assert(#moves == 25)
for i, a in ipairs(moves) do
    assert(a.id ~= 1 and a.id ~= 7 and a.id ~= 8 and a.id ~= 9)
    assert(a.position.z == 30 and a.bucket == 1 and math.abs(a.position.x-100)<25)
    if i>1 then assert(a.at-moves[i-1].at >= 750) end
    for j=1,i-1 do local b=moves[j]; assert((a.position.x-b.position.x)^2+(a.position.y-b.position.y)^2 >= 8.999) end
end
assert(messages[#messages]:find("25/28 completed, 3 skipped"))
reset(); command("tpall", true, "tpall"); tick(); allowed=false; drain(); assert(#moves==1)
assert(messages[#messages]:find("permission revoked"))
reset(); command("tpall", true); tick(); handlers.onPlayerDisconnected('1'); drain(); assert(#moves==1)
reset(); command("tpall", true); tick(); command("cancel"); drain(); assert(#moves==1)
reset(); players[1].ready=false; assert(not command("tpall",true))
players[1].ready=true; players[1].seat={}; assert(not command("tpall",true)); players[1].seat=nil
local readyApi=Open77.ready; Open77.ready=nil; assert(not command("tpall",true)); Open77.ready=readyApi
reset()
vehicles={ [100]={id=100,resource="freeroam",bucket=0}, [101]={id=101,resource="other",bucket=99,occupants={{playerId=2}}},
    [102]={id=102,resource="open77_admin",occupants={}} }
assert(not command("dvall",false)); assert(command("dvall",true)); tick(); assert(#removed==1)
vehicles[103]={id=103,resource="new"} -- spawns after snapshot are not swept
drain(); assert(#removed==3 and #exits==1 and vehicles[103])
assert(messages[#messages]:find("3/3 completed"))
reset(); ejectWorks=false; vehicles={[1]={id=1,occupants={2}},[2]={id=2,occupants={}}}
command("dvall",true); drain(); assert(#removed==1 and removed[1]==2 and vehicles[1])
assert(messages[#messages]:find("still occupied; left intact"))
reset(); ejectWorks=false; vehicles={[1]={id=1,occupants={2}},[2]={id=2}}
command("dvall",true); tick(); allowed=false; drain(); assert(#removed==0)
reset(); vehicles={[1]={id=1},[2]={id=2},[3]={id=3}}
command("dvall",true); tick(); vehicles[2]=nil; drain(); assert(#removed==2)
assert(messages[#messages]:find("2/3 completed, 1 skipped"))
assert(#audits>0)
print("PASS: 32-player snapshot, readiness, stagger, offsets, frozen origin, disconnect/rejoin, ACL revoke, cancel, all-resource/all-bucket cleanup, occupied wait/timeout, no chase of new vehicles")
