-- Reflex overdrive, as OTHER players see it.
--
-- The client primitive makes a body faster. On every other screen that is all a
-- boosted player was: a faster body. This script is the answer to "what did that
-- guy just do to me", and it is server-authored on purpose -- the same shape as
-- `open77_hacking/server/presentation.lua`, through the same public
-- `Open77.effects` surface, with the same bounded leases and handle caps.
--
-- WHAT IS NOT HERE, AND WHY (the audit is in docs/research/native-sandevistan.md,
-- section "Observer-presentation audit -- 2026-09-15"):
--
--   * No vanilla Sandevistan asset is reused, because none exists for a player.
--     `sandevistan` matches zero of the 101 553 cooked paths in the archive
--     listing and zero `.effect` rows of `docs/generated/vfx-assets-2.31.csv`.
--     In the installed 2.31 `tweakdb.bin` (176 198 records, 2 880 555 flats) the
--     names `fx_sandevistan_trails*`, `fx_sandevistan_loop`, `sandevistan_loop`
--     and `sandevistan_high|low|medium_00..03` exist only as `.name` on leaf
--     records that no status effect, package or effector references; the
--     decompiled `AdamSmasherHealthChangeListener.DisableAllSandyEdgerunnerFxs`
--     breaks them as replicated effect loops on Adam Smasher. NPC-side, both
--     times, by two independent methods.
--   * No camera grade. The vanilla look is `SetCameraTimeDilationCurve`, which
--     samples against a time dilation that this feature refuses to create.
--   * No full-screen effect on an observer. A cue that says "someone else is
--     fast" must live on that someone else's body, never on the watcher's eyes.
--
-- SO THIS IS AN OPEN77 PRESENTATION, NOT A REPLICA. Every layer below is a
-- catalog alias whose depot path is a row of `docs/generated/vfx-assets-2.31.csv`,
-- attached to a slot both player proxy bodies author
-- (`assets/wolvenkit/cyberm/entities/player_proxy_{ma,wa}*.ent.json`).
--
-- The layers were chosen by a measured sweep, not by their names. On
-- 2026-09-15 nine candidates were attached one at a time to a body 5 m from a
-- second client, in fog and again under pinned clear night, and photographed:
--
--   * `neon.loot_drop` on `Chest` -- the ONE alias that reads unmistakably in a
--     still: a blue volumetric glow wrapping the body. It is a light rather
--     than a particle, which is also why it is the layer expected to survive
--     distance where particles subtend nothing.
--   * `electric.industrial_arm` on `Chest` and `sparks.welding` on both feet --
--     the original texture layers, a few bright sparks at close range; kept
--     because they are proven, not because they carry the read.
--   * `cyber.trail_electric` on both heels -- a katana swing trail is the only
--     ribbon the inventory authors; it only draws when the emitter MOVES, so a
--     still cannot judge it and it is carried at nil cost.
--   * `reflex_heavy` adds `electric.arc` on `RightHand`, so the tiers differ.
--
-- What the sweep ruled OUT, so nobody re-adds them by name: the character
-- status-effect sheets `cyber.emp_body` and `cyber.electrocuted_body`, the EMP
-- sizes `electric.emp{,.big}`, the blade idles and `electric.arc` alone all
-- rendered nothing visible on a slot at 5 m in either lighting; and
-- `cyber.emp_blast` as the activation flash is a generator explosion -- a black
-- smoke cloud that swallows the body -- so the start burst is the proven
-- `sparks.burst.large` again.
--
-- The loud activation is `w_cyb_berserker_activate` / `w_cyb_berserker_deactivate`,
-- the `activationSFXName` / `deactivationSFXName` of the `PlaySFXEffector`
-- (`unique = true`) in the package of `BaseStatusEffect.BerserkPlayerBuff` -- a
-- 2.31 record on a PLAYER buff, which is one evidence grade above the 1.6 seed
-- names `time_dilation_sandevistan_enter/exit`. It is a cyberware-activation
-- adaptation, stated as one. These player events are non-spatial in 2.31.
-- The native effects layer keeps them on the owner but substitutes authored
-- spatial cyberware cues on observers, with explicit distance/lifetime culling.
-- Merely posting the player event on another body does not spatialise it.
--
-- `OWNER_EVENT` is deliberately nil. `berserk` (the `.VFX` name of
-- `BaseStatusEffect.BerserkPlayerBuff`) and `perk_edgerunner` (of
-- `AdvancedBerserkPlayerBuff`) are the only player-bound cyberware-overclock VFX
-- names in the installed database, but nothing offline says whether either is a
-- body effect or a red full-screen berserk grade, and a 15-second unverified
-- overlay on the owner's own eyes is worse than none. Without a `localEvent` the
-- owner simply gets the same attached layers on his own body, which is what
-- first and third person both want. Set it after a live look, not before.
--
-- The definition's `presentation` field is honoured: `native` is everything,
-- `silent` drops the two sounds, `none` renders nothing at all.
local ACTIVE, SEEN, stopped = {}, {}, false

-- The client's own ceiling is 15 000 ms (`ReflexConfig.MaximumDurationMs`); the
-- extra 500 ms is delivery margin, exactly like the hacking leases.
local CAP_MS, MAX_HANDLES, START_MS, END_MS, SEEN_MS = 15500, 24, 900, 700, 60000
local START_SOUND, END_SOUND = "w_cyb_berserker_activate", "w_cyb_berserker_deactivate"
local OWNER_EVENT = nil -- audited but unproven: "berserk", "perk_edgerunner"
local START_BURST = {effect="sparks.burst.large", slot="Chest"}
local END_BURST = {effect="sparks.burst.small", slot="Chest"}
local TIERS = {
    reflex = {
        {effect="neon.loot_drop", slot="Chest", localEvent=OWNER_EVENT},
        {effect="electric.industrial_arm", slot="Chest"},
        {effect="sparks.welding", slot="LeftFoot"},
        {effect="sparks.welding", slot="RightFoot"},
        {effect="cyber.trail_electric", slot="LeftFoot"},
        {effect="cyber.trail_electric", slot="RightFoot"},
    },
    reflex_heavy = {
        {effect="neon.loot_drop", slot="Chest", localEvent=OWNER_EVENT},
        {effect="electric.industrial_arm", slot="Chest"},
        {effect="electric.arc", slot="RightHand"},
        {effect="sparks.welding", slot="LeftFoot"},
        {effect="sparks.welding", slot="RightFoot"},
        {effect="cyber.trail_electric", slot="LeftFoot"},
        {effect="cyber.trail_electric", slot="RightFoot"},
    },
}

local function token(value) return type(value)=="string" and #value==32 and value:match("^%x+$")~=nil end
local function handleCount()
    local count=0
    for _,item in pairs(ACTIVE) do count=count+#item.handles end
    return count
end
local function retire(key)
    local item=ACTIVE[key]
    if not item then return end
    for _,handle in ipairs(item.handles) do Open77.effects.remove(handle) end
    ACTIVE[key]=nil
end
--- One lease per layer, created once for the whole phase so the particles never
--- restart on a renewal. A slot the body does not author, or a catalog alias the
--- client refuses, costs exactly one nil -- the projector renders nothing rather
--- than something wrong, so an unproven anchor is cheap to carry.
local function attach(key, player, layers, ttlMs)
    local target={kind="player", id=tostring(player)}
    local item=ACTIVE[key] or {player=player, handles={}, expires=0}
    for _,layer in ipairs(layers) do
        if handleCount()>=MAX_HANDLES then break end
        local handle=Open77.effects.attach(target, layer.effect, {slot=layer.slot, localEvent=layer.localEvent,
            ttlMs=ttlMs, streamingRadius=90, streamingHysteresis=20})
        if handle then item.handles[#item.handles+1]=handle end
    end
    if #item.handles==0 then return end
    item.expires=math.max(item.expires, GetGameTimer()+ttlMs)
    ACTIVE[key]=item
end
--- Bounded, deduplicated, and body-positioned. `actionId` is the generic sound
--- service's own one-shot key, so a duplicated authority event cannot double the
--- whir; `SEEN` keeps this resource from re-entering that path at all.
local function sound(key, player, event)
    if SEEN[key] then return end
    local count=0
    for _ in pairs(SEEN) do count=count+1 end
    if count>=512 then return end
    SEEN[key]=GetGameTimer()+SEEN_MS
    Open77.effects.sound({kind="player", id=tostring(player)}, event,
        {duration=2, actionId="reflex:"..key})
end

--- The nameplate marker, and why the particles are not enough on their own.
---
--- Measured 2026-09-15 from a second client on open ground: the attached layers
--- read clearly at 4 m and at 10 m -- torso glow, foot sparks, the ground lit --
--- and at 20 m they are simply gone. Small body-anchored particles subtend too
--- few pixels to survive that distance, and scaling them up would make the close
--- range unreadable instead. The plate does survive it: it is projected from the
--- head and drawn natively at whatever distance the viewer allows, so it carries
--- the cue the particles cannot.
---
--- It is announced to every session rather than to a computed viewer set. A
--- marker on a body a viewer cannot see draws nothing, because the plate is only
--- projected for players that client already has; sending it widely costs one
--- small event per phase change and removes a whole class of bug where an
--- observer who arrived late never learns the boost ended.
--- NOT `open77:reflex:marker`. `open77:reflex:` is reserved to the C# authority
--- and `TriggerClientEvent` refuses it with `reserved_reflex_event`, which is
--- the right rule: a Lua resource must not be able to forge a projection, a
--- permit or a phase. The marker is this resource's own cosmetic channel, so it
--- is named for the resource instead of for the authority. The worst a forged
--- one can do is mislabel a plate, which the client already bounds by length,
--- colour and ownership.
local MARKER_EVENT = "open77_reflex:marker"
local function marker(player, on)
    -- Resolve the lookup before calling it: `pcall(Open77.players.name, ...)`
    -- indexes `players` OUTSIDE the pcall, so a build without that table would
    -- throw on every activation and take the whole handler with it. The harness
    -- caught exactly that.
    local players = type(Open77) == "table" and Open77.players or nil
    local lookup = type(players) == "table" and players.name or nil
    local name = nil
    if type(lookup) == "function" then
        local okName, value = pcall(lookup, player)
        if okName then name = value end
    end
    if on and type(name) ~= "string" then return end
    TriggerClientEvent(MARKER_EVENT, -1, {player = player, name = name, on = on == true})
end

AddEventHandler("onReflexChanged", function(player, encoded)
    if stopped then return end
    local ok,value=pcall(json.decode, encoded)
    if not ok or type(value)~="table" or not token(value.activation) then return end
    local target=tonumber(player)
    if not target or (type(value.player)=="number" and value.player~=target) then return end
    local id,phase,mode=value.activation, value.phase, value.presentation
    local terminal=phase=="completed" or phase=="cancelled"
    -- `none`, and anything this build does not know, asks for no presentation.
    -- A terminal phase still cleans up, so a definition edited mid-session can
    -- never strand a lease.
    if mode~="native" and mode~="silent" then
        if terminal then retire(id) end
        return
    end
    if terminal then
        local shown=ACTIVE[id]~=nil and ACTIVE[id].shown==true
        retire(id)
        -- The end cue only fires for a boost that actually reached a body. An
        -- activation refused by the client between `accepted` and `active` gets
        -- its start burst dropped and stays silent, which is the truth.
        if not shown then return end
        marker(target, false)
        attach(id..":end", target, {END_BURST}, END_MS)
        if mode=="native" then sound(id..":end", target, END_SOUND) end
        return
    end
    if phase=="accepted" then
        if ACTIVE[id] then return end
        attach(id, target, {START_BURST}, START_MS)
        if mode=="native" then sound(id, target, START_SOUND) end
        return
    end
    if phase~="active" then return end
    if ACTIVE[id] and ACTIVE[id].shown then return end
    -- Remaining milliseconds read as a difference inside the payload, so no
    -- assumption is made about this VM's clock matching the authority's.
    local remaining=(tonumber(value.expiresAtMs) or 0)-(tonumber(value.serverTimeMs) or 0)
    attach(id, target, TIERS[value.tier] or TIERS.reflex, math.max(1, math.min(CAP_MS, remaining+500)))
    if ACTIVE[id] then ACTIVE[id].shown=true end
    marker(target, true)
end)

AddEventHandler("onPlayerDisconnected", function(player)
    local target=tonumber(player)
    if not target then return end
    for key,item in pairs(ACTIVE) do if item.player==target then retire(key) end end
    -- The plate is drawn from a roster this client may still hold for a moment,
    -- so the marker is lowered explicitly rather than left to the roster.
    marker(target, false)
end)

-- The watchdog behind every release path: a terminal phase that never arrives,
-- a payload whose deadline was optimistic, or a native handle the projector kept
-- past its lease. Nothing here can leave a body glowing.
CreateThread(function()
    while not stopped do
        local now=GetGameTimer()
        for key,item in pairs(ACTIVE) do
            if now>=item.expires then
                if item.shown then marker(item.player, false) end
                retire(key)
            end
        end
        for key,expiry in pairs(SEEN) do if now>=expiry then SEEN[key]=nil end end
        Wait(200)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name~=GetCurrentResourceName() then return end
    stopped=true
    for key,item in pairs(ACTIVE) do
        if item.shown then marker(item.player, false) end
        retire(key)
    end
    SEEN={}
end)
