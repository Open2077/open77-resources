-- rp_fixer / server/config.lua: everything an operator may move or retune.
--
-- Places are real Night City landmarks. Points marked `measured = false` were not walked by a
-- player for this resource: stand on the spot, read `/pos`, paste it here. Their sources:
--   * rp_fixer 1.0 (the Afterlife booth, Kabuki Noodle Row) and rp_zones (Vik's clinic);
--   * the pedestrian spot catalogue of open77_pedestrians (spots-generated.lua, dataset
--     cp2077-2310-9ff49a042f46aff01c17f276): vanilla vendor spots, used 1.5 m in front of the
--     vendor, where a customer stands;
--   * rp_salvage's scrapyard (the junkyard lane between its walked points).

FixerConfig = {}
local C = FixerConfig

C.bucket = 0

-- The fixer job (rp_jobs) a player needs, on duty, to post contracts from a board.
C.fixerJob = { job = "fixer", duty = true }

-- ---------------------------------------------------------------------------------------------
-- Money. Every reward is escrowed at post time: ONE rp_economy operation moves it out of the
-- poster's wallet (or, for a fixer NPC, creates it out of sys:rp_fixer:board) into the escrow
-- society account. Completion pays the runner and the fixers' cut out of escrow in ONE
-- operation; expiry or cancellation refunds the poster in ONE operation. Nobody withdraws from
-- the escrow society: it is not a job.
-- ---------------------------------------------------------------------------------------------
C.escrowSociety = "fixer_escrow"
C.cutSociety = "fixer"                      -- the fixers' society (rp_jobs job name)
C.cutRate = { npc = 0.15, player = 0.10 }   -- share of the reward kept for the fixers' society
C.escrowInstrument = "cash_then_bank"       -- how a player fixer funds a contract
C.npcFunding = "board"                      -- sys:rp_fixer:<label>: rp_economy's mint allowlist (rp_fixer)

-- ---------------------------------------------------------------------------------------------
-- Reputation (per player, SQL). Gates the better-paid contracts.
-- ---------------------------------------------------------------------------------------------
C.tiers = {
    { name = "street", min = 0 },
    { name = "known", min = 3 },
    { name = "trusted", min = 8 },
    { name = "legend", min = 20 },
}
C.reputation = {
    floor = 0,
    abandon = -1,      -- a runner walks away from a taken contract
    expire = -1,       -- a taken contract runs out
}

-- ---------------------------------------------------------------------------------------------
-- Limits and timing
-- ---------------------------------------------------------------------------------------------
C.maxLive = 48                 -- posting, open, taken and settling contracts on the server
C.maxPerPoster = 4             -- live contracts one player fixer may have posted
C.maxPerRunner = 2             -- contracts one runner may hold at once
C.boardReach = 4.0             -- /contracts answers within this distance of a fixer point
C.sweepMs = 5000               -- expiry, escrow settlement, payment retries, NPC watch
C.retryMs = 15000              -- a payment or refund that did not settle is sent again after this
C.postingSettleMs = 30000      -- an escrow still unknown after this is settled (fenced) or voided
C.notifyCooldownMs = 1500
C.briefMax = 120               -- characters of a fixer's own brief (plain ASCII only)
C.announce = true              -- tell the players who could take it that a contract was posted
C.recentKept = 24              -- settled contracts kept in memory for /contract and the board

-- NPC fixers keep their boards stocked from their `offers` (below).
C.npcBoard = { enabled = true, refillMs = 5 * 60 * 1000 }

-- ---------------------------------------------------------------------------------------------
-- Fixer points: one prompt with the board (E) and the hand-over of a retrieval (F), a delivery
-- drop on the same spot for crate carriers, an optional contact NPC and a map pin. `offers` =
-- the templates this NPC fixer posts itself, `keepOpen` = how many of them stay on its board.
-- ---------------------------------------------------------------------------------------------
C.hubs = {
    afterlife = {
        label = "The Afterlife", fixer = "Rogue", district = "Little China, Watson",
        -- Rogue's booth at the back of the Afterlife (rp_fixer 1.0 office, AMM floor + 0.1).
        position = { x = -1436.8, y = 977.0, z = 17.0 }, yaw = 83.0, measured = false,
        contact = { position = { x = -1435.6, y = 978.0, z = 16.9 }, yaw = 263.0 },
        offers = { "afterlife_meds_run", "afterlife_chips", "afterlife_breach", "afterlife_implant", "afterlife_box",
                   "afterlife_smuggle" },
        keepOpen = 2,
    },
    wakako = {
        label = "Wakako's", fixer = "Wakako Okada", district = "Japantown, Westbrook",
        -- 1.5 m in front of the Japantown street-food vendor (catalogue row 15042, wbr_jpn_food_01,
        -- -651.212, 925.495, 9.390, yaw 95), on Wakako's side of Japantown.
        position = { x = -652.71, y = 925.36, z = 9.39 }, yaw = -85.0, measured = false,
        contact = { position = { x = -653.9, y = 926.6, z = 9.39 }, yaw = -85.0 },
        offers = { "wakako_ripper_run", "wakako_components", "wakako_chooh2", "wakako_hardware" },
        keepOpen = 2,
    },
    regina = {
        label = "Regina's corner", fixer = "Regina Jones", district = "Kabuki, Watson",
        -- 1.5 m in front of the Kabuki market vendor (catalogue row 29556, wat_kab_foodshop_03,
        -- -1234.111, 1983.707, 7.973, yaw -116.22), inside the market's safe zone.
        position = { x = -1232.77, y = 1983.04, z = 7.97 }, yaw = 63.8, measured = false,
        contact = { position = { x = -1231.6, y = 1984.3, z = 7.97 }, yaw = 63.8 },
        offers = { "regina_psycho_kabuki", "regina_psycho_northside", "regina_noodle_drop", "regina_chooh2",
                   "regina_patch_up" },
        keepOpen = 2,
    },
}
C.hubOrder = { "afterlife", "wakako", "regina" }

-- The contact standing at each board (presentation only; a refusal is logged, the board works
-- without it). Proven alias, invulnerable and passive. Records to try once checked in game:
-- Character.RogueOld_Puppet_Photomode, Character.Wakako_Puppet_Photomode,
-- Character.Regina_Puppet_Photomode (catalogue risk "candidate").
C.contactNpc = { enabled = true, template = "civilian_female_relaxed_01", record = nil, damagePolicy = 2 }

-- The board prompt and the hand-over (open77_actions).
C.actions = {
    board = { label = "Contract board", durationMs = 500 },
    handover = { label = "Hand over the goods", progress = "Handing over", durationMs = 3000,
                 animation = { profile = "give", at = "self", required = false } },
    maxDistance = 2.5,
}

-- ---------------------------------------------------------------------------------------------
-- Delivery: a crate is set at the pickup point when a runner takes the contract; only that
-- runner can lift it; it is delivered by putting it down on the drop (a fixer point, or a drop
-- zone of C.drops). Carried on foot: a vehicle, a drawn weapon or a fall drops it where it is.
-- ---------------------------------------------------------------------------------------------
C.crate = { model = "crate.ammo_box", label = "sealed crate", reach = 2.0 }
C.points = {
    -- Kabuki, Noodle Row (rp_fixer 1.0, walked).
    kabuki_noodle_row = { label = "Kabuki Market, Noodle Row", position = { x = -1178.66, y = 2028.45, z = 7.95 },
                          yaw = 0.0, measured = false },
    -- Vik's clinic door (rp_zones `viktor_clinic` centre).
    vik_clinic = { label = "Vik's clinic", position = { x = -1548.0, y = 1230.0, z = 11.6 }, yaw = 0.0, measured = false },
    -- 1.5 m in front of the Japantown ripperdoc (catalogue row 37085, wbr_jpn_ripdoc_01,
    -- -714.930, 869.112, 11.986, yaw -40.82).
    japantown_ripperdoc = { label = "Japantown ripperdoc", position = { x = -713.95, y = 870.25, z = 11.99 },
                            yaw = 139.2, measured = false },
}
-- Extra drop zones a crate may be delivered to (key -> { label, position, measured }). Every
-- fixer point is a drop zone already, under its hub key.
C.drops = {}

-- ---------------------------------------------------------------------------------------------
-- Cyberpsycho sightings: where a bounty's target spawns. All outside safe zones.
-- ---------------------------------------------------------------------------------------------
C.sightings = {
    -- Kabuki, the burrito-machine alcove north-west of the market (walked 2026-10-12: a street
    -- corner by the crowd spots 6087/34829), 96 m from the market centre: outside the
    -- `kabuki_market` safe zone (r 70). The old catalogue spot 15215 stood behind a closed shutter.
    kabuki_alley = { label = "Kabuki, north-west of the market", position = { x = -1265.0, y = 2062.91, z = 11.98 },
                     yaw = 0.0, measured = true },
    -- Northside industrial district (catalogue row 8055, wat_nid_foodshop_01 spot).
    northside = { label = "Northside industrial", position = { x = -1914.454, y = 2739.485, z = 10.899 },
                  yaw = -47.0, measured = false },
    -- Rancho Coronado junkyard, the open lane between the wreck stack and the bays (rp_salvage).
    junkyard = { label = "Rancho Coronado junkyard", position = { x = 1374.5, y = -1681.0, z = 49.3 },
                 yaw = 0.0, measured = false },
}

-- The cyberpsycho: a mortal, hostile server NPC whose player hits the platform prices
-- (hitPricing = "platform"), so its death names the shooter. Proven combat record (rp_fixer 1.0
-- guards). Candidates once checked in game: Character.ma_pac_cvi_08_psycho,
-- Character.ma_pac_cvi_15_cyberpsycho (catalogue risk "candidate").
C.psycho = {
    record = "Character.cpz_maelstrom_grunt1_ranged1_lexington_wa",
    health = 400,
    leash = 12,                -- Open77.npcs.tasks.guard radius around the sighting (2..100)
    engageDistance = 25.0,     -- ordered to attack the nearest player inside this distance
    group = "rp_fixer_psychos",
    creditWindowMs = 30000,    -- a death with no player source credits the last player hit this recent
    respawnMs = 60000,         -- a lost body, or one nobody killed, comes back after this
    clearRadius = 4.0,         -- never spawned with a player this close to the sighting (0 = off)
    clearRetryMs = 5000,       -- how soon a spawn held back by a player on the spot is tried again
    corpseMs = 30000,          -- a dead cyberpsycho's body is removed after this
}

-- ---------------------------------------------------------------------------------------------
-- Contract templates. Common fields: kind, title, brief, reward = { min, max } (eddies, the
-- escrowed gross), hours (time to expiry), minRep, repGain, posters ({ npc, player }).
--   delivery   from = a C.points key, to = a hub key or a C.drops key
--   retrieval  item (an rp_inventory item id), count, drop = the hub where it is handed over
--   job        job, kinds = { ... }, count, match = { data field = value } (optional: the event
--              counts only when every field equals the event's `data` field, compared as text),
--              countField = the data field holding a count (default: 1 per event)
--   bounty     sighting = a C.sightings key, mode = "claimed" | "open" (a player fixer chooses
--              in the post dialog), onForeignKill = "refund" | "respawn" (claimed mode: a kill
--              by someone who does not hold the contract)
-- ---------------------------------------------------------------------------------------------
C.templates = {
    -- The Afterlife (Rogue)
    afterlife_meds_run = {
        kind = "delivery", title = "Meds for Vik", posters = { npc = true, player = true },
        brief = "A sealed crate from Vik's clinic to Rogue's booth. On foot, no questions.",
        from = "vik_clinic", to = "afterlife", reward = { min = 600, max = 900 }, hours = 2, minRep = 0, repGain = 1,
    },
    afterlife_chips = {
        kind = "retrieval", title = "Clean data chips", posters = { npc = true, player = true },
        brief = "Three clean data chips, brought to the booth.",
        item = "chip", count = 3, drop = "afterlife", reward = { min = 500, max = 800 }, hours = 4, minRep = 0, repGain = 1,
    },
    afterlife_breach = {
        kind = "job", title = "Breach a terminal", posters = { npc = true, player = true },
        brief = "A client needs a terminal cracked. Any successful breach counts, the log is the proof.",
        job = "netrunner", kinds = { "breach_success" }, count = 1, reward = { min = 900, max = 1400 }, hours = 4,
        minRep = 3, repGain = 2,
    },
    afterlife_implant = {
        kind = "job", title = "Install an implant", posters = { npc = true, player = true },
        brief = "Somebody owes Rogue a favour and wants chrome. Install an implant in a ripperdoc's chair.",
        job = "ripperdoc", kinds = { "operation" }, match = { action = "install" }, count = 1,
        reward = { min = 1200, max = 1800 }, hours = 6, minRep = 3, repGain = 2,
    },
    -- rp_nomade fires `deliver` once per crate handed over, with `data.complete = true` on the one
    -- that empties the run: the order counts the run brought home, not its first crate.
    afterlife_smuggle = {
        kind = "job", title = "A nomad run", posters = { npc = true, player = true },
        brief = "Rogue has a buyer waiting for a load from the Badlands. Bring a nomad run home.",
        job = "nomad", kinds = { "deliver" }, match = { complete = true }, count = 1,
        reward = { min = 1500, max = 2500 }, hours = 8, minRep = 3, repGain = 2,
    },
    -- The box is rp_ripperdoc's graded item (Gorilla Arms, Street grade): without rp_ripperdoc
    -- running, the item is unknown and this contract is not posted.
    afterlife_box = {
        kind = "retrieval", title = "Gorilla Arms in a box", posters = { npc = true, player = true },
        brief = "A boxed set of Gorilla Arms, no serials. Rogue pays well and forgets fast.",
        item = "implant_box_arms", count = 1, drop = "afterlife", reward = { min = 2500, max = 3500 }, hours = 6,
        minRep = 8, repGain = 3,
    },
    -- Wakako's
    wakako_ripper_run = {
        kind = "delivery", title = "Chrome for Wakako", posters = { npc = true, player = true },
        brief = "A crate from the Japantown ripperdoc to Wakako's people. Walk it over.",
        from = "japantown_ripperdoc", to = "wakako", reward = { min = 500, max = 800 }, hours = 2, minRep = 0, repGain = 1,
    },
    wakako_components = {
        kind = "retrieval", title = "Components", posters = { npc = true, player = true },
        brief = "Four components for a Tyger Claws mechanic. Wakako takes them herself.",
        item = "component", count = 4, drop = "wakako", reward = { min = 600, max = 900 }, hours = 4, minRep = 0, repGain = 1,
    },
    wakako_chooh2 = {
        kind = "job", title = "Refine 10 CHOOH2", posters = { npc = true, player = true },
        brief = "Wakako has a buyer for fresh CHOOH2. Refine ten canisters at the plant.",
        job = "chooh2", kinds = { "refine" }, count = 10, countField = "canisters",
        reward = { min = 1500, max = 2200 }, hours = 8, minRep = 3, repGain = 2,
    },
    wakako_hardware = {
        kind = "job", title = "Two clean pieces", posters = { npc = true, player = true },
        brief = "Wakako's people need hardware without a history. Assemble two weapons at a bench.",
        job = "techie", kinds = { "assemble" }, count = 2, reward = { min = 900, max = 1400 }, hours = 6,
        minRep = 0, repGain = 1,
    },
    -- Regina's corner
    regina_psycho_kabuki = {
        kind = "bounty", title = "Cyberpsycho in Kabuki", posters = { npc = true, player = true },
        brief = "A psycho is tearing up the street north-west of the market. Whoever puts them down gets paid.",
        sighting = "kabuki_alley", mode = "open", reward = { min = 2000, max = 3000 }, hours = 2,
        minRep = 3, repGain = 3,
    },
    regina_psycho_northside = {
        kind = "bounty", title = "Cyberpsycho in Northside", posters = { npc = true, player = true },
        brief = "A sighting in Northside. Claim it, then go: nobody else gets paid for this one.",
        sighting = "northside", mode = "claimed", onForeignKill = "refund",
        reward = { min = 3000, max = 4500 }, hours = 3, minRep = 8, repGain = 4,
    },
    regina_noodle_drop = {
        kind = "delivery", title = "Noodle Row pickup", posters = { npc = true, player = true },
        brief = "A crate waits on Noodle Row. Regina wants it at her corner, unopened.",
        from = "kabuki_noodle_row", to = "regina", reward = { min = 400, max = 600 }, hours = 2, minRep = 0, repGain = 1,
    },
    -- The canister is rp_chooh2's refinery output (`chooh2_canister`, not rp_inventory's `chooh2`
    -- fuel can): without rp_chooh2 running, the item is unknown and this contract is not posted.
    regina_chooh2 = {
        kind = "retrieval", title = "Two canisters of CHOOH2", posters = { npc = true, player = true },
        brief = "Regina's driver is dry. Two CHOOH2 canisters from the Petrochem refinery, at her corner.",
        item = "chooh2_canister", count = 2, drop = "regina", reward = { min = 500, max = 750 }, hours = 4,
        minRep = 0, repGain = 1,
    },
    -- rp_trauma reports `stabilise` (E "Stabilise the patient", the 8 s act on a downed body) and
    -- `revive` (ALT+click or /reanimer); Patch up on a standing citizen reports nothing.
    regina_patch_up = {
        kind = "job", title = "Keep them breathing", posters = { npc = true, player = true },
        brief = "The psychos leave bodies. Regina pays for every one a medic brings back: stabilise or revive two.",
        job = "trauma", kinds = { "stabilise", "revive" }, count = 2, reward = { min = 800, max = 1200 }, hours = 6,
        minRep = 0, repGain = 1,
    },
    junkyard_psycho = {
        kind = "bounty", title = "Cyberpsycho at the junkyard", posters = { player = true },
        brief = "Scrappers saw a psycho at the Rancho Coronado junkyard.",
        sighting = "junkyard", mode = "claimed", onForeignKill = "respawn",
        reward = { min = 2500, max = 6000 }, hours = 3, minRep = 3, repGain = 3,
    },
}
-- The order the post dialog lists player templates in.
C.templateOrder = {
    "afterlife_meds_run", "regina_noodle_drop", "wakako_ripper_run",
    "afterlife_chips", "wakako_components", "regina_chooh2", "afterlife_box",
    "wakako_hardware", "regina_patch_up", "afterlife_breach", "afterlife_implant", "wakako_chooh2",
    "afterlife_smuggle",
    "regina_psycho_kabuki", "regina_psycho_northside", "junkyard_psycho",
}

-- Hours a player fixer may choose in the post dialog.
C.postHours = { 1, 2, 4, 8, 24 }
C.rewardStep = 50
