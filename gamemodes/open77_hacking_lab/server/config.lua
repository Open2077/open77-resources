-- Reference balance only. No game mode or paid implant is enabled by loading this file.
HackingLab = {
    hack = {id="lab.short_circuit",grades={
        {id="training",range=20,uploadMs=2000,staminaCost=20,cooldownMs=5000,damage=25,
            statusMs=750,recoveryMs=4000,lockHacking=false,nonlethal=true,friendlyFire=false},
        {id="cosmetic",range=20,uploadMs=2000,staminaCost=0,cooldownMs=2500,damage=0,
            statusMs=0,recoveryMs=1000,cosmetic=true,nonlethal=true},
        -- Optional permission-controlled fixture for two-client ally status purge.
        {id="ally_status",range=20,uploadMs=2000,staminaCost=0,cooldownMs=2500,damage=0,
            statusMs=2000,recoveryMs=3000,lockHacking=false,nonlethal=true,friendlyFire=true},
        -- Server-owner outcome catalogue: the platform applies `effects` on a connected
        -- upload through existing primitives. Every field is optional and capped
        -- (freezeMs <= 10000 and <= recoveryMs, disableCyberwareMs <= 30000, damage 0-300).
        {id="stun",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=750,recoveryMs=6000,nonlethal=true,
            effects={damage=10,freezeMs=2000,knockdown=true,disableCyberwareMs=5000}},
        -- Overheat: the same upload, then a server-ticked burn through the damage
        -- ledger (here 40 damage over 5 s in 500 ms ticks after a 5-point direct hit)
        -- until it expires or the victim/an ally purges it. `statusMs` is ignored by
        -- this kind (the burn is the status); `burn` is optional and capped
        -- (totalDamage 0-300, durationMs 1000-15000, tickMs 250-1000). One burn per
        -- victim at a time: a second one is refused, never stacked or refreshed.
        {id="overheat",kind="overheat",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=5,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            burn={totalDamage=40,durationMs=5000,tickMs=500}},
        -- Cyberware Malfunction: a visible, purgeable suppression of the listed
        -- Open77 abilities (`blocks` omitted = dash, ground_slam, gorilla, hacking) for
        -- durationMs (1000-30000); refusals read `cyberware_suspended`. Grants stay
        -- installed; purge, death, reconnect, bucket change and lab stop lift it.
        {id="malfunction",kind="malfunction",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            malfunction={durationMs=8000,blocks={"dash","ground_slam","gorilla","hacking"}}},
        -- Malfunction aimed at the reflex overdrive, so the refusal the overdrive
        -- already enforces is reachable from a hack. Hacking is left alone so the
        -- victim can still purge itself.
        {id="malfunction_reflex",kind="malfunction",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            malfunction={durationMs=8000,blocks={"reflex_overdrive"}}},
        -- Malfunction that leaves hacking alone, so the victim can still purge itself.
        {id="malfunction_motion",kind="malfunction",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            malfunction={durationMs=8000,blocks={"dash","ground_slam","gorilla"}}},
        -- Cripple Movement: no damage; the victim's own client slows itself through the
        -- movement lock (`cripple` = MaxSpeed x0.75, `cripple_heavy` = x0.4, no dodge in
        -- both) for durationMs (1000-30000), while the server refuses Dash and Ground
        -- Slam with `crippled` for the same deadline (hacking, purge and Gorilla stay
        -- usable). One cripple per victim; purge, death, reconnect, bucket change and
        -- lab stop lift it. The 12 s deadline outlasts the 6 s cooldown so a second
        -- upload inside it demonstrates the stacking refusal.
        {id="cripple",kind="cripple",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            cripple={durationMs=12000,heavy=false}},
        {id="cripple_heavy",kind="cripple",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            cripple={durationMs=12000,heavy=true}},
        -- Reboot Optics: no damage; the victim's own client applies the native blind
        -- (`Open77.hacking.nativeStatus("blind")`, an Open77 clone of the netrunner
        -- HackBlind record: status_blinded VFX/SFX, hacking_glitch_low, scanner off,
        -- accuracy x0.01, no movement stats) for durationMs (1000-15000). Nothing is
        -- gated server-side. One per victim; purge, death, reconnect, bucket change and
        -- lab stop lift it. 8 s outlasts the 6 s cooldown so a second upload inside it
        -- demonstrates the stacking refusal.
        {id="reboot_optics",kind="reboot_optics",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            optics={durationMs=8000}},
        -- Weapon Glitch: no damage; the victim's own client applies the native jam
        -- (`weapon_jam`, an Open77 clone of BaseStatusEffect.WeaponMalfunction: the held
        -- weapon reads not-ready and cannot fire, movement untouched) for durationMs
        -- (1000-15000), while the server refuses Gorilla Arms arming with
        -- `weapon_glitched` for the same deadline (hacking, purge, Dash, Ground Slam and
        -- ordinary melee stay usable). One per victim; same lifecycle as above.
        {id="weapon_glitch",kind="weapon_glitch",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=0,recoveryMs=6000,nonlethal=true,
            glitch={durationMs=8000}},
        -- A freeze longer than the native knockdown (about 3 s): the victim's client keeps
        -- the body locked through the movement lock for the remaining 3 s; hacking, purge,
        -- Dash and Ground Slam refuse `frozen` for the whole 6 s.
        {id="freeze_long",range=20,uploadMs=2000,staminaCost=20,cooldownMs=6000,damage=0,
            statusMs=750,recoveryMs=6000,nonlethal=true,
            effects={freezeMs=6000}},
    }},
    ice = {id="lab.self_ice",grades={{id="training",charges=1,rechargeMs=15000}}},
    purge = {id="lab.active_purge",grades={{id="training",staminaCost=15,cooldownMs=8000,
        allowSelf=true,allowAlly=true,range=10,cancelUploads=true,removeStatuses=true}}},
}
