-- Public resource metadata, not a claim about any connected client's native state.
exports("capabilities", function()
    return {schemaVersion=1,side="server",profile="gorilla_arms",profiles={"gorilla_arms","double_jump","ground_slam","dash","cyberdeck","self_ice","active_purge"},support="declared_backend",
        implantProfiles={"gorilla_arms","double_jump","cyberdeck","self_ice","active_purge"},abilityProfiles={"ground_slam","dash"},
        logicalSlots={"arms","legs","operating_system","self_ice","purge"},
        hackingAuthority="Open77.hacking.capabilities",hackingNativeValidation="pending",
        dashAuthority="Open77.dash.capabilities",dashNativeValidation="pending",
        supportedBodyFamilies={"male","female"},compatibility={protocol="1.29",testedGameBuild="2.31",
            actualGameBuild="unknown",dlcVerification="unknown"},
        limits={gradesPerDefinition=32,damageMaximum=300,knockbackMetersMaximum=6,
            staminaCostMaximum=300,maxChargeMs=60000,temporaryLeaseMsMaximum=300000},
        features={durableImplants=true,temporaryLeases=true,normalPunch=true,chargedPunch=true,doubleJump=true,
            cosmetic=true,nonlethal=true,groundSlam=true,dash=true,airDash=true,sessionAbilities=true},
        groundSlam={entitlement="session",support="declared_backend",liveAcceptance="pending",
            nativeEligibility="blunt_weapon",clientReadiness="unknown"},clientReadiness="unknown"}
end)
