local offerId, handle
local function remove(value)
    if not value then return end
    CreateThread(function()
        local promise = Open77.exports.call("open77_interactions", "remove", value)
        if promise then promise:await() end
    end)
end
RegisterNetEvent("open77:ripperdoc:offer", function(offer)
    if type(offer) ~= "table" or type(offer.id) ~= "string" then return end
    remove(handle); handle = nil; offerId = offer.id
    CreateThread(function()
        local promise = Open77.exports.call("open77_interactions", "create", {
            id="ripperdoc-consent",position={x=offer.position.x,y=offer.position.y,z=offer.position.z+1.3},
            distance=3.5,markerDistance=10,marker="person",priority=30,
            label=offer.label,description=tostring(offer.cost) .. " clinic credits",
            choices={
                {id="accept",label="Accept procedure",key="E",event="open77:ripperdoc:accept",holdSeconds=0.5},
                {id="decline",label="Decline",key="F",event="open77:ripperdoc:decline"},
            },
        })
        local result = promise and promise:await()
        if result and result.ok then
            if offerId == offer.id then handle = result.handle else remove(result.handle) end
        end
    end)
end)
RegisterNetEvent("open77:ripperdoc:close", function(id)
    if id ~= offerId then return end
    offerId = nil; remove(handle); handle = nil
end)
AddEventHandler("open77:ripperdoc:accept", function()
    if offerId then TriggerServerEvent("open77:ripperdoc:answer", offerId, true) end
end)
AddEventHandler("open77:ripperdoc:decline", function()
    if offerId then TriggerServerEvent("open77:ripperdoc:answer", offerId, false) end
end)
AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then offerId = nil end
end)
