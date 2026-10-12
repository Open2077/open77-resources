-- Optional presentation policy. Disable globally, replace this server script,
-- or select effects for your own grades. Installation/combat rules stay in the
-- resource that defines the implant; this file changes visuals only.
CyberwarePresentation = {
    enabled = true,
    pollMs = 100,
    feedback = {
        enabled = true,
        intervalMs = 1000,
        messages = {
            insufficient_stamina = "Not enough stamina for that punch.",
            cooldown = "Your arms are recovering. Try again in a moment.",
        },
    },
    defaults = {
        effect = "electric.industrial_arm",
        slot = "RightHand",
        localAnchor = "weaponRight",
        localSlot = "right_hand_start",
        localEvent = "spy_perk_charge",
        chargeSoundEvent = "w_cyb_strongarms_spy_perk_charge",
        soundOnOwner = true,
        impactSoundEvent = "w_cyb_npc_strongarms_hit_face",
        impactSoundDuration = 5,
        -- Operators may omit network audio for listeners whose native contact
        -- already supplies the desired sound. Defaults retain existing audio.
        impactSoundOnAttacker = true,
        impactSoundOnVictim = true,
        soundOnZeroDamage = false,
        chargedOnly = false,
    },
    -- Cross-definition grade fallback is empty by default. Operators may
    -- explicitly populate it when they want that policy for all definitions.
    grades = {},
    -- Only the optional shipped examples opt in. A custom definition using
    -- the same grade names receives no implicit charge/impact presentation.
    -- Additional definition-specific overrides, e.g.
    -- ["my.gorilla"] = { street = { enabled=true, chargedOnly=true } },
    -- ["quiet.gorilla"] = false,
    definitions = {
        ["example.gorilla"] = {
            training = { enabled = true }, industrial = { enabled = true }, cosmetic = { enabled = true },
        },
        ["example.arena.gorilla"] = {
            training = { enabled = true }, industrial = { enabled = true }, cosmetic = { enabled = true },
            lethal = { enabled = true },
        },
        ["lab.gorilla"] = {
            training = { enabled = true }, industrial = { enabled = true }, cosmetic = { enabled = true },
        },
    },
}
