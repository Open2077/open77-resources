-- open77_admin -- configuration.
--
-- Shared, so the panel can render what the server will enforce. Nothing here is
-- an authorisation decision: rights live in acl.jsonc and are resolved by the
-- server host before any handler in this resource runs. See README.md.

Open77AdminConfig = {

    -- The panel's own identity, shown in its title bar.
    label = "OPEN//77 ADMIN",

    -- ------------------------------------------------------------------
    -- Rate limits, applied server-side, per calling player.
    --
    -- The transport already caps 32 events/second per session, but that is a
    -- limit on packets, not on effect: thirty spawns a second is inside the
    -- budget and would still take a server down.
    -- ------------------------------------------------------------------
    limits = {
        readIntervalMs = 500,       -- floor between two read commands
        actionIntervalMs = 250,     -- floor between two mutations
        vehiclesPerOperator = 24,   -- ledger cap; cleanup releases them
        propsPerOperator = 64,      -- ledger cap for props and lights; clear releases them
        auditEntries = 200,         -- ring buffer, current uptime only
        rosterPushMs = 1000,        -- panel poll cadence while open
    },

    -- ------------------------------------------------------------------
    -- Short aliases.
    --
    -- An operator under pressure types /noclip, not /admin.self.noclip. These
    -- register the bare name in ADDITION to the namespaced one, with the same
    -- handler, but its own `command.<alias>` permission. Alias rights must be
    -- granted explicitly; a namespaced permission does not grant its alias.
    --
    -- Command dispatch walks running resources in ordinal NAME order and takes
    -- the first match. Duplicate handlers can therefore shadow these aliases.
    -- In particular Freeroam must NOT register noclip/fly/noclip.speed: all
    -- flight entry points need this resource's single state and native owner.
    -- For the remaining names, freeroam (f) beats open77_admin (o), whereas
    -- `open77_admin` (a) beats `open77_freeroam` (f), so the properly gated
    -- kick/ban here shadow that resource's Lua-enforced pair.
    --
    -- Set `aliases.enabled = false` on a server where you would rather type
    -- the long names than reason about which resource answers.
    -- ------------------------------------------------------------------
    aliases = {
        enabled = true,
        map = {
            ["noclip"]       = "admin.self.noclip",
            ["fly"]          = "admin.self.fly",
            ["noclip.speed"] = "admin.self.speed",
            ["god"]          = "admin.self.god",
            -- Arms the map's double-click travel, and carries the click itself.
            -- Rights are not shared between a name and its alias, so the arming
            -- reply tells the client WHICH word was typed and the double click
            -- sends that same word back -- otherwise an operator granted only
            -- `command.maptp` could arm the gesture and then be refused by it.
            ["maptp"]        = "admin.self.maptravel",
            ["heal"]         = "admin.self.heal",
            ["players"]      = "admin.read.players",
            -- Same canonical/alias split as `players`, and for the same
            -- reason: the canonical name answers in structured data and total
            -- silence so a polling surface leaves no trace in chat, and the
            -- alias is the one a human types to get the slot listing printed.
            -- Without it there is no human path to the reading at all.
            ["weapons"]      = "admin.read.weapons",
            ["goto"]         = "admin.player.at",
            ["bring"]        = "admin.player.bring",
            ["tpall"]        = "admin.bulk.tpall",
            ["dvall"]        = "admin.bulk.dvall",
            ["tp"]           = "admin.player.tp",
            ["kick"]         = "admin.moderate.kick",
            ["ban"]          = "admin.moderate.ban",
            ["car"]          = "admin.veh.spawn",
            ["dv"]           = "admin.veh.remove",
            -- `gun`, and NOT `weapon.give`: `open77_weapons` owns the
            -- `weapon.*` names and `open77_admin` (a) would shadow it in
            -- ordinal dispatch order. See the note in `weapons.aliases`.
            ["gun"]          = "admin.weap.give",
            ["announce"]     = "admin.world.announce",
            -- Props and effects. The BARE names only, deliberately.
            --
            -- `open77_props` and `open77_effects` own `prop.*`, `light.*` and
            -- `fx.*`, and dispatch takes the first resource in ordinal name
            -- order: `open77_admin` (a) beats both (p, e). An alias spelled
            -- `prop.here` here would therefore SHADOW the registry's own
            -- command -- a resource whose commands are already ACL-gated and
            -- which owns props this package cannot mutate. Shadowing freeroam
            -- was the point; shadowing the props authority is not.
            ["prop"]         = "admin.props.here",
            ["props"]        = "admin.props.list",
            ["fx"]           = "admin.fx.play",
        },
    },

    -- ------------------------------------------------------------------
    -- Teleport transaction.
    --
    -- Every move is a kill -> respawn, never a transform write: a direct
    -- teleport over any real distance drops the player into unstreamed world,
    -- and the respawn transaction is what carries the fade, the streaming
    -- preload and the grace window.
    -- ------------------------------------------------------------------
    bulk = {
        teleportIntervalMs = 750, -- one player at a time, never a same-tick wave
        spacing = 3.0,           -- concentric rings, with the operator at the centre
        vehicleIntervalMs = 150,
        exitTimeoutMs = 5000,    -- never remove a vehicle while an occupant remains
        cooldownMs = 10000,
    },

    teleport = {
        health = 1.0,
        graceMs = 5000,
        -- Metres to the side of the caller when bringing someone to them, so
        -- two players never resolve inside each other.
        bringOffset = { x = 1.6, y = 0.0, z = 0.0 },
    },

    -- ------------------------------------------------------------------
    -- Saved destinations.
    --
    -- Seeded from resources/gamemodes/freeroam/shared/config.lua, whose coordinates come
    -- from repository captures and are known-safe landing spots. Runtime
    -- additions from /admin.world.loc.add live in Open77.state, which survives
    -- a reload but deliberately not a stop -- so an operator keeps a "come up
    -- as at boot" lever.
    -- ------------------------------------------------------------------
    locations = {
        { name = "lab",       label = "Open77 laboratory",    position = { x = 1669.75, y = -739.12, z = 49.86 },   heading = 0.0 },
        { name = "city",      label = "City west",            position = { x = -667.14, y = -382.61, z = 9.16 },    heading = 0.0 },
        { name = "dealer",    label = "Vehicle dealership",   position = { x = -1442.2, y = 127.4,   z = 18.0 },    heading = 0.0 },
        { name = "heights",   label = "Northwest heights",    position = { x = -1441.0, y = 1269.0,  z = 123.0 },   heading = 180.0 },
        { name = "stoop",     label = "King Stoop forecourt", position = { x = -410.22, y = 722.73,  z = 115.0 },   heading = 147.0 },
        { name = "northside", label = "North promenade",      position = { x = -469.47, y = 930.99,  z = 56.45 },   heading = -68.0 },
        { name = "coast",     label = "Southwest coast",      position = { x = -1716.38, y = -2421.28, z = 62.59 }, heading = 0.0 },
    },

    -- ------------------------------------------------------------------
    -- Vehicles.
    -- ------------------------------------------------------------------
    vehicles = {
        -- Where a spawned car appears relative to the operator, world axes.
        spawnOffset = { x = 3.0, y = 0.0, z = 0.25 },

        -- /admin.veh.spawn <alias> shortcuts, seeded from freeroam. Any of the
        -- 1372 catalogue records is also accepted verbatim; the alias table
        -- exists so the common ones are one word.
        aliases = {
            hella      = "Vehicle.v_standard2_archer_hella_player",
            bandit     = "Vehicle.v_standard2_archer_bandit_player",
            quartz     = "Vehicle.v_standard2_archer_quartz_player",
            caliburn   = "Vehicle.v_sport1_rayfield_caliburn_player",
            mordred    = "Vehicle.v_sport1_rayfield_caliburn_mordred_player",
            aerondight = "Vehicle.v_sport1_rayfield_aerondight_player",
            outlaw     = "Vehicle.v_sport1_herrera_outlaw_player",
            turbo      = "Vehicle.v_sport1_quadra_turbo_player",
            type66     = "Vehicle.v_sport2_quadra_type66_player",
            shion      = "Vehicle.v_sport2_mizutani_shion_player",
            porsche    = "Vehicle.v_sport2_porsche_911turbo_player",
            alvarado   = "Vehicle.v_sport2_villefort_alvarado_player",
            deleon     = "Vehicle.v_sport2_villefort_deleon_player",
            cortes     = "Vehicle.v_standard2_villefort_cortes_player",
            colby      = "Vehicle.v_standard2_thorton_colby_player",
            galena     = "Vehicle.v_standard2_thorton_galena_player",
            supron     = "Vehicle.v_standard25_mahir_supron_player",
            maimai     = "Vehicle.v_standard2_makigai_maimai_player",
            hozuki     = "Vehicle.v_standard2_mizutani_hozuki_player",
            thrax      = "Vehicle.v_standard2_chevalier_thrax_player",
            kusanagi   = "Vehicle.v_sportbike1_yaiba_kusanagi_player",
            arch       = "Vehicle.v_sportbike2_arch_player",
            jackie     = "Vehicle.v_sportbike2_arch_jackie_player",
            apollo     = "Vehicle.v_sportbike3_brennan_apollo_player",
        },

        -- How far "the nearest Open77 vehicle" may be for the `here` governor
        -- commands when the operator is on foot. Deliberately short: past this
        -- the operator cannot tell WHICH car he is about to cap, and capping a
        -- car he cannot see is the class of surprise these commands exist to
        -- avoid. Aboard a vehicle the radius is irrelevant -- the occupied one
        -- always wins.
        nearRadius = 40.0,

        -- Governor bounds. The native accepts a wider range than any vehicle
        -- in the catalogue can use; these are the bounds the PANEL offers, and
        -- the server refuses anything outside them before the native sees it.
        --
        -- accelerationScale cannot exceed 1.0 -- by construction, so the
        -- governor cannot be a cheat. It only ever multiplies throttle
        -- downward. There is no boost to offer and the UI must not imply one.
        governor = {
            topSpeedKph      = { min = 0.0,  max = 300.0, step = 5.0,  default = 0.0 },
            taperKph         = { min = 3.0,  max = 60.0,  step = 1.0,  default = 12.0 },
            accelerationScale = { min = 0.1, max = 1.0,   step = 0.05, default = 1.0 },
        },

        -- Repair scopes safe to run on an occupied vehicle. `full` and
        -- `mechanical` are absent on purpose: both may escalate to a
        -- controlled respawn, which on a car with a driver in it is a destroy.
        occupiedSafeRepairScopes = { glass = true, body = true, lights = true, tires = true, visual = true },

        -- Flags an operator may toggle. Reading and writing these is safe on
        -- an occupied vehicle; nothing here moves a car or touches its
        -- physics lease.
        flags = { "engineOn", "locked", "lightsOn", "highBeams", "sirenOn", "invulnerable", "immortal" },
    },

    -- ------------------------------------------------------------------
    -- World props, lights and effects.
    --
    -- The registry lives in the host (`Open77.props`, `Open77.effects`); this
    -- package only calls it, exactly as `open77_props` and `open77_effects`
    -- do. Two rules from that API shape everything in server/props.lua and are
    -- worth stating where the numbers live:
    --
    --   * a prop is created into a ROUTING BUCKET, and a prop created into a
    --     bucket nobody is in is invisible to everybody while the call still
    --     reports success. Every command here takes the caller's own bucket;
    --     none of them defaults to 0.
    --   * mutations are owner-scoped by the host. This package can move,
    --     remove and re-light only what IT created; a prop spawned by
    --     `open77_props` or by a gamemode answers `owned_by_another_resource`.
    --     That is reported, never swallowed.
    -- ------------------------------------------------------------------
    props = {
        -- Radius, in metres, for "props near me" when the operator names none.
        nearRadius = 25.0,
        maxRadius = 500.0,
        -- Rows carried in one push. The panel polls this once a second, and a
        -- server with a thousand props must not send a thousand rows.
        maxListed = 60,

        -- Light bounds. The client validates its own, and these are what the
        -- panel offers and what the server refuses before the host sees it, so
        -- an out-of-range value gets a usage line instead of a rejection code.
        --
        -- Colour channels are 0..1 and travel as `color = { x = r, y = g,
        -- z = b }` -- x/y/z, not r/g/b, because they go through the shared
        -- vector reader. Naming them r/g/b in the table silently yields black.
        light = {
            intensity = { min = 0.0, max = 10000.0, default = 20.0 },
            radius    = { min = 0.1, max = 500.0,   default = 10.0 },
            color     = { min = 0.0, max = 1.0,     default = { x = 1.0, y = 1.0, z = 1.0 } },
        },

        -- Curated model aliases, mirrored from the client's own table in
        -- `client/src/api/Props.cpp`. An alias is what a caller writes; the
        -- depot path behind it is a client-side implementation detail, which is
        -- why only the names are here and no paths.
        --
        -- The list is a CONVENIENCE, not a whitelist: any string the client can
        -- resolve -- including a raw depot path -- is accepted by the commands.
        -- And nothing in it is validated in game: the client's table records
        -- `discoverable_not_individually_validated` for every row, so a spawn
        -- that answers `entity_spawn_failed` is a real answer, not a bug here.
        --
        -- 185 aliases in 29 families, ordered the same way as the C++ table and
        -- grouped one family per run of lines. The panel reads that grouping
        -- straight off the alias prefix, so keeping a family contiguous here is
        -- what keeps its buttons together on screen.
        --
        -- SIZE MATTERS. `admin.props.catalog` pushes `models` + `effects` +
        -- `hosted` in ONE WebUI event, and `hosted` is roughly as long as
        -- `models`. The ceiling is 1024 value nodes and a payload that crosses
        -- it is dropped in silence, so the budget is ~421 nodes today against
        -- 1024. Do not take `models` much past 200.
        models = {
            "furniture.chair.metal", "furniture.chair.plastic", "furniture.stool.metal",
            "furniture.stool.bar", "furniture.bench.wood", "furniture.bench.metal",
            "furniture.bench.outdoor", "furniture.bench.wall",
            "furniture.table.industrial", "furniture.table.lab", "furniture.table.outdoor",
            "furniture.table.bar", "furniture.counter.bar", "furniture.sofa.poor",
            "furniture.bed.single", "furniture.shelf.industrial",
            "furniture.cabinet.industrial", "furniture.cabinet.glass",
            "office.desk", "office.desk.corpo", "office.chair", "office.chair.corpo",
            "office.cabinet.file", "office.reception_desk",
            "kitchen.counter", "kitchen.fridge", "kitchen.fridge.poor", "kitchen.stove",
            "kitchen.coffee_machine",
            "bathroom.toilet", "bathroom.shower", "bathroom.mirror",
            "crate.small", "crate.valuable", "crate.delivery", "crate.delivery.tall",
            "crate.cargo", "crate.cardboard", "crate.ammo_box",
            "container.barrel", "container.locker", "container.safe", "container.toolbox",
            "container.ammo_case", "container.keg", "container.gas_tank",
            "container.gas_can", "container.water_jug", "container.bucket",
            "container.freight", "container.shipping",
            "barrier.concrete", "barrier.blockade.wide", "barrier.blockade.mechanical",
            "barrier.hesco", "barrier.gate.swinging", "barrier.pedestrian", "barrier.road",
            "barrier.road.jersey", "barrier.roadblock.concrete", "barrier.tire_blocker",
            "fence.railing", "fence.railing.industrial", "fence.railing.balcony",
            "fence.wire.reinforcement",
            "sign.rect.blank", "sign.rect.keep_out", "sign.arrow.left", "sign.street",
            "sign.homeless", "sign.kiosk_frame",
            "street.lamp", "street.lamp.neomilitary", "street.hydrant",
            "street.parking_meter", "street.traffic_light", "street.newspaper_stand",
            "street.electrical_pole", "street.electrical_box", "street.awning",
            "street.water_tower", "street.ac_unit",
            "bin.dumpster.large", "bin.dumpster.small", "bin.dumpster.medium",
            "bin.trash_can", "bin.trash_can.small",
            "garbage.bag", "garbage.cardboard_pile", "garbage.street_trash",
            "garbage.industrial_trash", "garbage.mattress",
            "debris.pile", "debris.corrugated_sheet", "debris.construction_pile",
            "debris.sand_pile", "debris.rebar",
            "pallet.wood", "pallet.wood.loaded", "pallet.stack",
            "industrial.forklift", "industrial.pallet_truck",
            "industrial.fire_extinguisher", "industrial.trolley", "industrial.cart",
            "industrial.generator", "industrial.gas_pump", "industrial.shop_rack",
            "industrial.machine", "industrial.vent.rooftop",
            "industrial.vent.shaft",
            "pipe.small", "pipe.medium", "pipe.round", "pipe.waste",
            "electronics.monitor", "electronics.monitor.device",
            -- The game's own televisions and monitors. Mirrors the block of the
            -- same names in `Props.cpp`'s `kModelAliases`, which stays the source
            -- of truth; this list is what the media catalogue is checked against,
            -- so a television record can only ever name a prop that exists.
            "electronics.tv.16x9", "electronics.tv.21x9",
            "electronics.tv.neokitsch.16x9", "electronics.tv.neokitsch.21x9",
            "electronics.tv.screen.16x9", "electronics.tv.screen.21x9",
            "electronics.tv.screen.neokitsch.16x9", "electronics.tv.screen.neokitsch.21x9",
            "electronics.tv.large",
            "electronics.monitor.device.a", "electronics.monitor.device.b",
            "electronics.monitor.device.c", "electronics.monitor.device.d",
            "electronics.monitor.device.e",
            "electronics.monitor.screen.a", "electronics.monitor.screen.b",
            "electronics.monitor.screen.c", "electronics.monitor.screen.d",
            "electronics.monitor.screen.a.vertical",
            "electronics.monitor.screen.b.vertical",
            "electronics.monitor.screen.c.vertical",
            "electronics.monitor.screen.d.vertical",
            "electronics.screen.21x9", "electronics.screen.16x9",
            "electronics.screen.4x3", "electronics.screen.3x4",
            "electronics.screen.9x16", "electronics.screen.9x21",
            "electronics.screen.2x1",
            "electronics.frame.a", "electronics.frame.ab", "electronics.frame.ac",
            "electronics.frame.ad", "electronics.frame.ae", "electronics.frame.af",
            "electronics.monitor.surveillance", "furniture.tv_stand",
            "electronics.vending_machine", "electronics.vending_machine.small",
            "electronics.vending_machine.drink", "electronics.arcade",
            "electronics.jukebox", "electronics.server", "electronics.cash_register",
            "electronics.fuse_box", "electronics.camera", "electronics.air_conditioner",
            "light.lantern.japanese", "light.lantern.chinese", "light.ceiling",
            "light.fluorescent", "light.spotlight", "light.desk", "light.hanging",
            "light.candle", "light.disco_ball",
            "vegetation.planter.large", "vegetation.planter.city", "vegetation.flower_pot",
            "vegetation.flower_pot.kitsch", "vegetation.palm_attachment",
            "market.stand", "market.stand.small", "market.kiosk", "market.shelf.chinese",
            "market.cabinet.chinese",
            "food.street_food", "food.soda_can", "food.drink_packaged", "food.snack",
            "food.bourbon", "food.beer_tap",
            "medical.cart", "medical.iv_stand", "medical.monitor_arm", "medical.device",
            "medical.container", "medical.morgue_table", "medical.body_bag",
            "military.case", "military.case.large", "military.weapon_rack",
            "military.checkpoint", "military.security_gate",
            "door.swinging_gate", "door.elevator", "door.glass", "door.shuttle",
            "recreation.billiard_table", "recreation.roulette_table",
            "recreation.gym_equipment", "recreation.tent", "recreation.sleeping_bag",
            "music.guitar.electric", "music.amplifier", "music.piano",
            "decor.sculpture.arasaka", "decor.sculpture.chinese", "decor.painting",
            "decor.vase.large",
            "tool.shovel", "tool.welder", "tool.fire_axe",
            -- Spawn-safe, visual-only host for sq024's road hologram. The
            -- generated entity preserves the vanilla lay-flat local transform.
            "race.route_arrow",
            -- Audited authored-template alias: exact two-sided sq024 solo race
            -- checkpoint. Unlike the mesh-host catalogue above, this keeps its
            -- StreetSignWidget component graph intact.
            "race.checkpoint",
        },

        -- Curated VFX aliases, mirrored from `client/src/api/Effects.cpp`. Same
        -- rule: a convenience list, not a whitelist. 60 aliases in 16 families.
        -- Held in alias order because the C++ side is a `std::map`, which sorts;
        -- the panel groups these by prefix too.
        effects = {
            "blood.puddle",
            "cyber.blade_idle_electric", "cyber.blade_idle_thermal", "cyber.electrocuted_body",
            "cyber.emp_blast", "cyber.emp_body", "cyber.trail_electric",
            "electric.arc", "electric.destruction", "electric.device", "electric.emp",
            "electric.emp.big", "electric.emp.small", "electric.industrial_arm",
            "explosion.frag", "explosion.fuel", "explosion.grenade", "explosion.nuclear",
            "explosion.steam", "explosion.turret",
            "fire.gas", "fire.large", "fire.medium", "fire.small", "fire.tiny",
            "glass.shatter",
            "impact.concrete", "impact.default", "impact.ground_slam", "impact.metal", "impact.water",
            "laser.mine",
            "neon.holo_zone", "neon.loot_drop",
            "race.firework.burst", "race.flare.smoke",
            "smoke.ambient", "smoke.column.black", "smoke.exterior", "smoke.machine",
            "smoke.poison_gas", "smoke.steam",
            "sparks.burst.large", "sparks.burst.small", "sparks.cable", "sparks.welding",
            "steam.column", "steam.sewer",
            "vehicle.exhaust", "vehicle.fire", "vehicle.police_lights", "vehicle.skid",
            "vehicle.skid.mark", "vehicle.skid.smoke",
            "water.drip", "water.hydrant", "water.sprinkler",
            "weather.dust", "weather.rain", "weather.sandstorm",
        },

        -- --------------------------------------------------------------
        -- The fireworks show -- `admin.fx.fireworks`.
        --
        -- WHY THE SERVER FIRES IT, AND NOT THE CLIENTS. The race start plays
        -- its own burst from client Lua (`Open77.vfx.play` in
        -- gamemodes/freeroam/race/client/main.lua), which is right there:
        -- every client already holds the same replicated start line and fires
        -- one effect at one moment. A show is a SEQUENCE -- a dozen shells
        -- over ten seconds -- and a sequence run independently on each client
        -- drifts apart, because each client walks its own timers. So every
        -- shell here goes through `Open77.effects.play` on the SERVER, which
        -- broadcasts it to the players in range: one authority, one clock,
        -- the same shell at the same world point for everybody watching.
        --
        -- THE FOUR SHELLS. Cyberpunk cooks `q112_firework_01..04`, and only
        -- the first has a curated alias -- `race.firework.burst`, the one the
        -- race start uses. `Open77.effects.play` takes a cooked depot path
        -- exactly like an alias, so the other three are named by path and the
        -- show alternates instead of repeating one burst. Removing any of
        -- them is a supported edit; the runner cycles whatever is left.
        fireworks = {
            shells = {
                "race.firework.burst",
                "base\\fx\\quest\\q112\\q112_firework_02.effect",
                "base\\fx\\quest\\q112\\q112_firework_03.effect",
                "base\\fx\\quest\\q112\\q112_firework_04.effect",
            },

            -- One "round" is a volley of `burstsPerRound` shells, spaced
            -- `spreadMs` apart; rounds are spaced `intervalMs` apart.
            -- Rounds are GROUPS of one to a few shells, not volleys: what
            -- reads as fireworks is launches going off here, then there, a
            -- couple together, a pause, a run of them. Fourteen groups run
            -- about twenty seconds with these gaps.
            rounds = 20,
            maxRounds = 80,
            -- Generous: four to eight shells a group, twenty groups. The
            -- spacing below is what keeps that from turning into a wall.
            burstsPerRound = 4,
            burstJitter = 4,
            -- The gap between shells of one group, and its jitter. Wide on
            -- purpose: shells fired 150 ms apart land as a single smear, which
            -- is exactly the "everything is stuck together" look.
            spreadMs = 300,
            spreadJitterMs = 220,
            -- And between groups. The jitter is what breaks the pulse; without
            -- it the ear hears the metronome even when the eye does not.
            intervalMs = 350,
            intervalJitterMs = 700,
            -- The last group is a wall, because a finale should be one.
            finaleMultiplier = 5,
            -- Two shells closer than this read as one burst, so a point is
            -- redrawn until it clears the previous one. Metres.
            minSeparation = 26.0,

            -- Where the shells go, relative to the aiming point: a disc of
            -- `radius` metres, `minHeight`..`maxHeight` above it. The cooked
            -- burst is authored around its own origin, so the height is what
            -- puts it in the sky rather than in the operator's face.
            -- IN THE SKY, which is the whole difference between fireworks and
            -- a bonfire. Measured from a player standing under them: at 30 m
            -- the shells are overhead and read as sparks at head height; from
            -- 55 m up they read as a display, and the spread has to grow with
            -- the height or they all sit in one column.
            radius = 40.0,
            minHeight = 25.0,
            maxHeight = 45.0,

            -- Broadcast radius, in metres (the host clamps to 1..500). The
            -- default 150 is tuned for ground effects; a shell thirty metres
            -- up is meant to be seen across a district, so this asks for the
            -- ceiling.
            range = 500.0,

            -- The vanilla launch boom, the same Wwise event the race start
            -- uses for its own fireworks. Played once per round, not once per
            -- shell: three overlapping copies sound like clipping, not like a
            -- volley. Set to false for a silent show.
            sound = "sq024_race_start_fireworks",
        },

        -- How far in front of the operator a show is cast from the menu, in
        -- metres. Not the few metres of the prop gesture: fireworks fired at
        -- one's feet go up out of frame and read as a bonfire, so a display is
        -- put out where it can be seen whole -- the direction the camera faces,
        -- on the ground, this far out. The altitude comes from the show.
        showDistance = 90.0,

        -- --------------------------------------------------------------
        -- Named effects for the shows below.
        --
        -- A cue may name a curated alias or a raw depot path, but a preset that
        -- repeats a forty-character path in six cues is unreadable and drifts
        -- the moment one copy is edited. Naming them once here is what lets a
        -- cue say `confetti`, and what makes swapping the asset one edit.
        --
        -- The four here that are not aliases are the ones 2.31 cooks for the
        -- q112 parade and for the holo devices. Confetti and petals were fired
        -- in game on 2026-09-19 and render; keep that habit for anything added
        -- from `docs/generated/vfx-assets-2.31.csv`, whose rows are discovered
        -- from the archive and not individually validated.
        showEffects = {
            confetti   = "base\\fx\\quest\\q112\\e_debris_confetti_q112.effect",
            petals     = "base\\fx\\quest\\q112\\q112_holo_petals.effect",
            holosphere = "base\\fx\\devices\\holo_sphere\\d_holo_sphere_distraction.effect",
            flare      = "race.flare.smoke",
            sparks     = "sparks.burst.large",
            beacon     = "neon.loot_drop",
            zone       = "neon.holo_zone",
            column     = "smoke.column.black",
            steam      = "steam.column",
            -- The electric family, for the `storm` show.
            arc         = "electric.arc",
            sparkscable = "sparks.cable",
            empsmall    = "electric.emp.small",
            empbig      = "electric.emp.big",
            empblast    = "cyber.emp_blast",
            industrial  = "electric.industrial_arm",
            device      = "electric.device",
            destruction = "electric.destruction",
        },

        -- --------------------------------------------------------------
        -- Scripted shows -- `admin.fx.show <preset>`.
        --
        -- A show is a list of CUES, and a cue is one beat: `at` milliseconds
        -- from the start, an `effect` (omitted means the next firework shell),
        -- `count` copies spaced `spreadMs` apart, and where they land --
        -- `radius`, `minHeight`, `maxHeight`, each falling back to the
        -- `fireworks` block so a cue states only what it changes.
        --
        -- Writing the timing as absolute offsets rather than as sleeps is what
        -- makes a preset readable as a score: the eye can see that the confetti
        -- lands a beat before the first volley, and two cues can share a beat.
        --
        -- The server walks this list on its own clock and broadcasts every
        -- beat, so the whole audience sees the same show at the same moment.
        shows = {
            -- The playtest opener: the ground lights first, then the sky. The
            -- flare and the sparks carry a `ttlMs` because they are not bursts
            -- -- a flare burns until something retires it, so fired as a
            -- one-shot it is still there when the show has ended.
            opening = {
                { at = 0,     effect = "flare",    count = 2, radius = 8.0,  minHeight = 0.0,  maxHeight = 0.5,
                  ttlMs = 12000, sound = "sq024_race_countdown_start" },
                { at = 900,   effect = "sparks",   count = 3, radius = 7.0,  minHeight = 1.0,  maxHeight = 2.5, spreadMs = 120 },
                { at = 1800,  effect = "confetti", count = 3, radius = 9.0,  minHeight = 9.0,  maxHeight = 14.0, spreadMs = 180 },
                { at = 2800,  effect = "petals",   count = 2, radius = 8.0,  minHeight = 10.0, maxHeight = 15.0, spreadMs = 200 },
                { at = 3800,                       count = 8, spreadMs = 200, radius = 40.0, sound = "sq024_race_start_fireworks" },
                { at = 5600,  effect = "confetti", count = 2, radius = 10.0, minHeight = 9.0,  maxHeight = 14.0, spreadMs = 200 },
                { at = 6400,                       count = 10, spreadMs = 180, radius = 55.0, sound = "sq024_race_start_fireworks" },
                { at = 8600,  effect = "petals",   count = 3, radius = 9.0,  minHeight = 10.0, maxHeight = 16.0, spreadMs = 220 },
                { at = 9400,                       count = 12, spreadMs = 170, radius = 65.0, sound = "sq024_race_start_fireworks" },
                { at = 12000, effect = "confetti", count = 4, radius = 11.0, minHeight = 9.0,  maxHeight = 15.0, spreadMs = 150 },
                { at = 12800,                      count = 16, spreadMs = 140, radius = 70.0, sound = "sq024_race_start_fireworks" },
                { at = 16000,                      count = 20, spreadMs = 120, radius = 75.0, sound = "sq024_race_start_fireworks" },
                { at = 19000,                      count = 28, spreadMs = 100, radius = 80.0, sound = "sq024_race_start_fireworks" },
            },

            -- Indoor-safe: nothing explodes, nothing burns, and everything
            -- stays at the height of the people it falls on. A wedding, an
            -- award, the end of a heist.
            celebration = {
                { at = 0,    effect = "confetti", count = 3, radius = 5.0, minHeight = 6.0, maxHeight = 9.0, spreadMs = 200 },
                { at = 1200, effect = "petals",   count = 2, radius = 4.0, minHeight = 7.0, maxHeight = 10.0, spreadMs = 250 },
                { at = 2600, effect = "confetti", count = 3, radius = 6.0, minHeight = 6.0, maxHeight = 9.0, spreadMs = 200 },
                { at = 4000, effect = "petals",   count = 3, radius = 5.0, minHeight = 7.0, maxHeight = 11.0, spreadMs = 250 },
                { at = 5600, effect = "confetti", count = 4, radius = 7.0, minHeight = 6.0, maxHeight = 10.0, spreadMs = 160 },
                { at = 7400, effect = "petals",   count = 4, radius = 6.0, minHeight = 7.0, maxHeight = 12.0, spreadMs = 200 },
                { at = 9200, effect = "confetti", count = 5, radius = 8.0, minHeight = 6.0, maxHeight = 11.0, spreadMs = 150 },
            },

            -- Thirty seconds, and it climbs the whole way: wide and low, then
            -- higher and closer together, a breath before the last barrage.
            -- Every volley is up in the sky; the confetti and petals are the
            -- only thing that comes down among the players.
            finale = {
                { at = 0,     count = 8,  spreadMs = 220, radius = 45.0, minHeight = 25.0, maxHeight = 50.0,
                  sound = "sq024_race_start_fireworks" },
                { at = 2200,  count = 10,  spreadMs = 200, radius = 55.0, minHeight = 25.0, maxHeight = 50.0 },
                { at = 4400,  count = 12,  spreadMs = 180, radius = 65.0, minHeight = 25.0, maxHeight = 50.0,
                  sound = "sq024_race_start_fireworks" },
                { at = 7000,  count = 8,  spreadMs = 260, radius = 35.0, minHeight = 25.0, maxHeight = 50.0 },
                { at = 9600,  effect = "confetti", count = 8, radius = 11.0, minHeight = 9.0, maxHeight = 15.0, spreadMs = 150 },
                { at = 10200, count = 16,  spreadMs = 160, radius = 70.0, minHeight = 25.0, maxHeight = 50.0,
                  sound = "sq024_race_start_fireworks" },
                { at = 13400, count = 16,  spreadMs = 150, radius = 75.0, minHeight = 25.0, maxHeight = 50.0 },
                { at = 16600, effect = "petals", count = 8, radius = 10.0, minHeight = 10.0, maxHeight = 16.0, spreadMs = 180 },
                { at = 17400, count = 12, spreadMs = 160, radius = 80.0, minHeight = 25.0, maxHeight = 50.0,
                  sound = "sq024_race_start_fireworks" },
                -- The breath. Nothing fires for two seconds, which is what
                -- makes the barrage after it land.
                { at = 22000, count = 12, spreadMs = 150, radius = 85.0, minHeight = 25.0, maxHeight = 50.0,
                  sound = "sq024_race_start_fireworks" },
                { at = 25600, effect = "confetti", count = 10, radius = 12.0, minHeight = 9.0, maxHeight = 16.0, spreadMs = 130 },
                -- Twelve, not thirty-six. A denser wall was tried and the
                -- CLIENT refused the tail of it: the game log fills with
                -- `one-shot <effect> rejected: quota_exceeded` while the server
                -- reports every call as a success. The barrage has a ceiling
                -- and it is on the receiving end, so the finale spends its
                -- shells on spacing rather than on count.
                { at = 26200, count = 12, spreadMs = 140, radius = 90.0, minHeight = 25.0, maxHeight = 50.0,
                  sound = "sq024_race_start_fireworks" },
            },

            -- The electric show: no pyrotechnics at all, everything is arcs,
            -- EMP and failing hardware. It belongs on the ground and around the
            -- audience rather than in the sky -- that is where the game authors
            -- these, and where they read. The arcs and the cable failures carry
            -- a `ttlMs` because they crackle rather than burst.
            storm = {
                { at = 0,     effect = "arc",       count = 3, radius = 14.0, minHeight = 0.5, maxHeight = 3.0,
                  ttlMs = 9000, spreadMs = 200 },
                { at = 1000,  effect = "sparkscable", count = 3, radius = 16.0, minHeight = 2.0, maxHeight = 6.0,
                  ttlMs = 8000, spreadMs = 220 },
                { at = 2200,  effect = "empsmall",  count = 4, radius = 12.0, minHeight = 1.0, maxHeight = 4.0, spreadMs = 180 },
                { at = 3600,  effect = "empblast",  count = 1, radius = 6.0,  minHeight = 2.0, maxHeight = 3.0 },
                { at = 4400,  effect = "arc",       count = 4, radius = 18.0, minHeight = 0.5, maxHeight = 4.0,
                  ttlMs = 7000, spreadMs = 160 },
                { at = 6000,  effect = "industrial", count = 3, radius = 15.0, minHeight = 1.0, maxHeight = 3.0,
                  ttlMs = 6000, spreadMs = 200 },
                { at = 7600,  effect = "empbig",    count = 2, radius = 10.0, minHeight = 2.0, maxHeight = 5.0, spreadMs = 400 },
                { at = 9200,  effect = "device",    count = 4, radius = 16.0, minHeight = 1.0, maxHeight = 4.0, spreadMs = 200 },
                { at = 10800, effect = "empsmall",  count = 6, radius = 20.0, minHeight = 1.0, maxHeight = 6.0, spreadMs = 140 },
                { at = 12600, effect = "arc",       count = 6, radius = 22.0, minHeight = 0.5, maxHeight = 5.0,
                  ttlMs = 6000, spreadMs = 130 },
                { at = 14400, effect = "empblast",  count = 1, radius = 4.0,  minHeight = 2.0, maxHeight = 3.0 },
                { at = 15000, effect = "destruction", count = 5, radius = 18.0, minHeight = 1.0, maxHeight = 5.0, spreadMs = 150 },
            },
        },

        -- --------------------------------------------------------------
        -- The drone show -- an ADAPTER, not a feature of this package.
        --
        -- `rp_drones` owns the swarm, the budget and every safety gate; this
        -- block only puts its shows on the menu so an operator fires them the
        -- way they fire the fireworks. Same shape as the weather adapter: the
        -- rows disappear when that resource is not running, and the list below
        -- is a CONVENIENCE, not an authority -- a name this file has wrong
        -- comes back as a usage line from the resource that owns it, which is
        -- exactly what should happen.
        celebrations = {
            resource = "rp_fireworks",
            command = "fireworks",
            shows = {
                { name = "opening", label = "Opening fireworks" },
                { name = "burst", label = "Short fireworks" },
                { name = "celebration", label = "Confetti & petals" },
            },
        },
        drones = {
            resource = "rp_drones",
            command = "droneshow",
            shows = {
                { name = "sign",      label = "OPEN//77 sign" },
                { name = "parade",    label = "Parade" },
                { name = "cut",       label = "Two figures" },
                { name = "heart",     label = "Heart" },
                { name = "open77",    label = "Five figures" },
                { name = "rehearsal", label = "Rehearsal" },
            },
        },

        -- --------------------------------------------------------------
        -- The venue -- `admin.fx.stage`.
        --
        -- Looping effects, unlike everything in `shows`: a one-shot plays
        -- itself out, a loop stays until it is removed, which is what a place
        -- needs. `admin.fx.stage.clear` takes it down; the ids are held by the
        -- resource so nobody has to copy them out of a listing.
        --
        -- Offsets are on WORLD axes and in metres, from the point the operator
        -- named. A venue is a place, not a direction.
        stage = {
            pieces = {
                -- `streamingRadius` and not the 90 m default: a column that
                -- marks a venue has to be visible from outside it.
                { effect = "zone",   x = 0.0,   y = 0.0,   z = 0.0, streamingRadius = 400.0 },
                { effect = "beacon", x = -10.0, y = -10.0, z = 0.0 },
                { effect = "beacon", x = 10.0,  y = -10.0, z = 0.0 },
                { effect = "beacon", x = -10.0, y = 10.0,  z = 0.0 },
                { effect = "beacon", x = 10.0,  y = 10.0,  z = 0.0 },
                { effect = "column", x = -16.0, y = 0.0,   z = 0.0, streamingRadius = 600.0 },
                { effect = "steam",  x = 16.0,  y = 0.0,   z = 0.0, streamingRadius = 600.0 },
            },
        },
    },

    -- ------------------------------------------------------------------
    -- Weapons.
    --
    -- The catalogue lives in shared/weapons.lua and is GENERATED (189 records
    -- filtered from the 1925-record 2.31 extraction). This block is the
    -- policy around it: what a full load is, what the ceiling is, and which
    -- records get a one-word name.
    --
    -- THREE THINGS FROM THE ENGINE SHAPE EVERYTHING HERE, and each is read
    -- out of client/redscript/Open77ScriptBridge.reds rather than assumed:
    --
    -- 1. THE AMMO TYPE IS NOT A CHOICE. `Open77WeaponAmmoValues` resolves it
    --    as `WeaponItem_Record.Ammo()` -- a foreign key on the weapon record
    --    itself -- and `Open77.weapons.setAmmo` has no parameter for it. So
    --    this file never names an ammo record and never needs a
    --    class -> ammo-type table: it says HOW MANY, and the engine says OF
    --    WHAT. A record whose `Ammo()` is undefined answers
    --    `weapon_has_no_ammo`, which is one reason the catalogue carries an
    --    `ammo` flag per class and the server skips the call for melee.
    --
    --    Melee is not quite that clean, though, and the flag is the honest
    --    answer to it: a Katana in game reported a REAL ammo id
    --    (0x0000000DA4AED401) with a total of 0, so its `Ammo()` does resolve
    --    -- the pool simply caps at zero, and asking for any reserve fails
    --    the engine's `total == reserve + magazine` check with
    --    `ammo_update_rejected`. Measured 2026-08-30.
    --
    --    That is not only tidier than a hand-written table, it is more
    --    correct. Four ammo ids came back in testing -- handgun, rifle,
    --    sniper, shotgun -- and PRECISION RIFLES draw RIFLE ammo, which a
    --    hand-written table would almost certainly have filed under sniper.
    --
    -- 2. AMMO LIVES IN TWO PLACES. The spare pool is inventory quantity of
    --    the ammo item (`TransactionSystem.GetItemQuantity`); the loaded
    --    magazine lives on the instantiated `WeaponObject` and only moves
    --    through a `SetAmmoCountEvent`. `setAmmo` writes both and then
    --    verifies `total == reserve + magazine`, so a request is either
    --    wholly applied or reported as failed.
    --
    -- 3. THE WEAPON MUST EXIST AS AN OBJECT. `setAmmo` needs
    --    `GetItemInSlotByItemID` to return a `WeaponObject`; an assigned but
    --    undrawn weapon retries for a second and then answers
    --    `weapon_not_drawn`. Every ammo call this package makes therefore
    --    passes `activate = true`, which draws the slot first.
    -- ------------------------------------------------------------------
    weapons = {
        enabled = true,

        -- Which slot a give lands in. See server/weapons.lua for the whole
        -- argument; in short, `auto` asks the client for a verified snapshot,
        -- takes the first EMPTY slot, and only replaces the ACTIVE one when
        -- all three are full -- so a give never silently displaces a weapon
        -- the operator was not looking at.
        defaultSlot = "auto",

        -- Full load, in SPARE rounds, when the give does not name one. The
        -- per-class figure in the catalogue is the default; a key here
        -- overrides it for this server.
        --
        -- ================================================================
        -- THERE IS A CEILING, AND OVER-ASKING REPORTS A FAILURE
        -- ================================================================
        -- Measured in game on 2.31, 2026-08-30, by asking for more than the
        -- engine would give and reading the loadout back: the carried pool is
        -- capped PER AMMO TYPE, on the TOTAL, which is reserve + magazine.
        --
        --   shotgun ammo   200   (196 spare over a 4-round magazine; asking
        --                         for exactly 196 then verified)
        --   sniper ammo    175
        --   rifle ammo     just under 1000
        --   handgun ammo   took 500 spare over a 21-round magazine, unclipped
        --
        -- The clip is not silent and it is not harmless. `Open77WeaponAmmoStep`
        -- verifies `total == reserve + magazine` in its last phase, so a
        -- request the ceiling clips answers `ammo_update_rejected`: the weapon
        -- IS equipped and IS loaded to the cap, but the operator is told the
        -- request failed. 1500 for an LMG did exactly that, and so did 200 for
        -- a shotgun -- 200 spare plus a 4-round magazine is 204, four rounds
        -- over the ceiling. server/weapons.lua reports that case honestly
        -- rather than as a failed give, and the shipped figures all sit under
        -- their ceiling with a full magazine to spare.
        --
        -- The figures themselves are still a POLICY -- sized by how fast a
        -- class eats rounds, under the ceiling that class can reach. Uncomment
        -- to override the catalogue default for this server.
        reserve = {
            -- handgun = 500, revolver = 500, smg = 800, rifle = 800,
            -- precision = 400, sniper = 120, shotgun = 150, dual = 150,
            -- lmg = 800,
        },

        -- Ceiling on an operator-typed reserve. The native's own limit is
        -- 1 000 000 (kMaximumAmmo in client/src/api/Weapons.cpp); this is the
        -- bound the panel offers and the server refuses before the native
        -- sees it, so a typo gets a usage line instead of a rejection code.
        maximumReserve = 5000,

        -- Fill the magazine to the weapon's own capacity as well as the
        -- spare pool.
        --
        -- Load-bearing for the whole feature: a weapon that arrives with an
        -- empty magazine and a full reserve is a weapon that cannot fire
        -- until the player reloads. The capacity is not knowable here -- it
        -- is `WeaponObject.GetMagazineCapacity` on the INSTANTIATED weapon --
        -- so the server reads it back off the first ammo result and issues
        -- exactly one top-up. `magazine > capacity` is refused by the engine
        -- with `magazine_exceeds_capacity`, which is why it is never guessed.
        topUpMagazine = true,

        -- One-word names, exactly like the vehicle aliases above. Any of the
        -- 189 catalogue records is also accepted verbatim.
        --
        -- Deliberately NOT registered as command aliases in `aliases.map`:
        -- `open77_weapons` owns `/weapon.give`, `/weapon.remove` and
        -- `/weapon.ammo`, and dispatch takes the first resource in ordinal
        -- name order -- `open77_admin` (a) beats `open77_weapons` (w). An
        -- alias spelled `weapon.give` here would SHADOW that resource's own
        -- ACL-gated command. Shadowing freeroam was the point; shadowing the
        -- weapons authority is not.
        aliases = {
            lexington  = "Items.Preset_Lexington_Default",
            unity      = "Items.Preset_Unity_Default",
            nue        = "Items.Preset_Nue_Default",
            overture   = "Items.Preset_Overture_Default",
            quasar     = "Items.Preset_Quasar_Default",
            malorian   = "Items.Preset_Silverhand_3516",
            saratoga   = "Items.Preset_Saratoga_Default",
            fenrir     = "Items.Preset_Saratoga_Maelstrom",
            ajax       = "Items.Preset_Ajax_Default",
            copperhead = "Items.Preset_Copperhead_Default",
            masamune   = "Items.Preset_Masamune_Default",
            achilles   = "Items.Preset_Achilles_Default",
            sor22      = "Items.Preset_Sor22_Default",
            grad       = "Items.Preset_Grad_Default",
            nekomata   = "Items.Preset_Nekomata_Default",
            ashura     = "Items.Preset_Ashura_Default",
            carnage    = "Items.Preset_Carnage_Default",
            satara     = "Items.Preset_Satara_Default",
            zhuo       = "Items.Preset_Zhuo_Default",
            defender   = "Items.Preset_Defender_Default",
            katana     = "Items.Preset_Katana_Default",
            knife      = "Items.Preset_Knife_Default",
            machete    = "Items.Preset_Machete_Default",
            hammer     = "Items.Preset_Hammer_Default",
        },
    },

    -- ------------------------------------------------------------------
    -- Noclip.
    --
    -- The native clamps 0.1..500 m/s and refuses anything outside it, so these
    -- are presentation bounds for the slider, not the enforcement.
    -- ------------------------------------------------------------------
    travel = {
        -- Noclip speed. `max` matches the native's own range (0.1..500,
        -- see SetMovementFlySpeed) rather than sitting below it: the command
        -- `admin.self.speed` already accepted 500, so the menu stopping at 200
        -- meant the two disagreed and the menu looked broken at the ceiling.
        --
        -- `step` is a FLOOR, not the step. A fixed 1 m/s increment needs ~190
        -- presses to cross the range, which is why the menu felt like it had
        -- stopped speeding up long before it had. The real increment is
        -- `stepFraction` of the current speed, so 5 m/s still tunes in ~0.75
        -- steps while 200 m/s moves in 30s.
        --
        -- `default` is applied when noclip is ENABLED, not merely displayed.
        -- 60 m/s is ~216 km/h: Night City is about 4 km across, so this crosses
        -- a district in seconds, which is what noclip is for.
        speed = { min = 1.0, max = 500.0, step = 0.5, stepFraction = 0.15, default = 60.0 },
        -- Modifier keys the native applies to the configured speed. Stated
        -- here because freeroam's own help text says Ctrl, and it is wrong:
        -- Ctrl is descend, Alt is the slow modifier.
        modifiers = "Wheel speed // Shift x4 // Alt x0.25 // Space up // Ctrl down",
    },
}
