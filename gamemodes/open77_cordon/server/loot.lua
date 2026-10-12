-- Cordon owns the inventory and every pickup transaction. Seeded loot and
-- death loot use typed physical containers with the mode's F interaction.
-- Weapon crates remain claimed until their assignment handshake completes.
-- Optional native drops are also included in the interaction catalogue; their
-- vanilla interactions are disabled, so visual existence alone is insufficient.

local K = Cordon
K.loot = {}
local L = K.loot

local drops = {}          -- [dropId] = { kind, ..., container = propId }
local pendingAmmo = {}    -- [drawRequestId] = { playerId, slot, reserve }
local pendingWeapons = {} -- [requestId] = assignment issued by this match
local applying = {}      -- [playerId] = timed consumable, bound to record and match
local seeded = false
local seedCount = 0
-- Containers created by THIS generation, counted against `maxContainers`. The
-- prop id itself lives on the drop's payload, so a pickup removes exactly the
-- box it emptied; this is only the budget.
local containerCount = 0

-- THE CRATE REGISTRY. `[propId] = { payload, x, y, z }`.
--
-- In crate mode there is NO native loot entity at all: the crate is the loot.
-- That is the owner's design ("we shouldnt see the weapon it should be in the
-- crate and then if its x weapon we get it") and it is also a crash fix. Taking
-- a weapon off a crate killed the client instantly at
-- Cyberpunk2077.exe+0x146152, reading `[0 + 0xF0]` -- a virtual call through a
-- NULL vtable pointer, i.e. a scripted method invoked on an item entity that
-- was being destroyed under it. An item that never exists cannot be called
-- after it is gone.
local crates = {}
local crateGeneration = 0

-- One-shot warning keys. Declared HERE rather than beside `resolveRecord`
-- where it used to live, because `containerSpecFor` below is the first thing
-- that writes to it and a local declared later would have been a nil global
-- at that point.
local warned = {}

local function cfg()
    return (Config and Config.loot) or {}
end

local function inv()
    return (Config and Config.inventory) or {}
end

local function containerCfg()
    return (cfg().containers) or {}
end

--- The container model and lid height for a loot kind, or nil when containers
--- are switched off, unconfigured, or the platform has no prop bindings.
---
--- The binding check is not defensive padding. `wiki/server-api.md` still
--- carries a caveat saying `Open77.props` is specified but not installed; the
--- binding IS installed today â€” `LuaResourceRuntime` registers the namespace
--- and its seven low-level aliases â€” but a server built before it landed would
--- otherwise take every seeded drop down with a nil call.
local function containerSpecFor(kind)
    -- EVERY NIL HERE IS NAMED, ONCE.
    --
    -- This returned a bare nil for three unrelated reasons and said nothing
    -- about which, so a mode with containers configured, enabled and permitted
    -- seeded eighty-four bare drops and reported success. Measured 2026-09-02:
    -- `br.loot.here street 5` answered `made=5 failed=0` while `props.list` on
    -- the client read `props=0`, and no warning existed anywhere to explain the
    -- gap. `spawnContainer` already names its own refusal; this is the half
    -- that was missing.
    local settings = containerCfg()
    if settings.enabled == false then return nil end
    if type(Open77) ~= "table" or type(Open77.props) ~= "table"
        or type(Open77.props.create) ~= "function" then
        if not warned["containerApi"] then
            warned["containerApi"] = true
            K.warn(("loot: containers configured but the platform exposes no prop " ..
                "bindings (Open77=%s props=%s create=%s) â€” every drop will be bare. " ..
                "The `world.props` permission is what installs them."):format(
                type(Open77), type(Open77) == "table" and type(Open77.props) or "n/a",
                (type(Open77) == "table" and type(Open77.props) == "table")
                    and type(Open77.props.create) or "n/a"))
        end
        return nil
    end
    local models = settings.models or {}
    local spec = models[kind] or models.default
    if type(spec) ~= "table" or type(spec.model) ~= "string" then
        if not warned["containerModel:" .. tostring(kind)] then
            warned["containerModel:" .. tostring(kind)] = true
            K.warn(("loot: no container model for kind %q and no default â€” " ..
                "drops of that kind will be bare."):format(tostring(kind)))
        end
        return nil
    end
    return spec
end

--- Every model this mode uses for a loot container, as a set.
---
--- It is how a container is RECOGNISED rather than remembered. A hot reload
--- gives this file a fresh Lua state while every prop it made lives on in the
--- platform's registry â€” exactly the failure that once left 168 drops where 84
--- were asked for. `L.clear` survives that for drops by iterating the loot
--- registry; containers need the same treatment, and a prop snapshot carries no
--- label to key on â€” only `id`, `model`, `bucket` and `resource` â€” so the model
--- set is the key. That is why the config block insists these aliases stay
--- disjoint from the cordon edge and the supply crate: every prop this mode
--- makes shares one owner name, so a stray match here would delete scenery that
--- belongs to another part of the same resource.
local function containerModels()
    local set = {}
    for _, spec in pairs(containerCfg().models or {}) do
        if type(spec) == "table" and type(spec.model) == "string" then
            set[spec.model] = true
        end
    end
    return set
end

local function removeContainer(propId)
    if propId == nil then return false end
    if type(Open77) ~= "table" or type(Open77.props) ~= "table" then return false end
    -- Prop ids are DECIMAL STRINGS and must survive as they came: passing one
    -- through `tonumber` loses the top of a 64-bit identity (wiki/props.md).
    if Open77.props.remove(propId) == true then
        containerCount = math.max(0, containerCount - 1)
        return true
    end
    return false
end

-- A claimed weapon crate stays in the world until assignment is confirmed.
-- Only this generation may restore its prompt or remove its prop.
local function settleCrate(pending, confirmed)
    local claim = pending and pending.crate
    if claim == nil or claim.generation ~= crateGeneration then return end
    pending.crate = nil
    if confirmed then
        removeContainer(claim.key)
        pending.player.cratesOpened = (pending.player.cratesOpened or 0) + 1
    else
        crates[claim.key] = claim.value
    end
    L.publishCrates()
end

local function discardPending(playerId)
    for request, pending in pairs(pendingWeapons) do
        if playerId == nil or pending.player.id == playerId then
            local claim = pending.crate
            if claim and claim.generation == crateGeneration then removeContainer(claim.key) end
            pendingWeapons[request] = nil
        end
    end
    for request, pending in pairs(pendingAmmo) do
        if playerId == nil or pending.playerId == playerId then pendingAmmo[request] = nil end
    end
end

--- Weighted pick over a list of { weight = n, ... }.
local function pickWeighted(list)
    local total = 0
    for _, entry in ipairs(list) do total = total + (entry.weight or 1) end
    if total <= 0 then return nil end
    local roll = math.random() * total
    for _, entry in ipairs(list) do
        roll = roll - (entry.weight or 1)
        if roll <= 0 then return entry end
    end
    return list[#list]
end

--- Weighted pick over a map of key -> weight.
local function pickKind(kinds)
    local total = 0
    for _, weight in pairs(kinds) do total = total + weight end
    if total <= 0 then return nil end
    local roll = math.random() * total
    for kind, weight in pairs(kinds) do
        roll = roll - weight
        if roll <= 0 then return kind end
    end
    return "ammo"
end

-- ---------------------------------------------------------------------------
-- UNVERIFIED RECORDS FAIL SOFT, LOUDLY.
--
-- Plates, heals and ammo are marked `verified = false` in the config because no
-- generated catalogue of consumables exists on this build and nobody has taken
-- one off the ground yet. A drop whose record the engine rejects would simply
-- not appear, and a map missing a third of its loot with no error is the worst
-- possible failure â€” so an unverified record falls back to a record that IS
-- verified (money), keeps the mode's own `kind`, and logs once.
--
-- The kind is what the mode grants. The record is only what the Take card says.
-- That separation is what makes the fallback harmless: you still get a plate.
-- ---------------------------------------------------------------------------
local function resolveRecord(spec, kind)
    if type(spec) ~= "table" then return nil, nil end
    if spec.verified == false then
        if not warned[kind] then
            warned[kind] = true
            K.warn(("loot: %s record %s is UNVERIFIED â€” dropping %s instead and still granting the %s. " ..
                "Verify with: loot.create.player 1 %s 1"):format(
                kind, tostring(spec.record), tostring(spec.fallbackRecord), kind, tostring(spec.record)))
        end
        return spec.fallbackRecord or "Items.money", spec.fallbackQuantity or 1
    end
    return spec.record, 1
end

-- ---------------------------------------------------------------------------
-- SHIELDS: THE EQUIPPABLE ARMOUR LAYER, AND WHY IT IS THE MODE'S OWN NUMBER.
--
-- A battle royale wants a second health bar that empties before flesh and is
-- topped up from loot. Open77 has something that looks exactly like one -- the
-- platform's `armor` -- and the whole design turned on whether to use it.
--
-- IT IS A REAL POOL, NOT VANILLA MITIGATION. Read in the server source: the
-- single damage funnel absorbs one point of damage per point of armour and
-- only then touches health.
--
--     var absorbed = Math.Min(entry.Armor, amount);
--     entry.Armor -= absorbed;
--     entry.Health = Math.Max(0F, entry.Health - (amount - absorbed));
--     -- server/src/Open77.Server.Core/Combat/DamageAuthorityService.cs:544-546
--
-- Flat, fully consumed, no per-body-part split, no leak-through, and lethality
-- is judged after it (:555). That IS a battle-royale shield, it is replicated
-- to everyone in the bucket for nothing, and the HUD already draws it.
--
-- AND THE MODE STILL DOES NOT USE IT. One line decides it, in the same file:
-- scripted damage reaches that same funnel (`ScriptedDamage` -> `Commit`, :382)
-- and scripted damage is what the cordon bleeds players with
-- (server/cordon.lua:801). A pool held in `entry.Armor` would therefore absorb
-- THE CORDON, and the cordon is the one damage in this mode that must never be
-- survivable: a full heavy carrier would buy seventy-five points of walking
-- around in the dark.
--
-- So the pool lives on the player record and the engine's armour is left at
-- zero. Three consequences, all of them the ones we wanted:
--
--   * the cordon is unabsorbable BY CONSTRUCTION, not by a special case
--     somebody has to remember to write;
--   * `K.placeAt` sets engine armour to zero on every placement
--     (server/kernel.lua:389) and every placement in this mode is a
--     kill-respawn, so a pool kept there would evaporate on every teleport.
--     This one does not;
--   * nothing double-absorbs. The arbiter below hands the funnel an amount the
--     shield has already eaten, and `entry.Armor` is zero, so it eats nothing
--     a second time.
--
-- What it costs is the interception, and the platform sells that cheaply: a
-- `Open77.combat.onDamage` arbiter may REWRITE the amount, not merely cancel it
-- (wiki/server-api.md:352).
--
-- ONE WORD, TWO MEANINGS -- read this before touching either. `K.shielded` and
-- `record.shieldUntilMs` are SPAWN PROTECTION: a timestamp, a countdown, a ring
-- on the combat HUD, and nothing whatever to do with this. The pool here is
-- spelt `armor` in every field name for exactly that reason, and the
-- player-facing strings keep SHIELD for the countdown and ARMOR for the pool.
-- ---------------------------------------------------------------------------

--- The tier list: the config first, a built-in floor behind it.
---
--- The floor is not a second source of truth. It is what makes the feature
--- visible before `Config.loot.shields` exists, and every record in it is taken
--- from `docs/generated/clothing-2.31.csv`, which is generated from this
--- build's own `tweakdb.bin`. That is the SAME standard of proof as every
--- weapon record in the config -- and a better one than a lab pickup, which is
--- what `plate` and `heal` are still waiting for.
local DEFAULT_SHIELD_TIERS = {
    { key = "light",  label = "LIGHT VEST",    capacity = 25, weight = 50,
      record = "Items.Vest_01_basic_01",           verified = true },
    { key = "medium", label = "MEDIUM VEST",   capacity = 50, weight = 34,
      record = "Items.Q000_Nomad_Vest",            verified = true },
    { key = "heavy",  label = "HEAVY CARRIER", capacity = 75, weight = 16,
      record = "Items.Q115_Custom_Predator_Armor", verified = true },
}

local function shieldTiers()
    local configured = (cfg().shields or {}).tiers
    if type(configured) == "table" and #configured > 0 then return configured end
    return DEFAULT_SHIELD_TIERS
end

--- The tier a player is wearing, or nil.
local function tierOf(record)
    if record == nil or record.armorTier == nil then return nil end
    for _, tier in ipairs(shieldTiers()) do
        if tier.key == record.armorTier then return tier end
    end
    return nil
end

--- CAPACITY IS DERIVED FROM THE TIER, NEVER STORED BESIDE IT. A number cached
--- on the record would outlive a config change and then quietly contradict it;
--- the tier key is the only part worth persisting.
---
--- THE CEILING IS 75 AND THAT IS NOT ARBITRARY. `combat.js` scales the armour
--- bar against a hard-coded 75, and `Config.inventory` already documents
--- "3 x 25 = 75" as the mode's armour ceiling. Raising the heaviest tier above
--- it without moving the HUD makes a full carrier render as an overflowing bar.
local function capacityOf(record)
    local tier = tierOf(record)
    if tier == nil then return 0 end
    return math.max(0, tonumber(tier.capacity) or 0)
end

--- Published for the state push, which has to send a maximum the HUD can scale
--- against and cannot reach a local in this file.
function L.shieldCapacity(record)
    return capacityOf(record)
end

--- Equip a looted shield, or strip it for a plate when it is not an upgrade.
---
--- A PICKUP CANNOT BE REFUSED, and that is what shapes this rule. By the time
--- `onLootPickup` reaches the mode the platform has already validated the take
--- and destroyed the drop; there is no "leave it on the ground" left to return
--- to. So a shield that is not an upgrade still has to be worth something, and
--- the honest conversion is the one the fiction already supports: a carrier you
--- cannot wear is stripped for the plate inside it.
---
--- Nothing is wasted, nothing ever downgrades, and the plate still has to be
--- applied with the same interruptible hold as any other -- so this is not a
--- back door to a free refill.
function L.giveShield(record, tier)
    if record == nil or type(tier) ~= "table" then return end
    local incoming = math.max(0, tonumber(tier.capacity) or 0)
    local worn = capacityOf(record)

    if incoming > worn then
        record.armorTier = tier.key
        -- A GROUND SHIELD ARRIVES FULL. The alternative -- an empty carrier you
        -- then have to feed three plates into -- makes the best loot in the
        -- game feel like homework, and it rewards only the players already
        -- winning enough to be carrying plates.
        record.armor = incoming
        K.notice(record.id, "shieldEquipped", {
            label = tostring(tier.label or tier.key or "?"),
            capacity = incoming,
        })
        return
    end

    local maximum = inv().plateMax or 3
    if (record.plates or 0) >= maximum then
        K.notice(record.id, "plateFull", { held = record.plates or 0 })
        return
    end
    record.plates = (record.plates or 0) + 1
    K.notice(record.id, "shieldStripped", {
        label = tostring(tier.label or tier.key or "?"),
        held = record.plates,
    })
end

-- ---------------------------------------------------------------------------
-- SEEDING. Clusters, not individual marks: one surveyed anchor generates a
-- neighbourhood of drops. Forty anchors is an afternoon of walking; six hundred
-- individual marks is a week, and it is the wrong granularity anyway â€” a player
-- remembers that the mall is worth looting, not the sixth pistol in it.
-- ---------------------------------------------------------------------------
-- Plan only on authored anchors/surfaces. Spatial bins bound collision checks;
-- extra density cannot turn a zero-radius hand placement into a stack of boxes.
function L.planSeed(map, density)
    local budget = math.max(0, math.min(1200, math.floor(tonumber(cfg().budget) or 900)))
    local spacing = math.max(1.5, tonumber(cfg().seedSpacingMetres) or 2.0)
    local bins, slots, extras = {}, {}, {}
    local function add(cluster, x, y, z)
        if #slots >= budget then return false end
        local bx, by = math.floor(x / spacing), math.floor(y / spacing)
        for dx=-1,1 do for dy=-1,1 do
            for _, other in ipairs(bins[(bx+dx)..":"..(by+dy)] or {}) do
                if (x-other.x)^2+(y-other.y)^2+(z-other.z)^2 < spacing^2 then return false end
            end
        end end
        local slot = { cluster=cluster, position={x=x,y=y,z=z} }
        slots[#slots+1] = slot
        local key=bx..":"..by
        bins[key]=bins[key] or {}; bins[key][#bins[key]+1]=slot.position
        return true
    end
    local wanted=0
    for _, cluster in ipairs(map.lootClusters or {}) do
        local p=cluster.position
        if p ~= nil and density > 0 then
            local count=math.max(1,math.floor((tonumber(cluster.count) or 1)*density))
            wanted=wanted+count
            local made=add(cluster,p.x,p.y,p.z) and 1 or 0
            extras[#extras+1]={cluster=cluster,remaining=count-made}
        end
    end
    -- Anchor coverage first, then a bounded lattice on that anchor's surveyed
    -- scatter surface. Never extend its radius or invent a new ground height.
    for _, entry in ipairs(extras) do
        local c=entry.cluster; local p=c.position
        local radius=math.max(0,math.min(tonumber(c.radius) or 0,tonumber(cfg().maxScatterMetres) or 8))
        local cells=math.floor(radius/spacing)
        for ring=1,cells do
            if entry.remaining<=0 or #slots>=budget then break end
            for dx=-ring,ring do for dy=-ring,ring do
                if entry.remaining>0 and #slots<budget and math.max(math.abs(dx),math.abs(dy))==ring
                    and (dx*spacing)^2+(dy*spacing)^2<=radius^2 then
                    if add(c,p.x+dx*spacing,p.y+dy*spacing,p.z) then entry.remaining=entry.remaining-1 end
                end
            end end
        end
    end
    -- Round-robin across 100 m regions so guaranteed weapons are not all in
    -- the first street the mapper happened to survey. Randomize region order.
    local regions,keys={},{}
    for _,slot in ipairs(slots) do
        local key=math.floor(slot.position.x/100)..":"..math.floor(slot.position.y/100)
        if regions[key]==nil then regions[key]={};keys[#keys+1]=key end
        table.insert(regions[key],slot)
    end
    for i=#keys,2,-1 do local j=math.random(i);keys[i],keys[j]=keys[j],keys[i] end
    local ordered={}; local index=1
    while #ordered<#slots do
        for _,key in ipairs(keys) do if regions[key][index] then ordered[#ordered+1]=regions[key][index] end end
        index=index+1
    end
    return ordered,wanted
end

function L.seed(map)
    -- ALWAYS clear, never "clear if this VM thinks it seeded".
    --
    -- `seeded` is a flag in this Lua state, and a hot reload gives the mode a
    -- fresh state while every drop it made lives on in the platform's registry.
    -- The successor then believes the district is empty and seeds a second full
    -- set on top of the first. Measured 2026-09-02: 168 drops where 84 were
    -- asked for, after the resource was reloaded between two matches.
    --
    -- It matters beyond tidiness. The budget is 900 drops and the platform's
    -- registry caps at 4096, so a set that doubles every match hits the ceiling
    -- in five. `L.clear` already iterates the REGISTRY rather than this state's
    -- table, for exactly this reason -- it was simply never reached.
    L.clear()
    local tiers = cfg().tiers or {}
    if #tiers == 0 then
        K.warn("loot: no tiers configured, seeding nothing")
        return 0
    end
    -- A ONE-SHOT WARNING FOR THE HALF OF THIS FEATURE THAT LIVES IN THE CONFIG.
    --
    -- Shields roll out of a tier's `kinds` table like every other loot kind, so
    -- a config whose tiers carry no `shield` weight seeds a district with no
    -- shields in it -- and then every plate a player finds is dead weight and
    -- refuses to apply. That reads as a broken mode rather than as a missing
    -- config row, which is exactly the failure this file already refuses to
    -- ship silently for unverified records.
    if not warned["shieldKind"] then
        local rolls = false
        for _, tier in ipairs(tiers) do
            if type(tier.kinds) == "table" and (tonumber(tier.kinds.shield) or 0) > 0 then
                rolls = true
                break
            end
        end
        if not rolls then
            warned["shieldKind"] = true
            K.warn("loot: no tier rolls the `shield` kind, so no shield will ever be " ..
                "seeded and every plate is dead weight. Add `shield = <weight>` to the " ..
                "`kinds` table of each tier in Config.loot.tiers.")
        end
    end

    local density = tonumber(K.tune("lootDensity", 1.0)) or 1.0
    local clusters = map.lootClusters or {}
    if #clusters == 0 then
        K.warn("loot: the map has no surveyed loot clusters, so the district is empty. " ..
            "This is a survey gap, not a code path â€” see Pacifica.lootClusters.")
        return 0
    end

    seedCount = 0
    local participants=0
    for _,record in pairs(K.players or {}) do
        if record.state=="alive" and (K.match==nil or K.match.isParticipant==nil or K.match.isParticipant(record)) then
            participants=participants+1
        end
    end
    participants=math.min(64,participants)
    local slots,wanted=L.planSeed(map,density)
    local minimum=cfg().minimumPerParticipant or {weapon=1,heal=1,shield=1,plate=1}
    local created={weapon=0,heal=0,shield=0,plate=0}
    local failed=0
    for _,slot in ipairs(slots) do
        local tier=tiers[math.min(math.max(math.floor(tonumber(slot.cluster.tier) or 1),1),#tiers)]
        local forced
        for _,kind in ipairs({"weapon","heal","shield","plate"}) do
            if created[kind] < participants*(tonumber(minimum[kind]) or 0)
                and (tonumber((tier.kinds or {})[kind]) or 0)>0 then forced=kind;break end
        end
        local ok,id,kind=pcall(L.spawnOne,tier,slot.position,nil,forced,slot.cluster.grounded == true)
        if ok and id~=nil then created[kind or forced or "other"]=(created[kind or forced or "other"] or 0)+1
        else failed=failed+1 end
    end
    if #slots<wanted or failed>0 then
        K.warn(("loot supply: requested=%d separated/budgeted=%d created=%d refused=%d; no overlapping extras invented")
            :format(wanted,#slots,seedCount,failed))
    end
    for _,kind in ipairs({"weapon","heal","shield","plate"}) do
        local need=participants*(tonumber(minimum[kind]) or 0)
        if created[kind]<need then K.warn(("loot shortage: %s %d/%d for %d participants; add surveyed anchors")
            :format(kind,created[kind],need,participants)) end
    end
    K.log(("loot supply: participants=%d weapons=%d heals=%d shields=%d plates=%d")
        :format(participants,created.weapon,created.heal,created.shield,created.plate))
    seeded = true
    K.log(("loot: seeded %d drops (%d containers) from %d clusters at density %.2f"):format(
        seedCount, containerCount, #clusters, density))
    return seedCount
end

--- Put a container down at a ground point. A refusal is not fatal: the drop is
--- what matters, so a failed container logs once and the drop is seeded bare.
function L.spawnContainer(spec, position, bucket)
    local settings = containerCfg()
    local propId, refusal = Open77.props.create({
        model = spec.model,
        position = position,
        -- Random heading, so ten crates in one cluster do not line up like
        -- warehouse shelving.
        yaw = settings.randomYaw ~= false and (math.random() * 360.0) or 0.0,
        bucket = bucket or K.matchBucket(),
        physics = "static",

        -- NO COLLISION, and it fixes two things at once.
        --
        -- These crates are SOLID by default, and the drop sits on the lid. The
        -- interaction ray then hits the crate instead of the item: the owner
        -- reported "j'ai pas d'interact en m'approchant et F fais rien" -- no
        -- prompt at all, on loot that was proven working before containers
        -- existed. A box you cannot loot from is worse than no box.
        --
        -- It also removes the crash mechanism. The item resting ON a solid
        -- crate is a physics CONTACT between them, and the pickup used to free
        -- both in the same frame; the fault is a use-after-free write into the
        -- engine's pool (Cyberpunk2077.exe+0x53F9D4 -- see
        -- docs/research/debugging-and-reverse.md). With no physical component
        -- there is no contact to go stale, which is a stronger fix than the 1.5 s
        -- removal delay beside it. Both are kept: they are independent.
        --
        -- The cost is that a player can walk through the crate. That is a fair
        -- trade for loot that can be picked up and does not crash, and
        -- `Api::Props` supports it directly -- a collision-free prop keeps its
        -- visual component and leaves the physical one off.
        collision = settings.collision == true,
        streamingRadius = tonumber(settings.streamingRadius) or 70.0,
        streamingHysteresis = tonumber(settings.streamingHysteresis) or 15.0,
    })
    if propId == nil then
        if not warned["container"] then
            warned["container"] = true
            K.warn(("loot: container prop refused: %s â€” every drop this match " ..
                "will be seeded bare. The drop itself is unaffected."):format(tostring(refusal)))
        end
        return nil
    end
    containerCount = containerCount + 1
    return propId
end

-- `bucket` is optional and defaults to the match bucket, which is what a real
-- seed always wants. It exists for the operator verb `br.loot.here`, which
-- seeds at a player who may be standing in STAGING (5100) rather than in the
-- match (5101). Without it that verb reported "made=5 failed=0" while the
-- player standing on the spot saw nothing -- correctly, because a prop in
-- another routing bucket is in another dimension. Measured 2026-09-02, and
-- it cost a second look at a projection path that was already fixed.
--- @param forcedKind string|nil  a loot kind to grant instead of rolling one.
---        Used by minimum-supply allocation and `br.loot.here`: a street crate is a
---        weapon about one roll in five, so an automated check of the loot
---        affordance that seeded a normal crate would pass or fail on the dice.
---        A kind the tier does not
---        carry is refused rather than silently rolled.
function L.spawnOne(tier, position, bucket, forcedKind, grounded)
    local kind = forcedKind or pickKind(tier.kinds or { ammo = 1 })
    if forcedKind ~= nil and (tonumber((tier.kinds or {})[forcedKind]) or 0) <= 0 then
        return nil
    end
    local record, quantity, payload = nil, 1, nil

    if kind == "weapon" then
        local weapon = pickWeighted(tier.weapons or {})
        if weapon == nil then return nil end
        record = weapon.record
        payload = { kind = "weapon", weapon = weapon }
    elseif kind == "ammo" then
        local ammo = cfg().ammo or {}
        local choices = {}
        for key, entry in pairs(ammo) do choices[#choices + 1] = { key = key, entry = entry, weight = 1 } end
        local chosen = pickWeighted(choices)
        if chosen == nil then return nil end
        record = chosen.entry.record
        payload = { kind = "ammo", ammo = chosen.entry }
    elseif kind == "shield" then
        -- THE TIER IS THE PAYLOAD, not just its key. A drop seeded before a
        -- config reload must still grant the capacity it was rolled with,
        -- rather than resolving a key that may have changed meaning underneath
        -- it -- the same reason a weapon drop carries its whole spec.
        local tier = pickWeighted(shieldTiers())
        if tier == nil then return nil end
        record, quantity = resolveRecord(tier, "shield:" .. tostring(tier.key or "?"))
        payload = { kind = "shield", shield = tier }
    elseif kind == "plate" then
        record, quantity = resolveRecord(cfg().plate, "plate")
        payload = { kind = "plate" }
    elseif kind == "heal" then
        local heals = (cfg().heal or {}).records or {}
        local chosen = heals[math.random(1, math.max(1, #heals))]
        record, quantity = resolveRecord(chosen or cfg().heal, "heal")
        payload = { kind = "heal" }
    else
        local money = cfg().money or {}
        record = money.record or "Items.money"
        quantity = math.random(money.min or 250, money.max or 1500)
        -- The platform already substitutes `Items.MoneyShard` for abstract
        -- currency; passing the configured visual explicitly costs nothing and
        -- means the config row is not a lie.
        payload = { kind = "money", amount = quantity, visualItem = money.visualItem }
    end
    if record == nil then return nil end

    -- THE CONTAINER GOES DOWN FIRST, because the drop's height depends on the
    -- lid. The order matters the other way round too: a container with nothing
    -- on it is a box a player crosses a street for and finds empty, so a
    -- refused `loot.create` below takes its container with it.
    local settings = containerCfg()
    local spec = containerSpecFor(payload.kind)
    local base, dropPosition, propId = position, position, nil
    if spec ~= nil and containerCount < (tonumber(settings.maxContainers) or 1200) then
        base = {
            x = position.x,
            y = position.y,
            -- Sunk a few centimetres. The anchor's z is a walked probe and the
            -- only ground truth the server has â€” there is no ground query in
            -- Lua on either side of this platform â€” so it is wrong by however
            -- much the surface moves under the scatter. Burying the box makes a
            -- small error read as settled rather than as hovering.
            z = position.z - (grounded == true and (tonumber(spec.minZMetres) or 0.0)
                or (tonumber(settings.sinkMetres) or 0.0)),
        }
        propId = L.spawnContainer(spec, base, bucket)
    end
    if propId ~= nil then
        dropPosition = {
            x = base.x,
            y = base.y,
            -- On the lid, pushed slightly back into it. Deliberately biased
            -- DOWN: an item a few centimetres inside a crate reads as sitting
            -- in it, an item a few centimetres above it reads as broken, and a
            -- drop has never been observed to fall onto anything, so gravity
            -- will not correct an underestimate.
            z = base.z + (tonumber(spec.heightMetres) or 0.4)
                - (tonumber(settings.overlapMetres) or 0.0),
        }
    end

    -- CRATE MODE: the container IS the drop, and no item entity is spawned.
    -- The mode draws its own prompt on the crate (client/main.lua) and grants
    -- the payload server-side, so the platform's loot registry is not involved.
    if propId ~= nil and containerCfg().crateOnly ~= false then
        crates[tostring(propId)] = {
            payload = payload,
            x = base.x, y = base.y, z = base.z,
            labelHeight = (tonumber(spec.heightMetres) or 0.4) + 0.15,
            quantity = quantity,
        }
        seedCount = seedCount + 1
        return propId, payload.kind
    end

    local dropId, refusal = Open77.loot.create({
        item = record,
        quantity = quantity,
        position = dropPosition,
        bucket = bucket or K.matchBucket(),
        radius = tonumber(cfg().radiusMetres) or 2.0,
        label = payload.kind,
        visualItem = payload.visualItem,
        ttlMs = tonumber(cfg().matchTtlMs) or 0,
    })
    if dropId == nil then
        if not warned["create"] then
            warned["create"] = true
            K.warn("loot: create refused: " .. tostring(refusal))
        end
        removeContainer(propId)
        return nil
    end
    payload.container = propId
    drops[tostring(dropId)] = payload
    seedCount = seedCount + 1
    return dropId, payload.kind
end

--- Remove every loot container in the match bucket, by model rather than by
--- memory. See `containerModels` for why the model is the key.
--- Crates go with the drops: `L.clear` empties both, so a new match never
--- inherits the last one's boxes.
function L.clearCrates()
    local count = 0
    for _ in pairs(crates) do count = count + 1 end
    crates = {}
    crateGeneration = crateGeneration + 1
    return count
end

function L.clearContainers()
    if type(Open77) ~= "table" or type(Open77.props) ~= "table"
        or type(Open77.props.all) ~= "function" then
        return 0
    end
    local models = containerModels()
    if next(models) == nil then return 0 end
    local mine = GetCurrentResourceName()
    local removed = 0
    for _, prop in ipairs(Open77.props.all(K.matchBucket()) or {}) do
        if models[prop.model] and (prop.resource == nil or prop.resource == mine) then
            if Open77.props.remove(prop.id) == true then removed = removed + 1 end
        end
    end
    containerCount = 0
    return removed
end

function L.clear()
    applying = {}
    discardPending()
    L.clearCrates()
    local removed = 0
    -- Iterate the PLATFORM's registry, never this VM's table: a hot reload
    -- empties the table while every drop lives on, and the successor generation
    -- would leak every one of them.
    for _, drop in ipairs(Open77.loot.all(K.matchBucket()) or {}) do
        if Open77.loot.remove(drop.id) then removed = removed + 1 end
    end
    local containers = L.clearContainers()
    if containers > 0 then
        K.log(("loot: cleared %d drop(s) and %d container(s)"):format(removed, containers))
    end
    drops = {}
    seeded = false
    seedCount = 0
    return removed
end

-- ---------------------------------------------------------------------------
-- PICKUP. `onLootPickup` fires into EVERY server VM, so the first thing to do
-- is establish that this drop was ours.
-- ---------------------------------------------------------------------------
AddEventHandler("onLootPickup", function(playerIdStr, dropId, item, quantity, owner)
    local payload = drops[tostring(dropId)]
    if payload == nil then return end
    drops[tostring(dropId)] = nil
    L.publishCrates()
    -- An emptied box is scenery that lies about itself, and nine hundred of
    -- them is a quota. It goes with the drop it held, whatever the grant below
    -- does â€” the pickup has already been validated and removed server-side.
    --
    -- BUT NOT IN THE SAME FRAME AS THE PICKUP, and that delay is a crash fix.
    --
    -- The item is deliberately placed ON THE LID of a solid crate, so the two
    -- are in physics contact. Removing the container here tore both down in one
    -- frame, and the owner's client crashed on picking a crate's drop up:
    -- Cyberpunk2077.exe+0x53F9D4, the engine's pool allocator, reading an
    -- unaligned pointer while every valid pointer in the frame was 8-aligned â€”
    -- heap corruption surfacing late, which is what a stale reference into a
    -- freed block looks like.
    --
    -- INFERENCE, not proof: the mechanism was not read out of a debugger, and
    -- the same faulting address appears in a capture predating containers by a
    -- day and a half, so this may only be removing the likeliest trigger of an
    -- older fault. What is certain is that the crash arrived with containers,
    -- reproduces on looting one, and that nothing needs the box to vanish on
    -- the same frame as the thing that was sitting on it.
    local container = payload.container
    if container ~= nil then
        SetTimeout(1500, function() removeContainer(container) end)
    end

    local record = K.ensure(playerIdStr)
    if record == nil then return end
    if record.state ~= "alive" then return end

    L.grant(record, payload, quantity)
end)

--- Hands one payload to a player. Extracted from `onLootPickup` so the crate
--- path below grants through EXACTLY the same code -- the mode's inventory, the
--- verified-weapon registration and the notices are the whole economy, and a
--- second copy of them would drift.
function L.grant(record, payload, quantity, crateClaim)
    if type(payload) ~= "table" or record == nil then return false end
    if payload.kind == "weapon" then
        return L.giveWeapon(record, payload.weapon, crateClaim)
    elseif payload.kind == "ammo" then
        L.giveAmmo(record, payload.ammo)
    elseif payload.kind == "shield" then
        L.giveShield(record, payload.shield)
    elseif payload.kind == "plate" then
        record.plates = math.min((record.plates or 0) + 1, inv().plateMax or 3)
        K.notice(record.id, "pickupPlate", { held = record.plates })
    elseif payload.kind == "heal" then
        record.heals = math.min((record.heals or 0) + 1, inv().healMax or 4)
        K.notice(record.id, "pickupHeal", { held = record.heals })
    elseif payload.kind == "money" then
        record.eddies = (record.eddies or 0) + (tonumber(quantity or payload.amount) or 0)
    else
        return false
    end
    return true
end

--- Put a looted weapon in the first free slot, or replace the active one.
---
--- The slot the client ends up holding is confirmed asynchronously on
--- `open77:weapons:completed`, and THAT id â€” not the record asked for â€” is what
--- main.lua writes into the verified set the arbiter matches. So a weapon whose
--- assignment never completes cannot be used to damage anybody, which is the
--- right failure: "cannot shoot", never "free damage".
function L.giveWeapon(record, weapon, crateClaim)
    if type(weapon) ~= "table" or type(weapon.record) ~= "string" then return false end
    local slots = inv().weaponSlots or 3
    local used = {}
    local reserved = {}
    for _, pending in pairs(pendingWeapons) do
        if pending.player == record then reserved[pending.slot] = true end
    end
    for _, slot in pairs(record.weapons or {}) do
        if type(slot) == "number" then used[slot] = true end
    end
    local target = nil
    for slot = 1, slots do
        if not used[slot] and not reserved[slot] then target = slot break end
    end
    if target == nil then
        for slot = 1, slots do
            if not reserved[slot] then target = slot break end
        end
    end
    if target == nil then return false end

    local request, refusal = Open77.weapons.assign(record.id, weapon.record, target, {
        active = target == 1, addToInventory = true,
    })
    if request == nil then
        K.warn(("loot: assign %s to %d refused: %s"):format(tostring(weapon.record), record.id, tostring(refusal)))
        return false
    end
    -- AMMO IS DEFERRED UNTIL THE WEAPON IS DRAWN.
    --
    -- Measured 2026-09-02: calling setAmmo immediately after assign is refused
    -- with `weapon_not_drawn`, and the player ends up holding a gun with an
    -- empty reserve. The assign completes asynchronously, and only once the
    -- client has actually drawn the weapon does the ammo call take â€” so the
    -- reserve is remembered here and issued from the completion handler.
    --
    -- Reserve ONLY, separately: `setAmmo` fails AS A WHOLE if `magazine`
    -- exceeds the weapon's capacity â€” a Lexington given {reserve=300,
    -- magazine=60} ends on 000 0000 â€” so the magazine key is never sent.
    pendingWeapons[tostring(request)] = {
        player = record, slot = target, reserve = weapon.reserve or 90,
        label = weapon.label or weapon.record, template = weapon.record, crate = crateClaim,
    }
    return true
end

function L.giveAmmo(record, ammo)
    -- Top up whichever slot the player is holding. Reserve only, same reason.
    for slot = 1, (inv().weaponSlots or 3) do
        pcall(Open77.weapons.setAmmo, record.id, slot, { reserve = ammo.amount or 90 })
    end
    K.notice(record.id, "pickupAmmo", { label = ammo.label })
end

-- ---------------------------------------------------------------------------
-- THE ABSORPTION, AND THE THREE THINGS THAT STOP HAPPENING WHEN A SHIELD EATS
-- A HIT.
--
-- REGISTERED LAST, DELIBERATELY, AND BY A TIMER. Arbiters run in registration
-- order and the first `false` ends the walk outright
-- (LuaResourceRuntime.cs:4239). main.lua's arbiter is the one that refuses a
-- hit on a spawn-shielded victim, on a squadmate, or from an unverified weapon
-- -- and manifest order loads THIS file before main.lua. Registering at load
-- time would therefore put the shield FIRST and spend it on hits that were
-- about to be refused anyway. `SetTimeout(0, ...)` fires on the first tick
-- after every script has loaded, which is what puts it last.
--
-- A FULLY ABSORBED HIT IS CANCELLED, NOT DELIVERED, and that is the part with
-- teeth. The host reads a rewritten amount of zero as a cancellation --
--
--     if (!float.IsFinite(verdict.Amount) || verdict.Amount <= 0F)
--     { error = "cancelled"; return true; }
--     -- Combat/DamageAuthorityService.cs:459
--
-- -- so `Commit` never runs, and three things the rest of the mode leans on
-- never happen. Each is repaired here rather than left to a downstream event
-- that will not fire:
--
--   1. the attacker gets no `open77:hitConfirmed`, so NO HITMARKER. Shooting a
--      shielded player would look precisely like missing. The HUD already has
--      the seam for this and has never had a sender:
--      open77_cordon_hud/client/combat.lua:243 registers `cordon:hit` and its
--      own comment says the mode is expected to report hits it can see;
--   2. the victim gets no `open77:playerDamaged`, so the plate they are
--      applying is NOT interrupted -- and the interrupt handler at the bottom
--      of this file listens for exactly that event. Without this line a
--      shielded player plates through incoming fire, which is the one thing
--      the hold exists to prevent;
--   3. the attacker's damage total never moves. main.lua counts the figure the
--      funnel reports, which is post-arbiter, so shield damage would simply not
--      be scored. It is credited here instead; the two halves sum to the real
--      number rather than double-counting it.
--
-- THE CORDON NEVER REACHES THIS FUNCTION, and that is the design, not an
-- oversight. The bleed is `Open77.players.damage`, and scripted damage does not
-- consult arbiters at all -- measured and written up at server/main.lua:107.
-- So the shield cannot absorb the cordon even by accident. The header at the
-- top of this file explains why the pool is kept off `entry.Armor`, which is
-- the half that would have made it absorb the cordon regardless.
-- ---------------------------------------------------------------------------
function L.absorbWithShield(event)
    local victim = K.players[tonumber(event.victim) or 0]
    if victim == nil or victim.state ~= "alive" then return nil end

    local pool = math.max(0, tonumber(victim.armor) or 0)
    local amount = tonumber(event.amount) or 0
    if pool <= 0 or amount <= 0 then return nil end

    local absorbed = math.min(pool, amount)
    victim.armor = pool - absorbed
    local remaining = amount - absorbed

    local attacker = K.players[tonumber(event.attacker) or 0]
    -- Self-damage is a real case here: a fall and an explosion of your own both
    -- name you as your own attacker. The shield still absorbs it -- only the
    -- scoring and the hitmarker are skipped.
    local hostile = attacker ~= nil and attacker.id ~= victim.id

    if hostile then
        attacker.damage = (attacker.damage or 0) + absorbed
    end

    -- (2) The hold is interrupted HERE, because the event that normally does it
    -- may never be raised for this hit.
    L.cancelUse(victim.id, "damaged")
    if K.squads ~= nil then K.squads.onDamage(victim.id) end

    -- (1) The hitmarker, for the case where nothing else will produce one.
    -- Bot participant IDs are negative: -1 means broadcast to the network API,
    -- and lower values are invalid envelopes. They earn damage credit above,
    -- but have no client to receive a hitmarker.
    if remaining <= 0 and hostile and attacker.id > 0 then
        TriggerClientEvent("cordon:hit", attacker.id, {
            amount = absorbed,
            bodyPart = tostring(event.bodyPart or "unknown"),
            lethal = false,
            -- The HUD currently tags every `cordon:hit` as a bot hit. That is
            -- cosmetic and it is the HUD's to fix -- this flag is here for it to
            -- read. The marker appears either way, which is the part that
            -- cannot be done from anywhere else.
            shield = true,
        })
    end

    -- Exactly once, on the hit that empties it: the early return above means a
    -- player already at zero never reaches this line.
    if victim.armor <= 0 then
        K.notice(victim.id, "shieldBroken", { held = victim.plates or 0 })
    end

    return remaining
end

SetTimeout(0, function()
    if type(Open77) ~= "table" or type(Open77.combat) ~= "table"
        or type(Open77.combat.onDamage) ~= "function" then
        K.warn("loot: no `Open77.combat.onDamage` binding, so shields absorb nothing. " ..
            "The `combat.config` permission is what installs it.")
        return
    end
    Open77.combat.onDamage(L.absorbWithShield)
    K.log("loot: shield absorption armed")
end)

-- ---------------------------------------------------------------------------
-- CONSUMABLES. Both are timed actions running a SERVER timer and both are
-- interrupted by damage: an instant heal in the open is not a decision, and the
-- decision is the whole point of carrying one.
-- ---------------------------------------------------------------------------
local function useEligibility(record, kind)
    if kind ~= "plate" and kind ~= "heal" then return false, "invalid_kind" end
    if record == nil or record.state ~= "alive" then return false, "not_alive" end
    if not K.match.isLive() or not K.match.isParticipant(record) then return false, "not_live" end
    local at = K.position(record.id)
    if at == nil or at.bucket ~= K.matchBucket() then return false, "wrong_bucket" end
    local held = kind == "plate" and (record.plates or 0) or (record.heals or 0)
    if held <= 0 then return false, "none_held" end
    if kind == "plate" then
        local capacity = capacityOf(record)
        if capacity <= 0 then return false, "no_shield" end
        if (record.armor or 0) >= capacity then return false, "armor_full" end
    else
        local ok, health = pcall(Open77.players.getHealth, record.id)
        if not ok or type(health) ~= "table" or type(health.health) ~= "number"
            or type(health.maxHealth) ~= "number" then return false, "health_unavailable" end
        if health.health <= 0 then return false, "not_alive" end
        if health.health >= health.maxHealth then return false, "health_full" end
    end
    return true
end

function L.beginUse(playerId, kind)
    local record = K.players[tonumber(playerId) or 0]
    local eligible, reason = useEligibility(record, kind)
    if not eligible then return false, reason end
    if applying[record.id] ~= nil then return false, "already_applying" end
    if K.squads and K.squads.isRevivingHealer and K.squads.isRevivingHealer(record.id) then
        return false, "already_applying"
    end
    -- THE CONFIG KEYS ARE `plateApplyMs` AND `healMs`. This read asked for
    -- `plateSeconds` and `healSeconds`, which exist in no config on this
    -- branch, so both fell through to the literal defaults beside them and the
    -- two durations the config block advertises as tunable were inert. It was
    -- invisible because the defaults happen to agree: 3000 ms and 4000 ms are
    -- exactly what 3.0 and 4.0 gave. Both spellings are honoured now, the
    -- documented one first.
    local seconds
    if kind == "plate" then
        seconds = (tonumber(inv().plateApplyMs) or 0) / 1000
        if seconds <= 0 then seconds = tonumber(inv().plateSeconds) or 3.0 end
    else
        seconds = (tonumber(inv().healMs) or 0) / 1000
        if seconds <= 0 then seconds = tonumber(inv().healSeconds) or 4.0 end
    end

    local duration = math.max(1, seconds * 1000)
    applying[record.id] = { kind = kind, untilMs = K.nowMs() + duration,
        durationMs = duration, record = record, matchId = K.match.current().id }
    K.notice(record.id, "using", { kind = kind, seconds = seconds })
    return true
end

function L.cancelUse(playerId, why)
    local id = tonumber(playerId)
    if id == nil or applying[id] == nil then return end
    applying[id] = nil
    K.notice(id, "useCancelled", { reason = why or "interrupted" })
end

function L.useView(record)
    local entry = record and applying[record.id]
    if entry == nil or entry.record ~= record or entry.matchId ~= K.match.current().id
        or not useEligibility(record, entry.kind) then return nil end
    return { kind = entry.kind, durationMs = entry.durationMs,
        remainingMs = math.max(0, entry.untilMs - K.nowMs()) }
end

function L.tick()
    local now = K.nowMs()
    local retired = false
    for id, crate in pairs(crates) do
        if crate.expiresAtMs and now >= crate.expiresAtMs then
            crates[id] = nil; removeContainer(id); retired = true
        end
    end
    if retired then L.publishCrates() end
    for playerId, entry in pairs(applying) do
        local record = K.players[playerId]
        local eligible, why = useEligibility(record, entry.kind)
        if record ~= entry.record or entry.matchId ~= K.match.current().id then
            -- Never notify or grant a replacement session that reused this id.
            applying[playerId] = nil
        elseif not eligible then
            L.cancelUse(playerId, why)
        elseif now >= entry.untilMs then
            applying[playerId] = nil
            if entry.kind == "plate" then
                local capacity = capacityOf(record)
                local was = math.max(0, tonumber(record.armor) or 0)
                record.armor = math.min(capacity, was + (inv().plateValue or 25))
                record.plates = record.plates - 1
                K.notice(playerId, "used", { kind = "plate", gained = record.armor - was,
                    armor = record.armor, capacity = capacity, held = record.plates })
            else
                -- The platform owns health. Spend the injector only after its
                -- canonical heal succeeds, including explicit false refusals.
                local called, healed, reason = pcall(Open77.players.heal, playerId, inv().healValue or 40)
                if called and healed == true then
                    record.heals = record.heals - 1
                    K.notice(playerId, "used", { kind = "heal", held = record.heals })
                else
                    K.notice(playerId, "useCancelled", { reason = called and reason or "heal_failed" })
                end
            end
        end
    end
end

--- Damage interrupts a timed action. Registered here rather than in main.lua so
--- the rule lives beside the thing it protects.
AddEventHandler("open77:playerDamaged", function(victimId)
    L.cancelUse(victimId, "damaged")
end)

RegisterNetEvent("cordon:use", function(kind)
    local playerId = source
    if kind ~= "plate" and kind ~= "heal" then return end
    local ok, why = L.beginUse(playerId, kind)
    -- Keep a refusal visible, including a full health pool or unavailable kit.
    if not ok then
        if why == "no_shield" then
            K.notice(playerId, "noShield", {})
        elseif why == "armor_full" then
            K.notice(playerId, "armorFull", { armor = K.players[tonumber(playerId) or 0]
                and (K.players[tonumber(playerId) or 0].armor or 0) or 0 })
        else
            K.notice(playerId, "useRefused", { reason = why })
        end
    end
end)

-- ---------------------------------------------------------------------------
-- DEATH DROPS. A kill has to be worth something, and four calls is the whole
-- of it: the loser's verified weapons hit the ground where they fell.
-- ---------------------------------------------------------------------------
-- Death loot shares the mode's collision-free, interactive container path.
-- If visual capacity is exhausted, native fallback stays in the same prompt
-- catalogue so a full prop budget cannot silently delete a loser's inventory.
function L.createDeathDrop(item, payload, position, quantity)
    local spec = containerSpecFor(payload.kind)
    if spec and containerCfg().crateOnly ~= false
        and containerCount < (tonumber(containerCfg().maxContainers) or 1200) then
        local propId = L.spawnContainer(spec, position, K.matchBucket())
        if propId ~= nil then
            crates[tostring(propId)] = { payload=payload, quantity=quantity or 1,
                x=position.x, y=position.y, z=position.z,
                labelHeight=(tonumber(spec.heightMetres) or 0.4)+0.15,
                expiresAtMs=K.nowMs()+(tonumber(cfg().deathDropTtlMs) or 300000) }
            return propId
        end
    end
    local id = Open77.loot.create({item=item, quantity=quantity or 1,
        position=position, bucket=K.matchBucket(), radius=tonumber(cfg().radiusMetres) or 2,
        label=payload.kind, ttlMs=tonumber(cfg().deathDropTtlMs) or 300000})
    if id then drops[tostring(id)] = payload end
    return id
end

function L.dropOnDeath(record)
    local position = K.position(record.id)
    if position == nil then return 0 end
    local dropped, spot = 0, 0
    local function nextDropPosition()
        spot = spot + 1
        local angle = (spot - 1) * 2.3999632297
        local radius = 0.65 + 0.28 * math.sqrt(spot - 1)
        return {x=position.x+math.cos(angle)*radius,
            y=position.y+math.sin(angle)*radius,z=position.z}
    end
    for tweakId, slot in pairs(record.weapons or {}) do
        local _ = slot
        -- Verified ids identify hits; assign() requires the original record
        -- NAME. Passing the hex id hashes that text into a different record.
        local template = record.weaponTemplates and record.weaponTemplates[tweakId]
        if type(template) == "string" then
            local label = record.weaponLabels and record.weaponLabels[tweakId] or "recovered"
            local id = L.createDeathDrop(template,
                {kind="weapon", weapon={record=template,label=label,reserve=60}},
                nextDropPosition(),1)
            if id ~= nil then dropped = dropped + 1 end
        else
            K.warn(("loot: player %d weapon %s has no assignment template; death drop skipped")
                :format(record.id, tostring(tweakId)))
        end
    end
    -- THE CARRIER COMES OFF THE BODY. It is the most valuable thing the loser
    -- was wearing and a kill has to be worth walking to, so it goes down at its
    -- own tier -- not converted into plates, which would launder a heavy
    -- carrier into three commons and quietly delete the tier economy.
    local wornTier = tierOf(record)
    if wornTier ~= nil then
        local shieldRecord = resolveRecord(wornTier, "shield:" .. tostring(wornTier.key or "?"))
        if shieldRecord ~= nil then
            L.createDeathDrop(shieldRecord, {kind="shield",shield=wornTier}, nextDropPosition(),1)
        end
    end
    -- The pool and the carrier both leave with the body, so a revived player
    -- comes back bare. `Config.strings` already promises exactly that in so
    -- many words: "%s pulled you back. %d HP, no armor."
    record.armor = 0
    record.armorTier = nil

    for _ = 1, (record.plates or 0) do
        local id = L.createDeathDrop((cfg().plate or {}).fallbackRecord or "Items.money",
            {kind="plate"},nextDropPosition(),1)
        if id ~= nil then record.plates = math.max(0,(record.plates or 0)-1) end
    end
    L.publishCrates()
    return dropped
end

function L.count() return seedCount end

--- The assign has completed and the client is holding the weapon, so the ammo
--- call will now be accepted. See the note in giveWeapon.
-- These refusals occur before equipment mutation in Weapons.cpp or
-- Open77WeaponAssign. Later failures can have partially modified inventory.
local assignmentRefusedBeforeMutation = {
    queue_full = true, player_unavailable = true, script_bridge_unavailable = true,
    invalid_weapon_template = true, template_is_not_weapon = true,
    invalid_weapon_slot = true, equipment_system_unavailable = true,
    unsupported_weapon_area = true, weapon_slot_locked = true,
}

local function uncertainAssignment(pending, requestId, reason)
    if pending.uncertain then return end
    pending.uncertain = true
    -- The relay timeout does not cancel the native operation. Keep this slot
    -- reserved until life/match cleanup; restoring its crate could duplicate
    -- a weapon whose success acknowledgement was lost.
    K.warn(("loot: weapon assignment %s unconfirmed (%s); slot %d reserved until reset")
        :format(tostring(requestId), tostring(reason), pending.slot))
    if K.players[pending.player.id] == pending.player then
        K.notice(pending.player.id, "pickupUncertain", {})
    end
end

AddEventHandler("open77:weapons:completed", function(playerId, requestId, operation, accepted, reason, result)
    local id = tonumber(playerId)
    if id == nil then return end
    if operation == "assign" then
        local pending = pendingWeapons[tostring(requestId)]
        if pending == nil or pending.player.id ~= id then return end
        local record = K.players[id]
        if not accepted then
            if assignmentRefusedBeforeMutation[tostring(reason)] then
                pendingWeapons[tostring(requestId)] = nil
                settleCrate(pending, false)
                K.warn(("loot: weapon assignment refused: %s player=%d template=%s")
                    :format(tostring(reason), id, tostring(pending.template)))
                if record == pending.player then K.notice(id, "pickupFailed", {}) end
            else
                uncertainAssignment(pending, requestId, reason)
            end
            return
        end
        if record ~= pending.player or record.state ~= "alive" or type(result) ~= "table"
            or tonumber(result.slot) ~= pending.slot then
            uncertainAssignment(pending, requestId, "invalid_assignment_result")
            return
        end
        local key = K.weaponId(result.tweakDbId)
        if key == "" then
            uncertainAssignment(pending, requestId, "missing_weapon_id")
            return
        end
        pendingWeapons[tostring(requestId)] = nil
        for old, slot in pairs(record.weapons) do
            if slot == pending.slot then
                record.weapons[old] = nil
                if record.weaponLabels then record.weaponLabels[old] = nil end
                if record.weaponTemplates then record.weaponTemplates[old] = nil end
            end
        end
        record.weapons[key] = pending.slot
        record.weaponLabels = record.weaponLabels or {}
        record.weaponLabels[key] = pending.label
        record.weaponTemplates = record.weaponTemplates or {}
        record.weaponTemplates[key] = pending.template
        settleCrate(pending, true)
        K.notice(id, "pickupWeapon", { label = pending.label, slot = pending.slot })
        local draw = Open77.weapons.setActive(id, pending.slot)
        if draw ~= nil then
            pendingAmmo[tostring(draw)] = { playerId = id, slot = pending.slot, reserve = pending.reserve }
        end
    elseif operation == "setActive" then
        local pending = pendingAmmo[tostring(requestId)]
        if pending == nil or pending.playerId ~= id then return end
        pendingAmmo[tostring(requestId)] = nil
        if accepted then pcall(Open77.weapons.setAmmo, id, pending.slot, { reserve = pending.reserve }) end
    end
end)

K.log("loot ready")


-- ---------------------------------------------------------------------------
-- CRATES: publishing them, and opening one.
-- ---------------------------------------------------------------------------

--- Everything a client needs to draw a prompt on a crate. Positions only: what
--- is inside is never sent, because a client that knows the contents of every
--- crate on the map is a client that can route straight to the good ones.
function L.cratePayload()
    local items = {}
    for propId, crate in pairs(crates) do
        items[#items + 1] = { id = propId, x = crate.x, y = crate.y, z = crate.z, kind=crate.payload.kind, labelHeight=crate.labelHeight }
    end
    for _, drop in ipairs(Open77.loot.all(K.matchBucket()) or {}) do
        local payload = drops[tostring(drop.id)]
        if payload then
            items[#items+1] = { id="d"..tostring(drop.id),x=drop.x,y=drop.y,z=drop.z,
                kind=payload.kind }
        end
    end
    return items
end

local catalogueSerial = 0
function L.publishCrates(playerId)
    local items = L.cratePayload()
    catalogueSerial = catalogueSerial + 1
    -- Bounded envelopes even after many deaths on a 64-player server. Clients
    -- replace the catalogue only after receiving every part of this revision.
    local total = math.max(1, math.ceil(#items / 64))
    local recipients = playerId ~= nil and {{id=playerId}} or K.humans()
    for part=1,total do
        local chunk = {}
        for i=(part-1)*64+1,math.min(part*64,#items) do chunk[#chunk+1]=items[i] end
        for _, record in ipairs(recipients) do
            TriggerClientEvent("cordon:crates", record.id, chunk,
                {generation=catalogueSerial,part=part,total=total})
        end
    end
end

--- A player asks to open a crate. The server owns every part of the decision:
--- the crate must exist, the match must be live, the player must be alive and
--- within reach. The client only ever asks.
--- Open one crate for one player. The whole rule, in one place.
---
--- Factored out of the net event so the OPERATOR verb below can take exactly
--- this path rather than a parallel one. A test that walks a second code path
--- proves that second path and nothing else; this way `br.loot.take` exercises
--- the same phase gate, the same reach check, the same claim-before-grant and
--- the same publish the player's own key press does.
---
--- @return boolean, string  granted, and why not when it refuses
function L.openCrate(record, propId)
    if record == nil or record.state ~= "alive" then return false, "not_alive" end
    if K.match == nil or not K.match.isLive() then return false, "not_live" end

    local key = tostring(propId)
    local crate = crates[key]
    if crate == nil then return false, "no_such_crate" end

    local position = K.position(record.id)
    if position == nil then return false, "no_position" end
    if position.bucket ~= K.matchBucket() then return false, "wrong_bucket" end
    local dx, dy, dz = position.x - crate.x, position.y - crate.y, position.z - crate.z
    local reach = tonumber(containerCfg().reachMetres) or 3.0
    if (dx * dx + dy * dy + dz * dz) > (reach * reach) then
        K.notice(record.id, "pickupFar", {})
        return false, "too_far"
    end

    -- Claimed BEFORE granting, so two players pressing at once cannot both be
    -- served: the second finds nothing here and is refused by the nil check.
    crates[key] = nil
    local weapon = crate.payload.kind == "weapon"
    local claim = weapon and { key = key, value = crate, generation = crateGeneration } or nil
    if not L.grant(record, crate.payload, crate.quantity, claim) then
        crates[key] = crate
        return false, "grant_failed"
    end
    if weapon then
        L.publishCrates()
        return true, "pending"
    end
    removeContainer(propId)
    L.publishCrates()
    -- HOW MANY CRATES THIS PLAYER HAS OPENED, and it exists so a test can
    -- assert on the act rather than on the roll. Everything a crate can grant
    -- is weighted -- a street crate is a weapon about one time in five -- so no
    -- kit number moves on every open, and an automated check that watched
    -- `guns` would pass or fail on the dice. This one moves every time. It is
    -- reported by `br.where`.
    record.cratesOpened = (record.cratesOpened or 0) + 1
    return true
end

--- The nearest crate to a player, and how far it is. Used by the operator verb
--- so a tester does not have to know a prop id to press.
function L.nearestCrate(record)
    if record == nil then return nil end
    local at = K.position(record.id)
    if at == nil then return nil end
    local bestId, bestDistance = nil, nil
    for key, crate in pairs(crates) do
        local dx, dy, dz = at.x - crate.x, at.y - crate.y, at.z - crate.z
        local distance = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
        if bestDistance == nil or distance < bestDistance then
            bestId, bestDistance = key, distance
        end
    end
    return bestId, bestDistance
end

RegisterNetEvent("cordon:loot:open", function(propId)
    L.openCrate(K.players[source], propId)
end)


--- Strips every weapon slot a player holds, and clears the mode's ledger with
--- it.
---
--- THE LEDGER IS NOT THE INVENTORY. `record.weapons = {}` in `M.toStaging` only
--- forgot what the mode had handed out; the engine still held the guns, so a
--- player walked into the next match carrying last match's loadout. The owner
--- caught it immediately: "when a match start it should reset all playesr
--- inventory, currently im keeping the weapons i have apparently".
---
--- That is not only unfair, it breaks the damage arbiter's premise: the arbiter
--- accepts only weapon ids it saw verified THIS match, so a carried-over gun is
--- a gun that cannot shoot -- fail-closed, and silently.
---
--- Slots are removed one at a time because that is the API the platform gives;
--- three calls per player at a match boundary is nothing, and each is a request
--- the client completes asynchronously.
function L.stripWeapons(record)
    if record == nil then return end
    applying[record.id] = nil
    discardPending(record.id)
    local slots = inv().weaponSlots or 3
    for slot = 1, slots do
        pcall(Open77.weapons.remove, record.id, slot)
    end
    pcall(Open77.weapons.holster, record.id)
    record.weapons = {}
    record.weaponLabels = {}
    record.weaponTemplates = {}
    -- THE SHIELD IS INVENTORY TOO. server/match.lua clears plates and heals at
    -- a match boundary and calls this function for the weapons, but nothing
    -- there knows the armour pool exists -- so a player who finished one match
    -- in a heavy carrier would start the next one with seventy-five free
    -- points and a capacity nobody granted them. This is the seam match.lua
    -- already reaches for, which is why the rule lives here rather than in a
    -- second reset somewhere else.
    record.armor = 0
    record.armorTier = nil
end

-- Relay teardown drops requests without a completion event. Release our
-- references even when the departed player was no longer alive.
AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if id ~= nil then
        applying[id] = nil
        discardPending(id)
    end
end)
