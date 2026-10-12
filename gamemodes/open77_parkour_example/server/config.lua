-- Optional self-service training policy. Enabling this resource does not grant
-- an ability until a player explicitly installs one through /parkour.
ParkourConfig = {
    inputKey = "ctrl",
    -- Audited presentation only: native = sound + FX, silent = FX only,
    -- none = neither. Locomotion animation/collision is still native in all modes.
    presentation = "native",
    -- Set to { [yourTrainingBucket] = true } to restrict this example.
    allowedBuckets = nil,
    presets = {
        basic = { staminaCost=20, cooldownMs=700, maxCharges=1, chargeRegenMs=2500 },
        advanced = { staminaCost=10, cooldownMs=450, maxCharges=3, chargeRegenMs=1500 },
    },
    -- Replace with your server-owned job/progression/access policy. This example
    -- is free; it neither creates currency nor charges an unrelated economy.
    canUse = function(player, preset, mode) return true end,
}
