-- Optional example policy. No platform service depends on these rules.
-- Credits here are a session-scoped clinic demonstration, keyed by account.
-- Replace payment with the server's economy adapter for a persistent economy.
Ripperdoc = {
    distance = 3.0, consentMs = 30000, procedureMs = 3000,
    startingCredits = 500, removalCost = 25, maxAccounts = 1024,
    costs = { training=100, industrial=250, cosmetic=0 },
    legsCosts = { training=100, athlete=250 },
    legsRemovalCost = 25,
    legsDefinition = { id="example.double_jump", version=1, slot="legs", profile="double_jump", grades={
        {id="training",normalDamage=0,chargedDamage=0,knockbackMeters=0,cooldownMs=800,chargeMs=650,
            jumpStaminaCost=15,maxAirborneMs=10000,maxFallSpeed=30},
        {id="athlete",normalDamage=0,chargedDamage=0,knockbackMeters=0,cooldownMs=500,chargeMs=650,
            jumpStaminaCost=8,maxAirborneMs=10000,maxFallSpeed=30},
    } },
    definition = { id="example.gorilla", version=1, slot="arms", profile="gorilla_arms", grades={
        {id="training",normalDamage=15,chargedDamage=35,knockbackMeters=3.5,cooldownMs=800,chargeMs=650,nonlethal=true},
        {id="industrial",normalDamage=25,chargedDamage=60,knockbackMeters=4.5,cooldownMs=1000,chargeMs=800},
        {id="cosmetic",normalDamage=0,chargedDamage=0,knockbackMeters=0,cooldownMs=800,chargeMs=650,cosmetic=true},
    } },
}
