-- GENERATED FILE -- do not edit by hand.
--
-- Produced by resources/system/open77_admin/tools/build-weapons.py from
-- docs/generated/weapons-2.31.csv (Cyberpunk 2077 build 2.31 + Phantom
-- Liberty). Re-run the generator instead of editing; a hand edit is lost on
-- the next build and drifts silently from the extraction it claims to mirror.
--
-- Shared, not server-only: the panel renders it and the server validates
-- against it, so both halves must read the same bytes. THE CATALOGUE IS THE
-- ALLOWLIST -- server/weapons.lua refuses any record that is not in `index`,
-- which is what stops a client naming an arbitrary TweakDB string. See the
-- authority note in wiki/weapons-api.md.
--
-- Every record here is `canonical`, `EquipmentArea.Weapon` and not deprecated.
-- The three areas the Lua weapons API refuses -- QuickSlot (grenades),
-- WeaponHeavy (the portable HMG) and ArmsCW (arm cyberware) -- are filtered
-- out at generation, so nothing in this file can answer
-- `unsupported_weapon_area`.
--
-- Records are parallel arrays, like the vehicle catalogue: 189 tables of
-- three string keys is Lua state built on every client at load, three arrays
-- is not.
--
-- ONE FILE, unlike shared/catalog*.lua, and that is measured rather than
-- careless: this costs about 1349 VM instructions against the host's
-- 10 000-instruction hook stride, where the 189-record vehicle catalogue cost
-- ~13 700 and had to be split. shared/catalog.lua carries the full note.

Open77AdminWeapons = {
    build = "2.31",
    count = 189,

    -- Ordered as the operator meets them. `ammo` says whether the class has an
    -- ammo pool at all -- `WeaponItem_Record.Ammo()` is undefined for melee,
    -- and asking for ammo there answers `weapon_has_no_ammo`. `reserve` is the
    -- full load this package hands out with the weapon; Open77AdminConfig
    -- .weapons.reserve overrides it per server.
    classes = {
        { key = "handgun", label = "Handguns", order = 10, ammo = true, reserve = 500, count = 41 },
        { key = "revolver", label = "Revolvers", order = 20, ammo = true, reserve = 500, count = 17 },
        { key = "smg", label = "SMGs", order = 30, ammo = true, reserve = 800, count = 18 },
        { key = "rifle", label = "Assault rifles", order = 40, ammo = true, reserve = 800, count = 18 },
        { key = "precision", label = "Precision rifles", order = 50, ammo = true, reserve = 400, count = 7 },
        { key = "sniper", label = "Sniper rifles", order = 60, ammo = true, reserve = 120, count = 12 },
        { key = "shotgun", label = "Shotguns", order = 70, ammo = true, reserve = 150, count = 13 },
        { key = "dual", label = "Double-barrels", order = 80, ammo = true, reserve = 150, count = 7 },
        { key = "lmg", label = "LMGs", order = 90, ammo = true, reserve = 800, count = 4 },
        { key = "blade", label = "Blades", order = 110, ammo = false, reserve = 0, count = 21 },
        { key = "knife", label = "Knives", order = 120, ammo = false, reserve = 0, count = 10 },
        { key = "blunt", label = "Blunt", order = 130, ammo = false, reserve = 0, count = 21 },
    },

    -- The records. Position in this array is the identity everything else
    -- keys on.
    records = {
        "Items.Preset_Chao_Default", "Items.Preset_Kenshin_Spy", "Items.Preset_Kenshin_Frank", "Items.Preset_Lexington_Toygun",
        "Items.Preset_Grit_Amazon", "Items.Preset_Kenshin_Royce", "Items.Preset_Kappa_George", "Items.Preset_Yukimura_Kiji",
        "Items.Preset_Unity_Angelica", "Items.Preset_Grit_Default", "Items.Preset_Yukimura_Default", "Items.Preset_Ticon_Gwent",
        "Items.Preset_Kenshin_Default", "Items.Preset_Kappa_Default", "Items.Preset_Kappa_Legendary", "Items.Preset_Liberty_Yorinobu",
        "Items.Preset_Nue_Jackie", "Items.Silenced_Lexington", "Items.Preset_Lexington_Shooting_Competition", "Items.Preset_Liberty_Default",
        "Items.Preset_Omaha_Suzie", "Items.Preset_Lexington_Default", "Items.Preset_Omaha_Default", "Items.Preset_Silverhand_3516",
        "Items.Preset_Ticon_Default", "Items.Preset_Nue_Maiko", "Items.Preset_Nue_Default", "Items.Preset_Q001_Lexington",
        "Items.Preset_Chao_VooDoo", "Items.Preset_Liberty_Rogue", "Items.Preset_Ticon_Reed", "Items.Preset_Liberty_Dex",
        "Items.Silverhand_Malorian", "Items.Preset_Nue_Bree", "Items.Preset_Lexington_Rook", "Items.Preset_Unity_Agent",
        "Items.Preset_Liberty_Padre", "Items.Preset_Yukimura_Skippy", "Items.Preset_Base_Slaughtomatic", "Items.Preset_Nue_Arasaka_2020",
        "Items.Preset_Unity_Default", "Items.Preset_Overture_Cassidy", "Items.Preset_Overture_Kerry", "Items.Preset_Overture_River",
        "Items.Preset_Nova_Doom_Doom", "Items.Preset_Quasar_Default", "Items.Preset_Nova_Default", "Items.Preset_Quasar_Baron",
        "Items.Preset_Burya_AirDrop", "Items.Preset_Nova_Hitman", "Items.Preset_Burya_Comrade", "Items.Preset_Metel_Default",
        "Items.Preset_Overture_Default", "Items.Preset_Metel_Kurt", "Items.Preset_Overture_Dodger", "Items.Preset_Burya_Default",
        "Items.Preset_Metel_AirDrop", "Items.Preset_Overture_Dante", "Items.Preset_Pulsar_Buzzsaw", "Items.Preset_Warden_Amazon",
        "Items.Preset_Pulsar_Default", "Items.Preset_Borg4a_HauntedGun", "Items.Preset_Saratoga_Maelstrom", "Items.Preset_Dian_Default",
        "Items.Preset_Guillotine_Default", "Items.Preset_Guillotine_Collectible", "Items.Preset_Saratoga_Default", "Items.Preset_Warden_Boris",
        "Items.Preset_Shingen_Prototype", "Items.Preset_Senkoh_Prototype", "Items.Preset_Senkoh_Default", "Items.Preset_Saratoga_Arasaka_2020",
        "Items.Preset_Saratoga_Raffen", "Items.Preset_Shingen_Default", "Items.Preset_Warden_Default", "Items.Preset_Dian_Yinglong",
        "Items.Preset_Umbra_Bebe", "Items.Preset_Kyubi_Amazon", "Items.Preset_Copperhead_Default", "Items.Preset_Sidewinder_Default",
        "Items.Preset_Umbra_Default", "Items.Preset_Kyubi_Myers", "Items.Preset_Hercules_Default", "Items.Preset_Masamune_Default",
        "Items.Preset_Kyubi_Default", "Items.Preset_Kyubi_Legendary", "Items.Preset_Sidewinder_Divided", "Items.Preset_Ajax_Default",
        "Items.Preset_Ajax_Moron", "Items.Preset_Masamune_Arasaka_2020", "Items.Preset_Ajax_Amazon", "Items.Preset_Masamune_Rogue",
        "Items.Preset_Copperhead_Genesis", "Items.Preset_Umbra_Collectible", "Items.Preset_Achilles_Collectible", "Items.Preset_Kolac_Tiny_Mike",
        "Items.Preset_Kolac_Default", "Items.q115_corpo_rifle", "Items.Preset_Achilles_Default", "Items.Preset_Sor22_Default",
        "Items.Preset_Achilles_Nash", "Items.Preset_Ashura_Default", "Items.Preset_Grad_AirDrop", "Items.Preset_Nekomata_Breakthrough",
        "Items.Preset_Nekomata_Amazon", "Items.Preset_Osprey_Default", "Items.Preset_Nekomata_Default", "Items.Preset_Grad_Buck",
        "Items.Preset_Grad_Panam", "Items.Preset_Tech_Sniper_Rifle_Default", "Items.Preset_Grad_Scav", "Items.Preset_Grad_Default",
        "Items.Preset_Ashura_Twitch", "Items.Preset_Pozhar_AirDrop", "Items.Preset_Crusher_Amazon", "Items.Preset_Zhuo_Eight_Star",
        "Items.Preset_Tactician_Dino", "Items.Preset_Carnage_Default", "Items.Preset_Crusher_Default", "Items.Preset_Carnage_Edgerunners",
        "Items.Preset_Zhuo_Default", "Items.Preset_Tactician_Headsman", "Items.Preset_Tactician_Default", "Items.Preset_Carnage_Mox",
        "Items.Preset_Pozhar_Legendary", "Items.Preset_Pozhar_Default", "Items.Preset_Satara_Default", "Items.Preset_Testera_Default",
        "Items.Preset_Igla_Default", "Items.Preset_Palica_Default", "Items.Preset_Testera_Nicolas", "Items.Preset_Satara_Brick",
        "Items.Preset_Igla_Sovereign", "Items.Preset_Defender_Kurt", "Items.Preset_Defender_Default", "Items.Preset_MA70_Default",
        "Items.Preset_MA70_Collectible", "Items.Preset_VB_Axe", "Items.Preset_Katana_Wakako", "Items.Preset_Butchers_Knife_Iconic",
        "Items.Preset_Chainsword_Default", "Items.Preset_Chainsword_Legendary", "Items.Preset_Katana_E3", "Items.Preset_Fanged_Axe_Default",
        "Items.Preset_Fanged_Axe_Collectible", "Items.Preset_Sword_Witcher", "Items.Preset_Katana_Takemura", "Items.Preset_Katana_Default",
        "Items.Preset_Kukri_Default", "Items.Preset_Katana_GoG", "Items.Preset_Machete_Default", "Items.Preset_Katana_Cocktail",
        "Items.Preset_Machete_Borg_Default", "Items.Preset_Katana_Saburo", "Items.Preset_Katana_Surgeon", "Items.Preset_Tomahawk_Default",
        "Items.Preset_Katana_Hiromi", "Items.Preset_Machete_Borg_AirDrop", "Items.Preset_Punk_Knife_Iconic", "Items.Preset_Chefs_Knife_Default",
        "Items.Preset_Punk_Knife_Default", "Items.Preset_Neurotoxin_Knife_Default", "Items.Preset_Knife_Kurtz_1", "Items.Preset_Neurotoxin_Knife_Iconic",
        "Items.Preset_Knife_Stinger", "Items.Preset_Tanto_Default", "Items.Preset_Knife_Default", "Items.Preset_Tanto_Saburo",
        "Items.Preset_Baseball_Bat_Malina", "Items.Preset_Baseball_Bat_Default", "Items.Preset_Baseball_Bat_Legendary", "Items.Preset_Baseball_Bat_Denny",
        "Items.Preset_Dildo_SexShop", "Items.Preset_Baton_Tinker_Bell", "Items.Preset_Tire_Iron_Default", "Items.Preset_Hammer_Default",
        "Items.Preset_Kanabo_Default", "Items.Preset_Knuckles_Golden", "Items.Preset_Baton_Murphy", "Items.Preset_Hammer_Sasquatch",
        "Items.Preset_Baton_Alpha", "Items.Preset_Baton_Beta", "Items.Preset_Baton_Gamma", "Items.Preset_Cane_Fingers",
        "Items.Preset_Shovel_Caretaker", "Items.Preset_Crowbar_Default", "Items.Preset_Knuckles_Default", "Items.Preset_Dildo_Stout",
        "Items.Preset_Iron_Pipe_Default",
    },

    -- Display names, parallel to records.
    names = {
        "A-22B Chao", "Ambition", "Apparition", "AR Raygun Supreme 9000",
        "Catahoula", "Chaos", "Gardien de la paix", "Genjiroh",
        "Guépard", "HA-4 Grit", "HJKE-11 Yukimura", "Incinération",
        "JKE-X2 Kenshin", "Kappa", "Kappa x-MOD2", "Kongou",
        "La Chingona Dorada", "Lexington M-10AF avec silencieux", "Lexington x-MOD2", "Liberty",
        "Lizzie", "M-10AF Lexington", "M-76e Omaha", "Malorian Arms 3516",
        "Militech Ticon", "Mort et impôts", "Nue", "Nuit moribonde",
        "Ogou", "Orgueil", "Paria", "Plan B",
        "Revolver de Johnny", "Riskit", "Rook", "Sa Majesté",
        "Seraph", "Skippy", "Slaught-O-Matic", "Tamayura",
        "Unity", "Amnesty", "Archangel", "Crash",
        "Doom Doom", "DR-12 Quasar", "DR5 Nova", "Gris-Gris",
        "Laika", "Mancinella", "Marteau du Camarade", "Metel",
        "Overture", "Pygargue", "Rosco", "RT-46 Burya",
        "Taïgan", "Vieille branche", "Buzzsaw", "Chesapeake",
        "DS1 Pulsar", "Erebus", "Fenrir", "G-58 Dian",
        "Guillotine", "Guillotine x-MOD2", "M221 Saratoga", "Pizdets",
        "Prototype : Shingen Mark V", "Raiju", "Senkoh LX", "Shigure",
        "Solutionneur", "TKI-20 Shingen", "Warden", "Yinglong",
        "Carmen", "Chinook", "D5 Copperhead", "D5 Sidewinder",
        "DA8 Umbra", "Faucon", "Hercules 3AX", "HJSH-18 Masamune",
        "Kyubi", "Kyubi x-MOD2", "La désunion fait la force", "M251s Ajax",
        "Moron Labe", "Nowaki", "Pit Bull", "Préjugés",
        "Psaume 11:6", "Umbra x-MOD2", "Achilles x-MOD2", "Hypercritique",
        "Kolac", "M-179 Achilles (modifié)", "M-179e Achilles", "SOR-22",
        "Widow Maker", "Ashura", "Borzaya", "Breakthrough",
        "Foxhound", "NDI Osprey", "Nekomata", "O'Five",
        "Overwatch", "Rasetsu", "Sparky", "SPT32 Grad",
        "Yasha", "Alabai", "Amstaff", "Ba Xing Chong",
        "Bloody Maria", "Carnage", "Crusher", "Guts",
        "L-69 Zhuo", "Le Bourreau", "M2038 Tactician", "Mox",
        "Pozhar x-MOD2", "VST-37 Pozhar", "DB-2 Satara", "DB-2 Testera",
        "DB-4 Igla", "DB-4 Palica", "Dezerter", "Order",
        "Sovereign", "Dingo", "M2067 Defender", "MA70 HB",
        "MA70 HB x-MOD2", "Agaou", "Byakko", "Couperet",
        "Cut-o-Matic", "Cut-o-Matic x-MOD2", "Errata", "Griffe",
        "Griffe x-MOD2", "Gwynbleidd", "Jinchu-maru", "Katana",
        "Koukri", "Licorne noire", "Machete", "Pique à cocktail",
        "Rasoir", "Satori", "Scalpel", "Tomahawk",
        "Tsumetogi", "Volkodav", "Chasseur de têtes", "Couteau de chef",
        "Couteau de voyou", "Couteau neurotoxique", "Croc", "Croc bleu",
        "Dard", "Kaiken", "Knife", "Nehan",
        "Baby Boomer", "Batte de baseball", "Batte de baseball x-MOD2", "Batte plaquée or",
        "BFC 9000", "Clochette", "Démonte-pneu", "Hammer",
        "Kanabo", "La désunion fait la force", "Loi de Murphy", "Marteau de Sasquatch",
        "Matraque alpha électrique", "Matraque bêta électrique", "Matraque gamma électrique", "Mocassin",
        "Pelle du Gardien", "Pied-de-biche", "Poing américain", "Sire Vergeraide",
        "Tube en acier",
    },

    -- Class row index, parallel to records.
    classOf = {
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5,
        5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    },
}

-- record -> position. Built here rather than shipped as a third array: a
-- 189-row loop is 567 opcodes, and shipping the keys would double the
-- file for no gain.
Open77AdminWeapons.index = {}
for position = 1, #Open77AdminWeapons.records do
    Open77AdminWeapons.index[Open77AdminWeapons.records[position]] = position
end

--- The class row for a record, or nil when the record is not in the catalogue.
function Open77AdminWeapons.classOfRecord(record)
    local position = Open77AdminWeapons.index[record]
    if position == nil then return nil end
    return Open77AdminWeapons.classes[Open77AdminWeapons.classOf[position]]
end

--- Display name for a record, falling back to the record itself.
function Open77AdminWeapons.nameOf(record)
    local position = Open77AdminWeapons.index[record]
    return position ~= nil and Open77AdminWeapons.names[position] or record
end

assert(#Open77AdminWeapons.records == Open77AdminWeapons.count
    and #Open77AdminWeapons.names == Open77AdminWeapons.count
    and #Open77AdminWeapons.classOf == Open77AdminWeapons.count,
    "open77_admin: weapon catalogue incomplete -- re-run tools/build-weapons.py")
