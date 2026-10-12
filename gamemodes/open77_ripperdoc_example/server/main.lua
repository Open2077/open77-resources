local participants, tickets, balances = {}, {}, {}
local ready = false
local accountCount = 0
local maxAccounts = tonumber(Ripperdoc.maxAccounts) or 1024
assert(maxAccounts >= 1 and maxAccounts <= 10000 and maxAccounts % 1 == 0, "maxAccounts must be an integer 1..10000")

local function notice(player, message)
    TriggerClientEvent("chat:addMessage", player, {args={"Ripperdoc", message}, color={34,216,226}})
end
local function validPair(doctor, patient)
    local a, b = Open77.players.position(doctor), Open77.players.position(patient)
    local x, y = Open77.players.getLifeState(doctor), Open77.players.getLifeState(patient)
    if not a or not b or not x or not y or x.phase ~= "alive" or y.phase ~= "alive" then return false end
    if a.bucket ~= b.bucket then return false end
    return (a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2 <= Ripperdoc.distance^2
end
local function account(player)
    local identity = Open77.players.identity(player)
    if not identity then return nil end
    local id = identity.userId
    if balances[id] == nil then
        if accountCount >= maxAccounts then return nil, "clinic capacity reached" end
        balances[id] = Ripperdoc.startingCredits
        accountCount = accountCount + 1
    end
    return id
end
local function finish(offer, success, reason)
    if offer.finished then return end
    offer.finished = true
    if offer.ticket then tickets[offer.ticket] = nil end
    participants[offer.doctor], participants[offer.patient] = nil, nil
    -- Payment is reserved before submission and charged only after the public
    -- backend completion. Failure returns the reserved demonstration credits.
    if offer.reserved and not success then balances[offer.account] = balances[offer.account] + offer.cost end
    TriggerClientEvent("open77:ripperdoc:close", offer.patient, offer.id)
    local message = success and "Procedure complete." or ("Procedure cancelled: " .. tostring(reason))
    if success and offer.inspect then
        local arms = offer.inspection[offer.slot]
        local label = offer.slot == "legs" and "Leg" or "Arm"
        if arms then
            local grade = arms.grade or {}
            message = ("%s inspection: %s; grade %s; profile %s; %s.")
                :format(label, arms.definition or "unknown", grade.id or "unknown", arms.profile or "unknown",
                    offer.slot == "legs" and ("jump stamina cost " .. tostring(grade.jumpStaminaCost or 0))
                        or (grade.cosmetic and "cosmetic" or (grade.nonlethal and "nonlethal" or "lethal damage permitted")))
        else message = label .. " inspection: no " .. (offer.slot == "legs" and "leg" or "arm") .. " implant installed." end
    end
    notice(offer.patient, message)
    notice(offer.doctor, message)
end
local function cancel(offer, reason)
    if offer.ticket then
        local cancelled, error = Open77.cyberware.cancel(offer.patient, offer.ticket)
        if not cancelled and error == "operation_committing" then return end
        -- Completion/rollback is owned by the platform once submitted.
        if cancelled then return end
    end
    finish(offer, false, reason)
end

CreateThread(function()
    local result, reason = Open77.cyberware.define(Ripperdoc.definition)
    ready = result ~= nil
    if not ready then print("[ripperdoc] definition unavailable: " .. tostring(reason)) end
    local legs, legsReason = Open77.cyberware.define(Ripperdoc.legsDefinition)
    if not legs then print("[ripperdoc] legs definition unavailable: " .. tostring(legsReason)) end
    Ripperdoc.legsReady = legs ~= nil
end)

RegisterCommand("doc", function(doctor, args)
    if args[1] == "cancel" then
        local offer = participants[doctor]
        if offer then cancel(offer, "doctor cancelled") end
        return
    end
    local patient, grade = tonumber(args[2]), args[3]
    local removing = args[1] == "remove"
    local inspecting = args[1] == "inspect"
    local slot = (removing or inspecting) and (args[3] or "arms") or (args[4] or "arms")
    if slot ~= "arms" and slot ~= "legs" then notice(doctor, "Implant slot must be arms or legs."); return end
    if slot == "legs" and not Ripperdoc.legsReady then notice(doctor, "Leg implants are unavailable."); return end
    if not ready or not patient or patient == doctor or (args[1] ~= "offer" and not removing and not inspecting) then
        notice(doctor, "Use /doc inspect <patient> [arms|legs], /doc offer <patient> <grade> [arms|legs], /doc remove <patient> [arms|legs], or /doc cancel."); return
    end
    local costs = slot == "legs" and Ripperdoc.legsCosts or Ripperdoc.costs
    local removalCost = slot == "legs" and Ripperdoc.legsRemovalCost or Ripperdoc.removalCost
    local cost = inspecting and 0 or (removing and removalCost or costs[grade])
    if not cost or cost < 0 or cost % 1 ~= 0 then notice(doctor, "Unknown grade or price."); return end
    if participants[doctor] or participants[patient] then notice(doctor, "A participant is already in a procedure."); return end
    if not validPair(doctor, patient) then notice(doctor, "Both participants must be alive and nearby."); return end
    local current = Open77.cyberware.current(patient)
    if not current then notice(doctor, "Patient implants are not ready."); return end
    if removing and not current[slot] then notice(doctor, "The patient has no " .. (slot == "legs" and "leg" or "arm") .. " implant."); return end
    local id, idError = Open77.cyberware.newOperationId()
    if not id then notice(doctor, "Procedure unavailable: " .. tostring(idError)); return end
    local offer = {id=id,doctor=doctor,patient=patient,grade=grade,slot=slot,removing=removing,inspect=inspecting,cost=cost,
        revision=current.revision,deadline=GetGameTimer()+Ripperdoc.consentMs,phase="offered"}
    participants[doctor], participants[patient] = offer, offer
    local position = Open77.players.position(doctor)
    TriggerClientEvent("open77:ripperdoc:offer", patient, {id=id,doctor=doctor,position=position,
        label=inspecting and ("Inspect " .. slot .. " implant") or (removing and ("Remove " .. slot .. " implant")
            or ("Install " .. (slot == "legs" and "Double Jump: " or "Gorilla Arms: ") .. grade)),cost=cost})
    notice(patient, ("%s offers %s for %s clinic credits. Look at the doctor to accept, or use /implantaccept.")
        :format(doctor, inspecting and (slot .. " inspection") or (removing and (slot .. " removal") or (slot .. " " .. grade)), cost))
    notice(doctor, "Waiting for patient consent.")
end, true)

local function accept(patient, id)
    local offer = participants[patient]
    if not offer or offer.patient ~= patient or offer.phase ~= "offered" or (id and id ~= offer.id) then return end
    if GetGameTimer() > offer.deadline or not validPair(offer.doctor, patient) then cancel(offer, "offer expired"); return end
    local current = Open77.cyberware.current(patient)
    if not current or current.revision ~= offer.revision then cancel(offer, "implants changed"); return end
    if offer.inspect then
        offer.inspection = current
        finish(offer, true)
        return
    end
    local owner, accountError = account(patient)
    if not owner or balances[owner] < offer.cost then cancel(offer, accountError or "insufficient clinic credits"); return end
    offer.account, offer.reserved = owner, true
    balances[owner] = balances[owner] - offer.cost
    offer.phase, offer.deadline = "procedure", GetGameTimer()+Ripperdoc.procedureMs
    TriggerClientEvent("open77:ripperdoc:close", patient, offer.id)
    notice(patient, "Procedure started. Stay beside the doctor.")
    notice(offer.doctor, "Patient consent received. Stay beside the patient.")
end
RegisterCommand("implantaccept", function(player) accept(player) end, false)
RegisterCommand("implantcancel", function(player)
    local offer = participants[player]
    if offer then cancel(offer, "participant cancelled") end
end, false)
RegisterCommand("cliniccredits", function(player)
    local owner, reason = account(player)
    if owner then notice(player, "Clinic credits available: " .. balances[owner])
    elseif reason then notice(player, reason) end
end, false)
RegisterNetEvent("open77:ripperdoc:answer", function(id, accepted)
    local patient = tonumber(source)
    local offer = participants[patient]
    if not offer or offer.patient ~= patient or offer.id ~= id then return end
    if accepted == true then accept(patient, id) elseif accepted == false then cancel(offer, "patient declined") end
end)
AddEventHandler("onCyberwareOperationCompleted", function(patient, ticket, encoded)
    local offer = tickets[ticket]
    if not offer or offer.patient ~= tonumber(patient) then return end
    local result = json.decode(encoded)
    finish(offer, result and result.ok == true, result and result.error or "projection failed")
end)
CreateThread(function()
    while true do
        for player, offer in pairs(participants) do
            if player == offer.patient and not offer.finished then
                if not validPair(offer.doctor, offer.patient) then cancel(offer, "participants separated")
                elseif offer.phase == "offered" and GetGameTimer() > offer.deadline then cancel(offer, "offer expired")
                elseif offer.phase == "procedure" and GetGameTimer() >= offer.deadline then
                    local options = {expectedRevision=offer.revision,operationId=offer.id,slot=offer.slot}
                    local result, reason
                    if offer.removing then result, reason = Open77.cyberware.remove(offer.patient, options)
                    else result, reason = Open77.cyberware.install(offer.patient,
                        (offer.slot == "legs" and Ripperdoc.legsDefinition or Ripperdoc.definition).id, offer.grade, options) end
                    if not result then finish(offer, false, reason)
                    elseif result.ticket then
                        offer.phase, offer.ticket = "projecting", result.ticket
                        tickets[result.ticket] = offer
                    else finish(offer, true) end
                end
            end
        end
        Wait(250)
    end
end)
