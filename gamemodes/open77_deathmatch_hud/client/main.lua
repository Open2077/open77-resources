-- Lifecycle for the two deathmatch HUD surfaces.
--
-- The resource owns two WebUI pages, split by update rate exactly as the
-- Kabuki Arena plan requires:
--
--   web/combat.html   60 fps, never focused, pointer-events off.
--                     Crosshair, hitmarker, directional damage, health, armor,
--                     ammo, spawn-protection ring, kill callouts.
--   web/match.html    low fps, focusable for the enrolment panel.
--                     Timer, phase, K/D, instance identity, kill feed,
--                     notices, standings, result banner, death screen.
--
-- Driving a scoreboard at 60 fps to get a responsive hitmarker is how a HUD
-- starts costing frame budget, so the two never share a page.
--
-- The resource stays separate from open77_deathmatch and stays on
-- reload_policy "reconnect": editing this HUD must never reset a live match.

local combatPage
local matchPage

local function strings()
    return DeathmatchHudStrings
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local reason
    matchPage, reason = WebUI.create({
        entry = "web/match.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 12,
        zIndex = 720,
        transparent = true,
        visible = true,
    })
    if matchPage == nil then
        Open77.log.error("deathmatch match surface failed: " .. tostring(reason))
    else
        DeathmatchMatch.attach(matchPage, strings())
    end

    combatPage, reason = WebUI.create({
        entry = "web/combat.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 60,
        -- Above the match surface: a hitmarker must never be occluded by a
        -- feed entry. Still below the platform's own 780 band.
        zIndex = 730,
        transparent = true,
        visible = true,
    })
    if combatPage == nil then
        Open77.log.error("deathmatch combat surface failed: " .. tostring(reason))
    else
        DeathmatchCombat.attach(combatPage, strings())
    end

    Open77.log.info("open77_deathmatch_hud ready")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    DeathmatchMatch.detach()
    DeathmatchCombat.detach()
    matchPage, combatPage = nil, nil
end)
