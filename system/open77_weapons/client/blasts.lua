-- Server-relayed physical blasts (server/blasts.lua). Another client's
-- explosion reached cars this client simulates, or NPC copies it presents.
-- The server found the cars and their owner and supplies the magnitudes; the
-- native moves only cars this client still owns, from its own poses, and
-- knocks down only living NPC copies inside the radius. A client whose DLL
-- predates Open77.weapons.applyBlast ignores the relay.

local refusals, refusalWindow = 0, 0

RegisterNetEvent("open77_weapons:blast", function(value)
    if type(value) ~= "table" or type(Open77) ~= "table" or type(Open77.weapons) ~= "table"
        or type(Open77.weapons.applyBlast) ~= "function" then return end
    local ok, reason = Open77.weapons.applyBlast({
        x = value.x, y = value.y, z = value.z,
        radius = value.radius, push = value.push, lift = value.lift, falloff = value.falloff,
        vehicles = type(value.vehicles) == "table" and value.vehicles or {},
        characters = value.characters == true,
    })
    if ok then return end
    -- A full native queue refuses in bursts: say so once per ten seconds.
    local now = GetGameTimer()
    if now - refusalWindow > 10000 then
        if refusals > 0 then print(("[open77_weapons] %d relayed blasts refused"):format(refusals)) end
        refusals, refusalWindow = 0, now
        print("[open77_weapons] relayed blast refused: " .. tostring(reason))
    else
        refusals = refusals + 1
    end
end)
