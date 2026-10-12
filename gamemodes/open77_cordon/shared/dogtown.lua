-- Editable starter, not a surveyed playable map. Owner coordinates, 2026-09-05.
-- The supplied coordinate is the CENTER; the SW origin is center minus 500 m.
-- No street, landing, vehicle or loot position has been invented here.
Dogtown = {
    name = "dogtown", title = "Dogtown", surveyed = false, provisional = true,
    grid = {
        origin = { x = -2206.303, y = -2826.993, z = 39.627 },
        cols = 10, rows = 10, blockMetres = 100.0,
        groundDefault = 39.627, ground = {}, floorMargin = 30.0, ceilingMargin = 200.0,
    },
    staging = { key = "lobby", position = { x = -1895.420, y = -2247.226, z = 440.767 },
        heading = 0.0, headingKnown = false, radius = 2.0 },
    spawns = {}, landings = {}, lootClusters = {}, vehicles = {},
    landmarks = {}, supply = {}, holdouts = {}, extractions = {},
    finalBlocks = {}, excluded = {},
}
