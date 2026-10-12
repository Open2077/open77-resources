-- rp_ripperdoc configuration. Shared: the client reads `quote.distance` (the ALT+click reach); the
-- server reads everything. Prices in eddies, durations in milliseconds, positions in metres.
--
-- Positions: `measured = false` marks a point nobody walked with this version of the job yet. Stand
-- on it in game, read `/pos`, correct it here and set `measured = true`. `source` says where each
-- point comes from.

RpRipperConfig = {}
local C = RpRipperConfig

-- ---------------------------------------------------------------------------------------------
-- The job. `job` is the rp_jobs job (label "Ripperdoc") that may quote, operate, restock and buy
-- chrome; `society` receives every fee (rp_jobs job name = rp_economy society name, soc:ripper).
-- `fixerJob` is the job id in the `rp:job:completed` event the fixer board listens to.
-- ---------------------------------------------------------------------------------------------
C.job = "ripper"
C.society = "ripper"
C.fixerJob = "ripperdoc"
C.bucket = 0

-- Asked by open77_actions at the start and again before the commit (operate, restock), and by this
-- resource for quotes and buy-backs. A clock-out moves the work epoch and stops what is running.
C.eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "ripper", duty = true } }
C.epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }

-- ---------------------------------------------------------------------------------------------
-- Clinics. Each one has a stock stash `stash:rd.<key>:stock`, an operating chair and the station
-- where the ripperdoc stands to operate. One procedure at a time per clinic.
-- ---------------------------------------------------------------------------------------------
C.clinics = {
    -- Viktor Vektor's clinic, under the Misty's Esoterica alley in Little China (Watson): the rp_zones
    -- `viktor_clinic` zone (centre -1548, 1230, 11.6, r 12), where rp_trauma wakes the dead up.
    viktor = {
        label = "Vik's clinic",
        zone = "viktor_clinic",          -- rp_zones zone the ripperdoc must stand in (nil = anywhere)
        zoneRadius = 12.0,               -- used only when rp_zones is not running (distance to the chair)
        stockCapacityG = 60000,          -- 30 boxed implants of 2 kg
        chair = {
            -- "placed": the patient lies through this resource's `lie` action (Open77.animations.playAt
            -- at the chair point, through open77_actions). "seating": the patient lies on a real
            -- furniture through open77_seating (its own prompt, or /ripper lie), `furniture` below.
            mode = "placed",
            -- Vik's chair room (AMM point; z is the floor under the chair + 0.1). The anchor of the
            -- lying posture: the integrator walks it with the posture playing and corrects it.
            position = { x = -1548.0, y = 1230.0, z = 11.6 },
            yaw = -89.5,
            arrivalRadius = 1.0,         -- playAt arrives within this radius (the chair pushes back)
            -- Lying / reclining profiles tried in order through Open77.animations.get (the first one
            -- the server's catalogue knows is played): rp-animation-catalogue `lie` (bed), `bedsidelie`
            -- (bed, on the side), `seatedsleep` (doze in a chair, for a reclining chair).
            profiles = { "lie", "bedsidelie", "seatedsleep" },
            lieMaxMs = 300000,           -- a patient gets up by themselves after this long
            furniture = nil,             -- seating mode: the open77_furniture id of the chair or bed
            spot = nil,                  -- seating mode: optional pose spot of that furniture
            label = "Operating chair",
            measured = false,
            source = "rp_ripperdoc 1.x chair (AMM point of Vik's chair room), rp_zones viktor_clinic centre",
        },
        station = {
            -- Where the ripperdoc stands to operate: 1.0 m to the side of the chair, facing it.
            position = { x = -1547.991, y = 1229.0, z = 11.6 },
            yaw = 0.5,
            label = "Operating station",
            measured = false,
            source = "arithmetic: 1.0 m to the right of the chair anchor (yaw -89.5), facing it",
        },
    },
}
C.clinicOrder = { "viktor" }

-- ---------------------------------------------------------------------------------------------
-- The chrome supplier: a fixed point in Night City where an on-duty ripperdoc buys stock for a
-- clinic (E "Buy chrome for the clinic", or /ripper restock). The boxes are delivered to the
-- clinic's stash in the same operation.
-- ---------------------------------------------------------------------------------------------
C.supplier = {
    id = "kabuki_chrome",
    label = "Chrome dealer",
    clinic = "viktor",               -- whose stash receives the order
    -- Kabuki Market, the tablet vendor by the market grill (pedestrian spot row 6552,
    -- amb_659592_stand_tablet at -1170.601, 2025.576, 7.761, yaw 120): the buyer stands 1.2 m in
    -- front of the vendor, facing them.
    position = { x = -1171.64, y = 2024.976, z = 7.761 },
    yaw = -60.0,
    measured = false,
    source = "arithmetic: 1.2 m in front of pedestrian spot row 6552 (amb_659592_stand_tablet, Kabuki Market)",
    -- "mint": boxes created out of sys:ripperdoc.supplier (an operator mint rule caps them per hour).
    -- "components": the same, but each box also burns the components its grade lists
    -- (`catalogue[].grades[].components`, e.g. a techie's parts) from `componentsFrom`; nothing is
    -- paid in money. The hook for a future techie job: give the grades their components.
    mode = "mint",
    componentsFrom = "char",         -- "char" = the ripperdoc's pockets, or an account id such as stash:...
    payFrom = { "society", "cash" }, -- who pays a mint order: the clinic's society, else the ripperdoc's cash
    priceFactor = 0.6,               -- wholesale share of the retail price
    maxCount = 5,                    -- boxes per order
    durationMs = 6000,               -- the order on the vendor's tablet
    profiles = { "tablet2", "phone" },
    reserveTimeoutMs = 45000,        -- the order menu stays open this long
}

-- ---------------------------------------------------------------------------------------------
-- The quote: the ripperdoc ALT+clicks a standing patient (or /ripper quote <id>), picks a procedure
-- in the catalogue, the patient accepts or declines on screen (or /interaction accept | decline).
-- Accepting puts the price and the implant on hold in ONE coordinator reservation.
-- ---------------------------------------------------------------------------------------------
C.quote = {
    distance = 4.0,                  -- ripperdoc and patient, server-observed
    inviteTimeoutMs = 30000,         -- time to answer
    interactionMs = 1000,            -- the consent step itself (no animation)
    validMs = 180000,                -- an accepted quote waits this long for the operation to start
    leashM = 25.0,                   -- an accepted patient who walks this far from the chair cancels it
    -- Optional RP profiles played during the consent step itself (Open77.playerInteractions
    -- actorAnimation / targetAnimation), e.g. "tablet2" on the ripperdoc. None by default.
    actorAnimation = nil,
    targetAnimation = nil,
}

-- The operation: the ripperdoc's action at the station.
C.operation = {
    -- Profiles tried in order: the standing drill workspot (amb_6862d5_stand_use_driller, drill
    -- checks and inspection), a tablet, the kneeling examination.
    profiles = { "amb_6862d5_stand_use_driller", "tablet2", "examine" },
    maxDistance = 2.5,
    installTimeoutMs = 20000,        -- the cyberware answer after the bar
    holdTtlMs = 600000,              -- the coordinator hold of an accepted quote (10 minutes at most)
    recoveryGraceMs = 30000,         -- after a restart, how long an unsettled install may still land
}

-- How a patient pays: the wallets tried in order.
C.payFrom = { "cash", "bank" }

-- A removal costs this share of the installed grade's price; it returns nothing to the stock.
C.removalPriceFactor = 0.5

-- Buying chrome from a player (/ripper buy <id> <implant> [grade] [count]): the seller accepts the
-- offer, the boxes go into the clinic's stash and the money to the seller in one operation.
C.buyback = {
    ratio = 0.5,                     -- share of the retail price paid per box
    maxCount = 5,
    distance = 3.0,
    inviteTimeoutMs = 20000,
    durationMs = 3000,               -- the platform's `give` presentation
    payFrom = { "society", "cash" },
}

-- Cyberpsychosis: a patient carrying MORE implants than this after an install gets the overlay
-- below and a warning. 0 shows it on the very first implant.
C.cyberpsychosisThreshold = 4
C.cyberpsychosis = {
    effect = "drugged",              -- Open77.effects.screen alias
    strength = 0.5,
    durationSeconds = 60,
}

-- ---------------------------------------------------------------------------------------------
-- The catalogue. One entry per implant slot the platform knows on this build (cyberware guide):
-- arms/gorilla_arms, legs/double_jump, operating_system/cyberdeck, self_ice/self_ice,
-- purge/active_purge. Every grade is stocked as its own boxed item (`item`, in `items` below) and
-- carries its RP fields (label, price, durationMs) next to the platform grade fields
-- Open77.cyberware.define wants; the hacking entries also carry `hacking`.
-- ---------------------------------------------------------------------------------------------
C.catalogue = {
    {
        key = "arms", label = "Gorilla Arms",
        slot = "arms", profile = "gorilla_arms",
        definitionId = "rp_ripperdoc.gorilla_arms", version = 1,
        grades = {
            { id = "street", label = "Street", price = 1500, durationMs = 15000, item = "implant_box_arms",
              normalDamage = 15, chargedDamage = 35, knockbackMeters = 2, normalKnockbackMeters = 0.5,
              cooldownMs = 800, chargeMs = 650, maxChargeMs = 10000,
              normalStaminaCost = 20, chargedStaminaCost = 35, nonlethal = true, cosmetic = false },
            { id = "industrial", label = "Industrial", price = 3200, durationMs = 22000, item = "implant_box_arms_ind",
              normalDamage = 30, chargedDamage = 70, knockbackMeters = 4, normalKnockbackMeters = 1.0,
              cooldownMs = 650, chargeMs = 650, maxChargeMs = 10000,
              normalStaminaCost = 20, chargedStaminaCost = 40, nonlethal = false, cosmetic = false },
        },
    },
    {
        key = "legs", label = "Reinforced Tendons",
        slot = "legs", profile = "double_jump",
        definitionId = "rp_ripperdoc.double_jump", version = 1,
        grades = {
            { id = "training", label = "Training", price = 1200, durationMs = 12000, item = "implant_box_legs",
              normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 800, chargeMs = 650,
              jumpStaminaCost = 15, maxAirborneMs = 10000, maxFallSpeed = 30 },
            { id = "athlete", label = "Athlete", price = 2500, durationMs = 18000, item = "implant_box_legs_ath",
              normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 400, chargeMs = 650,
              jumpStaminaCost = 8, maxAirborneMs = 10000, maxFallSpeed = 30 },
        },
    },
    {
        key = "deck", label = "Cyberdeck",
        slot = "operating_system", profile = "cyberdeck",
        definitionId = "rp_ripperdoc.cyberdeck", version = 1, hacking = "hack",
        grades = {
            { id = "street", label = "Street", price = 2000, durationMs = 20000, item = "implant_box_deck",
              normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
              hacking = { range = 20, uploadMs = 2000, staminaCost = 20, cooldownMs = 5000,
                          damage = 25, statusMs = 750, recoveryMs = 4000, nonlethal = true } },
        },
    },
    {
        key = "ice", label = "Self-ICE",
        slot = "self_ice", profile = "self_ice",
        definitionId = "rp_ripperdoc.self_ice", version = 1, hacking = "ice",
        grades = {
            { id = "street", label = "Street", price = 1800, durationMs = 14000, item = "implant_box_ice",
              normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
              hacking = { charges = 1, rechargeMs = 15000 } },
        },
    },
    {
        key = "purge", label = "Active Purge",
        slot = "purge", profile = "active_purge",
        definitionId = "rp_ripperdoc.purge", version = 1, hacking = "purge",
        grades = {
            { id = "street", label = "Street", price = 1600, durationMs = 14000, item = "implant_box_purge",
              normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
              hacking = { staminaCost = 15, cooldownMs = 8000, allowSelf = true, allowAlly = true,
                          range = 10, cancelUploads = true, removeStatuses = true } },
        },
    },
}

-- Boxed implants, one item per grade, registered in rp_inventory through exports.rp_inventory:define.
-- Illegal unless the holder has the `ripper` job (`permit`). The base grades keep the 1.x ids, so
-- boxes already in pockets and rp_crime's fence keep working.
C.items = {
    implant_box_arms     = { label = "Implant box: Gorilla Arms (Street)",            weight = 2.0, usable = false, illegal = true, permit = "ripper" },
    implant_box_arms_ind = { label = "Implant box: Gorilla Arms (Industrial)",        weight = 2.0, usable = false, illegal = true, permit = "ripper" },
    implant_box_legs     = { label = "Implant box: Reinforced Tendons (Training)",    weight = 2.0, usable = false, illegal = true, permit = "ripper" },
    implant_box_legs_ath = { label = "Implant box: Reinforced Tendons (Athlete)",     weight = 2.0, usable = false, illegal = true, permit = "ripper" },
    implant_box_deck     = { label = "Implant box: Cyberdeck (Street)",               weight = 2.0, usable = false, illegal = true, permit = "ripper" },
    implant_box_ice      = { label = "Implant box: Self-ICE (Street)",                weight = 2.0, usable = false, illegal = true, permit = "ripper" },
    implant_box_purge    = { label = "Implant box: Active Purge (Street)",            weight = 2.0, usable = false, illegal = true, permit = "ripper" },
}

-- ---------------------------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------------------------
C.sweepMs = 2000                     -- quote expiry, leash, deaths, unsettled installs
C.notifyCooldownMs = 1500            -- at most one refusal message per player per this long
C.lostOfferMs = 60000                -- an offer the platform no longer knows is dropped after this long
C.logKept = 100                      -- operations kept for /ripper (KVP ring)
C.color = "#B57BFF"
