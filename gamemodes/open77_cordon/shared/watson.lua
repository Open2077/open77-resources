-- Watson / Kabuki Market -- the COMPACT TEST MAP.
--
-- ---------------------------------------------------------------------------
-- WHY THIS MAP EXISTS, AND WHY IT IS SMALL ON PURPOSE.
--
-- Cordon's v1 map is Pacifica (decision 20). It is not playable today, and not
-- for a map reason: the district the grid landed in, Dogtown, does not load its
-- collision for an Open77 session. The owner walks roads and nightclub stairs
-- and falls through them, at the same places, on foot, with `char.state`
-- reporting `grounded=yes` a metre away. Confirmed 2026-09-02 by a third party
-- that the SAME streets are solid in vanilla, so the holes are ours and follow
-- the mod rather than the district -- which is why relocating is not a fix. It
-- is an unblock: the battle royale can be built and tested on ground that
-- works while that bug is diagnosed on its own.
--
-- Set the `activeMap` tunable back to "pacifica" when it is fixed. Nothing else
-- has to change; see `K.builtinMaps` in server/main.lua.
--
-- ---------------------------------------------------------------------------
-- EVERY COORDINATE BELOW WAS WALKED, NOT PROBED, AND THAT IS THE POINT.
--
-- The survey probe flies the surveyor UP and drops them, so in a dense district
-- it measures the first thing it lands on -- which in Watson is a ROOFTOP. Four
-- sweeps over Watson returned z between 8.9 and 57.8 for exactly that reason,
-- and those roof heights are worthless as landing zones.
--
-- So this map takes its geometry from `open77_deathmatch/shared/kabuki.lua`
-- instead: fourteen positions that the deathmatch mode spawns real players on
-- and has been fought over for weeks, every one of them between z 7.76 and
-- 11.94, with not one collision complaint. That is a stronger guarantee than
-- any probe sweep in this repository, and it is why `surveyed` is true and
-- `provisional` is false here while Pacifica is the reverse.
--
-- THE GRID IS SIZED TO THE PROVEN GROUND, not to a battle royale. Two hundred
-- metres square is far too small for sixty-four players and is not pretending
-- otherwise: it exists so the match loop, the cordon, loot, squads, revive and
-- extraction can be exercised end to end on ground that cannot fall out from
-- under the test. Every one of the four cells contains walked ground, which no
-- larger framing of this data can honestly claim. Expand it by walking more of
-- Watson, never by widening the grid over cells nobody has stood in.
-- ---------------------------------------------------------------------------

Watson = Watson or {}

Watson.name = "watson"
Watson.title = "Watson — Kabuki Market"

-- True because every position here is a walked deathmatch spawn, not a probe
-- reading. See the header.
Watson.surveyed = true
Watson.provisional = false

-- The walked source points, kept so a later re-survey can tell what was
-- inherited from the deathmatch map from what was added by walking Watson.
Watson.groundSamples = {
    { x = -1247.272, y = 1973.837, z = 7.966 },
    { x = -1223.905, y = 1989.450, z = 7.984 },
    { x = -1220.135, y = 2048.270, z = 7.817 },
    { x = -1218.649, y = 2022.934, z = 7.816 },
    { x = -1218.127, y = 1950.171, z = 7.984 },
    { x = -1212.332, y = 2082.062, z = 7.847 },
    { x = -1212.264, y = 1978.527, z = 7.984 },
    { x = -1204.229, y = 2068.211, z = 7.886 },
    { x = -1192.751, y = 2072.839, z = 7.816 },
    { x = -1191.302, y = 2006.883, z = 7.816 },
    { x = -1178.658, y = 2028.453, z = 7.954 },
    { x = -1173.115, y = 2087.440, z = 11.941 },
    { x = -1160.499, y = 2019.064, z = 7.763 },
    { x = -1149.223, y = 2054.840, z = 7.764 },
}

Watson.grid = {
    -- SW corner of block (1,1). Chosen so that all fourteen walked points fall
    -- inside the 2x2, and so that each of the four cells contains at least one:
    -- (1,1) holds seven, (1,2) four, (2,1) one, (2,2) one.
    origin = { x = -1270.0, y = 1930.0, z = 8.0 },
    blockMetres = 100.0,
    cols = 2,
    rows = 2,

    -- Kabuki's own volumes run z 2.33 (the lower walkway) to 23.94 (the market
    -- roof edge), so the floor margin has to clear the walkway and the ceiling
    -- has to clear the gallery without swallowing the megabuildings above.
    floorMargin = 20.0,
    ceilingMargin = 200.0,

    -- REQUIRED, and its absence is not a warning but a refusal: K.recomputeSurveyed
    -- treats a nil groundDefault as an unsurveyed map, and an unsurveyed map
    -- refuses staging and deploy outright. Measured 2026-09-02 -- the mode
    -- started, logged "map is NOT surveyed", and would place nobody.
    --
    -- 7.9 is the MEDIAN of the fourteen walked spawns, not the first of them.
    -- Twelve of the fourteen sit between 7.76 and 7.99, so the median is a
    -- genuine street level here rather than an average across a cliff -- which
    -- is exactly the mistake Pacifica's header warns about, where real land
    -- ranged 5.8 to 42.6 within a few hundred metres and one default would bury
    -- or drop a player.
    groundDefault = 7.9,

    -- Only the gallery differs enough to matter: cell (1,2) holds the raised
    -- walkway at 11.94, four metres above the market floor.
    ground = {
        ["1,2"] = 11.941,
    },
}

-- Nothing is excluded: every cell has walked ground. That is the whole reason
-- the grid was sized this way.
Watson.excluded = {}

-- ALL FOUR BLOCKS, and the reason is the owner's own report after playing it:
-- "le cercle se ferme toujours au meme endroit sur les meme bloc".
--
-- This used to be `{ "1,1", "1,2" }` -- the two DENSEST cells, on the
-- argument that the last fight should happen where the ground is best
-- attested. That argument is sound and it produced a map with two endings.
-- Worse than two: on the 8x8 lattice the final cell is drawn from the walked
-- cells near each block's MIDDLE (`finalCandidates` in server/cordon.lua), and
-- for these two blocks every such cell sits in lattice columns 1-3 -- the
-- west three-eighths of the district. Every match converged on the same
-- corner, and the closing rings, which are drawn around the final cell,
-- swept the same streets in the same order every time.
--
-- Every one of the four blocks contains walked ground -- (2,1) holds East Row
-- (-1160.5, 2019.1), (2,2) holds Far Corner (-1149.2, 2054.8), both of them
-- deathmatch spawns that have been fought over for weeks -- so all four
-- qualify under the one criterion that matters ("real ground, real cover,
-- reachable from more than one direction" -- see Pacifica's whitelist note).
-- With the candidate rule widened to every walked cell of a whitelisted block,
-- this gives fourteen distinct final cells spread across the whole lattice
-- instead of eight bunched in one corner, and `finalRepeatMemory` in
-- `Config.cordon` stops two consecutive matches from picking the same one.
--
-- Expand this list only with blocks that carry a walked point; `/br.map check`
-- now asks for all four.
Watson.finalBlocks = { "1,1", "1,2", "2,1", "2,2" }

Watson.staging = {
    -- THE AFTERLIFE, and it is not on this map at all -- that is the point.
    --
    -- Staging runs in its OWN routing bucket (5100) while the match runs in
    -- 5101, so the lobby is a different dimension and needs no relationship to
    -- the play grid. It can therefore be the best room in Night City rather
    -- than a corner of the arena.
    --
    -- Chosen after testing candidates on 2026-09-03. The Arasaka orbital
    -- station was tried first and is unusable: its geometry is quest-only decor
    -- and is never streamed into the persistent world, so a player teleported
    -- there reads `grounded=no` and falls thirteen hundred metres into the
    -- Badlands. The Afterlife is the opposite -- fully streamed persistent
    -- world, solid floor 1.3 m under the requested z, a real minimap, and an
    -- interior, which matters: Cyberpunk's interiors are built to be walked,
    -- unlike the outdoor decks that have cost this project a whole evening of
    -- falling through Dogtown.
    --
    -- Being enclosed is a feature for a lobby: sixty-four players waiting
    -- cannot wander out of it.
    position = { x = -1455.068, y = 1010.975, z = 17.824 },
    heading = 0.0,
    radius = 12.0,
}

Watson.landmarks = {
    { key = "market",   label = "Kabuki Market",   position = { x = -1204.229, y = 2068.211, z = 7.886 } },
    { key = "gallery",  label = "The Gallery",     position = { x = -1173.115, y = 2087.440, z = 11.941 } },
    -- The centre of Kabuki's own `lower` volume (min -1207.146,2030.000,2.332
    -- to max -1195.000,2041.200,8.866), not a copy of the market anchor. It
    -- was a duplicate of it and the two labels drew on top of each other.
    { key = "lower",    label = "Lower Walkway",   position = { x = -1201.073, y = 2035.600, z = 5.599 } },
    { key = "southgate",label = "South Gate",      position = { x = -1218.127, y = 1950.171, z = 7.984 } },
    { key = "eastrow",  label = "East Row",        position = { x = -1149.223, y = 2054.840, z = 7.764 } },
}

-- Twelve landing zones. Two are hot: the gallery, which is the only elevated
-- ground on the map, and the market centre, which is the natural convergence.
Watson.landings = {
    { key = "lz_south",   label = "South Gate",     position = { x = -1218.127, y = 1950.171, z = 7.984 }, hot = false, probed = true },
    { key = "lz_west",    label = "West Approach",  position = { x = -1247.272, y = 1973.837, z = 7.966 }, hot = false, probed = true },
    { key = "lz_stalls",  label = "The Stalls",     position = { x = -1223.905, y = 1989.450, z = 7.984 }, hot = false, probed = true },
    { key = "lz_lane",    label = "Vendor Lane",    position = { x = -1212.264, y = 1978.527, z = 7.984 }, hot = false, probed = true },
    { key = "lz_centre",  label = "Market Centre",  position = { x = -1191.302, y = 2006.883, z = 7.816 }, hot = true,  probed = true },
    { key = "lz_cross",   label = "The Crossing",   position = { x = -1218.649, y = 2022.934, z = 7.816 }, hot = false, probed = true },
    { key = "lz_noodle",  label = "Noodle Row",     position = { x = -1178.658, y = 2028.453, z = 7.954 }, hot = false, probed = true },
    { key = "lz_east",    label = "East Row",       position = { x = -1160.499, y = 2019.064, z = 7.763 }, hot = false, probed = true },
    { key = "lz_north",   label = "North Stalls",   position = { x = -1220.135, y = 2048.270, z = 7.817 }, hot = false, probed = true },
    { key = "lz_arch",    label = "The Arch",       position = { x = -1192.751, y = 2072.839, z = 7.816 }, hot = false, probed = true },
    { key = "lz_gallery", label = "The Gallery",    position = { x = -1173.115, y = 2087.440, z = 11.941 }, hot = true,  probed = true },
    { key = "lz_far",     label = "Far Corner",     position = { x = -1149.223, y = 2054.840, z = 7.764 }, hot = false, probed = true },
}
Watson.landingTarget = 12

-- Loot follows the walked points, tiered by how exposed each one is: the open
-- centre and the gallery pay best because they are the hardest to hold.
Watson.lootClusters = {
    { key = "w1", tier = 1, count = 12, radius = 18.0, position = { x = -1247.272, y = 1973.837, z = 7.966 }, probed = true },
    { key = "w2", tier = 1, count = 12, radius = 18.0, position = { x = -1218.127, y = 1950.171, z = 7.984 }, probed = true },
    { key = "w3", tier = 1, count = 12, radius = 18.0, position = { x = -1212.264, y = 1978.527, z = 7.984 }, probed = true },
    { key = "w4", tier = 2, count = 10, radius = 16.0, position = { x = -1218.649, y = 2022.934, z = 7.816 }, probed = true },
    { key = "w5", tier = 2, count = 10, radius = 16.0, position = { x = -1178.658, y = 2028.453, z = 7.954 }, probed = true },
    { key = "w6", tier = 2, count = 10, radius = 16.0, position = { x = -1220.135, y = 2048.270, z = 7.817 }, probed = true },
    { key = "w7", tier = 3, count = 8,  radius = 14.0, position = { x = -1191.302, y = 2006.883, z = 7.816 }, probed = true },
    { key = "w8", tier = 3, count = 8,  radius = 14.0, position = { x = -1160.499, y = 2019.064, z = 7.763 }, probed = true },
    { key = "w9", tier = 4, count = 6,  radius = 12.0, position = { x = -1173.115, y = 2087.440, z = 11.941 }, probed = true },
}
Watson.lootClusterTarget = 9

-- Not surveyed for this test map, and deliberately left empty rather than
-- guessed: a vehicle spawned inside market geometry is worse than no vehicle.
Watson.vehicles = {}
Watson.vehicleTarget = 0

Watson.holdouts = {}
Watson.holdoutTarget = 0

Watson.supply = {
    { key = "ws1", position = { x = -1191.302, y = 2006.883, z = 7.816 }, probed = true },
    { key = "ws2", position = { x = -1204.229, y = 2068.211, z = 7.886 }, probed = true },
    { key = "ws3", position = { x = -1212.332, y = 2082.062, z = 7.847 }, probed = true },
}
Watson.supplyTarget = 3

Watson.extractions = {}

-- The targets are what THIS map actually carries, so `/br.map check` reports
-- the truth about it rather than measuring a 200 m test map against a 2 km
-- sector's requirements and calling it incomplete forever.
Watson.progress = {
    { key = "origin",       need = 1,  what = "grid origin (SW corner of block 1,1)" },
    { key = "ground",       need = 1,  what = "default ground Z, from the walked deathmatch spawns" },
    { key = "staging",      need = 1,  what = "staging anchor" },
    { key = "landmarks",    need = 5,  what = "named landmarks for the tac-map" },
    { key = "landings",     need = 12, what = "landing zones, 2 marked hot" },
    { key = "lootClusters", need = 9,  what = "loot cluster anchors with tiers" },
    { key = "vehicles",     need = 0,  what = "vehicle spots (not surveyed on the test map)" },
    { key = "holdouts",     need = 0,  what = "gang holdout sites (not surveyed on the test map)" },
    { key = "supply",       need = 3,  what = "supply drop candidates" },
    -- FOUR, not two. `need = 2` is how a two-block whitelist shipped and every
    -- match ended in the same corner (see `Watson.finalBlocks`). On this map
    -- every block has walked ground, so the honest requirement is every block.
    { key = "finalBlocks",  need = 4,  what = "final-block whitelist -- every block, all four carry walked ground" },
    { key = "excluded",     need = 0,  what = "cells with no walkable ground -- there are none here" },
}

return Watson
