-- Public authority events -> existing owned, streamed, incarnation-bound effects.
-- TweakDB confirms the owner events/audio. Observer depot positioning needs live proof.
--
-- One connected hack projects a few bounded layers on the victim's body so the hit
-- reads on camera, not only in chat. The layers follow the hack `kind` the
-- transition carries (`short_circuit`, `overheat`, `malfunction`, `cripple`,
-- `reboot_optics`, `weapon_glitch`):
--   * Short Circuit: the cooked electrocuted status effect on RightHand (live-reviewed
--     sparks on both body families) with the target's own view driven by the
--     entity-authored `status_electrocuted` event, exactly as the native Overload
--     package does; the same effect on Chest, the slot the native Overload attack
--     resolves on the puppet (installed TweakDB evidence); and the catalog
--     `electric.arc` device arc on RightHand as a brighter second layer.
--   * Overheat: no cooked character burn resource exists by name in the installed
--     archives (docs/research/native-hacking.md, 2026-09-14 audit), so observers get
--     the closest audited substitutes -- the catalog `fire.tiny` idle flame and the
--     `smoke.steam` pouring steam, both on Chest -- while the victim's own view asks
--     for the authored `hacks_overheat_lvl1` event, the VFX name of the installed
--     `BaseStatusEffect.Overheat` record. Sound: `quickhack_overheat`, the SFX of
--     that same record. Layers live for the whole burn.
--   * Malfunction: the cooked EMP character status effect on Chest (the native
--     "cyberware disabled" look; archive-indexed) with the victim's own view asking
--     for the authored `hacks_cyberware_malfunction` event (VFX name of
--     `BaseStatusEffect.CyberwareMalfunction`), plus the catalog `sparks.cable`
--     electric-failure sparks on RightHand. Live at 06:42 on 2026-09-14 that pair read
--     as a few small sparks from 4 m, so the proven electrocuted status effect (the
--     Short Circuit layer, live-reviewed on both body families) is added on Chest and
--     RightHand for the whole suppression. Sound: `quickhack_cyberware_malfunction`.
--   * Cripple Movement: sound only (`quickhack_locomotion_malfunction`, the daemon
--     event of the TweakDB CName inventory and the WolvenKit seed). The victim's own
--     view is the `hacking_glitch_low` entity effect the cripple clone starts on the
--     player itself (`AIQuickHackStatusEffect.HackLocomotion` package A), plus the
--     native crippled HUD icon; no observer body layer, because no leg slot has been
--     proven on a multiplayer puppet (`RightHand` and `Chest` are the only ones) and
--     an unproven slot is refused by the projector anyway.
--   * Reboot Optics: the victim's own view is the native `status_blinded` VFX/SFX
--     and `hacking_glitch_low` the blind clone (`AIQuickHackStatusEffect.HackBlind`)
--     starts on the player itself, plus the native blinded HUD icon; observers get
--     the catalog `electric.arc` on Chest for the whole blind (no head slot is proven
--     on a multiplayer puppet) and the `quickhack_optics_malfunction` daemon event
--     (TweakDB CName inventory).
--   * Weapon Glitch: the victim's own view is the jam clone
--     (`BaseStatusEffect.WeaponMalfunction`: weapon not-ready, `hacks_weapon_malfunction`)
--     plus the native jammed-weapon HUD icon; observers get the proven electrocuted
--     status effect and the catalog `sparks.cable` on RightHand -- the hand that holds
--     the weapon -- for the whole jam. Sound: `quickhack_weapon_malfunction`, the SFX
--     of the installed WeaponMalfunction record.
-- Everything is capped: at most #layers handles per action, MAX_ACTIVE handles in
-- total, one lease per status bounded by the kind's ceiling, and one audited hit
-- sound deduplicated per action. The projector refuses an absent slot or an
-- unauthored local event, so a missing binding costs nothing.
local active,seen={},{}
local electric="base\\fx\\characters\\npc\\_common\\status_effects\\electricuted\\ch_electricuted_status_effect.effect"
local emp="base\\fx\\characters\\npc\\_common\\status_effects\\emp\\ch_emp_status_effect.effect"
local KINDS={
    short_circuit={maxMs=2000,sound="quickhack_shortcircuit",layers={
        {effect=electric,slot="RightHand",localEvent="status_electrocuted"},
        {effect=electric,slot="Chest"},
        {effect="electric.arc",slot="RightHand"},
    }},
    overheat={maxMs=15500,sound="quickhack_overheat",layers={
        {effect="fire.tiny",slot="Chest",localEvent="hacks_overheat_lvl1"},
        {effect="smoke.steam",slot="Chest"},
    }},
    malfunction={maxMs=30500,sound="quickhack_cyberware_malfunction",layers={
        {effect=emp,slot="Chest",localEvent="hacks_cyberware_malfunction"},
        {effect=electric,slot="Chest"},
        {effect=electric,slot="RightHand"},
        {effect="sparks.cable",slot="RightHand"},
    }},
    cripple={maxMs=30500,sound="quickhack_locomotion_malfunction",layers={}},
    reboot_optics={maxMs=15500,sound="quickhack_optics_malfunction",layers={
        {effect="electric.arc",slot="Chest"},
    }},
    weapon_glitch={maxMs=15500,sound="quickhack_weapon_malfunction",layers={
        {effect=electric,slot="RightHand"},
        {effect="sparks.cable",slot="RightHand"},
    }},
}
local IMPACT_MS,MAX_ACTIVE=1500,24
local function profile(kind) return KINDS[kind] or KINDS.short_circuit end
local function retire(id)
    local item=active[id]
    if not item then return end
    for _,handle in ipairs(item.handles) do Open77.effects.remove(handle) end
    active[id]=nil
end
local function activeHandles()
    local count=0
    for _,item in pairs(active) do count=count+#item.handles end
    return count
end
local function attach(id,value,duration)
    local kind=profile(value.kind)
    local target={kind="player",id=tostring(value.target)}
    local handles={}
    for _,layer in ipairs(kind.layers) do
        if activeHandles()+#handles>=MAX_ACTIVE then break end
        local handle=Open77.effects.attach(target,layer.effect,{slot=layer.slot,localEvent=layer.localEvent,
            ttlMs=duration,streamingRadius=90,streamingHysteresis=20})
        if handle then handles[#handles+1]=handle end
    end
    if #handles>0 then active[id]={handles=handles,expires=GetGameTimer()+duration} end
end
local function sound(id,value)
    if seen[id] then return end
    local count=0; for _ in pairs(seen) do count=count+1 end
    if count>=512 then return end
    seen[id]=GetGameTimer()+60000
    Open77.effects.sound({kind="player",id=tostring(value.target)},profile(value.kind).sound,
        {duration=1.5,actionId="hacking:"..tostring(id)..":impact"})
end
AddEventHandler("onHackingTransition",function(encoded)
    local ok,value=pcall(json.decode,encoded)
    if not ok or type(value)~="table" or type(value.actionId)~="number" or type(value.target)~="number" then return end
    local id,phase=value.actionId,value.phase
    if phase=="status_expired" or phase=="status_purged" or phase=="interrupted" then retire(id); return end
    if phase~="impact" and phase~="status_applied" then return end
    local kind=profile(value.kind)
    local current=Open77.hacking.state(value.target)
    if not current or not current.ready or current.incarnation~=value.targetIncarnation then return end
    if phase=="status_applied" then
        local duration=math.max(1,math.min(kind.maxMs,(value.statusEndsAt or 0)-GetGameTimer()))
        if active[id] then
            -- Short Circuit: the impact layers already run; stretch them to the status end.
            for _,handle in ipairs(active[id].handles) do Open77.effects.update(handle,{ttlMs=duration}) end
            active[id].expires=GetGameTimer()+duration
        else
            -- Overheat / Malfunction (and a scripted status): one lease for the whole
            -- status, created once so the particles never restart on a renewal.
            attach(id,value,duration)
        end
        sound(id,value)
        return
    end
    -- impact: the electrical hit shows at once (once per action); the other kinds
    -- wait for their status so a refused (stacked) burn or malfunction only plays
    -- the hit sound.
    if (value.kind==nil or value.kind=="short_circuit") and not active[id] and not seen[id] then attach(id,value,IMPACT_MS) end
    sound(id,value)
end)
CreateThread(function()
    while true do
        local now=GetGameTimer()
        for id,item in pairs(active) do if now>=item.expires then retire(id) end end
        for id,expiry in pairs(seen) do if now>=expiry then seen[id]=nil end end
        Wait(100)
    end
end)
AddEventHandler("onResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    for id in pairs(active) do retire(id) end
end)
