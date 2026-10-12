-- Open77 debug inspector overlay.
--
-- A transparent surface that never takes focus: the ray, the readout and the
-- outline all have to work while the player is walking around and looking at
-- things, so the moment this captured input it would defeat its own purpose.
--
-- The ray itself lives in the plugin (`Api::Inspector`) and runs on the game
-- thread at 10 Hz. This only reads the snapshot -- `Open77.inspector.target()`
-- is a plain read of the last result, never a probe, so polling it costs
-- nothing and cannot land a raycast on the wrong thread.

local overlay
local shown = false
local lastSignature

-- Matches the plugin's probe rate. Reading faster would only re-send values the
-- native side has not recomputed yet.
local POLL_MS = 100

-- Single resource-owned mappin used by the live developer probe below. It is
-- also removed by the native ownership ledger if this resource reloads.
local testBlip
local testBlips = {}

-- Authenticated server -> local privileged VM execution. The C++ binding
-- compiles text-only Lua in this resource's own state, under the ordinary
-- memory, instruction and frame-time quotas. It returns values as bounded text
-- and never exposes engine pointers or another resource's globals.
RegisterNetEvent("open77:debug:exec", function(requestId, code)
    local ok, result = Open77.debug.eval(tostring(code or ""), tostring(requestId or "exec"))
    print(string.format("[open77_debug] exec request=%s ok=%s result=%s",
        tostring(requestId), tostring(ok), tostring(result)))
    local sent, reason = TriggerServerEvent(
        "open77:debug:result", tostring(requestId or ""), ok == true, tostring(result or ""))
    if sent == false then
        print("[open77_debug] result delivery failed: " .. tostring(reason))
    end
end)

local function signatureOf(target)
    if not target or not target.valid then return "none" end
    return string.format("%d|%s|%.1f", target.engineId, target.class, target.distance)
end

local function publish(target)
    if not overlay then return end
    overlay:send("inspect:target", {
        valid = target ~= nil and target.valid or false,
        engineId = target and string.format("0x%X", target.engineId) or "",
        class = target and target.class or "",
        name = target and target.name or "",
        kind = target and target.kind or "",
        distance = target and target.distance or 0,
        position = target and target.position or { x = 0, y = 0, z = 0 }
    })
end

-- The surface itself is never shown or hidden; the page shows or hides its own
-- content instead.
--
-- That is not a style choice. Surface creation is asynchronous, so a `show()`
-- issued near `create` loses to the `visible` flag the request carried, and the
-- surface then never paints at all -- which is exactly how this overlay failed
-- the first three times. Keeping the surface permanently visible removes the
-- race entirely; a fully transparent page costs one composited quad.
local function setShown(value)
    if not overlay or shown == value then return end
    shown = value
    overlay:send(value and "inspect:show" or "inspect:hide", {})
    Open77.inspector.enable(value)
    if value then
        -- Forces the next poll to publish, so the panel is populated on opening
        -- rather than staying empty until the aim happens to move.
        lastSignature = nil
    end
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local errorMessage
    overlay, errorMessage = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 60,
        -- Transparent and never focused: the readout has to sit over a game the
        -- player is still driving.
        transparent = true,
        -- Visible from the request, and it stays that way. See `setShown`.
        visible = true
    })

    if not overlay then
        print("[open77_debug] surface unavailable: " .. tostring(errorMessage))
        return
    end
    CreateThread(function()
        while true do
            if shown then
                local target = Open77.inspector.target()
                -- Only on change: a 10 Hz stream of identical frames would burn
                -- the browser process for nothing.
                local signature = signatureOf(target)
                if signature ~= lastSignature then
                    lastSignature = signature
                    publish(target)
                end
            end
            Wait(POLL_MS)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- The outline belongs to this resource; it must not survive a reload.
    Open77.inspector.enable(false)
end)

-- Driven by the plugin, not by a console verb.
--
-- The Lua host deliberately exposes no `RegisterCommand` -- the first version of
-- this file called one and the resource failed to start, over and over, because
-- a failed start is retried. The pause menu has the same constraint and solves
-- it the same way: the native side emits, the resource listens.
AddEventHandler("open77:inspector:on", function()
    setShown(true)
end)

AddEventHandler("open77:inspector:off", function()
    setShown(false)
end)

AddEventHandler("open77:network:report", function()
    local status = Open77.network.status()
    if not status then
        print("[open77_debug] network status unavailable")
        return
    end
    print(string.format(
        "[open77_debug] network phase=%s endpoint=%s player=%s bucket=%s ping=%s error=%s",
        tostring(status.phase), tostring(status.endpoint), tostring(status.playerId),
        tostring(status.routingBucket), tostring(status.ping), tostring(status.error)))
end)

AddEventHandler("open77:network:reconnect-local", function()
    local accepted, reason = Open77.network.connect("127.0.0.1:11778", "Player")
    print(string.format(
        "[open77_debug] reconnect-local accepted=%s reason=%s",
        tostring(accepted), tostring(reason)))
end)

-- Live vanilla mappin laboratory. Examples from the developer console:
--
--   resource.emit open77:blips:probe create objective
--   resource.emit open77:blips:probe suite
--   resource.emit open77:blips:probe sprite vehicle
--   resource.emit open77:blips:probe state
--   resource.emit open77:blips:probe remove
--
-- Creation uses the active camera so the pin lands a few metres ahead of the
-- player without exposing any arbitrary engine object to the console.
AddEventHandler("open77:blips:probe", function(action, value)
    action = action or "state"

    if action == "clear" then
        local cleared, reason = Open77.blips.clear()
        testBlip = nil
        testBlips = {}
        print(string.format("[open77_debug] blip clear accepted=%s reason=%s",
            tostring(cleared), tostring(reason)))
        return
    end

    if action == "remove" then
        if testBlip then
            local removed, reason = Open77.blips.remove(testBlip)
            print(string.format("[open77_debug] blip remove id=%s accepted=%s reason=%s",
                tostring(testBlip), tostring(removed), tostring(reason)))
            testBlip = nil
        else
            print("[open77_debug] blip remove: no active test blip")
        end
        return
    end

    if action == "suite" then
        Open77.blips.clear()
        testBlip = nil
        testBlips = {}

        local view = Open77.camera.view()
        if not view then
            print("[open77_debug] blip suite failed: camera_unavailable")
            return
        end

        local samples = {
            {
                sprite = "ServicePointTechVariant",
                title = "Pôle emploi de Night City",
                description = "Consultez les offres disponibles, déposez votre candidature et rencontrez un conseiller."
            },
            {
                sprite = "VehicleVariant",
                title = "Concessionnaire automobile",
                description = "Vente, financement et livraison de véhicules neufs et d'occasion."
            },
            {
                sprite = "ServicePointMedsVariant",
                title = "Centre médical Kabuki",
                description = "Urgences, consultations et soins médicaux. Ouvert vingt-quatre heures sur vingt-quatre."
            },
            {
                sprite = "Zzz06_NCPDGigVariant",
                title = "Commissariat de Watson",
                description = "Accueil du public, dépôt de plainte et signalement des personnes recherchées."
            },
            {
                sprite = "ApartmentVariant",
                title = "Agence immobilière",
                description = "Location et vente d'appartements, commerces et entrepôts dans Night City."
            },
            {
                sprite = "ServicePointBarVariant",
                title = "Bar de l'Afterlife",
                description = "Boissons, restauration et rendez-vous professionnels. Tenue correcte exigée."
            }
        }
        local forwardDistance = 30.0
        local lateralSpacing = 14.0
        local rightX = view.forward.y
        local rightY = -view.forward.x

        for index, sample in ipairs(samples) do
            local lateral = (index - (#samples + 1) * 0.5) * lateralSpacing
            local position = {
                x = view.position.x + view.forward.x * forwardDistance + rightX * lateral,
                y = view.position.y + view.forward.y * forwardDistance + rightY * lateral,
                z = view.position.z
            }
            local id, reason = Open77.blips.create({
                position = position,
                sprite = sample.sprite,
                title = sample.title,
                description = sample.description,
                active = true,
                visibleThroughWalls = true
            })
            if id then
                testBlips[#testBlips + 1] = id
                testBlip = id
            end
            print(string.format(
                "[open77_debug] blip suite index=%d id=%s sprite=%s title=%s position=%.2f,%.2f,%.2f reason=%s",
                index, tostring(id), sample.sprite, sample.title,
                position.x, position.y, position.z, tostring(reason)))
        end
        return
    end

    if action == "sprites" then
        local sprites, reason = Open77.blips.sprites()
        print(string.format("[open77_debug] blip sprites count=%s reason=%s",
            tostring(sprites and #sprites), tostring(reason)))
        return
    end

    if action == "create" then
        if testBlip then Open77.blips.remove(testBlip) end
        local view = Open77.camera.view()
        if not view then
            print("[open77_debug] blip create failed: camera_unavailable")
            return
        end
        local distance = 12.0
        local position = {
            x = view.position.x + view.forward.x * distance,
            y = view.position.y + view.forward.y * distance,
            z = view.position.z + view.forward.z * distance
        }
        local reason
        testBlip, reason = Open77.blips.create({
            position = position,
            sprite = value or "objective",
            title = "Open77 test blip",
            description = "Runtime blip API probe.",
            active = true,
            visibleThroughWalls = true
        })
        print(string.format(
            "[open77_debug] blip create id=%s sprite=%s position=%.2f,%.2f,%.2f reason=%s",
            tostring(testBlip), tostring(value or "objective"),
            position.x, position.y, position.z, tostring(reason)))
        return
    end

    if action == "sprite" then
        if not testBlip then
            print("[open77_debug] blip sprite failed: no active test blip")
            return
        end
        local accepted, reason = Open77.blips.setSprite(testBlip, value or "vehicle")
        print(string.format("[open77_debug] blip sprite id=%s value=%s accepted=%s reason=%s",
            tostring(testBlip), tostring(value), tostring(accepted), tostring(reason)))
        return
    end

    if action == "state" or action == "list" then
        local owned, reason = Open77.blips.list()
        print(string.format("[open77_debug] blip list count=%s active=%s reason=%s",
            tostring(owned and #owned), tostring(testBlip), tostring(reason)))
        return
    end

    print("[open77_debug] unknown blip action: " .. tostring(action))
end)

-- Live door laboratory. The developer console emits this event because Lua
-- resources intentionally cannot register native console commands themselves.
-- With no action (or "state") this is strictly read-only.
AddEventHandler("open77:doors:probe", function(action)
    action = action or "state"
    local door, reason = Open77.doors.aimed()
    if not door then
        print(string.format("[open77_debug] door probe failed: %s", tostring(reason)))
        return
    end

    print(string.format(
        "[open77_debug] door id=%s class=%s name=%s distance=%.2f open=%s locked=%s sealed=%s busy=%s autoClose=%s",
        tostring(door.id), tostring(door.class), tostring(door.name),
        tonumber(door.distance) or 0, tostring(door.open), tostring(door.locked),
        tostring(door.sealed), tostring(door.busy), tostring(door.automaticClose)))

    if action == "state" then return end

    local accepted, commandReason
    if action == "open" then
        accepted, commandReason = Open77.doors.open(door.id)
    elseif action == "close" then
        accepted, commandReason = Open77.doors.close(door.id)
    elseif action == "lock" then
        accepted, commandReason = Open77.doors.lock(door.id)
    elseif action == "unlock" then
        accepted, commandReason = Open77.doors.unlock(door.id)
    elseif action == "seal" then
        accepted, commandReason = Open77.doors.seal(door.id)
    elseif action == "unseal" then
        accepted, commandReason = Open77.doors.unseal(door.id)
    elseif action == "reset" then
        accepted, commandReason = Open77.doors.reset(door.id)
    elseif action == "deny" then
        accepted, commandReason = Open77.doors.setInteractionAllowed(door.id, false)
    elseif action == "allow" then
        accepted, commandReason = Open77.doors.clearInteractionPolicy(door.id)
    elseif action == "grant" then
        accepted, commandReason = Open77.doors.grantKey(door.id, "0x0000000000000001")
    elseif action == "revoke" then
        accepted, commandReason = Open77.doors.revokeKey(door.id, "0x0000000000000001")
    elseif action == "keys" then
        local holders, holdersReason = Open77.doors.holders(door.id)
        if not holders then
            print("[open77_debug] door keys failed: " .. tostring(holdersReason))
            return
        end
        local hasPlayer = Open77.doors.hasKey(door.id, "0x0000000000000001")
        print(string.format("[open77_debug] door keys count=%d player=%s holders=%s",
            #holders, tostring(hasPlayer), table.concat(holders, ",")))
        return
    else
        print("[open77_debug] unknown door action: " .. tostring(action))
        return
    end
    print(string.format("[open77_debug] door action=%s accepted=%s reason=%s",
        action, tostring(accepted), tostring(commandReason)))
end)
