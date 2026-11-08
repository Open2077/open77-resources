Aetherfall = {
    title = "AETHERFALL", subtitle = "THE ASTRAL CONCLAVE",
    animationStyle = "aetherfall",
    costumes = {
        {Head=false, Face=false, Outfit=false, OuterChest="Items.Coat_01_basic_01",
            InnerChest="Items.FormalShirt_01_rich_06", Legs="Items.FormalPants_01_basic_01", Feet="Items.Boots_01_basic_01"},
        {Head=false, Face=false, Outfit=false, OuterChest="Items.Coat_04_rich_02",
            InnerChest="Items.FormalShirt_01_rich_06", Legs="Items.FormalPants_01_basic_01", Feet="Items.Boots_01_basic_01"},
    },
    -- Hogwarts house robes (resources/assets/mods/open77_hogwarts_wear, private) worn over the
    -- costume when that resource has registered them; otherwise the costume's own coat.
    robes = { "Items.Open77_HW_StudentRobe_Gryffindor", "Items.Open77_HW_StudentRobe_Slytherin",
        "Items.Open77_HW_StudentRobe_Ravenclaw", "Items.Open77_HW_StudentRobe_Hufflepuff" },
    bucket = 12770, maxPlayers = 8, tickMs = 50, snapshotMs = 100,
    -- The training grounds: the same arena in a bucket of its own. Players arrive here; a duel is
    -- started from the Conclave menu by the mages in its queue.
    lobby = { bucket = 12771, maxPlayers = 32, menuKey = "N" },
    duel = { minPlayers = 2 },
    -- Spell sounds (shared/sounds.lua): master volume, 0..1, on top of each moment's own level.
    sound = { volume = 0.45 },
    -- Training dummies: passive server NPCs (offsets from the arena centre, metres), whose health is
    -- this mode's; a dummy with a patrol walks it back and forth (practise leading your shots).
    training = {
        template = "gang_tygerclaws_ranged_01", health = 200, respawnMs = 3000,
        dummies = {
            {name="Sentinel I", offset={x=0, y=8}},
            {name="Sentinel II", offset={x=-6, y=13}},
            {name="Sentinel III", offset={x=6, y=15}},
            {name="Wanderer", offset={x=-8, y=3}, patrol={{x=-8, y=3}, {x=8, y=3}}},
        },
    },
    arena = { center = {x=2570, y=113, z=96}, radius=19, height=6 },
    rules = { health=200, mana=100, manaRegen=8, wins=3,
        countdownMs=5000, roundMs=90000, intermissionMs=6500, resultMs=12000,
        castLockMs=180, respawnMs=3000, snapshotAgeMs=750 },
    order = {"bolt", "lance", "nova", "ward", "cataclysm"},
    spells = {
        bolt = {name="Emberbolt", key="MOUSE1", icon="bolt", color="#ffb36c", kind="projectile",
            damage=22, cost=0, cooldownMs=650, windupMs=270, speed=32, radius=0.28, range=48,
            -- Hogwarts Flipendo (open77_aetherfall_vfx; its README says how to change them).
            effect="ncwe\\vfx\\flipendo_projectile_f9ea86\\flipendo_projectile_f9ea86.effect",
            impact="ncwe\\vfx\\flipendo_impact_c90a64\\flipendo_impact_c90a64.effect", audio="audio/bolt.wav",
            description="A swift ember. Lead moving targets."},
        lance = {name="Astral Lance", key="V", icon="lance", color="#82ddff", kind="projectile",
            damage=48, cost=25, cooldownMs=4500, windupMs=350, speed=44, radius=0.38, range=52,
            -- Hogwarts Petrificus Totalus (open77_aetherfall_vfx).
            effect="ncwe\\vfx\\petrificus_projectile_116e5a\\petrificus_projectile_116e5a.effect",
            impact="ncwe\\vfx\\petrificus_impact_c1a7cc\\petrificus_impact_c1a7cc.effect", audio="audio/lance.wav",
            description="A piercing arc of astral energy. 48 damage."},
        nova = {name="Cinder Nova", key="E", icon="nova", color="#ff786e", kind="area",
            damage=42, cost=30, cooldownMs=8500, windupMs=850, radius=4.5, range=18,
            effect="fire.small", impact="explosion.frag", audio="audio/nova.wav",
            description="Mark a circle ahead. It erupts after a short warning."},
        ward = {name="Prismatic Ward", key="R", icon="ward", color="#9cf0d0", kind="shield",
            shield=65, durationMs=2200, cost=20, cooldownMs=7000, windupMs=0,
            audio="audio/ward.wav",
            description="Absorb 65 damage for 2.2 seconds. Time it against a lance."},
        cataclysm = {name="Starfall", key="F", icon="star", color="#d7adff", kind="area",
            damage=90, cost=70, cooldownMs=22000, windupMs=1700, radius=6.5, range=24,
            effect="electric.emp.big", impact="cyber.emp_blast", audio="audio/starfall.wav",
            description="Call down a falling star. A wide warning precedes 90 damage."},
    },
}
