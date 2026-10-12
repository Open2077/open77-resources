-- Appearance client. Two copies of one thing exist: the server's record of this
-- player's appearance (family and canonical options) and what the game shows
-- on the local player. This resource keeps the game equal to the record and
-- publishes what the game shows, for observers to spawn their proxy from.
--
-- The record is the server's word and is kept across world entries; it changes
-- only when the server says so (bootstrap, restore, an accepted edit, a
-- character change). Everything else here is read from the game when needed:
-- whether this world entry's player reset has completed, whether the player is
-- alive in the world, what body family it has, which options it wears.

local record = nil     -- { key, revision, family, snapshot }: the server's appearance for this player
local world = false    -- this world entry is the pristine gameplay world (the shell's bootstrap was ready when it attached)
local reset = false    -- this world entry's pristine player reset has completed (the game's own event)
local announced = false -- gameplay-ready has been sent for this world entry
local settledSnapshot = nil -- frozen confirmed options; vanilla retires its live catalogue on close
local applying = false -- the native mirror is putting the record on the player
local failed = nil     -- the record revision the native could not put on this player, this entry
local reopen = nil     -- an editor to reopen once the body family it needs is loaded
local edit = nil       -- { nonce, revision, key, family }: the server-authorized edit session
local bodyPending = true
local bodySequence = 0
local creation = nil   -- { nonce, key, heartbeatAt }: the character creator is open
local readinessWaitTicks = 0
local previewOwner = nil
local previewRestoring = false
local presentationPlayer = nil
local committedEquipment = nil
local committedWardrobe = nil
local CLOTHING = { "Head", "Face", "InnerChest", "OuterChest", "Legs", "Feet", "Outfit" }
local EQUIPMENT = { "Head", "Face", "InnerChest", "OuterChest", "Legs", "Feet", "Outfit", "UnderwearTop", "UnderwearBottom" }

-- Equipment writes enqueue attachment work. A successful write or a quiet
-- timer is not proof that preview garments have left the player. Compare both
-- authoritative registries and each observed visual projection instead. Native
-- wardrobe overrides can keep the underlying equipment attachment's ItemID.
local function presentationRestored()
    if type(committedEquipment) ~= "table" or type(committedWardrobe) ~= "table" then return false end
    local registry = Open77.equipment.registry()
    if type(registry) ~= "table" then return false end
    for _, slot in ipairs(EQUIPMENT) do
        if (registry[slot] or false) ~= (committedEquipment[slot] or false) then return false end
    end
    local active = Open77.wardrobe.active()
    if active == nil then return false end -- unreadable, unlike false = off
    local expectedActive = tonumber(committedWardrobe.active)
    if expectedActive and expectedActive < 0 then expectedActive = nil end
    if active == false then
        if expectedActive ~= nil then return false end
    elseif active ~= expectedActive then return false end
    local outfits = committedWardrobe.outfits or {}
    local shown = expectedActive and (outfits[expectedActive] or outfits[tostring(expectedActive)]) or {}
    shown = shown or {}
    for _, slot in ipairs(CLOTHING) do
        local expected = shown[slot]
        if expected == nil then expected = committedEquipment[slot] end
        -- Nonvisual templates stay in the equipment registry but spawn no garment.
        local info = expected and Open77.equipment.info(expected)
        if info and info.nonvisual then expected = false end
        if Open77.equipment.visualSettled(slot, expected or false) ~= true then return false end
    end
    return true
end

-- The creator's liveness beat: its absence is what tells the server a creation
-- was abandoned. It grants no time, there is no time to grant.
local CREATION_HEARTBEAT_SECONDS = 5.0

local function notify(kind, text)
    print(("[open77_appearance] %s"):format(tostring(text)))
    TriggerEvent("chat:addMessage", {
        type = kind == "error" and "error" or "system",
        author = "APPEARANCE",
        text = tostring(text),
        color = kind == "error" and { 255, 76, 92 } or { 0, 229, 255 }
    })
end

-- `apply` opens a publication barrier in the native layer; it closes here once
-- the change is accepted or the previous appearance is back on the player.
local function finishMutation()
    local ok, reason = Open77.appearance.finishCommit()
    if not ok then print("[open77_appearance] finishCommit: " .. tostring(reason)) end
end

-- The body family the game currently shows on the player.
local function family()
    local body = Open77.appearance.captureBody()
    return type(body) == "table" and body.family or nil
end

-- Whether the player wears the record's options: every option the record names
-- has that value on the player.
local function wears(snapshot)
    local current = settledSnapshot or Open77.appearance.capture()
    if type(current) ~= "table" or type(current.options) ~= "table" then return false end
    local values = {}
    for _, option in ipairs(current.options) do
        values[tostring(option.part) .. ":" .. string.lower(tostring(option.name))] = option.value
    end
    for _, option in ipairs(snapshot.options) do
        if values[tostring(option.part) .. ":" .. string.lower(tostring(option.name))] ~= option.value then
            return false
        end
    end
    return true
end

-- The editor's metadata (editable/active/censored) stays local; the record
-- carries the catalogue identity and the selected value.
local function networkSnapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.options) ~= "table" then
        return nil, "invalid_snapshot"
    end
    local compact = {
        schemaVersion = snapshot.schemaVersion,
        gameBuild = snapshot.gameBuild,
        catalogDigest = snapshot.catalogDigest,
        gender = snapshot.gender,
        options = {},
    }
    for index, option in ipairs(snapshot.options) do
        if type(option) ~= "table" then return nil, "invalid_option" end
        compact.options[index] = {
            part = option.part,
            name = option.name,
            value = option.value,
            choices = option.choices,
        }
    end
    return compact
end

-- What the game shows, as the server records it: family and customization
-- keys. Observers spawn their proxy of this player from it.
local function publishBody()
    bodyPending = true
    if failed ~= nil or previewOwner then return false end
    if previewRestoring then
        if not presentationRestored() then return false end
        previewRestoring = false
    end
    if not announced or not world or not reset or record == nil or applying or edit ~= nil or reopen ~= nil then return false end
    if record.snapshot ~= nil and not wears(record.snapshot) then return false end
    local body, reason = Open77.appearance.captureBody()
    if type(body) ~= "table" then
        print("[open77_appearance] body capture failed: " .. tostring(reason))
        return false
    end
    local logical = networkSnapshot(settledSnapshot or Open77.appearance.capture())
    bodySequence = bodySequence + 1
    local sent, sendReason = TriggerServerEvent("open77:appearance:body", body,
        record.key or "default", record.revision or 0, logical, bodySequence)
    if not sent then print("[open77_appearance] body not sent: " .. tostring(sendReason)) end
    return sent
end

-- The player is in the world wearing its record: the platform may act on them.
local function announce()
    if announced or failed ~= nil then return end
    local state = Open77.character.state()
    if type(state) ~= "table" or state.alive ~= true then return end
    local sent, reason = TriggerServerEvent("open77:session:gameplayReady")
    if not sent then
        print("[open77_appearance] gameplay-ready not sent: " .. tostring(reason))
        return
    end
    announced = true
    finishMutation()
    print(("[open77_appearance] gameplay-ready revision=%s"):format(tostring(record and record.revision)))
end

local function requestOpen(mode, gender)
    if previewOwner or previewRestoring or edit ~= nil or Open77.appearance.isOpen() then return false, "appearance_busy" end
    mode = string.lower(tostring(mode or "ripperdoc"))
    if mode ~= "ripperdoc" and mode ~= "hairdresser" then return false, "invalid_mode" end
    gender = string.lower(tostring(gender or ""))
    if gender ~= "" and gender ~= "keep" and gender ~= "male" and gender ~= "female" then
        return false, "invalid_gender"
    end
    if gender ~= "" and gender ~= "keep" and mode ~= "ripperdoc" then
        return false, "gender_requires_ripperdoc"
    end
    return TriggerServerEvent("open77:appearance:requestOpen", mode, gender)
end

-- Make the game equal to the record, then publish. Runs whenever either side
-- changed; every step is idempotent and reads the game before acting.
local function reconcile()
    -- A watchdog can leave the native mirror open after its API state clears.
    -- Do not retry, publish, or signal gameplay until a validated confirmation
    -- or a fresh world entry establishes recovery.
    if failed ~= nil or not world or not reset or record == nil or edit ~= nil or applying then return end
    local current = family()
    -- An edit that reloaded the other family is not the record until accepted.
    if reopen == nil and record.family ~= nil and current ~= nil and record.family ~= current then
        -- Only a reload shows the other body family; the world entry that follows
        -- runs this again on the new player.
        local switched, reason = Open77.appearance.switchBodyFamily(record.family, false)
        if switched then
            notify("system", "Reloading the " .. record.family .. " player body.")
            return
        end
        if tostring(reason) ~= "body_family_already_active" then
            TriggerServerEvent("open77:appearance:bodyFamilyRejected", record.family)
            record.family = current
            notify("error", "Body type change unavailable: " .. tostring(reason))
        end
    end
    if record.snapshot ~= nil and failed ~= record.revision and not wears(record.snapshot) then
        local ok, reason = Open77.appearance.apply(record.snapshot)
        if ok then
            applying = true -- confirmed or restore_failed continues
            return
        end
        if reason == "player_unavailable" then
            -- RequestAppearanceRestore returns this before admitting a native
            -- mirror request (its local-player gender read failed). A scene
            -- can attach while the previous menu puppet's reset still reads
            -- complete. Wait for the actual new puppet's reset event instead
            -- of latching a failure for a mirror that never started.
            reset = false
            return
        end
        failed = record.revision
        finishMutation()
        notify("error", "Stored appearance could not be restored: " .. tostring(reason) .. ". Reconnect to retry.")
        return
    end
    if reopen ~= nil then
        local gender = reopen
        reopen = nil
        local sent = TriggerServerEvent("open77:appearance:requestOpen", "ripperdoc", gender)
        if sent then notify("system", "Body type loaded. Reopening the appearance editor.") end
    end
    announce()
    publishBody()
end

-- -- the world -----------------------------------------------------------------

-- Why the body family was reloaded, if it was: an edit that needs the other
-- family reopens its editor once the new player wears the record.
local function takeTransition()
    local result = Open77.appearance.takeBodyFamilyTransition()
    if type(result) ~= "string" or result == "" then return end
    local action, gender = result:match("^([^:]+):(.+)$")
    if action == "error" then
        notify("error", "Body type change failed: " .. tostring(gender))
    elseif action == "edit" and (gender == "male" or gender == "female") then
        reopen = gender
    end
end

-- The shell loads the pristine gameplay world only once its character bootstrap
-- is ready; a world that attaches at any earlier phase is the menu's, and its
-- puppet is not the player.
local function bootstrapReady()
    local ok, bootstrap = pcall(Open77.session.characterBootstrap)
    return ok and type(bootstrap) == "table" and bootstrap.phase == "ready", bootstrap
end

local function enterWorld()
    local ready, bootstrap = bootstrapReady()
    -- A synthetic replay cannot prove that a failed or running native mirror
    -- has gone away. Only a new native reset cycle can clear that barrier.
    if ready and bootstrap.playerReset == "complete" and (failed ~= nil or applying) then return end
    previewOwner, previewRestoring = nil, false
    committedEquipment, committedWardrobe, presentationPlayer = nil, nil, nil
    world = ready
    readinessWaitTicks = 0
    settledSnapshot = nil
    -- The host also replays worldReady after a resource hot swap. That does
    -- not reattach the native body or produce another playerReset event.
    -- Read its actual reset state; a real body attachment clears it natively.
    reset = ready and bootstrap.playerReset == "complete"
    bodyPending = true
    announced = false
    applying = false
    failed = nil
    takeTransition()
    -- The server answers with the family to load (bootstrapReady), the record
    -- (restore), or a character to create (createRequired).
    local sent, reason = TriggerServerEvent("open77:appearance:ready")
    if not sent then print("[open77_appearance] ready not sent: " .. tostring(reason)) end
end

AddEventHandler("open77:worldReady", enterWorld)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    enterWorld()
    -- A restart while the player is already in the world: the reset has run.
    local ready, bootstrap = bootstrapReady()
    reset = ready and bootstrap.playerReset == "complete"
    reconcile()
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        if edit then TriggerServerEvent("open77:appearance:abort", edit.nonce, "resource_stopped") end
        edit = nil
        finishMutation()
    end
end)

AddEventHandler("open77:playerReset:complete", function()
    reset = true
    reconcile()
end)

AddEventHandler("open77:playerReset:failed", function()
    reset = false
    notify("error", "[OP77-INIT-001] Character initialization failed. Server interfaces are still blocked for safety. " ..
        "Reconnect to retry. Before closing the game, export Diagnostics; the developer console has the pending equipment details.")
end)

-- The feet variant of the body follows the footwear: republish when a garment
-- is on the body, which is after the registry write, when the game attaches it.
AddEventHandler("open77:equipment:attached", function()
    if announced then publishBody() end
end)

-- -- the record ----------------------------------------------------------------

RegisterNetEvent("open77:appearance:bootstrapFailed", function(reason)
    Open77.session.failCharacterBootstrap(tostring(reason or "database_error"))
    notify("error", "Character could not be loaded: " .. tostring(reason))
end)


RegisterNetEvent("open77:appearance:bootstrapReady", function(family, characterKey)
    family = string.lower(tostring(family or ""))
    if family ~= "female" and family ~= "male" then
        Open77.session.failCharacterBootstrap("invalid_body_family")
        return
    end
    record = record or {}
    record.family = family
    record.key = tostring(characterKey or "default")
    local ok, reason = Open77.session.resolveCharacterBootstrap(family)
    if not ok then notify("error", "Character bootstrap failed: " .. tostring(reason)) end
    reconcile()
end)

RegisterNetEvent("open77:appearance:restore", function(snapshot, revision, characterKey)
    if type(snapshot) ~= "table" then return end
    record = record or {}
    record.key = tostring(characterKey or "default")
    record.revision = tonumber(revision) or 0
    record.snapshot = snapshot
    reconcile()
end)

RegisterNetEvent("open77:appearance:characterChanged", function(characterKey, snapshot, revision, family)
    record = record or {}
    record.family = family
    announced = false
    record.key = tostring(characterKey or "default")
    record.revision = tonumber(revision) or 0
    record.snapshot = type(snapshot) == "table" and snapshot or nil
    reconcile()
end)

-- The server changed this player's body family (a session command).
RegisterNetEvent("open77:appearance:switchBodyFamily", function(target)
    target = string.lower(tostring(target or ""))
    if target ~= "male" and target ~= "female" then return end
    record = record or {}
    record.family = target
    reconcile()
end)

-- A body, or false while the player has none in the world (its own is being
-- reloaded): the proxy goes and comes back with the body that follows.
RegisterNetEvent("open77:appearance:body", function(player, body)
    player = tonumber(player)
    if player == nil or (type(body) ~= "table" and body ~= false) then return end
    Open77.puppets.setBody(player, body)
end)

RegisterNetEvent("open77:appearance:bodyAck", function(key, revision, sequence)
    if record and key == record.key and revision == (record.revision or 0) and sequence == bodySequence then
        bodyPending = false
    end
end)

-- Retain work across transient engine unavailability or a refused send. A
-- successful send alone is not evidence that the server accepted the record.
CreateThread(function()
    while true do
        Wait(1000)
        -- A hot-reloaded resource or a missed local event must not lose an
        -- already confirmed native reset. This never invents a completion.
        if world and not reset then
            local ready, bootstrap = bootstrapReady()
            if ready and bootstrap.playerReset == "complete" then reset = true end
        end
        if world and reset and record and edit == nil and not applying then
            if not announced then reconcile()
            elseif bodyPending then publishBody() end
        end
        if world and not announced and edit == nil and creation == nil then
            readinessWaitTicks = readinessWaitTicks + 1
            if readinessWaitTicks % 15 == 0 then
                local ready, bootstrap = bootstrapReady()
                local stage = not reset and "player_reset" or not record and "appearance_record"
                    or failed ~= nil and "appearance_failed" or applying and "appearance_applying"
                    or "alive_or_gameplay_announcement"
                print(("[OP77-INIT-002] Gameplay readiness waiting: stage=%s reset=%s bootstrap=%s elapsedSeconds=%d. " ..
                    "Run script.state and webui.status; export Diagnostics while connected.")
                    :format(stage, tostring(bootstrap and bootstrap.playerReset),
                        tostring(bootstrap and bootstrap.phase), readinessWaitTicks))
                TriggerServerEvent("open77:appearance:readinessDiagnostic", stage,
                    tostring(bootstrap and bootstrap.playerReset), tostring(bootstrap and bootstrap.phase),
                    math.min(readinessWaitTicks, 86400))
            end
        else
            readinessWaitTicks = 0
        end
    end
end)

-- -- editing -------------------------------------------------------------------

RegisterNetEvent("open77:appearance:beginEdit", function(nonce, revision, mode, gender, characterKey, snapshot)
    if previewOwner or previewRestoring or edit ~= nil or Open77.appearance.isOpen() then
        TriggerServerEvent("open77:appearance:abort", tostring(nonce or ""), "client_busy")
        return
    end
    record = record or {}
    record.key = tostring(characterKey or "default")
    record.revision = tonumber(revision) or 0
    if type(snapshot) == "table" then record.snapshot = snapshot end
    gender = (gender == "male" or gender == "female") and gender or nil
    edit = { nonce = tostring(nonce or ""), revision = record.revision, key = record.key,
        family = gender, heartbeatAt = -math.huge }
    if gender ~= nil and gender ~= family() then
        -- The editor for the other family opens on that family's player.
        local switched, reason = Open77.appearance.switchBodyFamily(gender, true)
        if switched then
            TriggerServerEvent("open77:appearance:abort", edit.nonce, "body_family_transition")
            edit = nil
            notify("system", "Switching body type. The editor will reopen automatically.")
            return
        end
        if tostring(reason) ~= "body_family_already_active" then
            TriggerServerEvent("open77:appearance:abort", edit.nonce, "body_family_transition_failed")
            edit = nil
            return notify("error", "Body type change unavailable: " .. tostring(reason))
        end
    end
    local opened, reason = Open77.appearance.open({ mode = mode, gender = gender })
    if not opened then
        TriggerServerEvent("open77:appearance:abort", edit.nonce, "open_failed")
        edit = nil
        notify("error", "Appearance editor unavailable: " .. tostring(reason))
    end
end)

-- The mirror closed on a confirmation: the player's edit, or the record put back
-- on the player.
AddEventHandler("open77:appearance:confirmed", function()
    local confirmed, captureError = Open77.appearance.capture()
    if type(confirmed) == "table" then settledSnapshot = confirmed end
    if edit == nil then
        if (applying or failed ~= nil) and record and record.snapshot and type(confirmed) == "table" then
            -- Creation and the mirror expose different contextual entries. The
            -- mirror can retire a neutral (zero) entry after applying it; it
            -- also adds entries which were not in the creation catalogue.
            -- Verify every observable stored selection before retaining the
            -- applied canonical record for publication after catalogue teardown.
            local values, matched, valid = {}, 0, true
            for _, option in ipairs(confirmed.options or {}) do
                values[tostring(option.part) .. ":" .. string.lower(tostring(option.name))] = option.value
            end
            for _, option in ipairs(record.snapshot.options or {}) do
                local key = tostring(option.part) .. ":" .. string.lower(tostring(option.name))
                local actual = values[key]
                if actual == option.value then matched = matched + 1
                elseif actual ~= nil or option.value ~= 0 then valid = false end
            end
            -- Match the native mirror's minimum catalogue overlap, while being
            -- stricter about absent non-neutral values and all differing values.
            if valid and matched * 4 >= #record.snapshot.options * 3 then
                settledSnapshot = record.snapshot
                failed = nil
            else
                failed = record.revision
                notify("error", "Restored appearance does not match its stored options.")
            end
        elseif (applying or failed ~= nil) and record then
            failed = record.revision
            notify("error", "Restored appearance could not be captured: " .. tostring(captureError))
        end
        applying = false
        finishMutation()
        reconcile()
        return
    end
    local snapshot, reason = confirmed, captureError
    local payload, payloadReason = networkSnapshot(snapshot)
    if not payload then
        TriggerServerEvent("open77:appearance:abort", edit.nonce, "capture_failed")
        edit = nil
        finishMutation()
        notify("error", "Appearance capture failed: " .. tostring(payloadReason or reason))
        reconcile()
        return
    end
    local sent, sendReason = TriggerServerEvent("open77:appearance:commit", edit.nonce, edit.revision, payload)
    if not sent then
        edit = nil
        finishMutation()
        notify("error", "Appearance was not saved: " .. tostring(sendReason))
        reconcile()
    end
end)

AddEventHandler("open77:appearance:cancelled", function()
    if edit ~= nil then TriggerServerEvent("open77:appearance:abort", edit.nonce, "cancelled") end
    edit = nil
    finishMutation()
    reconcile() -- the record's family and options come back on the player
end)

-- The native mirror gave up on the record for this player.
AddEventHandler("open77:appearance:restore_failed", function()
    applying = false
    if record ~= nil then failed = record.revision end
    finishMutation()
    notify("error", "Stored appearance could not be restored by the customization mirror. Reconnect to retry.")
    reconcile()
end)

RegisterNetEvent("open77:appearance:accepted", function(nonce, revision, snapshot)
    if edit == nil or tostring(nonce) ~= edit.nonce then return end
    record.revision = tonumber(revision) or record.revision
    if type(snapshot) == "table" then record.snapshot = snapshot end
    if edit.family ~= nil then record.family = edit.family end
    edit = nil
    finishMutation()
    notify("system", "Appearance saved.")
    reconcile()
end)

RegisterNetEvent("open77:appearance:rejected", function(nonce, reason, revision, snapshot)
    if edit ~= nil and tostring(nonce) ~= edit.nonce then return end
    if record ~= nil then
        record.revision = tonumber(revision) or record.revision
        if type(snapshot) == "table" then record.snapshot = snapshot end
    end
    edit = nil
    finishMutation()
    notify("error", "Appearance was not saved: " .. tostring(reason))
    reconcile()
end)

-- -- character creation --------------------------------------------------------

RegisterNetEvent("open77:appearance:createRequired", function(nonce, characterKey)
    nonce = tostring(nonce or "")
    if nonce == "" then
        Open77.session.failCharacterBootstrap("invalid_creation_session")
        return
    end
    -- Resource start and the menu-world attachment can both announce ready.
    -- The server intentionally resends its existing creation lease. Reopening
    -- after the first request has left SingleplayerMenu fails on older clients
    -- with main_menu_not_ready and abandons a perfectly live vanilla editor.
    if creation ~= nil and creation.nonce == nonce then return end
    local _, bootstrap = bootstrapReady()
    if type(bootstrap) == "table" and bootstrap.phase == "ready" then
        return -- a delayed database reply must not reopen a committed character
    end
    if creation ~= nil and creation.nonce ~= nonce then
        TriggerServerEvent("open77:appearance:createAbort", creation.nonce)
    end
    creation = { nonce = nonce, key = tostring(characterKey or "default"), heartbeatAt = 0 }
    if type(bootstrap) == "table" and (bootstrap.phase == "creator_requested" or
        bootstrap.phase == "creator_open" or bootstrap.phase == "awaiting_commit") then
        return -- renewed lease: keep the current editor and its customization
    end
    local opened, reason = Open77.session.requestCharacterCreator()
    if not opened then
        TriggerServerEvent("open77:appearance:createAbort", nonce)
        creation = nil
        Open77.session.failCharacterBootstrap(reason or "character_creator_unavailable")
        notify("error", "Character creator unavailable: " .. tostring(reason))
    end
end)

local function abandonCreation(reason)
    TriggerServerEvent("open77:appearance:createAbort", creation.nonce)
    creation = nil
    finishMutation()
    Open77.session.failCharacterBootstrap(reason)
end

RegisterNetEvent("open77:appearance:createAccepted", function(nonce, family, revision, snapshot, characterKey)
    if creation == nil or tostring(nonce or "") ~= creation.nonce then return end
    creation = nil
    record = {
        key = tostring(characterKey or "default"),
        revision = tonumber(revision) or 1,
        family = tostring(family or ""),
        snapshot = type(snapshot) == "table" and snapshot or nil,
    }
    local resolved, reason = Open77.session.resolveCharacterBootstrap(record.family)
    if not resolved then
        Open77.session.failCharacterBootstrap(reason or "character_bootstrap_failed")
        return notify("error", "Character creation failed: " .. tostring(reason))
    end
    notify("system", "Character created. Entering Night City.")
end)

RegisterNetEvent("open77:appearance:createRejected", function(nonce, reason)
    if creation == nil or tostring(nonce or "") ~= creation.nonce then return end
    creation = nil
    finishMutation()
    Open77.session.failCharacterBootstrap(reason or "character_creation_rejected")
    notify("error", "Character was not created: " .. tostring(reason))
end)

-- The creator is a modal the native layer reports through a mailbox; while one
-- is open this reads it and beats.
CreateThread(function()
    while true do
        Wait(200)
        if edit ~= nil and not applying and Open77.appearance.isOpen() then
            local now = Open77.time.monotonic()
            if now - edit.heartbeatAt >= 5.0 then
                edit.heartbeatAt = now
                TriggerServerEvent("open77:appearance:editing", edit.nonce, edit.key, edit.revision)
            end
        end
        if creation ~= nil then
            local now = Open77.time.monotonic()
            if now - creation.heartbeatAt >= CREATION_HEARTBEAT_SECONDS then
                creation.heartbeatAt = now
                TriggerServerEvent("open77:appearance:creating", creation.nonce)
            end
            local result = Open77.session.takeCharacterCreatorResult()
            if type(result) == "string" and result ~= "" then
                local action, family = result:match("^([^:]+):(.+)$")
                if result == "cancelled" then
                    abandonCreation("character_creation_cancelled")
                elseif action == "confirmed" and (family == "female" or family == "male") then
                    local snapshot, captureError = Open77.appearance.capture()
                    local payload, payloadError = networkSnapshot(snapshot)
                    if not payload then
                        abandonCreation(payloadError or captureError or "character_capture_failed")
                    else
                        local sent, sendError = TriggerServerEvent(
                            "open77:appearance:createCommit", creation.nonce, family, payload)
                        if not sent then abandonCreation(sendError or "character_creation_network_failure") end
                    end
                else
                    abandonCreation("invalid_creator_result")
                end
            end
        end
    end
end)

-- -- the server-side relay (B14) ------------------------------------------------
--
-- `Open77.appearance.capture/apply` on the server address this handler. The
-- relay does not talk to the native layer behind this resource's back: an
-- `apply` becomes a new *record*, which is the server's word about what this
-- player wears, and the ordinary `reconcile()` above puts it on the body. That
-- is the same road `open77:appearance:restore` takes at world entry, so a
-- relayed face survives a death, a bucket change and a reload exactly like a
-- stored one, instead of being quietly undone by the next reconcile.
--
-- What it does NOT do is change the body family. A different family is a player
-- *reload*, not an appearance change, and a caller that asked to restore a face
-- has not asked for that; a snapshot whose gender disagrees with the body on the
-- player is refused by name instead.
local RELAY_SETTLE_SECONDS = 8.0

-- One reason why this player cannot take a relayed appearance right now, or nil.
local function relayUnavailable()
    if previewOwner or previewRestoring then return "appearance_busy" end
    if edit ~= nil or reopen ~= nil or creation ~= nil then return "appearance_busy" end
    if Open77.appearance.isOpen() then return "appearance_busy" end
    if not world or not reset then return "player_not_ready" end
    if record == nil then return "appearance_record_unavailable" end
    if failed ~= nil then return "appearance_restore_failed" end
    return nil
end

RegisterNetEvent("open77:appearance:relayRequest", function(request, operation, payload)
    if type(request) ~= "string" or #request == 0 or #request > 96 then return end
    if operation ~= "capture" and operation ~= "apply" then return end
    local function answer(ok, reason, result)
        TriggerServerEvent("open77:appearance:relayResult", request, operation, ok, reason or "", result)
    end
    local unavailable = relayUnavailable()
    if unavailable then return answer(false, unavailable) end

    local current, captureReason = Open77.appearance.capture()
    if type(current) ~= "table" then return answer(false, tostring(captureReason or "capture_failed")) end

    if operation == "capture" then
        local compact, compactReason = networkSnapshot(settledSnapshot or current)
        if not compact then return answer(false, tostring(compactReason)) end
        local body = Open77.appearance.captureBody()
        return answer(true, "", {
            snapshot = compact,
            family = type(body) == "table" and body.family or nil,
            revision = record.revision or 0,
            characterKey = record.key or "default",
        })
    end

    local compact, compactReason = networkSnapshot(payload)
    if not compact then return answer(false, tostring(compactReason)) end
    if compact.gender ~= current.gender then return answer(false, "body_family_mismatch") end

    -- A new revision both supersedes an in-flight relay and clears the failure
    -- latch, which is keyed by revision.
    local target = (tonumber(record.revision) or 0) + 1
    record.revision = target
    record.snapshot = compact
    settledSnapshot = nil -- the confirmed set is about to change
    reconcile()
    CreateThread(function()
        local deadline = Open77.time.monotonic() + RELAY_SETTLE_SECONDS
        while Open77.time.monotonic() < deadline do
            if record == nil or record.revision ~= target then
                return answer(false, "appearance_superseded")
            end
            if failed == target then return answer(false, "appearance_restore_failed") end
            if not applying and wears(compact) then
                return answer(true, "", { revision = target })
            end
            Wait(100)
        end
        answer(false, "apply_timeout")
    end)
end)

exports("open", requestOpen)
exports("capture", function() return Open77.appearance.capture() end)
exports("isOpen", function() return Open77.appearance.isOpen() end)
-- Wardrobe restoration must follow the customization mirror's confirmation.
-- This is only the body-mutation barrier: checking presentationRestored here
-- would deadlock against the wardrobe state this caller still needs to apply.
exports("wardrobeMutationReady", function()
    return announced and world and reset and record ~= nil and not applying
        and edit == nil and reopen == nil and not Open77.appearance.isOpen()
end)
exports("revision", function() return record and record.revision or 0 end)
exports("characterKey", function() return record and record.key or "default" end)

print("Open77 persistent appearance client ready")

-- Capture the same authoritative statements as the equipment owners, without
-- mutating them. Server acceptance can update these while a preview is open.
RegisterNetEvent("open77:equipment:me", function(player) presentationPlayer = tonumber(player) end)
RegisterNetEvent("open77:equipment:self", function(value)
    if type(value) == "table" then committedEquipment = value end
end)
RegisterNetEvent("open77:equipment:slot", function(player, slot, value)
    if tonumber(player) == presentationPlayer and committedEquipment then committedEquipment[slot] = value end
end)
RegisterNetEvent("open77:wardrobe:self", function(value)
    if type(value) == "table" then committedWardrobe = value end
end)
RegisterNetEvent("open77:wardrobe:record", function(player, value)
    if tonumber(player) == presentationPlayer and type(value) == "table" then committedWardrobe = value end
end)
-- Used by fitting-room -> native editor handoff. This is a state check,
-- not a timer: clear the release barrier only after restored attachments match.
exports("previewReady", function()
    local player = Open77.character.state()
    if previewOwner or not announced or not world or not reset or applying or edit or reopen
        or Open77.appearance.isOpen() or type(player) ~= "table" or not player.alive
        or not presentationRestored() then return false, "presentation_not_ready" end
    if previewRestoring then
        previewRestoring = false
        bodyPending = true
    end
    return true
end)
exports("beginPreview", function()
    local owner = GetInvokingResource()
    if owner ~= "open77_wardrobe_ui" then return nil, "preview_owner_denied" end
    if previewOwner or previewRestoring or not announced or not world or not reset
        or applying or edit or reopen or Open77.appearance.isOpen()
        or not presentationRestored() then return nil, "presentation_not_ready" end
    previewOwner = owner
    return true
end)
exports("endPreview", function()
    if GetInvokingResource() ~= previewOwner then return nil, "preview_owner_denied" end
    previewOwner = nil
    previewRestoring = true
    bodyPending = true
    return true
end)
AddEventHandler("onClientResourceStop", function(name)
    if name == previewOwner then
        previewOwner = nil
        previewRestoring = true
        bodyPending = true
    end
end)
