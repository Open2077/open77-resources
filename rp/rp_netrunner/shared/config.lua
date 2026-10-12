-- rp_netrunner: the quickhacks, shared by the server (rules) and the client (ALT+click ranges, the
-- ping pin). The contract job (sites, tiers, the fixer drop, pay, the trace) is server-only:
-- server/config.lua. Nothing here is a secret.
Config = {}

-- The job (rp_jobs) every quickhack checks: a netrunner on duty.
Config.job = "netrunner"

-- Cooldown per quickhack kind, per netrunner (ms).
Config.cooldownMs = 30000

-- Probability that a quickhack leaves a trace: an rp_ncpd record on the netrunner plus an
-- rp_ncpd:alert where it was run (0 = never, 1 = always). A failed contract breach always does.
Config.traceChance = 0.5

-- Quickhack items, declared through exports.rp_inventory:define. One unit is burned (moved into
-- sys:netrunner through open77_transactions) per quickhack; all are contraband for the NCPD.
Config.items = {
    qh_ping          = { label = "Quickhack: Ping",          weight = 0.05, usable = false, illegal = true },
    qh_short_circuit = { label = "Quickhack: Short Circuit", weight = 0.05, usable = false, illegal = true },
    qh_overheat      = { label = "Quickhack: Overheat",      weight = 0.05, usable = false, illegal = true },
    qh_jammer        = { label = "Quickhack: Jammer",        weight = 0.10, usable = false, illegal = true },
}

-- The netrunner's operating system: one cyberdeck definition (Open77.hacking.define +
-- Open77.cyberware.define, same id / version / grade ids, slot operating_system). One grade = one
-- hack kind; the deck holds ONE grade at a time, so a Short Circuit deck must be reloaded with the
-- Overheat grade before an Overheat (the resource does it and asks to run the hack again).
Config.deck = {
    id = "rp_netrunner.deck",
    version = 1,
    -- Price charged (rp_economy charge, cash, to the netrunner society) when a grade is loaded; 0 = free.
    price = 0,
}

-- Player-targeted hacks: item burned, range (metres, 1-80) and the grade fields the platform
-- documents (hacking guide: "Hack grade" / "What each kind does").
Config.hacks = {
    short_circuit = {
        item = "qh_short_circuit", label = "Short Circuit", range = 25, uploadMs = 2000, staminaCost = 20,
        damage = 25, statusMs = 750, recoveryMs = 4000, nonlethal = true,
    },
    overheat = {
        item = "qh_overheat", label = "Overheat", range = 25, uploadMs = 2500, staminaCost = 20,
        damage = 10, statusMs = 750, recoveryMs = 4000, nonlethal = true,
        burn = { totalDamage = 40, durationMs = 5000, tickMs = 500 },
    },
}

-- Ping: a tracking pin on the target for the netrunner only.
Config.ping = {
    item = "qh_ping",
    range = 50,            -- metres between the netrunner and the target when the ping is sent
    durationMs = 60000,    -- how long the pin follows the target
    refreshMs = 2000,      -- server relay period of the target's position
    sprite = "objective",  -- map-capable vanilla sprite (blips guide: stable aliases)
    warnTarget = false,    -- true = the target reads "Your optics flicker" when pinged
}

-- Jam NCPD radio: rp_netrunner:jammed(true/false) on the host bus for the whole window and a
-- static line to every on-duty officer every noiseEveryMs.
Config.jam = {
    item = "qh_jammer",
    durationMs = 60000,
    noiseEveryMs = 15000,
    noise = {
        "kzzzt--- ...all units... ---tsszzk--- [CARRIER LOST]",
        "...10-4... ...repeat... [SIGNAL DEGRADED]",
        "---bzzzt--- ...dispatch, do you--- ---kzzz--- [NO CARRIER]",
        "...code 3... ...unreadable... [ICE ON THE LINE]",
    },
}

-- The quick tap on the deck that a ping or a jammer plays (open77_actions, no bar).
Config.gesture = { profile = "phonecheck", durationMs = 3000 }

-- Chat colours (positional { r, g, b }).
Config.colors = {
    net = { 0, 229, 255 },
    warn = { 255, 120, 0 },
    static = { 130, 130, 130 },
}
