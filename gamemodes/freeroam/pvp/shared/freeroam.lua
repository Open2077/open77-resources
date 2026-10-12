-- PvP is an opt-in activity. The city never becomes a fenced Deathmatch lobby.
DeathmatchConfig.buckets.lobby = 0
-- Freeroam has one public FFA, not a pool of twelve-player shards. Private
-- queued arena matches retain their separate routing range and capacity.
DeathmatchConfig.buckets.ffaLast = DeathmatchConfig.buckets.ffaFirst
DeathmatchConfig.instances.ffaCeiling = 1
DeathmatchConfig.instances.ffaCapacity = 0 -- zero denotes unlimited, not zero slots
DeathmatchConfig.instances.ffaUnlimited = true
DeathmatchConfig.tunables.ffaCeiling.value = 1
DeathmatchConfig.tunables.ffaCeiling.max = 1
DeathmatchConfig.tunables.ffaCeiling.description = "Freeroam always uses one shared free-for-all."
DeathmatchConfig.tunables.ffaCapacity.value = 0
DeathmatchConfig.tunables.ffaCapacity.min = 0
DeathmatchConfig.tunables.ffaCapacity.max = 0
DeathmatchConfig.tunables.ffaCapacity.description = "Unlimited shared FFA. Only the server's global connection limit applies."
DeathmatchConfig.instances.adoptOnReload = false
DeathmatchConfig.freeroam = true
-- Separate ruleset, same FFA geometry and round engine.
DeathmatchConfig.blade = {
    bucket = 4201,
    label = "Blade FFA",
    default = "katana",
    weapons = {
        { key="katana", label="Katana", category="Katana", record="Items.Preset_Katana_Default" },
        { key="mantis", label="Mantis Blades", category="Arm blades", record="Items.MantisBlades" },
        { key="mantis_electric", label="Electric Mantis Blades", category="Arm blades", record="Items.AdvancedMantisBladesElectricLegendaryPlusPlus" },
        { key="errata", label="Errata", category="Katana", record="Items.Preset_Katana_E3" },
        { key="byakko", label="Byakko", category="Katana", record="Items.Preset_Katana_Wakako" },
        { key="knife", label="Knife", category="Knife", record="Items.Preset_Knife_Default" },
        { key="bluefang", label="Blue Fang", category="Knife", record="Items.Preset_Neurotoxin_Knife_Iconic" },
        { key="machete", label="Machete", category="Long blade", record="Items.Preset_Machete_Default" },
        { key="tomahawk", label="Tomahawk", category="Axe", record="Items.Preset_Tomahawk_Default" },
        { key="hammer", label="Hammer", category="Blunt", record="Items.Preset_Hammer_Default" },
        { key="bat", label="Baseball Bat", category="Blunt", record="Items.Preset_Baseball_Bat_Default" },
        { key="baton", label="Electric Baton", category="Blunt", record="Items.Preset_Baton_Alpha" },
        { key="chainsword", label="Cut-o-Matic", category="Chainsword", record="Items.Preset_Chainsword_Default" },
    },
}
-- Applied to the player's pre-match maximum, never to an already boosted life.
DeathmatchConfig.healthMultiplier = 3
DeathmatchConfig.sfx = {
    enabled = true,
    select = "ui_menu_onpress",
    join = "ui_menu_onpress",
    tick = "sq024_race_countdown",
    start = "sq024_race_start",
    result = "sq024_race_finish",
}
DeathmatchConfig.strings.notice.leftMatch = {
    title = "FREEROAM", body = "Returning to your position in the city.",
}

-- Server owner's captured arena, 2026-09-21. Keep the legacy built-in map key
-- `kabuki` for saved activeMap compatibility; replace its geometry in Freeroam
-- only. The standalone deathmatch gamemode keeps its own map unchanged.
local center = { x = 2998.928223, y = -2414.493408, z = 118.472412 }
local edge = { x = 3047.236328, y = -2282.439697, z = 124.460297 }
local dx, dy = edge.x - center.x, edge.y - center.y
DeathmatchKabuki.volumes = {
    { id = "freeroam_arena", shape = "cylinder", center = center,
      radius = math.sqrt(dx * dx + dy * dy) },
}
local positions = {
    { x = 3007.401367, y = -2423.930664, z = 118.324081 },
    { x = 3007.488281, y = -2401.259033, z = 124.373550 },
    { x = 2983.617676, y = -2388.931885, z = 125.373550 },
    { x = 2994.935791, y = -2400.323486, z = 124.438919 },
    { x = 2978.211670, y = -2379.203857, z = 124.385406 },
    { x = 2990.336914, y = -2366.787598, z = 122.421799 },
    { x = 2987.299805, y = -2351.030762, z = 122.426468 },
    { x = 2983.348633, y = -2359.938965, z = 118.414841 },
    { x = 2978.224365, y = -2383.057373, z = 118.461868 },
    { x = 2960.343506, y = -2383.238281, z = 119.381134 },
    { x = 2959.277100, y = -2396.604980, z = 118.469955 },
    { x = 2958.379639, y = -2405.053711, z = 120.409180 },
    { x = 2962.617920, y = -2365.191162, z = 118.457489 },
    { x = 3037.262207, y = -2396.562012, z = 118.316330 },
    { x = 3058.307373, y = -2407.259277, z = 118.436737 },
    { x = 3030.920898, y = -2426.716797, z = 118.461639 },
    { x = 2987.544434, y = -2446.254883, z = 118.706406 },
}
local marks = {}
for index, position in ipairs(positions) do
    marks[index] = { position = position,
        heading = math.deg(math.atan(position.x - center.x, center.y - position.y)) % 360 }
end
DeathmatchKabuki.spawns.ffa = marks
-- Reuse captured ground-level marks for team modes; no invented positions.
local teamA, teamB = { marks[10], marks[11], marks[12] }, { marks[14], marks[15], marks[16] }
for _, format in ipairs({ "ffa", "1v1", "2v2", "3v3" }) do
    DeathmatchKabuki.formats[format].volumes = { "freeroam_arena" }
    DeathmatchConfig.zones[format].volumes = { "freeroam_arena" }
    DeathmatchConfig.zones[format].label = "Freeroam Arena"
    if format ~= "ffa" then
        local count = tonumber(format:sub(1, 1))
        local teams = { a = {}, b = {} }
        for index = 1, count do teams.a[index], teams.b[index] = teamA[index], teamB[index] end
        DeathmatchKabuki.teams[format] = teams
    end
end
DeathmatchKabuki.set("ffa").limit = #marks
DeathmatchConfig.strings.title = "FREEROAM ARENA"
