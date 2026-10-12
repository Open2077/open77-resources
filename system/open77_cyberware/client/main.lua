-- Native projection support only. Definitions, surgery and all RP policy are
-- owned by the server. Only platform-origin projection events reach this VM.
local generation = 0
-- A new identity when this VM starts or loses its native projection.
-- A uniqueness label, not a credential: the transport authenticates the sender.
local function newProjectorNonce()
    return string.format("%016x%016x",
        math.floor(Open77.time.monotonic() * 1000000), math.random(0, 2147483647))
end
local projectorNonce = newProjectorNonce()
-- A failed restore stays failed on the server until this projector restarts
-- with a new nonce. A transient native failure (the equipment request raced
-- the appearance mirror right after bootstrap and was rejected as stale, or
-- the script queue was busy) gets a bounded, backed-off retry; a structural
-- one (unsupported profile) never does. Measured 2026-09-29: without it one
-- lost race left a player without implants for the whole session.
local restoreRetries, restoreRetryAt = 0, nil
local transientRestore = {}
for reason in ("native_equipment_timeout stale_projection body_changed body_not_ready " ..
    "player_unavailable cyberware_equipment_owned queue_full projection_failed"):gmatch("%S+") do
    transientRestore[reason] = true
end
local actionIncarnation
local legsRequest, legsIncarnation, pendingJump
-- The activation lease for the double jump.
--
-- With one held the native gate spends a press locally and the jump happens on
-- the frame the player pressed; the server is told afterwards and reconciles at
-- the stamp. Without one the old ask-and-wait path runs unchanged, so a server
-- that issues no lease still works exactly as it did.
--
-- `ttl` is always a REMAINING lifetime, never an absolute server timestamp: the
-- native layer compares it against its own monotonic clock, and handing it a
-- server stamp would silently mix two clock domains.
local legLease
local dropLegLease
local bodyIncarnation
local predictedArmsGrade
local motionBodies = {}
local capabilityRequest, capabilityPhase, capabilityReason, capabilityFamily, capabilityIncarnation = nil, "idle", "not_projected", nil, nil
local capabilityReasons = {}
for reason in ("not_projected api_unavailable pending player_unavailable body_not_ready body_changed unbound " ..
    "unsupported_profile cyberware_equipment_owned queue_full stale_projection native_equipment_timeout " ..
    "native_melee_observer_unavailable gorilla_arms_not_drawn invalid_charge_limit projection_failed native_leg_grant_lost"):gmatch("%S+") do
    capabilityReasons[reason] = true
end
local function capabilityFailure(reason)
    capabilityReason = capabilityReasons[reason] and reason or "projection_failed"
end
-- Resource exports execute in this projector's VM, retaining native ownership.
-- Observation does not expose a projection ticket or approve/activate movement.
exports("legsActivity", function()
    if not legsIncarnation or not legsRequest then return nil, "legs_not_ready" end
    local api = Open77.cyberware
    if type(api) ~= "table" or type(api.legsActivity) ~= "function" then return nil, "api_unavailable" end
    local value, reason = api.legsActivity()
    if not value or value.request ~= legsRequest then return nil, "legs_not_ready" end
    return {sequence=value.sequence,phase=value.phase,grounded=value.grounded,
        airborneMs=value.airborneMs,verticalSpeed=value.verticalSpeed}
end)
exports("capabilities", function()
    local phase, reason = capabilityPhase, capabilityReason
    local api = Open77.cyberware
    for _, name in ipairs({"projectLocal", "localState", "configureLocal", "captureArms", "presentArms"}) do
        if type(api) ~= "table" or type(api[name]) ~= "function" then phase, reason = "unavailable", "api_unavailable"; break end
    end
    if phase == "ready" and capabilityRequest then
        local ok, state, why = pcall(api.localState, capabilityRequest)
        if not ok or state ~= "ready" then phase = "unavailable"; reason = capabilityReasons[why] and why or "body_not_ready" end
    end
    local legsPhase, legsReason = "idle", "not_projected"
    if type(api) ~= "table" or type(api.legsState) ~= "function" then legsPhase, legsReason = "unavailable", "api_unavailable"
    elseif legsRequest then
        local ok, state, why = pcall(api.legsState, legsRequest)
        legsPhase, legsReason = ok and state or "failed", ok and why or "projection_failed"
    end
    local slamPhase, slamReason, actionPhase = "idle", "not_projected", "unknown"
    local abilities = Open77.abilities
    if type(abilities)~="table" or type(abilities.slamState)~="function" or type(abilities.slamActivity)~="function" then
        slamPhase,slamReason="unavailable","api_unavailable"
    else
        local ok,value=pcall(abilities.slamActivity)
        if ok and type(value)=="table" and type(value.request)=="number" and value.request>0 then
            local read,state=pcall(abilities.slamState,value.request)
            if read and (state=="pending" or state=="ready" or state=="failed") then
                slamPhase=state;slamReason=state=="ready" and nil or "native_projection_pending_or_failed"
                local allowed={idle=true,pending=true,eligible=true,granted=true,windup=true,descent=true,contact=true,
                    impact=true,recovery=true,complete=true,cancelled=true,rejected=true}
                actionPhase=allowed[value.phase] and value.phase or "unknown"
            else slamPhase,slamReason="unavailable","body_not_ready" end
        end
    end
    return {schemaVersion=1, side="client", profile="gorilla_arms", profiles={"gorilla_arms","double_jump","ground_slam"},
        implantProfiles={"gorilla_arms","double_jump"},abilityProfiles={"ground_slam"},supportedBodyFamilies={"male","female"},
        support="declared_adapter", compatibility={protocol="1.28",testedGameBuild="2.31",actualGameBuild="unknown",dlcVerification="unknown"},
        slamProjection={phase=slamPhase,reason=slamReason,actionPhase=actionPhase,nativeReadback=slamPhase=="ready",
            visualProof=false,entitlement="session",liveAcceptance="pending"},
        legsProjection={phase=legsPhase,reason=legsReason,equipmentReadback=legsPhase == "ready",visualProof=false},
        localProjection={phase=phase,reason=reason,family=capabilityFamily,
            equipmentReadback=phase == "ready",visualProof=false}}
end)
RegisterNetEvent("open77:cyberware:project", function(projection)
    if type(projection) ~= "table" or type(projection.ticket) ~= "string"
        or #projection.ticket ~= 32 or type(projection.incarnation) ~= "string"
        or #projection.incarnation ~= 32 or type(projection.record) ~= "table" then return end
    generation = generation + 1
    predictedArmsGrade = nil
    CyberwareMeleePrediction.clear()
    legsIncarnation, pendingJump = nil, nil
    capabilityRequest, capabilityPhase, capabilityReason, capabilityFamily = nil, "pending", "pending", nil
    capabilityIncarnation = projection.incarnation
    restoreRetryAt = nil
    local this = generation
    local projectionDeadline = Open77.time.monotonic() + 12
    local arms, legs = projection.record.arms, projection.record.legs
    CreateThread(function()
        local request, reason, visual, requestLegs
        -- Which half stalled. A leg timeout and an arm timeout print the same
        -- reason; the server fails the whole binding either way (B5, 2026-09-30).
        local stage = "arms"
        -- The native adapters own distinct equipment areas and request IDs.
        -- Start legs now so arm readiness does not consume its restore window.
        if (legs == nil or (type(legs) == "table" and legs.profile == "double_jump"))
            and type(Open77.cyberware.projectLegs) == "function" then
            requestLegs = Open77.cyberware.projectLegs(legs ~= nil)
        end
        local ready = false
        for _ = 1, 120 do
            if this ~= generation then return end
            if arms ~= nil and (type(arms) ~= "table" or arms.profile ~= "gorilla_arms") then
                reason = "unsupported_profile"
                break
            end
            if not request then
                request, reason = Open77.cyberware.projectLocal(arms ~= nil)
                capabilityRequest = request
                -- The previous VM's native unequip lease may still be draining.
                -- Retry within this ticket's bound; ownership must not be stolen.
                if not request and reason ~= "body_not_ready" and reason ~= "player_unavailable"
                    and reason ~= "cyberware_equipment_owned" and reason ~= "queue_full" then break end
            end
            if request then
                local state
                state, reason = Open77.cyberware.localState(request)
                if state == "ready" then
                    local configured
                    configured, reason = Open77.cyberware.configureLocal(request, arms and arms.grade or {})
                    if not configured then break end
                    if arms ~= nil then visual, reason = Open77.cyberware.captureArms() end
                    if arms == nil or visual then ready = true; break end
                elseif state ~= "pending" then break end
            end
            Wait(100)
        end
        if this ~= generation then return end
        if ready then
            ready = false
            stage = "legs"
            if legs and (type(legs) ~= "table" or legs.profile ~= "double_jump") then
                reason = "unsupported_profile"
            elseif type(Open77.cyberware.projectLegs) ~= "function" then
                ready, reason = legs == nil, legs and "api_unavailable" or nil
            else
                legsIncarnation = nil
                for _ = 1, 120 do
                    if this ~= generation then return end
                    if Open77.time.monotonic() >= projectionDeadline then reason = "native_equipment_timeout"; break end
                    if not requestLegs then requestLegs, reason = Open77.cyberware.projectLegs(legs ~= nil) end
                    if requestLegs then
                        local state
                        state, reason = Open77.cyberware.legsState(requestLegs)
                        if state == "ready" then
                            local grade = legs and legs.grade or {}
                            ready, reason = Open77.cyberware.configureLegs(requestLegs, legs ~= nil,
                                grade.maxAirborneMs or 10000, grade.maxFallSpeed or 30)
                            if ready then legsRequest = requestLegs end
                            break
                        elseif state ~= "pending" then break end
                    elseif reason ~= "body_not_ready" and reason ~= "player_unavailable"
                        and reason ~= "cyberware_equipment_owned" and reason ~= "queue_full" then break end
                    Wait(100)
                end
            end
        end
        if this ~= generation then return end
        if not ready and (reason == nil or reason == "") then reason = "native_equipment_timeout" end
        capabilityPhase = ready and "ready" or "failed"
        predictedArmsGrade = ready and arms and arms.grade or nil
        capabilityFamily = visual and visual.family or nil
        if ready then capabilityReason = nil else capabilityFailure(reason) end
        TriggerServerEvent("open77:cyberware:ack", {
            incarnation = projection.incarnation, ticket = projection.ticket, ready = ready, visual = visual,
        })
        if not ready then
            print("[cyberware] native projection failed: " .. tostring(reason or "timeout") .. " stage=" .. stage)
        end
        if ready then restoreRetries, restoreRetryAt = 0, nil
        elseif transientRestore[reason] and restoreRetries < 4 then
            restoreRetryAt = Open77.time.monotonic() + 2 ^ (restoreRetries + 1) -- 2, 4, 8, 16 s
        end
    end)
end)

-- Patient-owned, committed profiles. State survives native proxy streaming;
-- handles are observations of this receiver only, never network identities.
local epoch, snapshotFloor, pendingSnapshot = nil, 0, nil
local records, seen = {}, {}
local serverClockOffset
local function milliseconds() return Open77.time.monotonic()*1000 end
local function integer(value, maximum)
    return type(value) == "number" and value % 1 == 0 and value > 0 and value <= maximum
end
local function envelope(value)
    if type(value) ~= "table" or type(value.epoch) ~= "string" or #value.epoch ~= 32
        or not integer(value.sequence, 9007199254740991) then return false end
    if epoch and epoch ~= value.epoch then return false end
    epoch = value.epoch
    if type(value.serverTime) == "number" and value.serverTime >= 0 and value.serverTime < math.huge then
        local offset = milliseconds() - value.serverTime
        -- Keep the least delayed authenticated timestamp observed in this
        -- resource session. Unlike Welcome.serverTime, this advances on every
        -- record/snapshot and never freezes at connection time.
        serverClockOffset = math.min(serverClockOffset or offset, offset)
    end
    return true
end
local function localPlayer()
    local session = Open77.network.status()
    return session and tonumber(session.playerId)
end
local function projectionValid(value)
    return type(value) == "table" and integer(value.player, 9007199254740991)
        and type(value.incarnation) == "string" and #value.incarnation == 32
        and type(value.record) == "table"
        and (value.record.arms == nil or type(value.visual) == "table")
end
local function keep(value, sequence)
    local player = value.player
    motionBodies[player] = value.reason ~= "unbound" and value.reason ~= "body_unavailable" and value.incarnation or nil
    seen[player] = sequence
    if player == localPlayer() then
        if (capabilityIncarnation and capabilityIncarnation ~= value.incarnation) or value.reason == "body_unavailable" or value.reason == "unbound" then
            capabilityRequest, capabilityPhase, capabilityFamily = nil, "unavailable", nil
            capabilityFailure(value.reason == "unbound" and "unbound" or "body_changed")
        end
        bodyIncarnation = value.reason ~= "unbound" and value.reason ~= "body_unavailable" and value.incarnation or nil
        actionIncarnation = value.record.arms ~= nil and value.incarnation or nil
        legsIncarnation = value.reason ~= "body_unavailable" and value.reason ~= "unbound"
            and value.record.legs ~= nil and value.incarnation or nil
    end
    local previous = records[player]
    if previous and previous.incarnation ~= value.incarnation then
        -- Retire the old body's overlay before accepting its replacement.
        Open77.cyberware.presentArms(player, false)
    end
    local usable = value.reason ~= "unbound" and value.reason ~= "body_unavailable" and value.record.arms ~= nil
    records[player] = { visual=usable and value.visual or false, dirty=true, incarnation=value.incarnation }
end
local function clearLocal()
    predictedArmsGrade = nil
    CyberwareMeleePrediction.clear()
    CyberwarePrediction.clear()
    capabilityRequest, capabilityPhase, capabilityReason, capabilityFamily = nil, "unavailable", "unbound", nil
    bodyIncarnation = nil
    legsIncarnation, legsRequest = nil, nil
    if type(Open77.cyberware.releaseLegs) == "function" then Open77.cyberware.releaseLegs() end
    generation = generation + 1
    local this = generation
    CreateThread(function()
        local request, reason
        for _ = 1, 120 do
            if this ~= generation then return end
            if not request then
                request, reason = Open77.cyberware.projectLocal(false)
                if not request and reason ~= "body_not_ready" and reason ~= "player_unavailable"
                    and reason ~= "queue_full" then return end
            end
            if request then
                local state
                state, reason = Open77.cyberware.localState(request)
                if state == "ready" then return end
                if state ~= "pending" then
                    print("[cyberware] unbind cleanup failed: " .. tostring(reason))
                    return
                end
            end
            Wait(100)
        end
        print("[cyberware] unbind cleanup timed out")
    end)
end
RegisterNetEvent("open77:cyberware:record", function(value)
    if not envelope(value) or not projectionValid(value.projection) then return end
    local projection = value.projection
    if value.sequence <= math.max(snapshotFloor, seen[projection.player] or 0) then return end
    keep(projection, value.sequence)
    if projection.player == localPlayer() and projection.reason == "unbound" then clearLocal() end
end)

RegisterNetEvent("open77:cyberware:snapshot", function(value)
    if not envelope(value) or value.sequence <= snapshotFloor
        or not integer(value.total, 256) or not integer(value.part, value.total)
        or type(value.records) ~= "table" or #value.records > 16 then return end
    if pendingSnapshot and value.sequence < pendingSnapshot.sequence then return end
    if not pendingSnapshot or value.sequence > pendingSnapshot.sequence then
        pendingSnapshot = { sequence=value.sequence, total=value.total, parts={}, count=0 }
    end
    local pending = pendingSnapshot
    if pending.total ~= value.total or pending.parts[value.part] then return end
    for _, projection in ipairs(value.records) do
        -- Snapshot records flatten the visual profile by one level to stay
        -- within the shared native event decoder's eight-level bound.
        if type(projection) == "table" and projection.family ~= nil then
            projection.visual = { family=projection.family, groups=projection.groups }
        end
        if not projectionValid(projection) then return end
    end
    pending.parts[value.part] = value.records
    pending.count = pending.count + 1
    if pending.count ~= pending.total then return end
    local nextRecords = {}
    for _, part in ipairs(pending.parts) do
        for _, projection in ipairs(part) do
            if nextRecords[projection.player] then pendingSnapshot = nil; return end
            nextRecords[projection.player] = projection
        end
    end
    for player in pairs(records) do
        if not nextRecords[player] and (seen[player] or 0) <= pending.sequence then
            records[player] = { visual=false, dirty=true }
        end
    end
    for player, projection in pairs(nextRecords) do
        if (seen[player] or 0) <= pending.sequence then keep(projection, pending.sequence) end
    end
    snapshotFloor = pending.sequence
    pendingSnapshot = nil
    for player, sequence in pairs(seen) do
        if not nextRecords[player] and sequence <= snapshotFloor then
            seen[player] = nil
            motionBodies[player] = nil
        end
    end
end)

CreateThread(function()
    local polls = 0
    while true do
        local session = Open77.network.status()
        if session and session.phase == "active" then
            if polls % 4 == 0 and capabilityPhase == "ready" and legsIncarnation and legsRequest then
                local state, reason = Open77.cyberware.legsState(legsRequest)
                if state == "failed" and (reason == "native_leg_grant_lost"
                    or reason == "body_changed" or reason == "stale_projection") then
                    -- Like Dash, recover through the existing authenticated
                    -- projector restart. The server restores committed equipment;
                    -- this neither installs a new implant nor grants a jump.
                    print("[cyberware] requesting fresh legs projection: "..tostring(reason))
                    generation = generation + 1
                    capabilityPhase = "pending"
                    capabilityFailure(reason)
                    legsRequest, legsIncarnation, pendingJump = nil, nil, nil
                    dropLegLease()
                    projectorNonce = newProjectorNonce()
                    polls = 0
                end
            end
            if restoreRetryAt and capabilityPhase == "failed" and Open77.time.monotonic() >= restoreRetryAt then
                restoreRetryAt, restoreRetries = nil, restoreRetries + 1
                print("[cyberware] requesting fresh projection after a failed restore: attempt "
                    .. restoreRetries .. " reason=" .. tostring(capabilityReason))
                projectorNonce = newProjectorNonce()
                polls = 0
            end
            if polls % 20 == 0 then
                TriggerServerEvent("open77:cyberware:request", projectorNonce)
            end
            polls = polls + 1
            for player, record in pairs(records) do
                local entity = Open77.vfx.resolveTarget({kind="player", id=tostring(player)})
                if record.dirty or entity ~= record.entity then
                    local ok = Open77.cyberware.presentArms(player, record.visual)
                    record.dirty = not ok
                    record.entity = entity
                    if record.visual == false and (ok or not entity) then records[player] = nil end
                end
            end
        end
        Wait(250)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then
        generation = generation + 1
        pendingJump, legsIncarnation, legsRequest = nil, nil, nil
        dropLegLease()
        if type(Open77.cyberware.releaseLegs) == "function" then Open77.cyberware.releaseLegs() end
    end
end)

-- The server sends a REMAINING LIFETIME, never an absolute deadline.
--
-- `Open77.network.status().serverTimeMicroseconds` is set once from the Welcome
-- packet and never advances -- it is a constant for the whole session. Deriving
-- a lease deadline from it produced a number that grew with wall time, crossed
-- the sanity bound within seconds, and silently discarded every lease. That is
-- what made the first live pass measure the old ask-and-wait path at 0 %.
local function leaseTtl(ttlMs)
    if type(ttlMs) ~= "number" or ttlMs ~= ttlMs then return nil end
    local ttl = math.floor(ttlMs)
    -- A lease worth nothing is not a lease. Fail closed rather than clamp up.
    if ttl <= 0 or ttl > 30000 then return nil end
    return ttl
end
dropLegLease = function()
    legLease = nil
    if type(Open77.cyberware.releaseLegLease) == "function" then Open77.cyberware.releaseLegLease() end
end
RegisterNetEvent("open77:leases:grant", function(value)
    if type(value) ~= "table" or value.ability ~= "double_jump" then return end
    if not legsIncarnation or value.incarnation ~= legsIncarnation then return end
    if type(value.leaseId) ~= "string" or #value.leaseId ~= 32 then return end
    local ttl = leaseTtl(value.ttlMs)
    if not ttl then return end
    if type(Open77.cyberware.grantLegLease) ~= "function" then return end
    if Open77.cyberware.grantLegLease(value.leaseId, value.epoch or 0, value.budget or 1, ttl) then
        legLease = {id=value.leaseId, epoch=value.epoch or 0}
    end
end)
RegisterNetEvent("open77:leases:refresh", function(value)
    if type(value) ~= "table" or value.ability ~= "double_jump" or not legLease then return end
    if value.leaseId ~= legLease.id or value.epoch ~= legLease.epoch then return end
    local ttl = leaseTtl(value.ttlMs)
    if not ttl or type(Open77.cyberware.refreshLegLease) ~= "function" then return end
    Open77.cyberware.refreshLegLease(legLease.epoch, value.remaining or 0, ttl)
end)
RegisterNetEvent("open77:leases:revoke", function(value)
    if type(value) ~= "table" or value.ability ~= "double_jump" then return end
    dropLegLease()
end)

-- The native adapter buffers an eligible second press. It remains disabled
-- until one server decision matches this body's request and action sequence.
RegisterNetEvent("open77:cyberware:jumpResult", function(result)
    local pending = pendingJump
    if not pending or type(result) ~= "table" or result.incarnation ~= pending.incarnation
        or result.sequence ~= pending.sequence or pending.incarnation ~= legsIncarnation
        or pending.request ~= legsRequest then return end
    pendingJump = nil
    Open77.cyberware.approveLegJump(pending.request, pending.sequence, result.ok == true)
end)
CreateThread(function()
    local sentRequest, sentSequence
    while true do
        if legsIncarnation and legsRequest and type(Open77.cyberware.legsActivity) == "function" then
            local state = Open77.cyberware.legsActivity()
            if state and state.request == legsRequest and state.phase == "reported"
                and legLease and state.lease == legLease.id and (state.reportSequence or 0) > 0 then
                -- The leased path: the jump already happened. Stamp it in the
                -- server's own clock domain by subtracting the age the native
                -- layer measured, so the server judges it where it happened
                -- rather than a third of a second downrange.
                do
                    TriggerServerEvent("open77:cyberware:jumpReport", {
                        incarnation = legsIncarnation,
                        report = {
                            lease = state.lease,
                            epoch = state.leaseEpoch or 0,
                            sequence = state.reportSequence,
                            -- How long ago the jump actually fired. The server
                            -- subtracts it from its own arrival clock, so the
                            -- one-way delay cancels instead of being counted
                            -- twice; the absolute stamps below are diagnosis.
                            ageMs = math.floor(state.ageMs or 0),
                            clientTimeMs = math.floor(Open77.time.monotonic() * 1000),
                        },
                    })
                    Open77.cyberware.legReportSent(state.reportSequence)
                end
            elseif state and state.request == legsRequest and state.phase == "pending"
                and (sentRequest ~= state.request or sentSequence ~= state.sequence) then
                sentRequest, sentSequence = state.request, state.sequence
                pendingJump = {request=state.request,sequence=state.sequence,incarnation=legsIncarnation}
                TriggerServerEvent("open77:cyberware:jump", {incarnation=legsIncarnation,sequence=state.sequence})
            end
        else
            pendingJump, sentRequest, sentSequence = nil, nil, nil
        end
        Wait(0)
    end
end)

CreateThread(function()
    local incarnation, previous, polls, expired
    while true do
        if actionIncarnation then
            if incarnation ~= actionIncarnation then
                incarnation, previous, polls = actionIncarnation, nil, 0
            end
            local state = Open77.cyberware.attackState()
            CyberwareMeleePrediction.observe(actionIncarnation,predictedArmsGrade,state,milliseconds(),
                Open77.players and type(Open77.players.getHealthState)=="function" and Open77.players.getHealthState() or nil)
            if state and state.chargeExpired and not expired then
                TriggerEvent("chat:addMessage", {type="system",author="Cyberware",text="Charge expired. Release attack to charge again."})
            end
            expired = state and state.chargeExpired or false
            local sequence = state and state.sequence or (previous and previous.sequence or 0)
            local armed, holding, variant = state ~= nil, state and state.holding or false, state and state.variant or 0
            if not previous or polls % 5 == 0 or previous.sequence ~= sequence or previous.armed ~= armed
                or previous.holding ~= holding or previous.variant ~= variant then
                previous = {incarnation=incarnation,sequence=sequence,armed=armed,holding=holding,variant=variant}
                TriggerServerEvent("open77:cyberware:action", previous)
            end
            polls = polls + 1
        else
            incarnation, previous = nil, nil
            CyberwareMeleePrediction.clear()
        end
        Wait(50)
    end
end)

-- Refusals are body-scoped and monotonic, including those arriving before
-- the local contact. Keep a bounded rejection window to avoid a late false fall.
local refusedMeleeActions,refusalSequence={},0
RegisterNetEvent("open77:cyberware:predictionRefused",function(value)
    if not envelope(value) or value.sequence<=refusalSequence or value.incarnation~=bodyIncarnation
        or not integer(value.action,4294967295) then return end
    refusalSequence=value.sequence
    local stamp=milliseconds()
    for key,item in pairs(refusedMeleeActions) do if stamp>=item.expires then refusedMeleeActions[key]=nil end end
    refusedMeleeActions[value.action%128]={action=value.action,expires=stamp+3000,incarnation=value.incarnation}
    CyberwarePrediction.cancel("melee",tostring(value.action),value.victim and value.victim>0 and value.victim or nil)
end)

-- Reserved platform motion events. Native ownership also cleans up on VM stop.
-- A native contact is stronger evidence than the button/attack activity poll.
-- Match its exact swing and weapon before consulting the committed grade.
AddEventHandler("open77:cyberware:contact", function(victim, sequence, weapon, x, y)
    local action=tonumber(sequence)
    if not action then return end
    local refused=refusedMeleeActions[action%128]
    if refused and refused.incarnation==bodyIncarnation and refused.action==action and milliseconds()<refused.expires then return end
    local grade = predictedArmsGrade
    if not grade or capabilityPhase ~= "ready" or not bodyIncarnation then return end
    local attack = Open77.cyberware.attackState()
    if not attack or attack.sequence ~= tonumber(sequence) or tonumber(weapon) ~= GetHashKey("Items.StrongArms")
        or attack.holding or attack.chargeExpired
        or (attack.variant ~= 0 and attack.variant ~= 1 and attack.variant ~= 2 and attack.variant ~= 6) then return end
    if not CyberwareMeleePrediction.allows(bodyIncarnation,grade,attack,milliseconds(),
        Open77.players and type(Open77.players.getHealthState)=="function" and Open77.players.getHealthState() or nil) then return end
    local charged = attack.variant == 1
    local distance = charged and grade.knockbackMeters or grade.normalKnockbackMeters
    if distance == nil then distance = (grade.knockbackMeters or 0) * 0.35 end
    if distance <= 0 then return end
    local damage = (grade.cosmetic or grade.nonlethal) and 0 or (charged and grade.chargedDamage or grade.normalDamage)
    CyberwarePrediction.request("melee", tonumber(victim), sequence, tonumber(x), tonumber(y), damage)
end)

local motions, motionSequences = {}, {}
local lifeMotionBodies = {}
-- ForcedMotionService.Acknowledge grants 6000 ms; native ForcedMotion.cpp ends
-- its pose after 3000 ms then retains another 3000 ms for recovery ownership.
local MOTION_RECOVERY_MS = 3000
local function motionBody(player)
    local generic=lifeMotionBodies[player]
    if generic then
        local life=Open77.players.getLifeState(player)
        if life and life.phase=="alive" and life.revision==generic.revision and life.bucket==generic.bucket then
            return generic.incarnation
        end
        return nil
    end
    if player == localPlayer() then return bodyIncarnation end
    return motionBodies[player]
end
local function applyMotion(entity, value)
    if value.kind == "launch" then
        if type(Open77.motion.launch) ~= "function" then return nil, "launch_backend_unavailable" end
        return Open77.motion.launch(entity, value.directionX, value.directionY, value.push, value.lift)
    end
    return Open77.motion.knockdown(entity, value.directionX, value.directionY, value.distance)
end
exports("incarnation", function(player) return motionBody(tonumber(player)) end)
local function tryObserverMotion(motion)
    if motion.handle or not motion.retry then return end
    local value = motion.retry
    if motionBody(value.player) ~= value.incarnation then return end
    -- The extra parentheses keep ONE value: an unresolved target answers
    -- (nil, reason), and tonumber(nil, reason) raises "bad argument #2". That
    -- error killed this retry loop's thread for the rest of the session
    -- (client A, 06:47:04 and 06:47:05, 2026-09-30).
    local entity = tonumber((Open77.vfx.resolveTarget({kind="player",id=tostring(value.player)})))
    if not entity or type(Open77.motion) ~= "table" then return end
    local handle = applyMotion(entity, value)
    if handle then
        print(("[motion] binding id=%s incarnation=%s player=%s entity=%s handle=%s role=observer")
            :format(motion.id, motion.incarnation, motion.player, entity, handle))
        motion.handle, motion.retry = handle, nil
    end
end
RegisterNetEvent("open77:cyberware:motion", function(message)
    if not envelope(message) then return end
    local value = message.motion
    if type(value) ~= "table" or type(value.id) ~= "string" or #value.id ~= 32
        or type(value.incarnation) ~= "string" or #value.incarnation ~= 32
        or not integer(value.player, 9007199254740991) then return end
    if message.sequence <= (motionSequences[value.player] or 0) then return end
    motionSequences[value.player] = message.sequence
    CyberwarePrediction.observeMotion(value, serverClockOffset)
    local existing = motions[value.id]
    if value.phase == "ended" then
        if existing and existing.handle then Open77.motion.stop(existing.handle) end
        motions[value.id] = {done=true,expires=milliseconds()+10000}
        return
    end
    if existing then
        if existing.retry and value.phase == "active" then existing.sequence = message.sequence end
        return -- preserve the original retry deadline; duplicate events cannot renew it.
    end
    if not serverClockOffset or type(value.expiresAt) ~= "number"
        or milliseconds() - serverClockOffset >= value.expiresAt then return end
    local owning = value.player == localPlayer()
    if (owning and value.phase ~= "pending") or (not owning and value.phase ~= "active") then return end
    if value.lifeRevision and value.lifeRevision>0 then
        if not integer(value.lifeRevision,9007199254740991) or type(value.bucket)~="number" then return end
        local life=Open77.players.getLifeState(value.player)
        if life and (life.phase~="alive" or life.revision~=value.lifeRevision or life.bucket~=value.bucket) then return end
        -- Authenticated server envelope; native/local lifecycle must still match.
        -- An observer may bind on its existing bounded retry after life arrives.
        lifeMotionBodies[value.player]={incarnation=value.incarnation,revision=value.lifeRevision,bucket=value.bucket,
            expires=milliseconds()+12000}
    else lifeMotionBodies[value.player]=nil end
    if not owning then
        local identity = motionBody(value.player)
        if identity and identity ~= value.incarnation then return end
        local now = milliseconds()
        -- Active leases include three seconds of forced pose plus three seconds
        -- of recovery. Never turn a delayed recovery update into a fresh fall.
        local poseDeadline = value.expiresAt + serverClockOffset - MOTION_RECOVERY_MS
        if now >= poseDeadline then return end
        local motion = {id=value.id,player=value.player,incarnation=value.incarnation,expires=now+10000,
            retry={player=value.player,incarnation=value.incarnation,directionX=value.directionX,
                directionY=value.directionY,distance=value.distance,kind=value.kind,push=value.push,lift=value.lift},
            retryUntil=math.min(now+1000,poseDeadline),sequence=message.sequence}
        motions[value.id] = motion
        tryObserverMotion(motion)
        return
    end
    if motionBody(value.player) ~= value.incarnation then return end
    if type(Open77.motion) ~= "table" then
        if owning then TriggerServerEvent("open77:cyberware:motionAck", {id=value.id,incarnation=value.incarnation,applied=false}) end
        return
    end
    local entity = owning and 1 or tonumber((Open77.vfx.resolveTarget({kind="player",id=tostring(value.player)})))
    local motion = {player=value.player,incarnation=value.incarnation,expires=milliseconds()+10000}
    motions[value.id] = motion
    local this = generation
    local function startOwnedMotion()
    local handle, reason
    local admissionDeadline=math.min(milliseconds()+500,value.expiresAt+serverClockOffset)
    repeat
        if motions[value.id]~=motion or this~=generation or motionBody(value.player)~=value.incarnation then return end
        if entity then handle, reason = applyMotion(entity, value) end
        if handle or value.kind~="launch" or reason~="body_not_available_for_motion"
            or milliseconds()>=admissionDeadline then break end
        -- A server-authorized ambient stop precedes this request on the wire,
        -- but native workspot teardown can need several engine frames.
        Wait(0)
    until false
    motion.handle=handle
    if handle then
        print(("[motion] binding id=%s incarnation=%s player=%s entity=%s handle=%s role=owner")
            :format(value.id, value.incarnation, value.player, entity, handle))
    end
    if not handle or type(Open77.motion.state) ~= "function" then
        if handle then Open77.motion.stop(handle) end
        TriggerServerEvent("open77:cyberware:motionAck", {id=value.id,incarnation=value.incarnation,applied=false})
        print("[motion] native projection unavailable: " .. tostring(reason or "native_state_unavailable"))
        return
    end
    -- A native handle only queues the status. Publishing active at that point
    -- starts the observer's fall before the owner's PSM/impulse has started.
    -- Wait for the actual native state, once per game frame, within this lease.
    local deadline = math.min(milliseconds()+1500, value.expiresAt+serverClockOffset)
    CreateThread(function()
        while motions[value.id] == motion and this == generation
            and motionBody(value.player) == value.incarnation and milliseconds() < deadline do
            local phase = Open77.motion.state(handle)
            if phase == "active" then
                TriggerServerEvent("open77:cyberware:motionAck", {id=value.id,incarnation=value.incarnation,applied=true})
                return
            end
            if phase ~= "pending" then break end
            Wait(0)
        end
        Open77.motion.stop(handle)
        if motions[value.id] == motion and this == generation then
            TriggerServerEvent("open77:cyberware:motionAck", {id=value.id,incarnation=value.incarnation,applied=false})
        end
    end)
    end
    if value.kind=="launch" then CreateThread(startOwnedMotion) else startOwnedMotion() end
end)
CreateThread(function()
    while true do
        local now = milliseconds()
        for player,identity in pairs(lifeMotionBodies) do
            if now>=identity.expires then lifeMotionBodies[player]=nil end
        end
        for id, motion in pairs(motions) do
            local identity = motion.player and motionBody(motion.player)
            local changed = motion.player and identity ~= motion.incarnation and (identity ~= nil or not motion.retry)
            if now >= motion.expires or changed then
                if motion.handle and Open77.motion then Open77.motion.stop(motion.handle) end
                motions[id] = nil
            elseif motion.retry then
                if now >= motion.retryUntil or motionSequences[motion.player] ~= motion.sequence then
                    motion.retry = nil -- bounded tombstone: never restart an expired/superseded reaction.
                    motion.player = nil
                else
                    tryObserverMotion(motion)
                end
            end
        end
        Wait(100)
    end
end)

-- Car impacts. PlayerPuppet.OnCarHitPlayer knocks only the victim's own body
-- down; every other client saw a replicated slide without the fall. The native
-- raises open77:localCarImpact on the victim with the separation direction
-- while it submits the victim's own damage report. The direction is only a
-- cosmetic detail: the server cues observers when the ledger ACCEPTED that
-- report for a living body, and only players of its bucket near the victim.
-- Observers play the fall as a pose-only reaction on the proxy (motion stays
-- replicated, so no second impulse exists anywhere).
AddEventHandler("open77:localCarImpact", function(directionX, directionY)
    local x, y = tonumber(directionX), tonumber(directionY)
    if not x or not y or x ~= x or y ~= y then return end
    print(("[carImpact] victim cue direction=%.2f,%.2f"):format(x, y))
    TriggerServerEvent("open77_cyberware:carImpact", {directionX=x, directionY=y})
end)
RegisterNetEvent("open77_cyberware:carImpactSeen", function(value)
    if type(value) ~= "table" or not integer(value.player, 9007199254740991) or value.player == localPlayer() then return end
    local x, y = tonumber(value.directionX), tonumber(value.directionY)
    if not x or not y or x ~= x or y ~= y or type(Open77.motion) ~= "table" then return end
    local entity = tonumber((Open77.vfx.resolveTarget({kind="player", id=tostring(value.player)})))
    if not entity then print(("[carImpact] observer player=%s proxy unresolved"):format(value.player)) return end
    -- Applied at once: the fall and the replicated slide play together, as on
    -- the victim. (A delayed start was only an experiment; the real override
    -- was the proxy's full-body mirror layers, gated on OwnsPose since build-10.)
    do
        local handle, reason = Open77.motion.knockdown(entity, x, y, 0)
        print(("[carImpact] observer player=%s entity=%s handle=%s reason=%s"):format(value.player, entity, tostring(handle), tostring(reason)))
        -- The victim's native knockdown lasts three seconds; end the pose with it.
        if handle then SetTimeout(3000, function() Open77.motion.stop(handle) end) end
    end
end)
