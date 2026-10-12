-- =============================================================================
-- open77_vehiclepicker -- the roster, and the reason it is what it is
-- =============================================================================
--
-- THIS FILE IS THE BALANCE ARGUMENT. The list of names is the cheap part; the
-- provenance beside each one is what stops it rotting. Read the block below
-- before adding, removing or reordering an entry.
--
-- -----------------------------------------------------------------------------
-- 1. Why curation and not a speed cap
-- -----------------------------------------------------------------------------
--
-- The request was "make sure they are all roughly the same speed, or impose a
-- technical speed limit if they are not". The second option was investigated
-- first because it would have been strictly better: a cap makes the roster a
-- free choice instead of a curated one.
--
-- IT DOES NOT EXIST. Four separate checks, all negative:
--
--   * `Open77.vehicles.update` accepts eleven fields and not one of them is a
--     performance field: health, flags, the two colours, doors, windows, tires,
--     bodyDamage, brokenGlass, brokenLights, detachedParts. The nine scriptable
--     `flags` bits are engineOn, locked, destroyed, exploded, invulnerable,
--     immortal, lightsOn, highBeams, sirenOn.
--   * `wiki/vehicles.md` says so outright: there is "no `setHorn`, `setRpm`,
--     `setSteering`, `setWheelRotation`" because those values "describe native
--     driver input, physics, or the validated occupancy ledger and cannot be
--     authored as durable script state".
--   * A soft governor is out too. The client CAN read `speed`, `rpm`, `rpmMax`,
--     `throttle` and `brake` off a vehicle snapshot -- but the loop cannot be
--     closed, because no Lua binding on either host applies throttle, brake,
--     force or velocity. `Open77.input` is `isDown` and `isCaptured`, both
--     reads. The one positional write, `setTransform`, revokes the physics
--     lease and teleports; it fights the driver rather than limiting him.
--   * Retuning the record itself is gated. TweakDB has no Lua namespace at all,
--     and the C++/debug-bridge `SetFlat` path refuses any record whose name is
--     not `<Type>.Open77*` -- `tweak.setflat Vehicle.v_standard2_...` answers
--     `ERR record_must_be_open77_owned`.
--
-- What the platform CAN write about a vehicle is identity, placement and
-- presentation. A cap would need new C++ plus a new binding; it is not a Lua
-- change and it is not this resource's to make.
--
-- So the only lever that exists is WHICH RECORD IS SPAWNED, and that is what
-- this file is.
--
-- -----------------------------------------------------------------------------
-- 2. What "roughly the same speed" is grounded on
-- -----------------------------------------------------------------------------
--
-- STATED PLAINLY, BECAUSE IT MATTERS: there is no vehicle performance dataset
-- in this repository. `docs/vehicle-models.md` -- the 1,376-record 2.31
-- catalogue, and the only vehicle data checked in -- carries exactly three
-- columns: the record name, its TweakDBID, and its `entityTemplatePath`. No
-- top speed, no acceleration, no mass, no drive type, no class rating. The
-- generated dumps under `docs/generated/` cover clothing, NPCs, weapons, VFX
-- and SFX; there is no vehicle dump at all.
--
-- The roster therefore rests on the one performance signal that IS a fact
-- rather than an opinion: REDengine's own chassis-class prefix, which is part
-- of the record name and so is data, not inference.
--
--     v_standard2_*     everyday saloons          <- THE BAND THIS ROSTER USES
--     v_standard25_*    pickups, larger saloons
--     v_standard3_*     SUVs and heavies
--     v_sport1_*        hypercars (Caliburn, Aerondight, Turbo, Outlaw)
--     v_sport2_*        sports cars (Type66, Shion, 911, Alvarado, Deleon)
--     v_sportbike*_*    motorcycles
--
-- EVERY ENTRY IN BOTH LISTS BELOW IS A `standard2` CHASSIS. That is the whole
-- balance mechanism, and it is deliberately conservative: a single class, no
-- mixing. It also happens to match what Pursuit already ships -- the Archer
-- Hella and the NCPD Villefort Cortes are both `standard2` -- so adopting this
-- roster does not change the performance of the default match at all.
--
-- What this claim is NOT: it is not a measurement. Sharing a class prefix is
-- strong evidence of a similar performance envelope and it is the best evidence
-- available offline, but it is not proof that two cars accelerate alike. See
-- section 4 for the one measurement that suggests the gap worth watching, and
-- README.md for the procedure that would settle every row.
--
-- -----------------------------------------------------------------------------
-- 3. Which records are allowed in, and why the two lists differ
-- -----------------------------------------------------------------------------
--
-- `docs/vehicle-models.md` (lines 24-29) states the tier rule: a non-zero
-- `entityTemplatePath` "confirms only the static prerequisites for
-- vehicle.spawn", and the guidance is to "prefer `*_player` records for
-- ordinary player vehicles" and to test anything else individually.
--
--   civilian  -- every entry is a `*_player` record, so every entry is in the
--                preferred tier. Nothing here needs a fallback.
--
--   police    -- NO NCPD `*_player` RECORD EXISTS. This is settled, not
--                assumed: `docs/vehicle-models.md` contains nine
--                `Vehicle.ncpd_*` records and none of them is a `*_player`
--                variant, and the same finding is recorded independently in
--                `resources/gamemodes/pursuit/shared/config.lua` and
--                `resources/gamemodes/pursuit/server/vehicles.lua`. So every police entry
--                is in the "test it individually" tier and carries a
--                `fallback` to the same chassis's `*_player` variant -- the
--                identical pattern Pursuit already implements.
--
-- -----------------------------------------------------------------------------
-- 4. The one number in the repository, and the question it raises
-- -----------------------------------------------------------------------------
--
-- Two hand-timed launches exist, in `scripts/scenarios/pursuit-v1-duo.md` and
-- quoted again in `resources/gamemodes/pursuit/shared/config.lua`. Distance covered in
-- five seconds from a standstill, hand-held throttle, one session each:
--
--     Vehicle.v_standard2_archer_hella_player     86.4 m   (runner, `*_player`)
--     Vehicle.ncpd_villefort_cortes_heat_1        59.7 m   (cop,    NCPD tier)
--
-- Same chassis class, 45% apart. THIS IS THE MOST IMPORTANT UNRESOLVED BALANCE
-- FACT IN PURSUIT, and it is not a fact this picker can fix, because it does
-- not sit between two civilian cars -- it sits between the `*_player` tier and
-- the NCPD tier. Three explanations are open and only measurement separates
-- them: (a) `*_player` records really are tuned quicker than their traffic and
-- police siblings; (b) the two runs differed in road, gradient or how hard the
-- throttle was held; (c) both.
--
-- The picker is built so that either answer is a data edit rather than a code
-- change. If (a) turns out to be true, the fix is to point the police list at
-- the `*_police`-liveried `standard2` records or at the plain `*_player`
-- chassis -- one `record` string per row, below -- and NOT to touch this file's
-- structure. The candidates are named in README.md.
--
-- -----------------------------------------------------------------------------
-- 5. Keys, and why the client never sends a record string
-- -----------------------------------------------------------------------------
--
-- Each entry has a `key`: a short opaque token. The picker sends the KEY over
-- the wire, never the record. A key is not a spawnable thing, so the worst a
-- tampered client can do is name a key that does not resolve -- and an
-- unresolved key falls back to the list default. Accepting a `Vehicle.*` string
-- from a client would instead hand it the whole 1,376-record catalogue,
-- including quest props, trains and drones. `wiki/data-reference.md` gives the
-- same advice in general terms: "promote it to a small resource-owned allowlist
-- instead of accepting arbitrary client strings."
--
-- Keys are STABLE. A key is written into a player's client KVP store, so
-- renaming one silently resets everybody who had chosen it. Add and deprecate;
-- do not rename.
-- =============================================================================

Open77VehicleRoster = {
    version = "1.0.0",

    -- The chassis class every entry in every list must belong to. Read by the
    -- self-check below, which is the thing that actually stops the roster
    -- drifting out of band when someone adds a car in a hurry.
    band = {
        prefix = "v_standard2_",
        label = "STANDARD // CLASS 2",
        note = "Saloon class. Every option in this list shares it.",
    },

    lists = {},
}

-- ------------------------------------------------------------------ civilian --
--
-- The runner's list. All eight are `v_standard2_*_player`, all eight appear in
-- the 89-row "Player and garage variants" table of `docs/vehicle-models.md`,
-- and all eight are already in the validated `/car` alias map of
-- `resources/gamemodes/freeroam/shared/config.lua`, whose own comment records that
-- "every record is a `*_player` variant validated in docs/vehicle-models.md".
--
-- Deliberately NOT here, and it is the only `standard2` `*_player` saloon left
-- out: `Vehicle.v_standard2_makigai_maimai_player`. The MaiMai is a city
-- micro-car and is very unlikely to hold the band, but note honestly that this
-- exclusion is a judgement about the car and NOT something this repository
-- evidences -- nothing checked in says how fast a MaiMai is. If somebody
-- measures it and it holds, it belongs in the list.
--
-- Sub-trims (`_gt`, `_base`, `_nomad`, `_delamain`, `_bobas`) are left out as a
-- rule rather than one by one: they multiply the list without adding a choice a
-- player can see at a glance, and each would need its own verification.
Open77VehicleRoster.lists.civilian = {
    id = "civilian",
    label = "Civilian",
    eyebrow = "LOADOUT // RUNNER",
    title = "Choose your car",
    default = "hella",
    entries = {
        {
            key = "hella",
            record = "Vehicle.v_standard2_archer_hella_player",
            name = "Archer Hella",
            maker = "Archer",
            -- The only civilian entry with a measured launch, and the record
            -- Pursuit spawns today. Keeping it the default means adopting the
            -- picker changes nothing for a player who never opens it.
            measured = { launch5s = 86.4, source = "scripts/scenarios/pursuit-v1-duo.md" },
        },
        {
            key = "bandit",
            record = "Vehicle.v_standard2_archer_bandit_player",
            name = "Archer Bandit",
            maker = "Archer",
        },
        {
            key = "quartz",
            record = "Vehicle.v_standard2_archer_quartz_player",
            name = "Archer Quartz",
            maker = "Archer",
        },
        {
            key = "cortes",
            record = "Vehicle.v_standard2_villefort_cortes_player",
            name = "Villefort Cortes",
            maker = "Villefort",
            -- Same chassis as the NCPD car the cop drives. Offered on purpose:
            -- a runner who picks it is racing an identical car with no livery,
            -- which is the cleanest possible read on whether the `*_player` and
            -- NCPD tiers actually differ. See section 4.
            note = "Same chassis as the NCPD patrol car.",
        },
        {
            key = "colby",
            record = "Vehicle.v_standard2_thorton_colby_player",
            name = "Thorton Colby",
            maker = "Thorton",
        },
        {
            key = "galena",
            record = "Vehicle.v_standard2_thorton_galena_player",
            name = "Thorton Galena",
            maker = "Thorton",
        },
        {
            key = "thrax",
            record = "Vehicle.v_standard2_chevalier_thrax_player",
            name = "Chevalier Thrax",
            maker = "Chevalier",
        },
        {
            key = "hozuki",
            record = "Vehicle.v_standard2_mizutani_hozuki_player",
            name = "Mizutani Hozuki",
            maker = "Mizutani",
        },
    },
}

-- -------------------------------------------------------------------- police --
--
-- The cop's list, and the honest answer to "there must be several police
-- options too?": THERE ARE NINE NCPD RECORDS AND ONLY FOUR OF THEM ARE IN THIS
-- BAND. The full nine, from `docs/vehicle-models.md`:
--
--     ncpd_villefort_cortes_heat_1          standard2 saloon   <- offered
--     ncpd_villefort_cortes_heat_2          standard2 saloon   <- offered
--     ncpd_archer_hella_heat_2              standard2 saloon   <- offered
--     ncpd_archer_hella_heat_3              standard2 saloon   <- offered
--     ncpd_thorton_merrimac_police_heat_4   standard25         out of band
--     ncpd_suv_chevalier_emperor_heat_4     standard3 SUV      out of band
--     ncpd_hellhound_heat_5                 standard3 heavy    out of band
--     ncpd_suv_thorton_merrimac_maxtac      standard25 MaxTac  out of band
--     ncpd_brennan_apollo_bike              motorcycle         out of band
--
-- The five out-of-band records are excluded because they leave the saloon class
-- the civilian list is pinned to, not because they are believed broken. They
-- are exactly the raw material for a future asymmetric mode -- a MaxTac
-- roadblock, a helicopter phase -- and README.md keeps that door open.
--
-- ONLY `heat_1` IS PROVEN. The pursuit server logs in `artifacts/` record 18
-- successful creations of `Vehicle.ncpd_villefort_cortes_heat_1` across four
-- sessions on 2026-08-26, with zero fallbacks and zero creation failures. It is
-- the only `Vehicle.ncpd_*` record this project has ever actually instantiated.
-- The other three below are structurally valid -- they carry a non-zero
-- `entityTemplatePath` in the 2.31 catalogue -- and untested. They are marked
-- `unverified = true`, the picker labels them so in the UI, and each carries a
-- `fallback` so an entry that turns out to be refused still yields a playable
-- match rather than no car.
--
-- What the `heat_N` suffix means is NOT established anywhere in this repository.
-- It is presumed to be the NCPD heat-level livery, and the two Cortes rows are
-- offered as visually distinct on that presumption. If heat_1 and heat_2 turn
-- out to look identical in game, the right response is to drop one row, not to
-- keep a choice that is not a choice.
Open77VehicleRoster.lists.police = {
    id = "police",
    label = "NCPD",
    eyebrow = "LOADOUT // NCPD",
    title = "Choose your patrol car",
    default = "cortes_h1",
    entries = {
        {
            key = "cortes_h1",
            record = "Vehicle.ncpd_villefort_cortes_heat_1",
            fallback = "Vehicle.v_standard2_villefort_cortes_player",
            name = "Villefort Cortes",
            maker = "NCPD Patrol",
            note = "Proven in service: 18 spawns, no failures.",
            measured = { launch5s = 59.7, source = "scripts/scenarios/pursuit-v1-duo.md" },
        },
        {
            key = "cortes_h2",
            record = "Vehicle.ncpd_villefort_cortes_heat_2",
            fallback = "Vehicle.v_standard2_villefort_cortes_player",
            name = "Villefort Cortes",
            maker = "NCPD Response",
            unverified = true,
        },
        {
            key = "hella_h2",
            record = "Vehicle.ncpd_archer_hella_heat_2",
            fallback = "Vehicle.v_standard2_archer_hella_player",
            name = "Archer Hella",
            maker = "NCPD Patrol",
            -- The catalogue's own usage example spawns this record
            -- (`docs/vehicle-models.md` line 16), which is the best evidence
            -- short of an actual spawn that the family works.
            unverified = true,
        },
        {
            key = "hella_h3",
            record = "Vehicle.ncpd_archer_hella_heat_3",
            fallback = "Vehicle.v_standard2_archer_hella_player",
            name = "Archer Hella",
            maker = "NCPD Response",
            unverified = true,
        },
    },
}

-- ================================================================== accessors ==
--
-- Deliberately tiny and side-effect free, because this file is COPIED into a
-- gamemode's server resource (see README.md, "Integrating"). Server resources
-- cannot call each other -- `wiki/gamemode-kernel.md` explains why that is a
-- platform fact and not an oversight -- so code generation is the sharing
-- mechanism, and anything clever here would have to be correct twice.

local lists = Open77VehicleRoster.lists

--- The list table for an id, or nil.
function Open77VehicleRoster.list(listId)
    if type(listId) ~= "string" then return nil end
    return lists[listId]
end

--- The default entry of a list. Never nil for a list that exists: the
--- self-check below refuses to load a list whose `default` does not resolve.
function Open77VehicleRoster.default(listId)
    local list = Open77VehicleRoster.list(listId)
    if list == nil then return nil end
    for _, entry in ipairs(list.entries) do
        if entry.key == list.default then return entry end
    end
    return list.entries[1]
end

--- THE VALIDATION BOUNDARY. Turns an untrusted key into a roster entry.
--- Returns nil for anything that is not a key of that list -- wrong type,
--- unknown key, a `Vehicle.*` string someone tried to smuggle through.
--- Callers must treat nil as "use the default", never as "use what was sent".
function Open77VehicleRoster.resolve(listId, key)
    local list = Open77VehicleRoster.list(listId)
    if list == nil or type(key) ~= "string" then return nil end
    for _, entry in ipairs(list.entries) do
        if entry.key == key then return entry end
    end
    return nil
end

--- Resolve to a spawnable pair, applying the default. Always returns a record.
--- This is the function a gamemode's server actually calls.
--- @return record, fallback, entry
function Open77VehicleRoster.records(listId, key)
    local entry = Open77VehicleRoster.resolve(listId, key)
        or Open77VehicleRoster.default(listId)
    if entry == nil then return nil, nil, nil end
    return entry.record, entry.fallback, entry
end

-- ================================================================ self-check ==
--
-- Runs at load, on both hosts, and reports rather than throws. A roster that
-- refused to load would take the whole resource down over a typo in a car name,
-- which is a worse failure than a car that is out of band. The line it prints
-- is the thing a reviewer greps for after editing this file.
--
-- It catches the three mistakes that are actually made: a duplicate key (the
-- second one becomes unreachable), a default that does not resolve (everybody
-- silently gets entry 1), and a record that leaves the chassis band (the
-- balance claim quietly stops being true).
do
    local problems = {}
    local prefix = Open77VehicleRoster.band.prefix

    for listId, list in pairs(lists) do
        local seen = {}
        local defaultFound = false

        for index, entry in ipairs(list.entries) do
            local where = ("%s[%d] %s"):format(listId, index, tostring(entry.key))

            if type(entry.key) ~= "string" or entry.key == "" then
                problems[#problems + 1] = where .. ": missing key"
            elseif seen[entry.key] then
                problems[#problems + 1] = where .. ": duplicate key"
            else
                seen[entry.key] = true
            end

            if type(entry.record) ~= "string" or not entry.record:match("^Vehicle%.") then
                problems[#problems + 1] = where .. ": record is not a Vehicle.* string"
            end

            if entry.key == list.default then defaultFound = true end

            -- The band test. An NCPD record does not carry the class prefix in
            -- its own name, so it is tested through its `fallback`, which is by
            -- construction the same chassis's `*_player` variant. An NCPD entry
            -- with no fallback cannot be band-checked at all, and that is
            -- itself worth a line.
            local bandProbe = entry.record
            if bandProbe:match("^Vehicle%.ncpd_") then
                bandProbe = entry.fallback
                if bandProbe == nil then
                    problems[#problems + 1] = where .. ": NCPD record with no fallback; chassis band unverifiable"
                end
            end
            if bandProbe ~= nil and not bandProbe:find(prefix, 1, true) then
                problems[#problems + 1] = ("%s: '%s' is outside the %s band"):format(
                    where, bandProbe, prefix)
            end
        end

        if not defaultFound then
            problems[#problems + 1] = ("%s: default '%s' resolves to no entry"):format(
                listId, tostring(list.default))
        end
    end

    Open77VehicleRoster.problems = problems

    -- `Open77.log` exists on both hosts; `print` is the fallback for a plain
    -- copy of this file dropped somewhere without the namespace.
    local function say(line)
        if type(Open77) == "table" and type(Open77.log) == "table" then
            if #problems > 0 then Open77.log.warn(line) else Open77.log.info(line) end
        else
            print(line)
        end
    end

    if #problems > 0 then
        say(("[vehicleroster] %d problem(s) -- %s"):format(#problems, table.concat(problems, "; ")))
    else
        local counts = {}
        for listId, list in pairs(lists) do
            counts[#counts + 1] = ("%s=%d"):format(listId, #list.entries)
        end
        table.sort(counts)
        say(("[vehicleroster] v%s ok, band %s, %s"):format(
            Open77VehicleRoster.version, prefix, table.concat(counts, " ")))
    end
end
