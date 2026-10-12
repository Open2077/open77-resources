-- Admin-only group admission. Reuse activity teardown/admission; never forge
-- client input, ignore life readiness or discard an author's editor draft.
local active, stopped = nil, false
local sessions = {}
local labels = { foot = "Foot Race", race = "Vehicle Race", ffa = "Free-for-all", blade = "Blade FFA" }
local function session(id)
    if not Open77.players.name(id) then return nil end
    if not sessions[id] then sessions[id] = {} end
    return sessions[id]
end
local function allowed(id, command)
    return id == 0 or (Open77.acl and Open77.acl.isAllowed(id, "command." .. command) == true)
end
local function ready(id)
    local life = Open77.players.getLifeState(id)
    return Open77.ready.isReady(id) and life and life.phase == "alive"
end
local function say(id, text)
    print("[playtest] " .. text)
    if id > 0 then
        TriggerClientEvent("chat:addMessage", id, { args = { "PLAYTEST", text } })
        TriggerClientEvent("freeroam:menu:result", id, true, text)
    end
end
local function running(batch)
    return not stopped and active == batch and not batch.cancelled and
        (batch.actor == 0 or (session(batch.actor) == batch.session and allowed(batch.actor, batch.command)))
end
local function start(actor, mode, command)
    if not allowed(actor, command) then return end
    if active then return say(actor, "A playtest transfer is running. Use /admin.playtest.cancel first.") end
    local isFfa = mode == "ffa" or mode == "blade"
    local ruleset = mode == "blade" and "blade" or "standard"
    if not isFfa and not FreeroamRace.canPlaytest(mode == "foot" and "foot" or "vehicle") then
        return say(actor, "No saved course is available for this race mode.")
    end
    local batch = { actor = actor, session = actor > 0 and session(actor) or nil,
        command = command, done = 0, skipped = 0, failed = 0, targets = {} }
    for _, value in ipairs(Open77.players.all()) do
        local id = tonumber(value)
        if id and ready(id) and not FreeroamRace.isEditing(id) then
            batch.targets[#batch.targets + 1] = { id = id, session = session(id) }
        else batch.skipped = batch.skipped + 1 end
    end
    if #batch.targets == 0 then return say(actor, "No ready players to transfer. Editor drafts are preserved.") end
    active = batch
    FreeroamRace.preparePlaytest()
    -- Request all returns together before waiting; cleanup belongs to the mode.
    for _, target in ipairs(batch.targets) do
        local instance = Deathmatch.instances.of(target.id)
        target.alreadyFfa = isFfa and instance and instance.format == "ffa"
            and (instance.ruleset or "standard") == ruleset
        if not target.alreadyFfa and FreeroamPvp.isReserved(target.id) then Deathmatch.leave(target.id, "auto") end
        TriggerClientEvent("deathmatch:panel", target.id, false)
        TriggerClientEvent("race:panel", target.id, false)
    end
    say(actor, labels[mode] .. ": transferring " .. #batch.targets .. " player(s), including the admin.")
    CreateThread(function()
        local ok, failure = pcall(function()
            for _, target in ipairs(batch.targets) do
                if not running(batch) then break end
                local id, deadline = target.id, GetGameTimer() + 35000
                local admitted, dismount = target.alreadyFfa, false
                while not admitted and running(batch) and session(id) == target.session and GetGameTimer() < deadline do
                    if not FreeroamRace.isReserved(id) and not FreeroamPvp.isReserved(id) and ready(id) then
                        local seat = Open77.vehicles.getPlayerSeat(id)
                        if seat and seat.vehicleId then
                            if not dismount then Open77.vehicles.forcePlayerOutOfVehicle(id, seat.vehicleId); dismount = true end
                        else
                            local position = Open77.players.position(id)
                            if position and position.bucket == 0 then
                                if isFfa then admitted = Deathmatch.round.join(id, ruleset) ~= nil
                                else admitted = FreeroamRace.joinPlaytest(id, mode == "foot" and "foot" or "vehicle") == true end
                            end
                        end
                    end
                    if not admitted then Wait(500) end
                end
                if not running(batch) then break end
                if admitted then
                    batch.done = batch.done + 1
                    TriggerClientEvent("chat:addMessage", id, { args = { "PLAYTEST", "An admin enrolled you in " .. labels[mode] .. "." } })
                elseif session(id) ~= target.session then batch.skipped = batch.skipped + 1
                else batch.failed = batch.failed + 1; say(actor, "Could not transfer player " .. id .. "; their character is not ready.") end
                Wait(150)
            end
        end)
        FreeroamRace.finishPlaytest()
        Deathmatch.broadcastState()
        local cancelled = not running(batch)
        active = nil
        say(actor, ("%s %s: %d enrolled, %d skipped, %d failed%s"):format(labels[mode],
            cancelled and "stopped" or "finished", batch.done, batch.skipped, batch.failed,
            not ok and (" (" .. tostring(failure) .. ")") or ""))
    end)
end
for mode in pairs(labels) do
    local name = "admin.playtest." .. mode
    RegisterCommand(name, function(actor, args)
        if args.n ~= 0 then return say(actor, "Usage: /" .. name) end
        start(actor, mode, name)
    end, true)
end
RegisterCommand("admin.playtest.cancel", function(actor)
    if not allowed(actor, "admin.playtest.cancel") then return end
    if active then active.cancelled = true end
    say(actor, "Pending transfers cancelled; already enrolled players stay in their mode.")
end, true)
AddEventHandler("onPlayerDisconnected", function(id) sessions[tonumber(id)] = nil end)
AddEventHandler("onResourceStop", function(name) if name == GetCurrentResourceName() then stopped = true end end)
