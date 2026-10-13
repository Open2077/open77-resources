-- Platform projection and intent only; all entitlement and outcomes are server owned.
local state, epoch, revision, sequence = nil, nil, 0, 0
local transitionRevision,retiredEpochs=0,{}
local actions, selected, retired = {}, nil, {}
local feedbackUntil,armedShown=0,false
-- Hold-to-hack: the hacking interface exists only while the hack key is held.
-- Press arms and submits the start intent; release cancels whatever own upload
-- the server has opened (the same cancel path END uses). `since` bounds the armed
-- panel when the server never answers.
local hold={active=false,target=nil,since=0}
local dismissWarning
local api = Open77.hacking
local input = HackingInput or {}
local feedback = type(input.feedback)=="table" and input.feedback or {}
if type(api) ~= "table" then print("[hacking] native API unavailable"); return end
local function now() return Open77.time.monotonic() * 1000 end
local function nextSequence() sequence = sequence + 1; return sequence end
local function integer(v) return type(v) == "number" and v > 0 and v < 9007199254740991 and v % 1 == 0 end
local function point(v)
    if type(v) ~= "table" then return false end
    for _, k in ipairs({"x","y","z"}) do
        if type(v[k]) ~= "number" or v[k] ~= v[k] or math.abs(v[k]) > 100000 then return false end
    end
    return true
end
local function me() return tonumber((Open77.network.status() or {}).playerId) end
-- The hack kind rides every server transition and the roster's `hack.kind`; the
-- input path is kind-agnostic, only the words change. The native bar takes the
-- kind as the fourth `hacking.hud:` field (`present{kind=}`), composing
-- `<KIND> UPLOAD` / `INCOMING <KIND>` / `<KIND> IMPACT`; a DLL without the field
-- keeps the Short Circuit headers.
local KIND_LABELS={short_circuit="Short Circuit",overheat="Overheat",malfunction="Cyberware Malfunction",cripple="Cripple Movement",
    reboot_optics="Reboot Optics",weapon_glitch="Weapon Glitch"}
local KINDS={"short_circuit","overheat","malfunction","cripple","reboot_optics","weapon_glitch"}
local function kindLabel(kind) return KIND_LABELS[kind] or KIND_LABELS.short_circuit end
local function kindHeader(kind) return string.upper(kindLabel(kind)) end
local function kindId(kind) return KIND_LABELS[kind] and kind or "short_circuit" end
local function ownKind() return state and type(state.hack)=="table" and state.hack.kind or "short_circuit" end
local ABILITY_LABELS={dash="Dash",ground_slam="Ground Slam",gorilla="Gorilla Arms",hacking="hacking"}
local function abilityList(blocks)
    if type(blocks)~="table" or #blocks==0 then return "all Open77 cyberware" end
    local names={}
    for _,ability in ipairs(blocks) do names[#names+1]=ABILITY_LABELS[ability] or tostring(ability) end
    return table.concat(names,", ")
end
-- Server-authored movement locks on this body: `effects.freezeMs` (reason `freeze`)
-- and Cripple Movement (`cripple` / `cripple_heavy`). The server gate (`frozen`,
-- `crippled`) is the authority; the lock is the victim's own presentation of the
-- same deadline through `Open77.movement.lock` (permission `player.movement.lock`),
-- which clamps at its own caps (freeze 10 s, cripple 30 s) and releases itself on
-- death, vehicle, workspot, session change and resource stop. One ledger entry per
-- family; the tick reconciles it against the one lock the primitive holds:
--   * a freeze always rides the platform's stationary knockdown (the server requests
--     the hold before it reports the freeze), and the knockdown's `Knockdown` state and
--     the freeze's `stunned` state are sibling locomotion states, so the two are never
--     applied in the same tick: the knockdown goes first and the freeze lock starts
--     `HackingInput.freezeAfterKnockdownMs` (3 s, the measured stand-up) after the
--     transition, for whatever remains of the server deadline; a freeze that ends
--     inside the knockdown never locks (the native hold already covered it);
--   * freeze outranks cripple (the primitive answers `lock_busy` to a second kind, so
--     the held kind is released first); a cripple resumes for its remaining time once
--     the freeze ends;
--   * a refusal is logged once and the entry dropped, never retried blindly;
--   * `status_purged` / `status_expired` of the cripple, `clear()` and resource stop
--     release; a fresh authoritative state (first roster, reconnect, resource reload)
--     re-locks from `activity.frozenMs` / `crippledMs` without the knockdown delay.
local locks,held={},nil
local function movementApi()
    local m=Open77.movement
    return type(m)=="table" and type(m.lock)=="function" and type(m.unlock)=="function" and m or nil
end
local function lockFamily(kind) return kind=="freeze" and "freeze" or "cripple" end
local function releaseHeld()
    if not held then return end
    local m=movementApi()
    if m then pcall(m.unlock) end
    held=nil
end
local function scheduleLock(kind,remaining,notBefore)
    if not movementApi() or (kind~="freeze" and kind~="cripple" and kind~="cripple_heavy") then return end
    remaining=tonumber(remaining) or 0
    if remaining<=0 then return end
    local family=lockFamily(kind)
    local endsAt=now()+remaining
    local current=locks[family]
    -- Never shorten a lock the server already authored; a longer or different one replaces it.
    if current and current.kind==kind and current.endsAt>=endsAt then return end
    locks[family]={kind=kind,endsAt=endsAt,notBefore=notBefore or now()}
end
local function remainingOf(value)
    local ends,server=tonumber(value.statusEndsAt),tonumber(value.serverTime)
    if ends and server and ends>server then return ends-server end
    return tonumber(value.amount) or 0
end
local function reconcileLocks()
    local m=movementApi()
    if not m then return end
    local t=now()
    for family,entry in pairs(locks) do if t>=entry.endsAt then locks[family]=nil end end
    if (held or next(locks)) and type(m.lockState)=="function" then
        local ok,current=pcall(m.lockState)
        if ok and type(current)=="table" then
            if held and current.locked==false then
                -- Released natively: on its own deadline the ledger entry is spent too
                -- (the clocks differ by milliseconds at most); on death, vehicle,
                -- workspot or a session change the server gate keeps running and the
                -- entry stays until its own deadline, so a still-authored lock can
                -- resume (a refusal below drops it if it cannot).
                if current.reason=="deadline" then locks[lockFamily(held.kind)]=nil end
                held=nil
            end
            -- The primitive retries the native removal until the body reads clean and
            -- answers `lock_releasing` meanwhile: wait for the next tick instead.
            if current.phase=="releasing" then return end
        end
    end
    local want=nil
    for _,family in ipairs({"freeze","cripple"}) do
        local entry=locks[family]
        if entry and t>=entry.notBefore then want=entry; break end
    end
    if not want then releaseHeld(); return end
    if held and held.kind~=want.kind then releaseHeld() end
    if held and held.kind==want.kind and want.endsAt<=held.endsAt then return end
    local duration=math.floor(math.max(1,want.endsAt-t))
    local request,why=m.lock(want.kind,duration)
    if request then held={kind=want.kind,endsAt=want.endsAt,request=request}
    else
        print("[hacking] movement lock "..want.kind.." for "..duration.." ms refused: "..tostring(why))
        locks[lockFamily(want.kind)]=nil
    end
end
local function releaseLocks()
    locks={}
    releaseHeld()
end
-- Server-authored native statuses on this body: Reboot Optics (`blind`) and Weapon
-- Glitch (`weapon_jam`). The server owns the deadline (and, for the glitch, refuses
-- Gorilla arming `weapon_glitched`); the status itself is the victim's own
-- presentation through `Open77.hacking.nativeStatus` (permission
-- `player.hacking.status`): one Open77 clone of the vanilla record per kind, one
-- independent slot per kind, clamped at 15 s, released by the primitive on death,
-- vehicle, workspot, session change and resource stop. One ledger entry per kind,
-- reconciled on the tick against the primitive's own state:
--   * `effect_applied reason=blind|weapon_jam target=me` applies at once for
--     statusEndsAt - serverTime; a fresh authoritative state (first roster,
--     reconnect, resource reload) re-applies from `activity.blindedMs` /
--     `weaponGlitchedMs`;
--   * a refusal (not_alive, in_vehicle, menu_open, status_busy ...) is logged once
--     and the entry dropped, never retried blindly;
--   * `status_purged` / `status_expired` of the kind, `clear()` and resource stop
--     clear the native status at once rather than at the client deadline;
--   * without the primitive (older DLL) Reboot Optics falls back to a bounded
--     screen-flash burst (`HackingInput.opticsFallback`); Weapon Glitch has no
--     substitute, the server-side Gorilla gate is all that remains.
local statuses,applied={},{}
local STATUS_KINDS={reboot_optics="blind",weapon_glitch="weapon_jam"}
local function statusApi()
    local h=Open77.hacking
    return type(h)=="table" and type(h.nativeStatus)=="function" and type(h.clearNativeStatus)=="function" and h or nil
end
local function statusKind(reason) return (reason=="blind" or reason=="weapon_jam") and reason or nil end
local function clearNative(kind)
    if not applied[kind] then return end
    local h=statusApi()
    if h then pcall(h.clearNativeStatus,kind) end
    applied[kind]=nil
end
local function scheduleStatus(kind,remaining)
    kind=statusKind(kind)
    if not kind then return end
    remaining=tonumber(remaining) or 0
    if remaining<=0 then return end
    local endsAt=now()+remaining
    local current=statuses[kind]
    -- Never shorten a status the server already authored; a longer one replaces it.
    if current and current.endsAt>=endsAt then return end
    statuses[kind]={endsAt=endsAt}
end
-- Reboot Optics without the native primitive: a bounded glitch burst through the
-- native fade (three tinted flashes at onset, one at recovery), documented as a
-- substitute for the `status_blinded` look, never a replacement for it.
local fallbackRunning=false
local function opticsFallback(remaining)
    if input.opticsFallback==false or fallbackRunning or feedback.flash==false then return end
    if type(Open77.screen)~="table" or type(Open77.screen.transition)~="function" then return end
    fallbackRunning=true
    local endsAt=now()+math.max(1000,math.min(15000,remaining))
    CreateThread(function()
        local function flash(hold)
            pcall(Open77.screen.transition,"fade",{durationMs=60,holdMs=hold,fadeInMs=220,timeoutMs=3000,color={r=200,g=240,b=255}})
        end
        for _,hold in ipairs({120,60,160}) do flash(hold); Wait(350) end
        while now()<endsAt-300 and statuses.blind do Wait(100) end
        flash(90)
        fallbackRunning=false
    end)
end
local function reconcileStatuses()
    local h=statusApi()
    local t=now()
    for kind,entry in pairs(statuses) do if t>=entry.endsAt then statuses[kind]=nil; if not h then applied[kind]=nil end end end
    if not h then return end
    if next(applied) and type(h.nativeStatusState)=="function" then
        local ok,current=pcall(h.nativeStatusState)
        if ok and type(current)=="table" then
            for kind in pairs(applied) do
                local slot=current[kind]
                -- Released natively: on its own deadline the ledger entry is spent too
                -- (the clocks differ by milliseconds at most); on death, vehicle,
                -- workspot or a session change the server status keeps running and the
                -- entry stays until its own deadline, so a still-authored status can be
                -- re-applied (a refusal below drops it if it cannot).
                if type(slot)=="table" and slot.applied==false then
                    if slot.reason=="deadline" then statuses[kind]=nil end
                    applied[kind]=nil
                end
            end
        end
    end
    for kind,entry in pairs(statuses) do
        if not applied[kind] then
            local duration=math.floor(math.max(1,entry.endsAt-t))
            local request,why=h.nativeStatus(kind,duration)
            if request then applied[kind]={request=request,endsAt=entry.endsAt}
            elseif why=="status_releasing" then
                -- The primitive retries the native removal until the body reads clean:
                -- wait for the next tick instead of dropping the entry.
            else
                print("[hacking] native status "..kind.." for "..duration.." ms refused: "..tostring(why))
                statuses[kind]=nil
            end
        end
    end
end
local function releaseStatuses()
    statuses={}
    for kind in pairs(applied) do clearNative(kind) end
    applied={}
end
local function clear()
    if dismissWarning then for _,action in pairs(actions) do dismissWarning(action.warning) end end
    state, selected, actions, retired = nil, nil, {}, {}
    hold.active, hold.target, armedShown = false, nil, false
    releaseLocks()
    releaseStatuses()
    api.clear()
end
local function notice(message)
    TriggerEvent("chat:addMessage", {args={"Hacking",message},color={70,220,240}})
end
local function notification(method,...)
    if not Open77.exports or type(Open77.exports.call)~="function" then return nil end
    local promise=Open77.exports.call("open77_notifications",method,...)
    return promise and promise:await() or nil
end
dismissWarning=function(warning)
    if not warning or not warning.handle then return end
    local handle=warning.handle; warning.handle=nil
    CreateThread(function() pcall(notification,"dismiss",handle) end)
end
local function incomingWarning(action)
    local warning={status="pending"}
    action.warning=warning
    local key=Open77.input.keyFor("purge_self") or "INSERT"
    local header="INCOMING "..kindHeader(action.kind)
    local message=header..": break sight/range, interrupt the hacker, or press "..key.." to purge if installed."
    notice(message)
    -- A bounded one-shot cue is independent of stock HUD ownership/admission.
    if Open77.sfx and type(Open77.sfx.play)=="function" then
        Open77.sfx.play("ui_hacking_access_denied",{entity="1",duration=.75})
    end
    api.present({actionId=action.actionId,phase="incoming",progress=0,kind=kindId(action.kind)})
    CreateThread(function()
        local ok,result=pcall(function()
            local surface=notification("readiness")
            if not surface or surface.ready~=true then return nil end
            return notification("show",{id="hacking_"..tostring(action.actionId),type="error",
                title=header,message=message,position="top_right",durationMs=17000,progress=false})
        end)
        warning.status=ok and type(result)=="table" and result.ok==true and "ready" or "failed"
        if warning.status=="ready" then warning.handle=result.handle end
        if not actions[action.actionId] or actions[action.actionId].warning~=warning then dismissWarning(warning) end
        if warning.status=="failed" then notice("Incoming hack refused: warning surface unavailable.") end
    end)
end
-- Victim-side cue: the installed hit sound of the kind on the local body.
-- The sounds are the SFX names of the installed BaseStatusEffect.Overload /
-- Overheat / CyberwareMalfunction / WeaponMalfunction records and the
-- `quickhack_locomotion_malfunction` / `quickhack_optics_malfunction` daemon events
-- (TweakDB CName inventory and the WolvenKit sound-event seed, both audited).
-- Playback is bounded and gated: no `world.effects` grant simply means no
-- cue. `unique` keeps a second start of the same Wwise event from stacking on the
-- server-authored body sound when both land on this client.
local CUES={
    short_circuit={sound="quickhack_shortcircuit"},
    overheat={sound="quickhack_overheat"},
    malfunction={sound="quickhack_cyberware_malfunction"},
    cripple={sound="quickhack_locomotion_malfunction"},
    reboot_optics={sound="quickhack_optics_malfunction"},
    weapon_glitch={sound="quickhack_weapon_malfunction"},
}
local function shockCue(kind)
    local cue=CUES[kind] or CUES.short_circuit
    -- The quest fade used for the old shock flash interrupts the victim's
    -- native knockdown (paired live controls, 2026-09-29). Keep combat feedback
    -- on the body/HUD/audio paths; a screen transition is not a harmless overlay.
    if feedback.sound~=false and Open77.sfx and type(Open77.sfx.play)=="function" then
        Open77.sfx.play(cue.sound,{entity="1",unique=true,duration=1.5})
    end
end
-- The activation lease for beginning an upload.
--
-- It does NOT shorten the upload: the duration is set server-side, in Evidence,
-- and is untouched. What it removes is the round trip on the INPUT path, and
-- what it buys is a range test judged at the instant the player pressed rather
-- than a third of a second later, by which time both players have moved.
local uploadLease
-- A remaining lifetime; the session clock is frozen at the Welcome packet.
local function leaseTtl(ttlMs)
    if type(ttlMs)~="number" or ttlMs~=ttlMs then return end
    local ttl=math.floor(ttlMs)
    if ttl<=0 or ttl>30000 then return end
    return ttl
end
RegisterNetEvent("open77:leases:grant",function(v)
    if type(v)~="table" or v.ability~="hack_upload" then return end
    if not state or v.incarnation~=state.incarnation then return end
    if type(v.leaseId)~="string" or #v.leaseId~=32 then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    uploadLease={id=v.leaseId,epoch=v.epoch or 0,budget=v.budget or 1,remaining=v.budget or 1,
        deadline=(Open77.time.monotonic()*1000)+ttl}
end)
RegisterNetEvent("open77:leases:refresh",function(v)
    if type(v)~="table" or v.ability~="hack_upload" or not uploadLease then return end
    if v.leaseId~=uploadLease.id or v.epoch~=uploadLease.epoch then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    local remaining=tonumber(v.remaining) or 0
    if remaining<0 then remaining=0 elseif remaining>uploadLease.budget then remaining=uploadLease.budget end
    uploadLease.remaining=remaining
    local deadline=(Open77.time.monotonic()*1000)+ttl
    if deadline>uploadLease.deadline then uploadLease.deadline=deadline end
end)
RegisterNetEvent("open77:leases:revoke",function(v)
    if type(v)~="table" or v.ability~="hack_upload" then return end
    uploadLease=nil
end)
local function uploadSpendable()
    if not uploadLease or uploadLease.remaining<=0 then return false end
    local net=Open77.network.status()
    if not net or net.phase~="active" then return false end
    return (Open77.time.monotonic()*1000)<uploadLease.deadline
end
local function intent(kind, target, definition)
    if not state or type(definition) ~= "table" then notice("Required implant is not ready."); return false end
    if not integer(target) then notice("Aim at a visible player in range."); return false end
    if kind=="start" and uploadSpendable() then
        uploadLease.remaining=uploadLease.remaining-1
        TriggerServerEvent("open77:hacking:startReport", {incarnation=state.incarnation,
            sequence=nextSequence(),target=target,definition=definition.definition,grade=definition.grade,
            lease=uploadLease.id,epoch=uploadLease.epoch,ageMs=0})
        return true
    end
    TriggerServerEvent("open77:hacking:" .. kind, {incarnation=state.incarnation,
        sequence=nextSequence(),target=target,definition=definition.definition,grade=definition.grade})
    return true
end
local function cancelOwnUploads()
    if not state then return 0 end
    local mine,count=me(),0
    for id, action in pairs(actions) do
        if action.attacker == mine then
            -- Do not refute a fired prediction here: the server may already
            -- have committed the impact. Its cancelled/interrupted transition
            -- refutes it if the cancel wins (code review #12).
            TriggerServerEvent("open77:hacking:cancel", {incarnation=state.incarnation,actionId=id})
            count=count+1
        end
    end
    return count
end
local function disarm()
    hold.active, hold.target = false, nil
    if armedShown then api.clear(); armedShown=false end
end
local function releaseHold()
    if not hold.active then return end
    disarm()
    cancelOwnUploads()
end
RegisterKeyMapping("short_circuit", "Hacking: hold to upload the installed hack on the aimed player", input.hack or "F8", function()
    if hold.active then return end
    if not state or type(state.hack)~="table" then notice("Required implant is not ready."); return end
    if not integer(selected) then
        notice("Aim at a visible player in range, then hold "..tostring(Open77.input.keyFor("short_circuit") or input.hack or "F8")..".")
        return
    end
    hold.active, hold.target, hold.since = true, selected, now()
    intent("start", selected, state.hack)
end, function() releaseHold() end)
RegisterKeyMapping("purge_self", "Hacking: purge yourself", input.purgeSelf or "INSERT", function()
    intent("purge", me(), state and state.purge)
end)
RegisterKeyMapping("purge_ally", "Hacking: purge aimed ally", input.purgeAlly or "DELETE", function()
    intent("purge", selected, state and state.purge)
end)
RegisterKeyMapping("cancel_hack", "Hacking: cancel own upload", input.cancel or "END", function()
    if not state then return end
    disarm()
    cancelOwnUploads()
end)
RegisterNetEvent("open77:hacking:state", function(value)
    if type(value) ~= "table" or type(value.epoch) ~= "string" or not integer(value.revision)
        or type(value.incarnation) ~= "string" or #value.incarnation ~= 32 then return end
    if retiredEpochs[value.epoch] then return end
    if epoch ~= value.epoch then
        if epoch then
            local count=0; for _ in pairs(retiredEpochs) do count=count+1 end
            if count>=16 then clear(); return end -- reconnect required after repeated authority replacements
            retiredEpochs[epoch]=true
        end
        clear(); epoch, revision, transitionRevision = value.epoch, 0, 0
    end
    if value.revision <= revision then return end
    if value.ready == false then clear(); revision=value.revision; return end
    if state and state.incarnation ~= value.incarnation then clear() end
    local resync=state==nil
    revision, state = value.revision, value
    local activity=type(value.activity)=="table" and value.activity or {}
    local floor=activity.clientSequence
    if integer(floor) and floor<=4294967295 then sequence=math.max(sequence,floor) end
    -- A fresh authoritative view of this body (first roster, reconnect, resource
    -- reload): the server gates survived on the durable identity / the status, the
    -- client lock did not (it releases on session change). Re-lock for the remaining
    -- time; no knockdown is in flight here, so no delay.
    if resync then
        scheduleLock("freeze",activity.frozenMs)
        scheduleLock(activity.crippleHeavy==true and "cripple_heavy" or "cripple",activity.crippledMs)
        reconcileLocks()
        scheduleStatus("blind",activity.blindedMs)
        scheduleStatus("weapon_jam",activity.weaponGlitchedMs)
        reconcileStatuses()
    end
end)
local messages = {blocked="Self-ICE blocked the upload.",interrupted="Upload interrupted.",
    status_purged="Purge removed the remaining disruption.",
    purged="Purge completed.",rejected="Hacking action refused."}
local function impactMessage(kind)
    if kind=="overheat" then return "Overheat connected." end
    if kind=="malfunction" then return "Cyberware Malfunction connected." end
    if kind=="cripple" then return "Cripple Movement connected." end
    if kind=="reboot_optics" then return "Reboot Optics connected." end
    if kind=="weapon_glitch" then return "Weapon Glitch connected." end
    return "Short Circuit connected."
end
-- Server-applied outcomes (`effects` on the grade, plus the Overheat burn and the
-- Malfunction suppression). Reason names the outcome; Amount is the configured
-- milliseconds; `blocks` lists the suppressed abilities. Presented as text plus a
-- victim toast whose countdown bar shows the remaining time: the authority already
-- moved the body, gated the abilities or started the burn, and the HUD bar kinds
-- are fixed in the client DLL.
local effectMessages={freeze="Systems frozen",knockdown="Knocked down",disable_cyberware="Cyberware disabled",
    burn="Overheating",malfunction="Cyberware malfunction",cripple="Movement crippled",cripple_heavy="Movement crippled (heavy)",
    blind="Optics rebooting",weapon_jam="Weapon glitched"}
local PURGEABLE={burn=true,malfunction=true,cripple=true,cripple_heavy=true,blind=true,weapon_jam=true}
local function effectNotice(value)
    local label=effectMessages[value.reason] or ("Effect "..tostring(value.reason))
    local ms=tonumber(value.amount) or 0
    local mine=me()
    local who=value.target==mine and "You" or ("Player "..tostring(value.target))
    local detail=""
    if value.reason=="malfunction" then detail=" - "..abilityList(value.blocks).." suppressed" end
    if value.reason=="cripple" or value.reason=="cripple_heavy" then
        detail=" - "..(value.reason=="cripple_heavy" and "speed x0.4" or "speed x0.75")..", no dodge, "..abilityList(value.blocks).." refused"
    end
    if value.reason=="blind" then detail=" - vision and scanner disrupted" end
    if value.reason=="weapon_jam" then detail=" - weapon jammed, "..abilityList(value.blocks).." refused" end
    local text=who..": "..label..detail..(ms>0 and (" for "..string.format("%.1f",ms/1000).." s") or "")
    if value.target==mine and value.phase=="effect_applied" and PURGEABLE[value.reason] then
        text=text..". Press "..tostring(Open77.input.keyFor("purge_self") or input.purgeSelf or "INSERT").." to purge if installed."
    end
    if value.phase=="effect_refused" then
        local remaining=tonumber(value.statusEndsAt) and tonumber(value.serverTime) and (value.statusEndsAt-value.serverTime) or 0
        text=who..": "..label..(remaining>0 and (" already running, "..string.format("%.1f",remaining/1000).." s left.")
            or " refused by the server.")
    end
    notice(text)
    if value.phase=="effect_applied" and value.target==mine then
        CreateThread(function()
            pcall(function()
                local surface=notification("readiness")
                if not surface or surface.ready~=true then return end
                notification("show",{id="hacking_effect_"..tostring(value.actionId).."_"..tostring(value.reason),type="error",
                    title=kindHeader(value.kind),message=text,position="top_right",
                    durationMs=math.max(1500,math.min(30000,ms>0 and ms or 1500)),progress=ms>0})
            end)
        end)
    end
end
RegisterNetEvent("open77:hacking:result",function(result)
    if not state or type(result)~="table" or result.incarnation~=state.incarnation then return end
    if result.ok~=true then
        local reasons={insufficient_stamina="Not enough stamina.",cooldown="Hacking ability is cooling down.",
            nothing_to_purge="No eligible upload or disruption to purge.",purge_target_denied="This player is not an eligible ally in range.",
            recovery_protected="Target is recovering from a recent hack.",implant_unavailable="Required implant is unavailable.",
            target_unavailable="Target is unavailable.",visibility_lost="Target is behind cover.",
            cyberware_suspended="Your cyberware is malfunctioning.",frozen="Your systems are frozen."}
        notice(reasons[result.error] or ("Action refused: "..tostring(result.error or "unavailable")))
        -- A refused start closes the armed panel; the key must be pressed again.
        if result.operation==nil or result.operation=="start" or result.operation=="open77:hacking:start"
            or result.operation=="open77:hacking:startReport" then disarm() end
    elseif result.operation=="purge" or result.operation=="open77:hacking:purge" then
        notice("Purge completed. Committed damage is unchanged.")
        api.present({actionId=math.max(1,tonumber(result.actionId) or tonumber(result.sequence) or 1),phase="purge",progress=1,kind=kindId(ownKind())})
        feedbackUntil=now()+900
        armedShown=false
    end
end)
-- Only an admitted outgoing upload gets this short-lived deadline coroutine.
-- The ordinary 100 ms evidence/UI loop and its server traffic stay unchanged.
local function predictReaction(current)
    if not state or current.predicted or current.attacker~=me() or not hold.active then return end
    current.predicted=true
    local hack=state.hack
    if not hack or hack.predictKnockdown~=true or hack.definition~=current.definition
        or hack.grade~=current.grade or current.phase=="challenge" then return end
    local seen=api.observe(current.target)
    if not seen or not seen.streamed or not seen.visible or seen.distance>hack.range then return end
    local function playerPosition(player)
        local entity=Open77.players.entity(player)
        if entity==nil then return end
        local x,y,z=Open77.character.position(entity)
        return {x=x,y=y,z=z}
    end
    local a,b=playerPosition(current.attacker),playerPosition(current.target)
    if not point(a) or not point(b) then return end
    local ray=Open77.world.raycast({x=a.x,y=a.y,z=a.z+1},{x=b.x,y=b.y,z=b.z+1})
    if not ray or ray.hit~=false then return end
    TriggerEvent("open77_prediction:hack",current.target,tostring(current.actionId),b.x-a.x,b.y-a.y,hack.predictedDamage)
end
local function predictUpload(action)
    if action.predictionScheduled or not state.hack or state.hack.predictKnockdown~=true then return end
    action.predictionScheduled=true
    local id,incarnation=action.actionId,state.incarnation
    CreateThread(function()
        while state and state.incarnation==incarnation do
            local current=actions[id]
            if not current or current.attacker~=me() or not hold.active or current.predicted then return end
            local remaining=current.predictionDeadline-now()
            if remaining<=0 then
                predictReaction(current)
                return
            end
            -- Sleep until close to the deadline, then align with game frames.
            Wait(remaining>50 and math.floor(remaining-25) or 0)
        end
    end)
end
RegisterNetEvent("open77:hacking:transition", function(value)
    if not state or type(value) ~= "table" or not integer(value.actionId) or type(value.phase) ~= "string" then return end
    if value.epoch~=epoch or not integer(value.revision) or value.revision<=transitionRevision then return end
    local mine = me()
    local incarnation = mine == value.attacker and value.attackerIncarnation or value.targetIncarnation
    if (mine ~= value.attacker and mine ~= value.target) or incarnation ~= state.incarnation then return end
    transitionRevision=value.revision
    -- effect_refused names the refused effect: only a refused knockdown or
    -- freeze refutes the predicted fall; a stacking refusal (cripple, burn)
    -- leaves the knockdown to its own effect_applied (code review #12).
    if mine==value.attacker and (value.phase=="interrupted" or value.phase=="blocked"
        or (value.phase=="effect_refused" and (value.reason=="knockdown" or value.reason=="freeze"))
        or value.phase=="cancelled" or value.phase=="rejected") then
        TriggerEvent("open77_prediction:cancel","hack",tostring(value.actionId),value.target)
    end
    local old = actions[value.actionId]
    if retired[value.actionId] and (value.phase == "challenge" or value.phase == "upload_started" or value.phase == "upload_progress") then return end
    if value.phase == "challenge" or value.phase == "upload_started" or value.phase == "upload_progress" then
        local count=0; for _ in pairs(actions) do count=count+1 end
        if not old and count >= 8 then return end
        value.receivedAt = now()
        value.localDeadline = now() + math.max(0, math.min(17000, (value.deadline or 0) - (value.serverTime or 0)))
        -- Estimate transit only for speculative pose timing; never feed it to
        -- evidence or authority. Bound a stale/high RTT estimate to 250 ms.
        local ping=tonumber((Open77.network.status() or {}).ping) or 0
        value.predictionDeadline=value.localDeadline-math.max(0,math.min(250,ping/2))
        if old then
            -- A progress packet with more transit delay must not push the same
            -- server completion later. A changed authority deadline still resets it.
            if old.deadline==value.deadline and old.predictionDeadline then
                value.predictionDeadline=math.min(value.predictionDeadline,old.predictionDeadline)
            end
            value.from, value.to = value.from or old.from, value.to or old.to
            value.nonce = value.nonce or old.nonce
            -- When the nonce is unchanged this is a progress update, not a new
            -- challenge, so the challenge receipt instant must be carried over:
            -- the elapsed time the server reconciles against is measured from
            -- the challenge that issued THIS nonce, not from the last packet.
            if value.nonce == old.nonce then value.nonceReceivedAt = old.nonceReceivedAt end
            value.warning=old.warning
            value.blockedTraceReported=old.blockedTraceReported
            value.predictionScheduled,value.predicted=old.predictionScheduled,old.predicted
            if value.phase=="challenge" and old.phase~="challenge" then value.phase=old.phase end
        end
        value.nonceReceivedAt = value.nonceReceivedAt or now()
        actions[value.actionId] = value
        if value.attacker==mine and value.phase~="challenge" then predictUpload(value) end
        if value.target==mine and not value.warning then incomingWarning(value) end
        -- The key was released before the server opened this upload: cancel it
        -- through the ordinary cancel path rather than let it run unattended.
        if value.attacker==mine and not hold.active and not old then
            TriggerServerEvent("open77:hacking:cancel", {incarnation=state.incarnation,actionId=value.actionId})
        end
    elseif value.phase=="effect_applied" or value.phase=="effect_refused" then
        effectNotice(value)
        if value.phase=="effect_applied" and value.target==mine then
            if value.reason=="freeze" then
                -- The server requested the stationary knockdown before reporting the
                -- freeze: let the floor reaction end, then lock for what remains.
                local delay=math.max(0,math.min(10000,tonumber(input.freezeAfterKnockdownMs) or 3000))
                scheduleLock("freeze",remainingOf(value),now()+delay)
            elseif value.reason=="cripple" or value.reason=="cripple_heavy" then
                scheduleLock(value.reason,remainingOf(value))
                reconcileLocks()
            elseif value.reason=="blind" or value.reason=="weapon_jam" then
                scheduleStatus(value.reason,remainingOf(value))
                if statusApi() then reconcileStatuses()
                elseif value.reason=="blind" then opticsFallback(remainingOf(value)) end
            end
        end
    elseif value.phase=="status_tick" then
        -- One burn tick: the authority already debited the ledger; nothing to present
        -- beyond the running body layers and the toast countdown.
        return
    else
        -- Network events can run before deadline coroutines on the same frame.
        -- Preserve the admitted upload's one presentation attempt before retiring
        -- it; the victim's native lease can still be pending or later refuse it.
        if value.phase=="impact" and old then pcall(predictReaction,old) end
        if old then dismissWarning(old.warning) end
        actions[value.actionId] = nil
        if value.phase ~= "impact" and value.phase ~= "status_applied" then
            local count=0; for _ in pairs(retired) do count=count+1 end
            if count >= 256 then clear(); return end
            retired[value.actionId]=now()+60000
        end
        if value.phase=="impact" then notice(impactMessage(value.kind))
        elseif messages[value.phase] then notice(messages[value.phase] .. (value.reason and (" "..value.reason) or "")) end
        -- The cripple ends with its status (purge, expiry, lifecycle): release the lock
        -- at once rather than at the client deadline.
        if value.target==mine and value.kind=="cripple" and (value.phase=="status_purged" or value.phase=="status_expired") then
            locks.cripple=nil; reconcileLocks()
        end
        -- Same for a blind or a jam: the native status ends with the server status.
        if value.target==mine and STATUS_KINDS[value.kind] and (value.phase=="status_purged" or value.phase=="status_expired") then
            statuses[STATUS_KINDS[value.kind]]=nil; clearNative(STATUS_KINDS[value.kind])
        end
        local phases={blocked="block",impact="impact",status_purged="purge",purged="purge",interrupted="cancel"}
        if phases[value.phase] then api.present({actionId=value.actionId,phase=phases[value.phase],progress=1,kind=kindId(value.kind)}) end
        if value.phase=="impact" and value.target==mine then shockCue(value.kind) end
        -- Terminal for the hacker's own upload: the held key no longer arms anything
        -- until it is pressed again.
        if value.attacker==mine and hold.active then hold.active, hold.target = false, nil end
        feedbackUntil=now()+900
        armedShown=false
    end
end)
exports("selection", function() return selected end)
exports("holding", function() return hold.active end)
exports("lockState", function()
    local m=movementApi()
    local native=m and type(m.lockState)=="function" and select(2,pcall(m.lockState)) or nil
    local ledger={}
    for family,entry in pairs(locks) do ledger[family]={kind=entry.kind,remainingMs=math.max(0,entry.endsAt-now()),pending=now()<entry.notBefore} end
    return {held=held and held.kind or nil,ledger=ledger,native=type(native)=="table" and native or nil}
end)
exports("statusState", function()
    local h=statusApi()
    local native=h and type(h.nativeStatusState)=="function" and select(2,pcall(h.nativeStatusState)) or nil
    local ledger={}
    for kind,entry in pairs(statuses) do ledger[kind]={remainingMs=math.max(0,entry.endsAt-now()),applied=applied[kind]~=nil} end
    return {ledger=ledger,native=type(native)=="table" and native or nil,fallback=fallbackRunning}
end)
exports("capabilities", function()
    return {schemaVersion=5,profile=ownKind(),kinds=KINDS,ready=state ~= nil,
        nativePresentation=type(api.present)=="function",kindHeaders=true,
        movementLock=movementApi()~=nil,nativeStatus=statusApi()~=nil,
        visualProof=false,realTimeTargeting=true,holdToHack=true,evidence="bilateral_server_endpoints"}
end)
CreateThread(function()
    local requests,lastSelected,lastNotice=0,nil,0
    while true do
        local session=Open77.network.status()
        if not session or session.phase ~= "active" then
            if state or epoch then clear(); epoch, revision, transitionRevision, retiredEpochs = nil, 0, 0, {} end
        else
            if requests % 10 == 0 then TriggerServerEvent("open77:hacking:request") end
            requests=requests+1
            for id,expiry in pairs(retired) do if now() >= expiry then retired[id]=nil end end
            selected=nil
            reconcileLocks()
            reconcileStatuses()
            if state then
                local maxRange=math.max(state.hack and state.hack.range or 0,state.purge and state.purge.range or 0)
                local best=math.max(.02,math.min(.35,tonumber(input.targetConeRadians) or .15))
                for index, player in ipairs(state.candidates or {}) do
                    if index > 32 then break end
                    local observation=api.observe(player)
                    if observation and observation.streamed and observation.visible and observation.distance <= maxRange
                        and observation.angle < best then selected,best=player,observation.angle end
                end
                -- Aiming draws nothing on the HUD. The only hint is one throttled chat
                -- line naming the target and the keys to hold/press.
                if selected and selected ~= lastSelected and now()-lastNotice >= 1000 then
                    local choices={}
                    if state.hack then choices[#choices+1]="hold "..tostring(Open77.input.keyFor("short_circuit") or "F8").." "..kindLabel(state.hack.kind) end
                    if state.purge then choices[#choices+1]=tostring(Open77.input.keyFor("purge_ally") or "DELETE").." ally purge" end
                    notice("Target "..tostring(selected).." - "..table.concat(choices," / "))
                    lastSelected,lastNotice=selected,now()
                end
                local mine=tonumber(session.playerId)
                local presentation
                for id, action in pairs(actions) do
                    if now() >= action.localDeadline + 1000 then dismissWarning(action.warning); actions[id]=nil; api.clear()
                    else
                        -- Endpoints and nonce originate on server. Missing/failed physics is blocked.
                        local ray
                        if point(action.from) and point(action.to) then ray=Open77.world.raycast(action.from,action.to) end
                        -- One bounded diagnostic per active action distinguishes a real
                        -- native collider hit from an unavailable query or warning veto.
                        if ray and ray.hit==true and not action.blockedTraceReported then
                            action.blockedTraceReported=true
                            print("[hacking evidence] action="..tostring(id).." nativeRayHit=true")
                        end
                        local warning=action.target==mine and action.warning or nil
                        -- Positive defender evidence requires an admitted independent warning.
                        -- A pending export cannot silently permit impact; challenge timeout remains authoritative.
                        if not warning or warning.status~="pending" then
                            -- `sinceChallengeMs` is this client's OWN elapsed time
                            -- between receiving the challenge and looking. It carries
                            -- no clock and no one-way delay, which is the only way the
                            -- server can compare the two halves of a bilateral round
                            -- in a single domain. `ageMs` is zero: the observation is
                            -- reported in the tick that made it.
                            local sinceChallenge = 0
                            if action.nonceReceivedAt then
                                sinceChallenge = math.max(0, math.floor(now() - action.nonceReceivedAt))
                            end
                            TriggerServerEvent("open77:hacking:evidence", {incarnation=state.incarnation,
                                sequence=nextSequence(),actionId=id,nonce=action.nonce,ageMs=0,
                                sinceChallengeMs=sinceChallenge,
                                clear=(not warning or warning.status=="ready") and ray ~= nil and ray.hit == false})
                        end
                        if action.phase ~= "challenge" and (not presentation or id < presentation.actionId) then presentation=action end
                    end
                end
                -- The armed panel is bounded: a start the server never answers closes it.
                if hold.active and now()-hold.since > 4000 then
                    local own=false
                    for _,action in pairs(actions) do if action.attacker==mine then own=true; break end end
                    if not own then disarm() end
                end
                if presentation then
                    local duration=math.max(1,(presentation.deadline or 0)-(presentation.startedAt or 0))
                    api.present({actionId=presentation.actionId,phase=presentation.target==mine and "incoming" or "upload",
                        progress=math.max(0,math.min(1,1-(presentation.localDeadline-now())/duration)),kind=kindId(presentation.kind)})
                    armedShown=false
                elseif now() >= feedbackUntil then
                    if hold.active and integer(hold.target) then
                        api.present({actionId=hold.target,phase="targeting",progress=0,kind=kindId(ownKind())})
                        armedShown=true
                    elseif armedShown then api.clear(); armedShown=false end
                end
            end
        end
        Wait(100)
    end
end)
AddEventHandler("onClientResourceStop",function(name) if name==GetCurrentResourceName() then clear() end end)
