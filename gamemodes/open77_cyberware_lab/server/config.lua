-- Optional acceptance presets. Operators may replace every grade/rule, or
-- remove this lab entirely and register definitions from their own resource.
-- Longer horizontal slide; native gravity, fall animation and collision stay in control.
CyberwareLab = {
    legsDefinition = {
        id="lab.double_jump",version=1,slot="legs",profile="double_jump",grades={
            {id="training",normalDamage=0,chargedDamage=0,knockbackMeters=0,cooldownMs=800,chargeMs=650,
                jumpStaminaCost=15,maxAirborneMs=10000,maxFallSpeed=30},
            {id="athlete",normalDamage=0,chargedDamage=0,knockbackMeters=0,cooldownMs=500,chargeMs=650,
                jumpStaminaCost=8,maxAirborneMs=10000,maxFallSpeed=30},
        },
    },
    definition = {
        id = "lab.gorilla", version = 1, slot = "arms", profile = "gorilla_arms",
        grades = {
            { id="training", normalDamage=15, chargedDamage=35, knockbackMeters=3.5,
                cooldownMs=800, chargeMs=650, nonlethal=true, cosmetic=false },
            { id="industrial", normalDamage=25, chargedDamage=60, knockbackMeters=4.5,
                cooldownMs=1000, chargeMs=800, nonlethal=false, cosmetic=false },
            { id="cosmetic", normalDamage=0, chargedDamage=0, knockbackMeters=0,
                cooldownMs=800, chargeMs=650, nonlethal=true, cosmetic=true },
        },
    },
}

-- Optional Dash session grants; no implant replacement or automatic installation.
CyberwareLab.dash = {
    inputKey="ctrl", presentation="native", allowedBuckets=nil,
    presets={basic={staminaCost=20,cooldownMs=700,maxCharges=1,chargeRegenMs=2500},
        advanced={staminaCost=10,cooldownMs=450,maxCharges=3,chargeRegenMs=1500}},
    -- Same open example policy as the existing lab. Replace for jobs/progression.
    canUse=function(issuer,target,preset,mode) return true end,
}

-- Optional reflex-overdrive session grants. A real-time buff: the shared world
-- keeps running at normal speed, other players are never slowed and no bullet
-- is slowed. The client owns the two stat tiers and their per-stat ceilings, so
-- a preset picks a tier and its economy, never a modifier.
CyberwareLab.reflex = {
    inputKey="x", presentation="native", allowedBuckets=nil,
    presets={
        street={tier="reflex",durationMs=10000,cooldownMs=13000,maxCharges=1,chargeRegenMs=23000,staminaCost=25},
        combat={tier="reflex_heavy",durationMs=8000,cooldownMs=25000,maxCharges=2,chargeRegenMs=45000,staminaCost=40},
    },
    -- Same open example policy as the rest of the lab. Replace for jobs/progression.
    canUse=function(issuer,target,preset) return true end,
}
