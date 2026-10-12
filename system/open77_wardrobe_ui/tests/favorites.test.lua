-- Run with Lua 5.4 or later, from the repository root.
dofile("resources/system/open77_wardrobe_ui/client/favorites.lua")
local F=WardrobeFavorites
local function info(record)
    if record=="Items.Unknown" then return nil end
    return {record=record,slot=record=="Items.Underwear" and "UnderwearBottom" or "Head",
        defaultSelectable=record~="Items.Restricted",nonvisual=record=="Items.EmptySlotsMask",supportsMale=true,supportsFemale=false}
end
assert(F.key({userId="12345678-1234-1234-1234-123456789ABC"})=="favorites.v1.12345678-1234-1234-1234-123456789abc")
assert(F.key({userId="------------------------------------"})==nil)
assert(F.key({userId="12345678-1234-1234-1234-123456789abc"})~=F.key({userId="87654321-1234-1234-1234-123456789abc"}))
local list=assert(F.decode("Items.Hat\nItems.Hat\nItems.Unknown\nItems.Restricted\nItems.Underwear\nItems.EmptySlotsMask\n../../file",info))
assert(F.encode(list)=="Items.Hat")
assert(F.record("Items.Hat\nItems.Other",info)==nil)
assert(F.record(string.rep("x",193),info)==nil)
assert(F.record("Items.Hat",info)=="Items.Hat") -- preserve across body-family switches
assert(F.decode(string.rep("x",256*193+1),info)==nil)
assert(F.decode(string.rep("Items.Hat\n",257),info)==nil)
local values={};for i=1,256 do values["Items.Hat_"..i]=true end
local encoded=assert(F.encode(values));local yields=0
local decoded=assert(F.decode(encoded,info,function() yields=yields+1 end))
assert(#F.list(decoded)==256 and yields==8)
values["Items.Excess"]=true;assert(F.encode(values)==nil)
-- Simulate durable KVP under its native endpoint/resource scopes and our
-- identity key, then construct a fresh client state (no CEF/localStorage).
local disk={};local a=assert(F.key({userId="12345678-1234-1234-1234-123456789abc"}))
local b=assert(F.key({userId="87654321-1234-1234-1234-123456789abc"}))
disk["serverA/resource/"..a]=F.encode({["Items.Hat"]=true})
assert(F.decode(disk["serverA/resource/"..a],info)["Items.Hat"])
assert(next(F.decode(disk["serverA/resource/"..b],info))==nil)
assert(next(F.decode(disk["serverB/resource/"..a],info))==nil)
print("Favorites Lua: identity scope, restart reconstruction, server separation, validation, deduplication, bounded records and yielding passed")

local shared="Items.First"
local attempts=0
local kvp={get=function()return shared end,compareAndSet=function(_,expected,replacement)
    attempts=attempts+1
    if attempts==1 then shared="Items.First\nItems.OtherProcess";return false end
    assert(shared==expected);shared=replacement;return true
end}
local merged=assert(F.update(kvp,a,"Items.OurProcess",true,info))
assert(attempts==2 and merged["Items.First"] and merged["Items.OtherProcess"] and merged["Items.OurProcess"])
kvp.compareAndSet=function()return false end
assert(select(2,F.update(kvp,a,"Items.Hat",true,info))=="storage_busy")
print("Favorites CAS: concurrent same-identity edit preserved, conflict retries bounded")
