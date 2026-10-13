-- rp_trauma - shared configuration (loaded on the server and on every client).
-- Everything a server owner may want to move or retune lives here.

Config = {}

-- The job (rp_jobs v2 name; "medecin" is accepted as an alias by rp_jobs) and the
-- society (rp_bank) every fee and bill is paid into.
Config.job = "trauma"
Config.society = "trauma"

-- How long a player stays "down" after death before /respawn is accepted while a
-- medic is on duty: 600 (10 min), time for a team to answer the call. A test server that
-- wants the whole flow in a minute sets 60.
Config.downSeconds = 600

-- /respawn is accepted after the countdown, or at once when no medic is on duty (false).
-- `true` keeps the countdown even with nobody on duty, so one tester alone can see it.
Config.countdownWithoutMedics = false

-- The down state survives a disconnect and a restart (of this resource or of the server): while
-- a player is down it is saved in this resource's kvp store under their durable subject. A player
-- who left while down, or whom a restart let go, is held down again at the same spot when they are
-- back, with what their countdown had left. The countdown runs on while they are away: once it has
-- run out, /respawn is open at once. `false`: the old rule, a disconnect or a restart frees the
-- body (a restart at full health).
Config.downPersist = true

-- A saved down state older than this many seconds (counted from the fall) is dropped and the
-- player comes back on their feet. Default 3 hours.
Config.downPersistMaxSeconds = 3 * 60 * 60
-- A held body found farther than this from its spot (metres, or as far below it: a floor that had
-- not streamed in) is put back on it.
Config.downSpotRadius = 3.0

-- What the hospital charges for a /respawn before the patient's plan (bank, then cash,
-- then an invoice).
Config.hospitalBill = 500

-- Medic fees before the patient's plan, charged through the coordinator and paid into the
-- trauma society (the medic gets a cut, server/config.lua TraumaConfig.medicShare).
Config.healFee = 100    -- Patch up (ALT+click) / /soin
Config.reviveFee = 300  -- Revive (ALT+click) / /reanimer

-- Progress bars shown to the medic (milliseconds), staged with Config.Stage below.
Config.stabiliseMs = 5000
Config.reviveMs = 8000

-- Staging (2026-09-18 pass): every intervention plays a pose, shows a prop and takes its time
-- behind a UI-kit bar, so the patient and the bystanders see the medic work. Same rules as
-- rp_mecano / rp_nomade: `pose.profiles` are open77_animations profiles tried in order through
-- Open77.animations.get (best FUTURE name first -- a base PR is adding medical profiles -- then
-- what today's 18-profile eval catalogue has); `loop = true` is held for the bar and stopped by
-- the server, `loop = false` is a one-shot of `durationMs`. Props are curated aliases (see
-- `prop.catalog`) tried in order, attached to a rig slot ("RightHand") or to the body root
-- (`bone = ""`); hand-slot axes are not measured on 2.31, start from zero and move one axis at
-- a time. A workspot is cancelled by the platform when the player moves > 0.5 m; the bar keeps
-- the medic still (client side, never a server freeze).
Config.Stage = {
    enabled = true,
    color = "#FF6060",
    -- Stabilise: kneeling over the patient with the injector in the right hand.
    stabilise = {
        durationMs = 5000,
        label = "Stabilising the patient",
        pose = { profiles = { { profile = "medical" }, { profile = "examine" } }, loop = true },
        prop = { models = { "medical.injector", "medical.device" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- Revive: same kneel, longer, the medical kit open at the medic's feet as well.
    revive = {
        durationMs = 8000,
        label = "Reviving the patient",
        pose = { profiles = { { profile = "medical" }, { profile = "examine" } }, loop = true },
        prop = { models = { "medical.injector", "medical.device" }, bone = "RightHand", offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
        place = { models = { "medical.kit", "medical.container" }, bone = "", offset = { x = 0.6, y = 0.3, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- The down player: held in the wounded seated pose for as long as they are down
    -- (started once the hold is applied, stopped on revive / respawn / disconnect). The
    -- platform may refuse it on a frozen body: logged once, the hold works without it.
    down = {
        pose = { profiles = { { profile = "wounded" } }, loop = true },
    },
    -- /911: the caller dials on the holo (one-shot, no bar).
    call = {
        durationMs = 3000,
        pose = { profiles = { { profile = "phone" } }, loop = false },
    },
}

-- Ranges in metres: the ALT+click action, and the slash-command fallback.
Config.actionRange = 3.0
Config.commandRange = 5.0

-- Health of a player while down (fraction of their maximum) and after a medic
-- revive. A hospital respawn restores full health.
Config.downHealthFraction = 0.05
Config.reviveHealthFraction = 0.5
Config.reviveGraceMs = 5000

-- Seconds between two paid acts of the same medic (spam guard).
Config.medicCooldownSeconds = 10

-- Reminder sent to a down player every N seconds (chat + toast).
Config.downReminderSeconds = 30

-- Trauma Team plans (Silver, Gold, Platinum), their kiosks, the response fees and the
-- medics' cut live in server/config.lua (TraumaConfig): the server owns every price.

-- "The hospital": where a /respawn puts the body. In the lore you wake up at Vik's, so
-- it is Viktor Vektor's clinic (Little China, Watson; the rp_zones `viktor_clinic` zone,
-- AMM chair room -1548, 1230, 11.5), 855 m south-west of the freeroam spawn (Kabuki
-- Market Centre -1191.30, 2006.88, 7.82). The respawn point is 2 m off the chair.
-- The keys keep their names (rp_config overrides `rp_trauma.hospital.*`).
Config.hospital = {
    zone = "viktor_clinic",
    respawn = { x = -1546.0, y = 1231.0, z = 11.6 },
    heading = 180.0,
}

-- The Trauma Team AV spawned by /trauma av (on-duty medic, standing on the pad), with the
-- medic at the controls. No `_player` variant of any AV exists in the 2.31 catalogue.
Config.av = {
    -- Measured 2026-10-13 on 2.31: Vehicle.av_trauma and Vehicle.av_trauma_savable are accepted by
    -- the server but never spawn on a client (the request registers and no entity follows), so the
    -- medic sat in nothing. The Militech Manticore, the same AV-4 airframe, spawns in 130 ms and flies.
    record = "Vehicle.av_militech_manticore",
    spawnDistance = 8.0,   -- metres in front of the medic
    spawnUp = 1.0,         -- metres above the medic's feet
    ttlMs = 30 * 60 * 1000,
    despawnWhenUnobserved = true,
    -- The landing / dispatch pad: the real street outside the Afterlife ramp (probed
    -- crosswalk -1408.0, 960.0, 23.5; a clinic interior cannot take an AV). The medic must
    -- stand within `radius` metres (planar) of it for /trauma av.
    pad = { x = -1370.0, y = 953.0, z = 23.5, radius = 12.0, label = "Afterlife street" },  -- east of the garage bays (-1398..-1380, y 953) so the AV never lands on a parked car
}

-- Blips drawn on every on-duty medic's map while a player is down. A per-blip
-- colour does not exist on 2.31, so the "gold" contract-holder pin is a different
-- sprite. `refreshMs` is how often the distance in the pin title is refreshed.
Config.blip = {
    sprite = "SOSsignalVariant",
    contractSprite = "important",
    refreshMs = 2000,
}

-- Chat colours (positional { r, g, b } arrays, as the chat UI expects).
Config.colors = {
    trauma = { 255, 96, 96 },
    alert = { 255, 190, 60 },
    info = { 120, 200, 255 },
}
