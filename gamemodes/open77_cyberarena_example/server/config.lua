-- Reserve this bucket for this optional resource. Players walk to the surveyed
-- site before joining; the example never teleports or forces a respawn.
Cyberarena = {
    bucket = 11877,
    center = {x=2570,y=113,z=78.63}, radius = 20, height = 6,
    maxPlayers = 8, durationMs = 300000, prepareTimeoutMs = 20000,
    resetCooldownMs = 10000, defaultGrade = "training",
    definition = {id="example.arena.gorilla",version=1,slot="arms",profile="gorilla_arms",grades={
        {id="training",normalDamage=15,chargedDamage=35,knockbackMeters=3.5,
            cooldownMs=800,chargeMs=650,maxChargeMs=3000,
            normalStaminaCost=10,chargedStaminaCost=20,nonlethal=true},
        {id="industrial",normalDamage=25,chargedDamage=60,knockbackMeters=4.5,
            cooldownMs=1000,chargeMs=800,maxChargeMs=4000,
            normalStaminaCost=20,chargedStaminaCost=35,nonlethal=true},
        {id="cosmetic",normalDamage=0,chargedDamage=0,knockbackMeters=0,
            cooldownMs=800,chargeMs=650,maxChargeMs=5000,
            normalStaminaCost=0,chargedStaminaCost=0,cosmetic=true,nonlethal=true},
        -- Explicit loadout selection for lethal combat; paid implants stay intact.
        {id="lethal",normalDamage=25,chargedDamage=60,knockbackMeters=4.5,
            cooldownMs=1000,chargeMs=800,maxChargeMs=4000,
            normalStaminaCost=20,chargedStaminaCost=35,nonlethal=false},
    }},
}
