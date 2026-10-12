-- Lifecycle and routing for the four Cordon HUD surfaces.
--
-- The resource owns four WebUI pages, split by update rate and by whether they
-- can take the mouse. Plan section 10 fixes the split; the reason it is a split
-- at all is the one the deathmatch HUD paid for first: driving a scoreboard at
-- 60 fps to get a responsive hitmarker is how a HUD starts costing frame
-- budget, so a page that repaints a standings table never shares a surface with
-- a page that has to answer a bullet inside one frame.
--
--   web/combat.html   60 fps, never focused, pointer-events off.
--                     Crosshair, hitmarker, directional damage, health, armor,
--                     ammo, spawn shield, the outside-the-cordon vignette and
--                     compass, revive progress.
--   web/match.html    12 fps, NEVER focused (see below).
--                     Staging panel, deploy panel, phase band, kill feed,
--                     notices, squad panel, inventory strip, result card.
--   web/tacmap.html   12 fps, focused while open, hidden otherwise.
--                     The block grid, closures, squad, pings; click to pin
--                     during deploy and to ping during the match.
--   web/wall.html     30 fps declared, driven at 20, HIDDEN unless there is
--                     boundary within the draw radius. The cordon edge itself,
--                     projected from world metres and stroked as SVG.
--
-- WHY THE MATCH SURFACE NEVER TAKES FOCUS, and it is a deliberate departure
-- from open77_deathmatch_hud, whose enrolment panel does:
--
--   A surface that owns the mouse owns it for everybody, including a player
--   standing in staging who would rather walk around. The deathmatch could
--   afford it because its panel is a modal the player opens; the Cordon staging
--   panel is a PERSISTENT readout for the whole staging phase. Making it modal
--   would take mouse-look away for two and a half minutes.
--
--   So this HUD has exactly one thing that takes focus -- the tac-map -- and
--   every other player action is a key. Joining the next match is a
--   RegisterKeyMapping toggle; joining a party is `/br.party <code>`, a chat
--   command the gamemode already owns (plan section 13). Nothing on this HUD
--   needs text entry, so nothing on it needs a caret.
--
-- THE FOURTH SURFACE, AND WHY IT IS A FOURTH SURFACE.
--
-- `docs/research/battle-royale-and-scale.md` (2026-09-02) is unambiguous about
-- the price of one: two in-world clients running this HUD fell to 0.2 Hz and
-- 3.0 Hz and then both processes disappeared, and the fix was to lower refresh
-- rates. The WebUI layer has no sub-rectangle -- `WebUiService::Draw` blits every
-- visible surface to the whole viewport -- so a page that draws twenty thin
-- lines still composites a full 1920x1080 texture. That measurement is the
-- reason `web/wall.html` is not simply switched on and left running.
--
-- It is a separate surface rather than a layer inside `web/combat.html` for one
-- reason that survives scrutiny: THE COMBAT SURFACE CANNOT BE HIDDEN. It carries
-- the reticle, the vitals and the vignette, so it is up for the whole match and
-- pays its composite every frame of it. The boundary is up for a MINORITY of a
-- match -- a player is within 150 m of the cordon edge for a small fraction of
-- the time, and for none of it during staging and the drop -- and a surface of
-- its own is the only way to charge for it only then. `SurfaceClient::SetVisible`
-- calls CEF's `WasHidden`, which stops the browser rendering outright, and
-- `WebUiService::Draw` skips a hidden surface before `AddImage`; so a hidden
-- surface costs its allocated texture and nothing per frame.
--
-- The second reason is smaller and still real: the combat surface is driven by
-- state pushes and damage events, and the wall is driven by the CAMERA. Putting
-- a camera-rate feed on the same page would make every hitmarker repaint pay for
-- the boundary and vice versa.
--
-- WHAT THAT COSTS WHEN IT IS UP: one more 1920x1080 composite at 20 Hz, against
-- match at 12, combat at 30 and tacmap at 6. If two-client testing regresses,
-- the lever is `fps` below and `FRAME_MS` in client/wall.lua, in that order --
-- and `Config.cordon.edge.wall.enabled = false` turns the layer off entirely
-- without a code change.
--
-- The resource stays separate from open77_cordon and stays on
-- reload_policy "reconnect": editing this HUD must never reset a live match.

local matchPage
local combatPage
local tacmapPage
local wallPage

CordonHud = {}
local latestState
local presented = false
local modal = false
local wardrobeOpen = false
local creatorPhases = { creator_requested=true, creator_open=true, awaiting_commit=true }

-- A creator preview puppet can be alive. Only the mode's readiness handshake
-- permits the HUD; native creator phases also suppress it on creator re-entry.
function CordonHud.canPresent()
    if wardrobeOpen then return false end
    local self = latestState and latestState.self
    if type(self) ~= "table" or type(self.state) ~= "string" or self.state == "lobby" then return false end
    if type(Open77.session) == "table" and type(Open77.session.characterBootstrap) == "function" then
        local ok, bootstrap = pcall(Open77.session.characterBootstrap)
        if ok and type(bootstrap) == "table" and creatorPhases[bootstrap.phase] then return false end
    end
    return true
end

function CordonHud.refreshPresentation(force)
    local allowed = CordonHud.canPresent()
    local nextModal = allowed and CordonTacmap.isOpen() == true
    if not force and allowed == presented and nextModal == modal then return end
    local becameReady = allowed and not presented
    presented, modal = allowed, nextModal
    if not allowed then CordonTacmap.setOpen(false) end
    if matchPage then
        if allowed and not modal then matchPage:show() else matchPage:hide() end
    end
    if combatPage then
        if allowed then combatPage:show() else combatPage:hide() end
    end
    if (not allowed or modal) and wallPage then wallPage:hide() end
    CordonCombat.push() -- also releases this resource's vanilla HUD claims
    if becameReady and latestState then CordonTacmap.onState(latestState) end
end

local function strings()
    return CordonHudStrings
end

AddEventHandler("open77:wardrobe:visibility", function(visible)
    wardrobeOpen = visible == true
    CordonHud.refreshPresentation()
end)

-- One fan-out for the one state push. client/match.lua owns the net event --
-- it is the surface that anchors the clocks -- and calls this, so the order in
-- which the three surfaces see a snapshot is stated here rather than emerging
-- from whichever file happened to register first.
--
-- Order matters exactly once: the match surface anchors `remainingMs` before
-- the others read it, so a phase clock and a closure clock cannot disagree by
-- a tick.
function CordonHud.route(state)
    if type(state) ~= "table" then return end
    latestState = state
    CordonHud.refreshPresentation()
    CordonCombat.onState(state)
    CordonTacmap.onState(state)
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
        visible = false,
    })
    if matchPage == nil then
        Open77.log.error("cordon match surface failed: " .. tostring(reason))
    else
        CordonMatch.attach(matchPage, strings())
    end

    combatPage, reason = WebUI.create({
        entry = "web/combat.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        -- 30, not 60. Measured 2026-09-02: three full-screen surfaces per
        -- client, one of them repainting sixty times a second, drove two
        -- in-world clients on a 12 GiB card to 0.2 Hz and then killed both.
        -- The WebUI layer has no sub-rectangle, so a hitmarker that only
        -- occupies the middle of the screen still costs a whole 1920x1080
        -- composite -- which makes its refresh rate the only lever there is.
        -- A hitmarker and a damage flash read the same at 30.
        fps = 30,
        -- Above the match surface: a hitmarker must never be occluded by a feed
        -- entry. Still below the platform's own 780 band.
        zIndex = 730,
        transparent = true,
        visible = false,
    })
    if combatPage == nil then
        Open77.log.error("cordon combat surface failed: " .. tostring(reason))
    else
        CordonCombat.attach(combatPage, strings())
    end

    tacmapPage, reason = WebUI.create({
        entry = "web/tacmap.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        -- The map is a map: it does not animate, and at six it still tracks a
        -- sprinting player. It is created hidden, but a hidden surface is not
        -- free, so this is the resting cost of carrying one.
        fps = 6,
        -- Above both, because while it is up it is the thing the player is
        -- looking at and clicking on. Created HIDDEN: a full-screen map that
        -- flashed on connect would be a bug the first time anybody saw it.
        zIndex = 740,
        transparent = true,
        visible = false,
    })
    if tacmapPage == nil then
        Open77.log.error("cordon tacmap surface failed: " .. tostring(reason))
    else
        CordonTacmap.attach(tacmapPage, strings())
    end

    wallPage, reason = WebUI.create({
        entry = "web/wall.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        -- DECLARED at 30, DRIVEN at 20 (client/wall.lua `FRAME_MS`). The
        -- declared rate is CEF's ceiling: setting it equal to the drive rate
        -- lets one paint swallow two updates whenever the two clocks drift, and
        -- the wall would judder for a frame every few seconds. The same
        -- relationship the combat surface has -- 30 declared, pushed at 25.
        fps = 30,
        -- THE BOTTOM OF THE FOUR. This is a wash over the scene, like the
        -- outside-the-cordon vignette, and nothing it paints may ever sit on top
        -- of a readout: match is 720, combat 730, tacmap 740.
        zIndex = 700,
        transparent = true,
        -- CREATED HIDDEN, and shown by client/wall.lua only while there is
        -- boundary within the draw radius. See the note above the page handles:
        -- this is the whole reason a fourth surface is affordable.
        visible = false,
    })
    if wallPage == nil then
        Open77.log.error("cordon wall surface failed: " .. tostring(reason))
    else
        CordonWall.attach(wallPage)
    end

    CordonHud.refreshPresentation(true)
    CreateThread(function()
        while matchPage ~= nil or combatPage ~= nil or tacmapPage ~= nil or wallPage ~= nil do
            Wait(100)
            CordonHud.refreshPresentation()
        end
    end)
    Open77.log.info("open77_cordon_hud ready")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == "open77_wardrobe_ui" then
        wardrobeOpen = false
        CordonHud.refreshPresentation()
    end
    if name ~= GetCurrentResourceName() then return end
    -- Tac-map first: it is the only surface that can be holding the mouse, and
    -- a resource that stopped while focused would leave the player without
    -- mouse-look and with nothing on screen to explain why.
    latestState, presented, modal = nil, false, false
    CordonTacmap.detach()
    CordonMatch.detach()
    CordonCombat.detach()
    CordonWall.detach()
    matchPage, combatPage, tacmapPage, wallPage = nil, nil, nil, nil
end)
