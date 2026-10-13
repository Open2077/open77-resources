-- rp_trauma / server/config.lua: the Trauma Team International service, as data.
--
-- Plans (tiers, prices, coverage, priority), the kiosks where they are sold, the response
-- actions (stabilise, evacuate), the fees, the medics' cut, the call dispatch and the
-- coordinator accounts. Server only: clients never read prices from here.
--
-- Positions: a point marked `measured = false` is an estimate from a nearby measured point;
-- the integrator walks it and moves it here. The down state, the hospital respawn point, the
-- AV pad and the legacy medic acts keep their keys in shared/config.lua (`Config`).
--
-- Global: TraumaConfig.

TraumaConfig = {}
local C = TraumaConfig

C.job = "trauma"            -- rp_jobs job of the responders
C.society = "trauma"        -- rp_economy society (account soc:trauma) every fee and plan is paid into
C.bucket = 0                -- routing bucket of the kiosks

-- ---------------------------------------------------------------------------------------------
-- Plans. `price` buys one period of `periodHours` (real time). `priority` orders the dispatch
-- (1 = first). `covers` is the fraction of each fee the plan pays (0..1): the patient is
-- charged the rest. `evacHealth` is the health fraction an evacuated patient wakes up with.
-- `dispatchDelaySeconds` holds a call back before it reaches the medics (0 = at once).
-- ---------------------------------------------------------------------------------------------
C.planOrder = { "silver", "gold", "platinum" }
C.plans = {
    silver = {
        label = "Silver", price = 1500, periodHours = 168, priority = 3, dispatchDelaySeconds = 5,
        covers = { stabilise = 1.0, evacuate = 0.5, hospital = 0.5, revive = 0.5, heal = 0.0 },
        evacHealth = 0.5,
        pitch = "Stabilisation covered, half of the evacuation and of Vik's bill.",
    },
    gold = {
        label = "Gold", price = 4000, periodHours = 168, priority = 2, dispatchDelaySeconds = 0,
        covers = { stabilise = 1.0, evacuate = 1.0, hospital = 1.0, revive = 1.0, heal = 0.5 },
        evacHealth = 0.75,
        pitch = "Stabilisation, evacuation and Vik's bill covered; priority dispatch.",
    },
    platinum = {
        label = "Platinum", price = 10000, periodHours = 168, priority = 1, dispatchDelaySeconds = 0,
        covers = { stabilise = 1.0, evacuate = 1.0, hospital = 1.0, revive = 1.0, heal = 1.0 },
        evacHealth = 1.0,
        pitch = "Everything covered, first in the queue, full health on arrival.",
    },
}
-- How many periods a player may pay ahead (renewing an active plan extends it by one period).
C.maxPrepaidPeriods = 4
-- Automatic renewal of an expired plan while the holder is connected, from the bank account only.
C.autoRenew = { default = true, from = { "bank" }, sweepSeconds = 30 }
-- How a plan is paid at a kiosk: bank first, then the cash wallet (one operation, both if needed).
C.payFrom = { "bank", "cash" }

-- ---------------------------------------------------------------------------------------------
-- Kiosks: where plans are sold (open77_actions targets, one card each). `landmark` is what players
-- read in `/tti plans`: words a player can walk to, no notes. A Trauma Team kiosk on the street of
-- the AV pad (the dispatch point of shared/config.lua `Config.av.pad`) and one in the Kabuki Market
-- hub. The market kiosk was walked in game; the pad kiosk was not: it is placed 6.5 m west of the
-- pad centre (-1370, 953, 23.5) and nobody has stood on it yet (`measured = false`).
-- ---------------------------------------------------------------------------------------------
C.kiosks = {
    {
        id = "tti_kiosk_pad", label = "Trauma Team kiosk", enabled = true, measured = false,
        position = { x = -1376.0, y = 950.5, z = 23.5 }, yaw = 90.0,
        landmark = "Afterlife street, beside the Trauma Team AV pad",
    },
    {
        -- Walked: the medical vending machine of The Stalls (the old point, 6 m from the market
        -- centre, was a cafe table against a wall).
        id = "tti_kiosk_market", label = "Trauma Team kiosk", enabled = true, measured = true,
        position = { x = -1223.91, y = 1989.45, z = 7.98 }, yaw = -14.7,
        landmark = "Kabuki Market, The Stalls: the medical vending machine beside Dr. Osei's Med-Point",
    },
}

-- ---------------------------------------------------------------------------------------------
-- Fees of each act (eddies), before the plan's coverage. `hospital` is the bill of a /respawn at
-- Vik's, `revive` and `heal` the ALT+click / slash-command acts: they keep their values in
-- shared/config.lua (Config.hospitalBill, reviveFee, healFee), which the client's menu labels show.
-- ---------------------------------------------------------------------------------------------
C.fees = {
    stabilise = 400,
    evacuate = 800,
    hospital = Config and Config.hospitalBill or 500,
    revive = Config and Config.reviveFee or 300,
    heal = Config and Config.healFee or 100,
}

-- The responding team's cut, as a fraction: of what the patient pays (straight from the
-- patient's wallet) and of what the plan covers (paid by the society when it can afford it).
-- The rest stays with the society.
C.medicShare = 0.4
C.medicWallet = "bank"
-- The cut is shared evenly by the medics of the call's team (/tti take, /tti assist) who are on
-- duty within this many metres of the patient when the act ends; the one who acted takes the
-- remainder. 0 pays only the medic who acted.
C.teamShareRadius = 30.0

-- An uninsured patient who answers the consent dialog is conscious: the charges need their yes.
-- No answer within `timeoutMs` counts as unconscious: the medic treats and the patient is billed
-- after (what the wallets do not cover becomes an invoice). A refusal holds for `declinedSeconds`.
C.consent = { timeoutMs = 15000, declinedSeconds = 60 }

-- What the patient's wallets do not cover becomes an invoice (eddies owed, paid with /tti pay).
C.invoices = { enabled = true, payFrom = { "bank", "cash" } }

-- ---------------------------------------------------------------------------------------------
-- Calls (raised when a player goes down; one per down episode).
-- ---------------------------------------------------------------------------------------------
C.calls = {
    uninsured = true,             -- a player without a plan still raises a (lower priority) call
    uninsuredPriority = 9,
    uninsuredDelaySeconds = 15,   -- held back before it reaches the medics
    remindSeconds = 60,           -- an untaken call is announced again this often
    sweepMs = 1000,
    maxCalls = 48,                -- one patient target each (open77_actions: 64 targets per resource)
}

-- ---------------------------------------------------------------------------------------------
-- Actions (open77_actions). Labels are plain ASCII (prompt cards).
-- ---------------------------------------------------------------------------------------------
C.actions = {
    subscribe = {
        id = "tti_plan", label = "Trauma Team plans", durationMs = 4000, maxDistance = 2.5,
        progress = "Signing the Trauma Team contract", profile = "tablet",
        menuTimeoutMs = 40000, reserveTimeoutMs = 55000,
    },
    stabilise = {
        id = "tti_stabilise", label = "Stabilise the patient", durationMs = 8000, maxDistance = 2.5,
        progress = "Stabilising the patient", profile = "examine",
        reserveTimeoutMs = 30000,
        health = 0.25,             -- the patient's health once stable (still down)
    },
    evacuate = {
        id = "tti_evacuate", label = "Evacuate to Vik's clinic", durationMs = 6000, maxDistance = 2.5,
        progress = "Preparing the evacuation", profile = "tablet2",
        reserveTimeoutMs = 30000,
        requiresStable = true,     -- stabilise first
    },
}
-- The prompt card over a patient: reach and height above the body.
-- keepCrowdOff: the crowd's pedestrians are kept off the body (an open77_pedestrians hold, 0.3-1.5 m).
-- Measured live in the Kabuki market: two standing NPCs stood on a downed patient's legs.
C.patientTarget = { distance = 2.0, promptHeight = 0.6, markerDistance = 25.0, keepCrowdOff = 1.5 }

-- Where an evacuated patient wakes up: nil = shared Config.hospital.respawn (Vik's clinic).
C.evacuation = { drop = nil, heading = nil, label = "Vik's clinic" }

-- ---------------------------------------------------------------------------------------------
-- Coordinator accounts and items (A13). `sys:` names have no second colon (mint rule grammar).
-- ---------------------------------------------------------------------------------------------
C.accounts = {
    plans = "sys:trauma.plans",       -- membership cards are minted out of it
    billing = "sys:trauma.billing",   -- invoices are minted out of it and burned back into it
    filePart = "tti",                 -- a holder's file: stash:<subject>:tti (card + invoices)
    fileCapacityG = 1000,
}
C.items = {
    tti_card = { label = "Trauma Team membership", weight = 0, unique = true, usable = false,
        illegal = false, category = "document" },
    tti_invoice = { label = "Trauma Team invoice (eddies owed)", weight = 0, usable = false,
        illegal = false, category = "document" },
}

-- Legacy rp_trauma 1.x state imported once per player (SQL rp_trauma_contracts / rp_trauma_bills,
-- or the kvp fallback): an active contract becomes a plan of this tier until its paid period ends;
-- an unpaid bill becomes an invoice.
C.legacy = { enabled = true, contractTier = "gold" }

C.notifyCooldownMs = 1500
C.receiptsKept = 8
