-- rp_trauma - server: Trauma Team, the RP death and Trauma Team International for a Night City
-- RP server.
--
-- Absorbs rp_medic. Commands: /soin /reanimer /911 /medic (gated by rp_jobs "trauma" + duty),
-- /respawn, /trauma [av|av off|factures|payer], /contrat, /tti (plans, calls, invoices).
--
-- The "down" state. The platform exposes nothing that lets a resource hold or cancel
-- the freeroam respawn (no death-hold API, no cancellable death event, no freeroam
-- export or tunable for it - see README). So this resource lets the respawn happen
-- and, the moment the life phase comes back to "alive", re-applies a "down" state at
-- the death position: Open77.players.teleport back to the spot, Open77.players.setFrozen,
-- health set low with regeneration off (Open77.stats), the client blocks every input,
-- and a countdown of Config.downSeconds runs. Going down raises a Trauma Team call
-- (server/service.lua): every on-duty medic gets a chat line, a toast and a map pin; one
-- team takes it, stabilises the body (an open77_actions action on it) and evacuates it to
-- Vik's clinic. /respawn is accepted after the countdown, or at once when no medic is on
-- duty: the body goes to the hospital and the bill follows the patient's plan.
--
-- The down state is durable (Config.downPersist): it is saved in this resource's kvp store under
-- the player's durable subject when they go down, die again or become stable, and deleted on every
-- way up. A player who disconnects while down, or whom a restart (of this resource or of the
-- server) lets go, is held down again at the same spot when they are back, with what their
-- countdown had left; a new call goes out for them.
--
-- Authority: everything is decided here and in service.lua; the client only renders (pins,
-- input block) and requests (ALT+click actions). Every eddy moves through the coordinator
-- (server/ledger.lua): reserve before the act, commit after it, cancel on any other end.
-- Jobs come from rp_jobs, names from rp_identity, both reached with pcall since neither may
-- be declared as a dependency of a resource that ships a client script.

local RESOURCE = GetCurrentResourceName()
local Svc = TraumaService.new({ config = TraumaConfig, shared = Config, model = TraumaModel,
    ledger = TraumaLedger, ports = TraumaPorts, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
TraumaRuntime = { service = Svc }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- [playerId] = { position, heading, since, deadline, deaths, held, applying, reminderAt,
--               announcedOpen, announced, episode, stable, stableFraction, pose,
--               subject, sinceUnix, deadlineUnix, saved, resumed, resumeTold, reapply }
-- A player with an entry here is down: the next "alive" life phase re-applies the hold.
-- Removing the entry is what frees them. `deadline` is monotonic (the live countdown),
-- `deadlineUnix` / `sinceUnix` are wall-clock (what is saved); `resumed` marks an entry read back
-- from the store after a disconnect or a restart.
local down = {}

-- The 1.x tables. Plans and invoices now live in the coordinator; the tables are kept
-- (same schema, created when missing) so the one-time import of a player's 1.x contract and
-- unpaid bills (service.lua S:importLegacy) and the readers of the tables (rp_mdt) keep a
-- table to read. Nothing but the import's "imported" marks is written to them any more.
local SQL_CONTRACTS = [[
CREATE TABLE IF NOT EXISTS rp_trauma_contracts (
    identifier VARCHAR(64) PRIMARY KEY,
    active     TINYINT(1) NOT NULL DEFAULT 1,
    until_at   BIGINT     NOT NULL DEFAULT 0,
    failures   TINYINT    NOT NULL DEFAULT 0,
    started_at BIGINT     NOT NULL DEFAULT 0,
    renewed_at BIGINT     NOT NULL DEFAULT 0
)]]

local SQL_BILLS = [[
CREATE TABLE IF NOT EXISTS rp_trauma_bills (
    id         INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    identifier VARCHAR(64)  NOT NULL,
    amount     INT          NOT NULL,
    reason     VARCHAR(32)  NOT NULL DEFAULT '',
    created_at BIGINT       NOT NULL DEFAULT 0,
    paid_at    BIGINT       NULL,
    KEY idx_rp_trauma_bills_identifier (identifier)
)]]

local avByMedic = {}   -- [medicId] = vehicleId
local cooldowns = {}   -- [medicId] = Open77.time.monotonic() of the last paid act
local busy = {}        -- [medicId] = true while a progress bar runs

local COLOR = Config.colors

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_trauma] " .. fmt):format(...))
end

local function nowMono()
    return Open77.time.monotonic()
end

local function nowUnix()
    return math.floor(Open77.time.unix())
end

local function round(value)
    return math.floor(value + 0.5)
end

-- Chat to one player (or -1). `playerId` is a number everywhere this is called.
local function say(playerId, text, color)
    local ok, reason = Open77.chat.send(playerId, { author = "TRAUMA", text = text, color = color or COLOR.trauma })
    if not ok then
        log("chat.send to %s failed: %s", tostring(playerId), tostring(reason))
    end
end

local function toast(playerId, kind, title, message, durationMs)
    local id, reason = Open77.notifications.send(playerId, {
        type = kind,
        title = title,
        message = message,
        icon = "TT",
        durationMs = durationMs or 6000,
    })
    if not id then
        log("notification to %s failed: %s", tostring(playerId), tostring(reason))
    end
end

local function fmtPos(pos)
    return ("%d, %d, %d"):format(round(pos.x), round(pos.y), round(pos.z))
end

local function playerIdArg(value)
    local n = tonumber(value)
    if not n or n < 1 or n % 1 ~= 0 then
        return nil
    end
    return math.tointeger(n)
end

-- ---------------------------------------------------------------------------
-- Sibling resources (synchronous exports raise when the resource is missing)
-- ---------------------------------------------------------------------------

local function displayName(playerId)
    local ok, name = pcall(function()
        return exports.rp_identity:fullName(playerId)
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

-- true / false when rp_jobs answered, nil when its exports are unavailable.
local function isMedicOnDuty(playerId)
    local ok, result = pcall(function()
        return exports.rp_jobs:hasJob(playerId, Config.job) and exports.rp_jobs:onDuty(playerId)
    end)
    if not ok then
        return nil
    end
    return result == true
end

local function listOnDuty(job)
    local ok, list = pcall(function()
        return exports.rp_jobs:listOnDuty(job)
    end)
    if ok and type(list) == "table" then
        return list
    end
    return {}
end

local function medicsOnDuty(except)
    local out = {}
    for _, id in ipairs(listOnDuty(Config.job)) do
        id = tonumber(id)
        if id and id ~= except then
            out[#out + 1] = id
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Medic counters (kvp, keyed by the durable identifier)
-- ---------------------------------------------------------------------------

local function bump(medicId, kind)
    local identifier = Open77.players.identifier(medicId)
    if not identifier then
        return
    end
    local key = kind .. ":" .. identifier
    local current = Open77.kvp.get(key, 0) or 0
    Open77.kvp.set(key, current + 1)
end

local function statsLine(medicId)
    local identifier = Open77.players.identifier(medicId)
    if not identifier then
        return nil
    end
    local heals = Open77.kvp.get("heal:" .. identifier, 0) or 0
    local revives = Open77.kvp.get("revive:" .. identifier, 0) or 0
    return ("Your interventions: %d patched up, %d revived."):format(heals, revives)
end

-- ---------------------------------------------------------------------------
-- The down state on disk (kvp, keyed by the durable subject)
-- ---------------------------------------------------------------------------
-- One string per down player, "down:<subject>" (TraumaModel.encodeDown): the spot, the heading,
-- the fall and the moment /respawn opens in wall-clock unix seconds, stable or not, the deaths.
-- Open77.kvp and not the coordinator or SQL: it is synchronous (a death, a disconnect and the
-- stop handler cannot wait on a promise), needs neither a database nor a running library, is
-- flushed when the resource stops, and already holds this resource's medic counters. The
-- coordinator keeps money and items; a body's position is neither. The subject is the one the
-- Trauma Team file uses (Svc:subjectOf: the coordinator's provider, else the identifier).

local DOWN_KEY = "down:"

local function persistEnabled()
    return Config.downPersist ~= false
end

local function persistMaxSeconds()
    return tonumber(Config.downPersistMaxSeconds) or 3 * 60 * 60
end

local function downKey(subject)
    return DOWN_KEY .. subject
end

-- The durable subject of a connected player, or nil. Never yields.
local function subjectFor(playerId)
    local ok, subject = pcall(Svc.subjectOf, Svc, playerId)
    if ok and type(subject) == "string" and subject ~= "" then
        return subject
    end
    return nil
end

-- Writes a down entry (on the fall, a death while down, stabilisation, a disconnect).
local function saveDown(playerId, entry)
    if not persistEnabled() then
        return
    end
    entry.subject = entry.subject or subjectFor(playerId)
    if not entry.subject then
        log("player %d: no durable subject, the down state is not saved", playerId)
        return
    end
    local ok, why = Open77.kvp.set(downKey(entry.subject), TraumaModel.encodeDown({
        position = entry.position, heading = entry.heading, at = entry.sinceUnix, untilAt = entry.deadlineUnix,
        stable = entry.stable == true, stableFraction = entry.stableFraction, deaths = entry.deaths,
    }))
    entry.saved = ok == true
    if not ok then
        log("player %d: down state not saved: %s", playerId, tostring(why))
    end
end

-- Deletes the saved entry: the player is up again, by whatever path.
local function forgetDown(entry)
    if entry and entry.subject then
        Open77.kvp.delete(downKey(entry.subject))
        entry.saved = false
    end
end

-- ---------------------------------------------------------------------------
-- The down state
-- ---------------------------------------------------------------------------

local function secondsLeft(entry)
    return math.max(0, math.ceil(entry.deadline - nowMono()))
end

-- Tells one client whether it is an on-duty medic (and which calls it can see).
local function pushMedicState(playerId)
    local onDuty = isMedicOnDuty(playerId) == true
    TriggerClientEvent("rp_trauma:medic", playerId, onDuty, onDuty and Svc:callList(playerId) or {})
end

local function downMessage(entry, playerId)
    local left = secondsLeft(entry)
    local bill = Svc:estimate(playerId, "hospital")
    if entry.stable then
        return "You are down but stable. Trauma Team is taking you to Vik's clinic: hold on."
    end
    if left > 0 then
        return ("You are down. Trauma Team has been notified. /respawn opens in %d s (Vik's bill %d eddies)."):format(left, bill)
    end
    return ("You are down. /respawn wakes you up at Vik's clinic (%d eddies) - or wait for Trauma Team."):format(bill)
end

-- The notice of a down state read back after a disconnect or a restart (said once).
local function stillDownMessage(entry, playerId)
    local left = secondsLeft(entry)
    local bill = Svc:estimate(playerId, "hospital")
    if entry.stable then
        return "You are still down, but stable: Trauma Team has been called again and will take you to Vik's clinic. Hold on."
    end
    if left > 0 then
        return ("You are still down where you fell. Trauma Team has been called again. /respawn opens in %d s (Vik's bill %d eddies)."):format(left, bill)
    end
    return ("You are still down where you fell, and your countdown has run out: /respawn wakes you up at Vik's clinic now (%d eddies) - or wait for Trauma Team."):format(bill)
end

-- ---------------------------------------------------------------------------
-- Staging: a pose, a prop in the hand (or at the feet) and a progress bar for
-- every action that manipulates something, so nothing completes instantly and
-- everybody around sees it. Pattern of rp_nomade's carry pose: profiles tried
-- in order through Open77.animations.get, every native call inside pcall, a
-- refusal logged once and never fatal. RP animations are workspots: the
-- platform cancels one when the player moves more than 0.5 m, so the UI-kit bar
-- keeps the player still (disable.move, client side); the server never freezes
-- anyone. Everything comes from Config.Stage (shared/config.lua).
-- ---------------------------------------------------------------------------

local STAGE = Config.Stage or {}
local STAGE_TAG = "[" .. GetCurrentResourceName() .. "]"
local stageWarned = {}          -- "<what>" -> true once logged
local stageResolved = {}        -- key -> { profile, clip } | false
local stageActive = {}          -- playerId -> { key, playbackId, props = { ids } } while staged

local function stageLog(fmt, ...)
    print((STAGE_TAG .. " " .. fmt):format(...))
end

local function stageWarnOnce(what, fmt, ...)
    if stageWarned[what] then return end
    stageWarned[what] = true
    stageLog(fmt, ...)
end

local function stageAnimationsApi()
    return type(Open77.animations) == "table" and type(Open77.animations.play) == "function"
end

local function stagePropsApi()
    return type(Open77.props) == "table" and type(Open77.props.attach) == "function"
end

-- First profile of `pose.profiles` the server's catalogue knows (memoised per key).
local function stageResolvePose(key, pose)
    if stageResolved[key] ~= nil then return stageResolved[key] or nil end
    local found = false
    if type(pose) == "table" and stageAnimationsApi() then
        for _, candidate in ipairs(pose.profiles or {}) do
            local ok, profile = pcall(Open77.animations.get, candidate.profile)
            if ok and type(profile) == "table" then
                local clip = candidate.clip
                if clip then
                    local known = false
                    for _, name in ipairs(profile.clips or {}) do
                        if name == clip then known = true break end
                    end
                    if not known then
                        stageLog("stage %s: clip %s is not in profile %s, using %s", key, clip, candidate.profile, tostring(profile.clip))
                        clip = nil
                    end
                end
                found = { profile = candidate.profile, clip = clip or profile.clip }
                break
            end
        end
    end
    stageResolved[key] = found
    if not found then
        local names = {}
        for _, candidate in ipairs(type(pose) == "table" and pose.profiles or {}) do names[#names + 1] = tostring(candidate.profile) end
        stageWarnOnce("pose:" .. key, "stage %s: no known profile among [%s], the action runs without a pose", key, table.concat(names, ", "))
    end
    return found or nil
end

local function stagePoseWord(key)
    local r = stageResolved[key]
    if not r then return "none" end
    return r.profile .. "/" .. tostring(r.clip)
end

-- Start a pose on a player. A `loop` pose runs until stagePoseStop; a one-shot uses
-- `durationMs` (the platform accepts 1 000..600 000 ms). Returns the playback id or nil.
local function stagePoseStart(playerId, key, pose, durationMs)
    if type(pose) ~= "table" then return nil end
    local resolved = stageResolvePose(key, pose)
    if not resolved then return nil end
    local options = {}
    if pose.loop == false then
        options.loop = false
        options.durationMs = math.floor(math.max(1000, math.min(600000, tonumber(durationMs) or tonumber(pose.durationMs) or 5000)))
    else
        options.loop = true
    end
    if resolved.clip then options.clip = resolved.clip end
    local ok, playback, reason = pcall(Open77.animations.play, playerId, resolved.profile, options)
    if ok and type(playback) == "table" and playback.playbackId then
        return playback.playbackId
    end
    if not ok then reason = playback end
    stageWarnOnce("play:" .. key .. ":" .. tostring(reason), "stage %s: pose %s refused for player %d: %s (the action runs without it)",
        key, resolved.profile, playerId, tostring(reason))
    return nil
end

local function stagePoseStop(playerId, playbackId)
    if not playbackId or not stageAnimationsApi() then return end
    local ok, stopped, why = pcall(Open77.animations.stop, playerId, playbackId)
    if ok and not stopped and why ~= "stale_playback" then
        stageLog("stage: pose stop refused for player %d: %s", playerId, tostring(why))
    end
end

-- Spawn a curated prop and make it follow the player (a hand slot, or the root frame:
-- +y where the player faces, +x their right, +z up, origin at the feet). Returns the
-- prop id and the model, or nil.
local function stagePropHold(playerId, key, prop)
    if type(prop) ~= "table" or not stagePropsApi() then return nil end
    local ok0, pos = pcall(Open77.players.position, playerId)
    if not ok0 or type(pos) ~= "table" or type(pos.x) ~= "number" then return nil end
    for _, model in ipairs(prop.models or {}) do
        local okC, id, reason = pcall(Open77.props.create, {
            model = model,
            position = { x = pos.x, y = pos.y, z = pos.z or 0.0 },
            yaw = 0.0,
            bucket = pos.bucket or 0,
        })
        if not okC then id, reason = nil, id end
        if id then
            local okA, attached, why = pcall(Open77.props.attach, id, {
                parentType = "player",
                parentId = playerId,
                bone = prop.bone or "",
                offset = prop.offset or { x = 0.0, y = 0.0, z = 0.0 },
                rotation = prop.rotation or { x = 0.0, y = 0.0, z = 0.0 },
            })
            if okA and attached then return id, model end
            if not okA then why = attached end
            pcall(Open77.props.remove, id)
            stageWarnOnce("attach:" .. key .. ":" .. model, "stage %s: attach of %s to player %d refused: %s (no prop shown)",
                key, model, playerId, tostring(why))
            return nil
        end
        stageWarnOnce("prop:" .. key .. ":" .. model, "stage %s: prop %s refused: %s", key, model, tostring(reason))
    end
    return nil
end

local function stagePropDrop(propId)
    if propId and stagePropsApi() then pcall(Open77.props.remove, propId) end
end

local function stageSlotWord(prop)
    if type(prop) ~= "table" then return "root" end
    return (prop.bone and prop.bone ~= "") and prop.bone or "root"
end

-- Everything a staged action put on a player is taken back.
local function stageFinish(playerId, entry)
    if not entry then return end
    if stageActive[playerId] == entry then stageActive[playerId] = nil end
    stagePoseStop(playerId, entry.playbackId)
    entry.playbackId = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
    entry.props = {}
end

-- Pose + props of `def` on a player, returned as an entry for stageFinish.
local function stageBegin(playerId, key, def, durationMs)
    local entry = { key = key, props = {}, words = {} }
    stageActive[playerId] = entry
    if STAGE.enabled == false or type(def) ~= "table" then return entry end
    entry.playbackId = stagePoseStart(playerId, key, def.pose, durationMs)
    if def.prop then
        local id, model = stagePropHold(playerId, key .. ".prop", def.prop)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.prop = model .. "@" .. stageSlotWord(def.prop)
        end
    end
    if def.place then
        local id, model = stagePropHold(playerId, key .. ".place", def.place)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.place = model
        end
    end
    return entry
end

-- The UI-kit bar (server twin). A plain wait keeps the beat when the kit is missing.
local function stageBar(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "progress", playerId, definition)
    if not promise then
        if reason == "progress_active" or reason == "dialog_active" then return nil, reason end
        stageWarnOnce("uikit:" .. tostring(reason), "stage: uikit progress unavailable (%s), plain wait instead", tostring(reason))
        Wait(definition.duration)
        return { ok = true, outcome = "ok", fallback = true }
    end
    local answer, err = promise:await()
    if not answer then return nil, err end
    return answer
end

-- Run a staged action on `playerId`: pose + props + bar, then everything is cleaned up.
-- `key` names a Config.Stage entry; opts.label / opts.durationMs / opts.cancellable override
-- it. Returns the bar's answer ({ ok, outcome }) or nil, reason when the bar never showed.
-- Yields: capture `source` before calling.
local function stage(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 5000)
    local entry = stageBegin(playerId, key, def, durationMs)
    local answer, err = stageBar(playerId, {
        label = opts.label or def.label or key,
        duration = durationMs,
        position = "bottom",
        style = "bar",
        color = def.color or STAGE.color,
        cancellable = opts.cancellable ~= false,
        cancelKey = "X",
        disable = { move = true, combat = true },
    })
    stageFinish(playerId, entry)
    stageLog("player %d stage %s: pose=%s prop=%s place=%s %d ms -> %s", playerId, key, stagePoseWord(key),
        entry.words.prop or "none", entry.words.place or "none", durationMs,
        answer and (answer.ok and "ok" or tostring(answer.outcome or "cancelled")) or ("failed:" .. tostring(err)))
    return answer, err
end

-- A gesture without a bar (a hand-over, a wave, a sip): pose + props for `durationMs`,
-- taken back by a timer. Never yields. Returns the entry.
local function gesture(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 3000)
    local entry = stageBegin(playerId, key, def, durationMs)
    SetTimeout(durationMs, function() stageFinish(playerId, entry) end)
    stageLog("player %d gesture %s: pose=%s prop=%s %d ms", playerId, key, stagePoseWord(key), entry.words.prop or "none", durationMs)
    return entry
end

-- A pose held until stageRelease (a cuffed suspect, a patient on the ground). Never yields.
local function stageHold(playerId, key)
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local entry = stageBegin(playerId, key, def, nil)
    stageLog("player %d hold %s: pose=%s prop=%s", playerId, key, stagePoseWord(key), entry.words.prop or "none")
    return entry
end

local function stageRelease(playerId, entry)
    stageFinish(playerId, entry or stageActive[playerId])
end

-- Disconnect: the pose died with the player, the props must not survive them.
local function stageClear(playerId)
    local entry = stageActive[playerId]
    if not entry then return end
    stageActive[playerId] = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
end

-- Frees the body: drops the hold, restores regeneration, sets the health, tells the
-- clients, closes the patient's call. `healthFraction` nil leaves the health alone; `how`
-- says why (revived, respawned, evacuated, released) and `by` who (a medic or nil).
local function releaseHold(playerId, healthFraction, how, by)
    local entry = down[playerId]
    down[playerId] = nil
    forgetDown(entry)
    if entry and entry.pose then stageRelease(playerId, entry.pose); entry.pose = nil end
    local ok, reason = Open77.players.setFrozen(playerId, false)
    if not ok then
        log("setFrozen(%d, false): %s", playerId, tostring(reason))
    end
    Open77.stats.setHealthRegenEnabled(playerId, true)
    if healthFraction then
        if healthFraction >= 1.0 then
            Open77.stats.restoreHealth(playerId)
        else
            local stats = Open77.stats.get(playerId)
            local maximum = stats and stats.health and stats.health.maximum or 100
            Open77.stats.setHealth(playerId, math.max(1, math.floor(maximum * healthFraction)))
        end
    end
    TriggerClientEvent("rp_trauma:hold", playerId, false, 0)
    TriggerClientEvent("rp_trauma:downClear", -1, playerId)
    if entry then Svc:onUp(playerId, how or "released", by) end
end

-- Runs when the life phase is back to "alive" for a down player: back to the death
-- spot, frozen, low health, inputs blocked on the client.
local function applyHold(playerId)
    local entry = down[playerId]
    if not entry then
        return
    end
    if entry.applying then
        -- Another alive phase while the body is in transit (the join spawn of a player who comes
        -- back down, a second phase of the same respawn): the hold runs once more after this one.
        entry.reapply = true
        return
    end
    entry.applying = true
    entry.reapply = nil

    -- Back to the death spot. The respawn may still be settling ("recovering"), so a
    -- refusal is retried a few times before the hold is applied where the body stands.
    for attempt = 1, 4 do
        local pending, reason = Open77.players.teleport(playerId, entry.position, { heading = entry.heading, dismount = true })
        local landed, err
        if pending then
            landed, err = pending:await()
        else
            err = reason
        end
        if landed or down[playerId] ~= entry then
            break
        end
        log("player %d: teleport back to the death spot failed (attempt %d): %s", playerId, attempt, tostring(err))
        Wait(1000)
    end
    if down[playerId] ~= entry then
        entry.applying = false
        return  -- revived or respawned while the body was in transit
    end

    local ok, why
    for _ = 1, 10 do
        ok, why = Open77.players.setFrozen(playerId, true)
        if ok or down[playerId] ~= entry then
            break
        end
        Wait(500)  -- transition_in_progress: the respawn is still being acked
    end
    if down[playerId] ~= entry then
        entry.applying = false
        return
    end
    if not ok then
        log("player %d: setFrozen refused: %s", playerId, tostring(why))
    end

    local stats = Open77.stats.get(playerId)
    local maximum = stats and stats.health and stats.health.maximum or 100
    local fraction = entry.stable and (entry.stableFraction or Config.downHealthFraction) or Config.downHealthFraction
    local low = math.max(1, math.floor(maximum * fraction))
    local okH, whyH = Open77.stats.setHealth(playerId, low)
    if not okH then
        log("player %d: setHealth(%d) refused: %s", playerId, low, tostring(whyH))
    end
    Open77.stats.setHealthRegenEnabled(playerId, false)
    entry.holdHealth = low

    entry.held = true
    entry.applying = false
    -- The wounded pose for as long as the player is down (Config.Stage.down). A second alive
    -- phase of the same respawn (the platform reports two) re-applies the hold: the first pose
    -- is stopped first, so a single stop frees the body at the end.
    if entry.pose then stageRelease(playerId, entry.pose); entry.pose = nil end
    entry.pose = stageHold(playerId, "down")
    TriggerClientEvent("rp_trauma:hold", playerId, true, secondsLeft(entry), entry.stable == true)
    -- Said once per state: the second alive phase of the same respawn holds again in silence.
    -- A down state read back after a disconnect or a restart says so, once.
    local state = entry.stable and "stable" or "down"
    if entry.announced ~= state then
        entry.announced = state
        local resumed = entry.resumed and not entry.resumeTold
        if resumed then entry.resumeTold = true end
        say(playerId, resumed and stillDownMessage(entry, playerId) or downMessage(entry, playerId))
        toast(playerId, "error", resumed and "You are still down" or "You are down",
            entry.stable and "Stable. Evacuation coming." or "Trauma Team has been notified.", 8000)
    end
    log("player %d held down at %s, %d s left%s", playerId, fmtPos(entry.position), secondsLeft(entry),
        entry.stable and " (stable)" or "")
    if entry.reapply and down[playerId] == entry then
        applyHold(playerId)
    end
end

-- The Trauma Team response, as main.lua's down state lets service.lua see and act on it.
-- Stable: the patient stays down, at a higher health, until the evacuation. A body that is
-- still dead (no respawn yet) is revived in place; its alive phase re-applies the hold.
local function stabiliseHeld(playerId, fraction)
    local entry = down[playerId]
    if not entry then
        return false
    end
    entry.stable = true
    entry.stableFraction = fraction
    saveDown(playerId, entry)
    if Open77.players.isDead(playerId) then
        local ok, reason = Open77.players.revive(playerId, { health = fraction, graceMs = Config.reviveGraceMs })
        if not ok then
            log("player %d: revive for stabilisation refused: %s", playerId, tostring(reason))
        end
        return ok == true
    end
    if entry.held then
        local stats = Open77.stats.get(playerId)
        local maximum = stats and stats.health and stats.health.maximum or 100
        entry.holdHealth = math.max(1, math.floor(maximum * fraction))
        Open77.stats.setHealth(playerId, entry.holdHealth)
        TriggerClientEvent("rp_trauma:hold", playerId, true, secondsLeft(entry), true)
    end
    return true
end

-- The evacuation: the hold is released and the body moved (fade) to the clinic. Yields.
-- true | nil, reason (released in place when the move failed).
local function evacuateHeld(playerId, opts)
    if not down[playerId] then
        return nil, "patient_gone"
    end
    releaseHold(playerId, nil, "evacuated", opts.by)
    local moved, why = true, nil
    if Open77.players.isDead(playerId) then
        local ok, reason = Open77.players.respawn(playerId, {
            position = opts.position, heading = opts.heading or 0.0, health = opts.health or 0.5, graceMs = Config.reviveGraceMs,
        })
        if not ok then moved, why = false, reason end
    else
        local pending, reason = Open77.players.teleport(playerId, opts.position, { heading = opts.heading, dismount = true })
        if not pending then
            moved, why = false, reason
        else
            local landed, err = pending:await()
            if not landed then moved, why = false, err end
        end
        local fraction = opts.health or 0.5
        if fraction >= 1.0 then
            Open77.stats.restoreHealth(playerId)
        else
            local stats = Open77.stats.get(playerId)
            local maximum = stats and stats.health and stats.health.maximum or 100
            Open77.stats.setHealth(playerId, math.max(1, math.floor(maximum * fraction)))
        end
    end
    if not moved then
        log("player %d: evacuation move failed: %s", playerId, tostring(why))
        return nil, why
    end
    return true
end

Svc:attach({
    entry = function(playerId) return down[playerId] end,
    isDown = function(playerId) return down[playerId] ~= nil end,
    name = displayName,
    stabilise = stabiliseHeld,
    evacuate = evacuateHeld,
})

-- A scripted kill is a move, not a death: the admin tools (open77_admin /tp, /goto, /bring)
-- kill with cause "script" and weapon "open77_admin:<verb>" then respawn at the destination.
-- Such a death must not put the player down. Anything else (weapons, falls, /suicide, an
-- explosion) is a real death.
local function isScriptedMove(playerId)
    local life = Open77.players.getLifeState(playerId)
    if type(life) ~= "table" then return false end
    local weapon = tostring(life.weapon or life.lastWeapon or "")
    local cause = tostring(life.cause or life.lastCause or "")
    if weapon:find("^open77_admin:") then return true end
    if cause == "script" and weapon ~= "" and not weapon:find("suicide") then return true end
    return false
end

local function onDeath(playerId)
    if isScriptedMove(playerId) then
        log("player %d killed by a scripted move (admin teleport): not a death", playerId)
        return
    end
    local read = Open77.players.get(playerId)
    local pos = (read and read.position) or Open77.players.position(playerId)
    local entry = down[playerId]
    if entry then
        entry.deaths = entry.deaths + 1
        if pos then
            entry.position = { x = pos.x, y = pos.y, z = pos.z }
            Svc:patientMoved(playerId, entry.position)
        end
        entry.held = false
        saveDown(playerId, entry)
        log("player %d died again while down (%d deaths)", playerId, entry.deaths)
        return
    end
    if not pos then
        log("player %d died with no known position: no down state", playerId)
        return
    end
    local unix = nowUnix()
    entry = {
        position = { x = pos.x, y = pos.y, z = pos.z },
        heading = (read and read.heading) or 0.0,
        since = nowMono(),
        deadline = nowMono() + Config.downSeconds,
        sinceUnix = unix,
        deadlineUnix = unix + Config.downSeconds,
        deaths = 1,
        held = false,
        applying = false,
        reminderAt = nowMono() + Config.downReminderSeconds,
        announcedOpen = false,
        announced = "down",      -- the state the player was last told about (down, stable)
        episode = Svc:newEpisode(),
        subject = subjectFor(playerId),
    }
    down[playerId] = entry
    saveDown(playerId, entry)
    local call = Svc:raiseCall(playerId, entry)
    say(playerId, downMessage(entry, playerId))
    toast(playerId, "error", "You are down", "Trauma Team has been notified.", 8000)
    TriggerEvent("rp_trauma:down", playerId, entry.position)
    log("player %d down at %s, call #%s, %d s", playerId, fmtPos(entry.position), call and tostring(call.id) or "-",
        Config.downSeconds)
end

-- ---------------------------------------------------------------------------
-- Back after a disconnect or a restart: the saved down state is held again
-- ---------------------------------------------------------------------------

local function lifePhase(playerId)
    local life = Open77.players.getLifeState(playerId)
    return type(life) == "table" and life.phase or nil
end

-- The call of a resumed down state, raised once the patient's plan is read (its tier sets the
-- priority and the words the patient reads): Svc:onReady reads it on a join, the service boot on a
-- start. After 20 s the call goes out with what is known. Yields.
local function resumeCall(playerId, entry)
    for _ = 1, 40 do
        if down[playerId] ~= entry then
            return
        end
        if Svc.plans[entry.subject] ~= nil then
            break
        end
        Wait(500)
    end
    if down[playerId] ~= entry or Svc.calls[playerId] then
        return
    end
    local call = Svc:raiseCall(playerId, entry)
    log("player %d still down: call #%s raised again", playerId, call and tostring(call.id) or "-")
end

-- The saved down state of a player who is back (a join, or a start that finds them connected),
-- put back in `down`: the same spot, what the countdown had left (0 when it ran out while they
-- were away: still down, /respawn open at once), stable or not, and a new call. No server action
-- here: the hold is applied by the "alive" life phase handler, or by holdIfAlive for a body that
-- is already standing. An entry older than Config.downPersistMaxSeconds is dropped. Never yields.
-- Returns the entry, or nil.
local function resumeDown(playerId, why)
    if not persistEnabled() or down[playerId] then
        return nil
    end
    local subject = subjectFor(playerId)
    if not subject then
        return nil
    end
    local raw = Open77.kvp.get(downKey(subject))
    if raw == nil then
        return nil
    end
    local saved = TraumaModel.decodeDown(raw)
    local now = nowUnix()
    local left = saved and TraumaModel.downResume(saved, now, persistMaxSeconds())
    if not left then
        Open77.kvp.delete(downKey(subject))
        log("player %d: saved down state dropped (%s)", playerId,
            saved and ("fell %d s ago, more than %d s"):format(now - saved.at, persistMaxSeconds()) or "unreadable")
        return nil
    end
    -- Never more than a full countdown (a clock set back, a shorter Config.downSeconds since).
    if left > Config.downSeconds then
        left = Config.downSeconds
        saved.untilAt = now + left
    end
    local entry = {
        position = saved.position,
        heading = saved.heading,
        since = nowMono() - math.max(0, now - saved.at),
        deadline = nowMono() + left,
        sinceUnix = saved.at,
        deadlineUnix = saved.untilAt,
        deaths = saved.deaths,
        held = false,
        applying = false,
        reminderAt = nowMono() + Config.downReminderSeconds,
        announcedOpen = left <= 0,   -- the resumed notice already says /respawn is open
        announced = nil,             -- the resumed notice is said at the first hold
        resumed = true,
        episode = Svc:newEpisode(),
        stable = saved.stable,
        stableFraction = saved.stableFraction,
        subject = subject,
        saved = true,
    }
    down[playerId] = entry
    log("player %d is still down (%s): at %s, %d s left%s", playerId, why, fmtPos(entry.position), left,
        entry.stable and " (stable)" or "")
    CreateThread(function() resumeCall(playerId, entry) end)
    return entry
end

-- A resumed body whose player already stands: no life phase will come to apply the hold (a start
-- finds the players settled long ago; a join may report its alive phase before the entry is back).
-- The same hold, from the same "alive" condition, never on a body that is not alive. Yields.
local function holdIfAlive(playerId)
    local entry = down[playerId]
    if entry and not entry.held and not entry.applying and lifePhase(playerId) == "alive" then
        applyHold(playerId)
    end
end

-- Saved down states older than the cap, of players who never came back: dropped at start.
local function purgeStaleDowns()
    if not persistEnabled() then
        return
    end
    local ok, keys = pcall(Open77.kvp.keys, DOWN_KEY, 256)
    if not ok or type(keys) ~= "table" then
        return
    end
    local now, dropped = nowUnix(), 0
    for _, key in ipairs(keys) do
        local saved = TraumaModel.decodeDown(Open77.kvp.get(key))
        if not saved or not TraumaModel.downResume(saved, now, persistMaxSeconds()) then
            Open77.kvp.delete(key)
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        log("%d stale saved down state(s) dropped", dropped)
    end
end

-- A connecting client reports a "dead" phase while its pristine template loads (measured
-- 2026-09-18: the event arrived 10 ms after the freeroam gate opened, at the handoff
-- position 2567, 113, 79, and would have held the player there). A death only counts once
-- the player has been seen alive after onPlayerReady, and never inside the connect grace.
local seenAlive = {}
local readyAt = {}
local CONNECT_GRACE_SECONDS = 15

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Players already in the world when the resource (re)starts have settled long ago.
    for _, id in ipairs(Open77.players.all()) do
        readyAt[id] = nowMono() - CONNECT_GRACE_SECONDS
        seenAlive[id] = not Open77.players.isDead(id)
        -- Down when the resource stopped (or when the server went down): held again now when
        -- standing, by their next alive phase otherwise. A player still connecting is resumed by
        -- onPlayerReady.
        local okRead, read = pcall(Open77.players.get, id)
        if okRead and type(read) == "table" and read.ready ~= false then
            -- The coordinator may not answer subjectOf yet while the resources restart (measured
            -- live: a stable patient was not held again and healed back to full): retried for 30 s.
            CreateThread(function()
                for attempt = 1, 30 do
                    if down[id] or not Open77.players.get(id) then break end
                    if resumeDown(id, "restart") then
                        holdIfAlive(id)
                        break
                    end
                    local subject = subjectFor(id)
                    if subject then   -- a subject and nothing saved: not down
                        if attempt > 1 then log("player %d: subject read after %d s, nothing saved", id, attempt - 1) end
                        break
                    end
                    if attempt == 30 then log("player %d: no durable subject 30 s after the start, not resumed", id) end
                    Wait(1000)
                end
            end)
        end
    end
    purgeStaleDowns()
end)

AddEventHandler("onPlayerLifeStateChanged", function(playerId, revision, phase)
    local id = tonumber(playerId)
    if not id then
        return
    end
    if phase == "dead" then
        local life = Open77.players.getLifeState(id)
        if type(life) == "table" then
            local parts = {}
            for k, v in pairs(life) do if type(v) ~= "table" then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end end
            table.sort(parts)
            log("player %d life snapshot: %s", id, table.concat(parts, " "))
        end
        local since = readyAt[id] and (nowMono() - readyAt[id]) or -1
        if not seenAlive[id] or since < CONNECT_GRACE_SECONDS then
            log("player %d dead phase ignored (connect grace: alive=%s, %.0f s after ready)", id,
                tostring(seenAlive[id] == true), since)
            return
        end
        onDeath(id)
    elseif phase == "alive" then
        if readyAt[id] then
            seenAlive[id] = true
        end
        if down[id] then
            applyHold(id)
        end
    end
end)

-- A held body that another resource healed (an admin or gamemode heal, the platform's
-- revive of a living player is a no-op) is up again: the hold would otherwise keep a player
-- at full health frozen on the floor, which no admin command could clear.
local function healedElsewhere(id, entry)
    if not entry.held or entry.applying or entry.respawning or not entry.holdHealth then return false end
    local stats = Open77.stats.get(id)
    local current = stats and stats.health and stats.health.value
    local maximum = stats and stats.health and stats.health.maximum or 100
    if type(current) ~= "number" or current <= entry.holdHealth + math.max(5, maximum * 0.15) then return false end
    log("player %d healed by another resource (%d > %d): hold released", id, current, entry.holdHealth)
    releaseHold(id, nil, "healed", nil)
    say(id, "You were patched up: you can move again.")
    return true
end

-- A held body whose wounded pose is not playing (refused while the body was still being moved
-- into place, or ended by a server move): played again, every 3 s at most. Measured live: the
-- second alive phase of a respawn re-held a patient while the body was in transit, the pose was
-- refused `player_unavailable` and observers saw the patient standing for the rest of the down.
local function keepDownPose(id, entry)
    if not entry.held or entry.applying or (entry.poseRetryAt or 0) > nowMono() then return end
    if not stageAnimationsApi() or type(Open77.animations.current) ~= "function" then return end
    local ok, current, why = pcall(Open77.animations.current, id)
    if not ok then return end
    local playbackId = entry.pose and entry.pose.playbackId
    if type(current) == "table" and playbackId and current.playbackId == playbackId then return end
    entry.poseRetryAt = nowMono() + 3
    if entry.pose then stageRelease(id, entry.pose); entry.pose = nil end
    entry.pose = stageHold(id, "down")
    log("player %d: wounded pose played again (%s; current=%s)", id, playbackId and "it had ended" or "it had been refused",
        type(current) == "table" and tostring(current.playbackId) .. "/" .. tostring(current.active) or tostring(why))
end

-- A held body away from its spot: put back on it, every 5 s at most, only while alive. Measured
-- live: the respawn placed a patient 800 m away, the travel back settled before the Kabuki market
-- floor had streamed in and the held body fell through the world (z -2000). Returns true when the
-- body is being moved (its pose is played again once it is back).
local function keepOnSpot(id, entry)
    if not entry.held or entry.applying or not entry.position then return false end
    if (entry.spotRetryAt or 0) > nowMono() then return true end
    local ok, pos = pcall(Open77.players.position, id)
    if not ok or type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.z) ~= "number" then return false end
    local dx, dy, dz = pos.x - entry.position.x, pos.y - entry.position.y, pos.z - entry.position.z
    if dx * dx + dy * dy <= Config.downSpotRadius * Config.downSpotRadius and dz > -Config.downSpotRadius then
        return false
    end
    if lifePhase(id) ~= "alive" then return false end
    entry.spotRetryAt = nowMono() + 5
    log("player %d: held body %.1f m from its spot (z %.1f), put back on it", id, math.sqrt(dx * dx + dy * dy + dz * dz), pos.z)
    CreateThread(function()
        local pending, why = Open77.players.teleport(id, entry.position, { heading = entry.heading, dismount = true })
        local landed, err = nil, why
        if pending then landed, err = pending:await() end
        if landed then
            entry.spotRetryAt = nowMono() + 1   -- the pose is played again at the next pass
        else
            log("player %d: back on the spot refused: %s", id, tostring(err))
        end
        entry.poseRetryAt = 0
    end)
    return true
end

-- Countdown reminders for down players.
CreateThread(function()
    while true do
        Wait(1000)
        for id, entry in pairs(down) do
          if not healedElsewhere(id, entry) then
            if not keepOnSpot(id, entry) then keepDownPose(id, entry) end
            local left = secondsLeft(entry)
            if left == 0 and not entry.announcedOpen then
                entry.announcedOpen = true
                say(id, ("/respawn is open: Vik's clinic takes you for %d eddies. Or keep waiting for Trauma Team."):format(
                    Svc:estimate(id, "hospital")))
                toast(id, "info", "Trauma Team", "/respawn is open.", 6000)
                if entry.held then
                    TriggerClientEvent("rp_trauma:hold", id, true, 0, entry.stable == true)
                end
            elseif nowMono() >= entry.reminderAt then
                entry.reminderAt = nowMono() + Config.downReminderSeconds
                say(id, downMessage(entry, id))
            end
          end
        end
    end
end)

-- The Trauma Team sweep: held-back calls, reminders, in-doubt charges, plan renewals.
CreateThread(function()
    while true do
        Wait(TraumaConfig.calls.sweepMs)
        local ok, err = pcall(Svc.sweep, Svc)
        if not ok then
            log("sweep raised: %s", tostring(err))
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Hospital respawn
-- ---------------------------------------------------------------------------

local function hospitalRespawn(playerId)
    local entry = down[playerId]
    if not entry or entry.respawning then
        return
    end
    entry.respawning = true
    -- The bill is held before the move, with an id of its own down episode: a retried
    -- /respawn reaches the same operation and never pays twice.
    local quote = Svc:quote({ patient = playerId, kind = "hospital", opId = entry.episode .. ":hosp" })
    if down[playerId] ~= entry then
        Svc:release(quote, "patient_gone")
        return
    end
    releaseHold(playerId, nil, "respawned")

    local target = Config.hospital.respawn
    if Open77.players.isDead(playerId) then
        local ok, reason = Open77.players.respawn(playerId, {
            position = target, heading = Config.hospital.heading, health = 1.0, graceMs = Config.reviveGraceMs,
        })
        if not ok then
            Svc:release(quote, "respawn_refused")
            say(playerId, "Hospital respawn refused: " .. tostring(reason) .. ". Try /respawn again.")
            log("player %d: respawn at the hospital refused: %s", playerId, tostring(reason))
            return
        end
    else
        local pending, reason = Open77.players.teleport(playerId, target, { heading = Config.hospital.heading, dismount = true })
        if not pending then
            say(playerId, "Transfer to Vik's clinic refused: " .. tostring(reason) .. ".")
            log("player %d: teleport to the hospital refused: %s", playerId, tostring(reason))
        else
            local landed, err = pending:await()
            if not landed then
                say(playerId, "Transfer to Vik's clinic failed: " .. tostring(err) .. ".")
                log("player %d: teleport to the hospital failed: %s", playerId, tostring(err))
            end
        end
        Open77.stats.restoreHealth(playerId)
    end

    local settled, why = Svc:settle(quote)
    local text = settled and Svc:chargeLine(quote or {}) or ("billing pending (" .. tostring(why) .. ")")
    say(playerId, ("Trauma Team dropped you at Vik's clinic. Bill: %s."):format(text))
    toast(playerId, "info", "Vik's clinic", ("Patched up. %s."):format(text), 8000)
    TriggerEvent("rp_trauma:revived", playerId, nil)
    log("player %d hospital respawn: fee=%d covered=%d account=%d cash=%d invoiced=%d%s", playerId,
        quote and quote.fee or 0, quote and quote.covered or 0, quote and quote.fromBank or 0,
        quote and quote.fromCash or 0, quote and quote.invoiced or 0,
        quote and quote.unbilled and (" unbilled=" .. quote.unbilled) or "")
end

RegisterCommand("respawn", function(source)
    if source == 0 then
        return print("[rp_trauma] /respawn must be used by a player in game, not from the console")
    end
    local entry = down[source]
    if not entry then
        return say(source, "You are not down, choom. Nothing to respawn from.")
    end
    if entry.applying or (entry.resumed and not entry.held and not Open77.players.isDead(source)) then
        return say(source, "Hold on, the body is still settling. Try again in a second.")
    end
    local left = secondsLeft(entry)
    local medics = #medicsOnDuty(source)
    if left > 0 and medics > 0 then
        return say(source, ("Trauma Team is on duty (%d medic%s). /respawn opens in %d s."):format(medics, medics > 1 and "s" or "", left))
    end
    if left > 0 and Config.countdownWithoutMedics then
        return say(source, ("Hold on, choom: /respawn opens in %d s."):format(left))
    end
    hospitalRespawn(source)
end, false)

-- ---------------------------------------------------------------------------
-- Medic acts: patch up (heal) and revive. Billed through the coordinator: the
-- charge is held before the bar (consent first when the patient pays), committed
-- after the act, released when the bar is cancelled or the act fails.
-- ---------------------------------------------------------------------------

-- Fills the patient's health. true | nil, reason.
local function doHeal(patient, medic)
    if Open77.players.isDead(patient) or down[patient] then
        return nil, "patient_down"
    end
    local ok, reason = Open77.stats.restoreHealth(patient)
    if not ok then
        return nil, reason or "heal_failed"
    end
    if medic then
        bump(medic, "heal")
    end
    log("player %s patched up player %d", tostring(medic), patient)
    return true
end

-- Brings a down (or dead) patient back where they lie. true | nil, reason.
local function doRevive(patient, medic)
    local entry = down[patient]
    local wasDead = Open77.players.isDead(patient)
    if not wasDead and not entry then
        return nil, "patient_not_down"
    end
    if wasDead then
        down[patient] = nil
        if entry and entry.pose then stageRelease(patient, entry.pose); entry.pose = nil end
        local ok, reason = Open77.players.revive(patient, { health = Config.reviveHealthFraction, graceMs = Config.reviveGraceMs })
        if not ok then
            down[patient] = entry
            return nil, reason or "revive_failed"
        end
        forgetDown(entry)
        TriggerClientEvent("rp_trauma:hold", patient, false, 0)
        TriggerClientEvent("rp_trauma:downClear", -1, patient)
        if entry then Svc:onUp(patient, "revived", medic) end
    else
        releaseHold(patient, Config.reviveHealthFraction, "revived", medic)
    end
    if medic then
        bump(medic, "revive")
        toast(patient, "success", "Trauma Team", "Back on your feet.", 6000)
    end
    TriggerEvent("rp_trauma:revived", patient, medic)
    log("player %s revived player %d dead=%s", tostring(medic), patient, tostring(wasDead))
    return true
end

local function cooldownLeft(medic)
    local last = cooldowns[medic]
    if not last then
        return 0
    end
    return math.max(0, Config.medicCooldownSeconds - (nowMono() - last))
end


-- The whole medic flow: gates, consent and charge, progress bar, re-check, act. `range` in metres.
local function performAction(medic, kind, target, range)
    if busy[medic] then
        return say(medic, "Finish your current intervention first.")
    end
    local onDuty = isMedicOnDuty(medic)
    if onDuty == nil then
        return say(medic, "Trauma Team roster unavailable (rp_jobs offline). Try again later.")
    end
    if not onDuty then
        return say(medic, "Trauma Team on duty only. Get the job and /service to clock in.")
    end
    local left = cooldownLeft(medic)
    if left > 0 then
        return say(medic, ("Wait another %d s before your next intervention."):format(math.ceil(left)))
    end
    if not target then
        return say(medic, "Usage: /" .. (kind == "revive" and "reanimer" or "soin") .. " <playerId>")
    end
    if target == medic then
        return say(medic, "You can't treat yourself, choom.")
    end
    local read, reason = Open77.players.get(target)
    if not read then
        return say(medic, ("Player %d not found (%s)."):format(target, tostring(reason)))
    end
    if not read.ready then
        return say(medic, "This player is not in the world yet.")
    end
    local metres, dreason = Open77.players.distance(medic, target)
    if not metres then
        return say(medic, "Patient position unknown (" .. tostring(dreason) .. ").")
    end
    if metres > range then
        return say(medic, ("Too far: %.1f m (%.0f m max)."):format(metres, range))
    end

    local dead = Open77.players.isDead(target)
    local isDownTarget = down[target] ~= nil
    if kind == "stabilise" then
        if dead or isDownTarget then
            return say(medic, "This patient is down: use Revive (/reanimer), or Stabilise on the body (E).")
        end
        local stats = Open77.stats.get(target)
        if stats and stats.health and stats.health.value >= stats.health.maximum then
            return say(medic, "This patient is already at full health.")
        end
    else
        if not dead and not isDownTarget then
            return say(medic, "This patient is on their feet: use Patch up (/soin).")
        end
    end

    busy[medic] = true
    local feeKind = kind == "stabilise" and "heal" or "revive"
    local quote, qwhy = Svc:careQuote(target, medic, feeKind, kind == "stabilise")
    if not quote then
        busy[medic] = nil
        if qwhy == "patient_declined" then
            return say(medic, ("%s did not accept the charges: no treatment."):format(displayName(target)))
        end
        return say(medic, "Intervention refused: " .. TraumaModel.textFor(qwhy))
    end

    local duration = kind == "stabilise" and Config.stabiliseMs or Config.reviveMs
    local label = kind == "stabilise" and "Patching up the patient" or "Reviving the patient"
    -- Staged: the medic kneels over the patient, injector in hand, for the whole bar
    -- (Config.Stage.stabilise / revive); without the UI kit the stage keeps the beat itself.
    local answer, err = stage(medic, kind, { label = label, durationMs = duration })
    busy[medic] = nil
    if not answer then
        Svc:release(quote, "interrupted")
        return say(medic, "Intervention interrupted (" .. tostring(err) .. ").")
    end
    if not answer.ok then
        Svc:release(quote, "cancelled_by_player")
        return say(medic, "Intervention cancelled.")
    end

    -- The world moved during the bar: check again.
    if Open77.players.isDead(medic) or down[medic] then
        Svc:release(quote, "dead")
        return
    end
    local again = Open77.players.distance(medic, target)
    if not again or again > range + 1.0 then
        Svc:release(quote, "too_far")
        return say(medic, "The patient is out of reach.")
    end

    local ok, why
    if kind == "stabilise" then
        ok, why = doHeal(target, medic)
    else
        ok, why = doRevive(target, medic)
    end
    if not ok then
        Svc:release(quote, TraumaModel.token(why, "act_failed"))
        return say(medic, "Intervention failed: " .. tostring(why) .. ".")
    end
    cooldowns[medic] = nowMono()
    local settled, swhy = Svc:settle(quote)
    local charges = settled and Svc:chargeLine(quote) or ("billing pending (" .. tostring(swhy) .. ")")
    local medicName, patientName = displayName(medic), displayName(target)
    if kind == "stabilise" then
        say(target, ("Medic %s patched you up: %s."):format(medicName, charges))
        say(medic, ("Patient %s patched up. %s."):format(patientName, TraumaModel.paySentence(quote)))
    else
        say(target, ("Medic %s revived you: %s."):format(medicName, charges))
        say(medic, ("Patient %s revived. %s."):format(patientName, TraumaModel.paySentence(quote)))
        if settled then
            Svc:jobCompleted("revive", medic, quote.txOpId or ("tt.revive:" .. tostring(target) .. ":" .. tostring(nowUnix())),
                { patient = target, fee = quote.fee, covered = quote.covered, paid = quote.paid,
                  invoiced = quote.invoiced, cut = quote.cut, bounty = quote.bounty })
        end
    end
end

RegisterCommand("soin", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /soin must be used by a player in game, not from the console")
    end
    performAction(source, "stabilise", playerIdArg(args[1]), Config.commandRange)
end, false)

RegisterCommand("reanimer", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /reanimer must be used by a player in game, not from the console")
    end
    performAction(source, "revive", playerIdArg(args[1]), Config.commandRange)
end, false)

-- ALT+click on a player: the client only names the target and the verb.
RegisterNetEvent("rp_trauma:action", function(kind, targetId)
    if type(source) ~= "number" or source < 1 then
        return
    end
    if kind ~= "stabilise" and kind ~= "revive" then
        return
    end
    performAction(source, kind, playerIdArg(targetId), Config.actionRange + 1.0)
end)

-- ---------------------------------------------------------------------------
-- /911 and /medic (from rp_medic)
-- ---------------------------------------------------------------------------

RegisterCommand("911", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /911 must be used by a player in game, not from the console")
    end
    local message = table.concat(args, " ", 1, args.n or #args):match("^%s*(.-)%s*$")
    if message == "" then
        return say(source, "Usage: /911 <message>")
    end
    local pos = Open77.players.position(source)
    local where = pos and fmtPos(pos) or "unknown position"
    gesture(source, "call")
    local alert = {
        author = "911",
        text = ("%s (id %d) at %s: %s"):format(displayName(source), source, where, message),
        color = COLOR.alert,
    }
    local responders = {}
    for _, id in ipairs(listOnDuty(Config.job)) do
        responders[tonumber(id) or -1] = true
    end
    for _, id in ipairs(listOnDuty("ncpd")) do
        responders[tonumber(id) or -1] = true
    end
    local notified = 0
    for id in pairs(responders) do
        if id ~= source and id > 0 then
            local ok, reason = Open77.chat.send(id, alert)
            if ok then
                notified = notified + 1
                toast(id, "warning", "911", ("%s: %s"):format(displayName(source), message), 8000)
            else
                log("911 alert to player %d failed: %s", id, tostring(reason))
            end
        end
    end
    if pos then
        TriggerEvent("rp_ncpd:alert", "911", { x = pos.x, y = pos.y, z = pos.z }, message, source)
    end
    say(source, ("Call relayed to %d responder(s) on duty (Trauma Team and NCPD)."):format(notified))
    log("player %d called 911 at %s notified=%d", source, where, notified)
end, false)

RegisterCommand("medic", function(source)
    if source == 0 then
        return print("[rp_trauma] /medic must be used by a player in game, not from the console")
    end
    local medics = {}
    local callerIsMedic = false
    for _, id in ipairs(listOnDuty(Config.job)) do
        id = tonumber(id)
        if id == source then
            callerIsMedic = true
        elseif id then
            medics[#medics + 1] = { id = id, name = displayName(id), metres = Open77.players.distance(source, id) }
        end
    end
    table.sort(medics, function(a, b)
        if a.metres and b.metres then
            return a.metres < b.metres
        end
        return a.metres ~= nil and b.metres == nil
    end)
    if #medics == 0 then
        say(source, callerIsMedic and "No other medic on duty." or "No medic on duty: /respawn is immediate if you go down.")
    else
        say(source, ("%d medic(s) on duty:"):format(#medics))
        for _, medic in ipairs(medics) do
            Wait(0)  -- two sends in the same tick arrive in reverse order
            local dist = medic.metres and ("%.0f m"):format(medic.metres) or "unknown distance"
            say(source, ("- %s (id %d): %s"):format(medic.name, medic.id, dist))
        end
    end
    if callerIsMedic then
        local line = statsLine(source)
        if line then
            Wait(0)
            say(source, line)
        end
    end
end, false)

-- ---------------------------------------------------------------------------
-- /trauma [av | av off | factures | payer]
-- ---------------------------------------------------------------------------

local function removeAv(medic)
    local vehicleId = avByMedic[medic]
    if not vehicleId then
        return false
    end
    avByMedic[medic] = nil
    local ok = Open77.vehicles.remove(vehicleId)
    log("player %d AV %s removed ok=%s", medic, tostring(vehicleId), tostring(ok))
    return true
end

local function traumaAv(medic, mode)
    local onDuty = isMedicOnDuty(medic)
    if onDuty == nil then
        return say(medic, "Trauma Team roster unavailable (rp_jobs offline).")
    end
    if not onDuty then
        return say(medic, "Trauma Team on duty only.")
    end
    if mode == "off" then
        if removeAv(medic) then
            return say(medic, "Your AV went back to the hangar.")
        end
        return say(medic, "You have no AV out.")
    end
    local read = Open77.players.get(medic)
    if not read or not read.position then
        return say(medic, "Your position is unknown: move a little and try again.")
    end
    -- The pad is a street point (Config.av.pad), not a zone: the clinic interior cannot take an AV.
    local pad = Config.av.pad
    local dx, dy = read.position.x - pad.x, read.position.y - pad.y
    local padDistance = math.sqrt(dx * dx + dy * dy)
    if padDistance > pad.radius then
        return say(medic, ("The AV pad is on the %s (%d, %d), %d m from you: stand on it first."):format(
            pad.label, math.floor(pad.x + 0.5), math.floor(pad.y + 0.5), math.floor(padDistance + 0.5)))
    end
    removeAv(medic)
    local yaw = read.heading or 0.0
    local rad = math.rad(yaw)
    local position = {
        x = read.position.x + math.sin(rad) * Config.av.spawnDistance,
        y = read.position.y + math.cos(rad) * Config.av.spawnDistance,
        z = read.position.z + Config.av.spawnUp,
    }
    local id, reason = Open77.vehicles.create({
        record = Config.av.record,
        position = position,
        yaw = yaw,
        ttlMs = Config.av.ttlMs,
        despawnWhenUnobserved = Config.av.despawnWhenUnobserved,
    })
    if not id then
        return say(medic, ("AV request refused (%s). Record: %s."):format(tostring(reason), Config.av.record))
    end
    avByMedic[medic] = id
    local ok, why = Open77.vehicles.warpPlayerIntoVehicle(medic, id, "driver")
    if ok then
        say(medic, "Trauma Team AV on the pad. You are at the controls. /trauma av off sends it back.")
    else
        say(medic, ("Trauma Team AV on the pad (id %s), seat refused: %s. Walk to it."):format(tostring(id), tostring(why)))
    end
    log("player %d spawned AV %s (%s) at %s seat=%s", medic, tostring(id), Config.av.record, fmtPos(position), tostring(ok))
end

-- ---------------------------------------------------------------------------
-- Status, invoices, plans
-- ---------------------------------------------------------------------------

local function sayLines(playerId, lines)
    for i, line in ipairs(lines) do
        if i > 1 then Wait(0) end  -- two sends in the same tick arrive in reverse order
        say(playerId, line)
    end
end

local function listBills(playerId)
    local owed = Svc:owedBy(playerId)
    if owed <= 0 then
        return say(playerId, "No unpaid Trauma Team invoice. Clean slate, choom.")
    end
    say(playerId, ("Unpaid Trauma Team invoices: %d eddies. /tti pay settles them (account, then cash)."):format(owed))
end

local function payBills(playerId)
    local r, leftOrWhy = Svc:payInvoices(playerId)
    if not r then
        return say(playerId, TraumaModel.textFor(leftOrWhy))
    end
    if leftOrWhy > 0 then
        say(playerId, ("Paid %d eddies of Trauma Team invoices. %d eddies still owed."):format(r.paid, leftOrWhy))
    else
        say(playerId, ("Paid %d eddies of Trauma Team invoices. Clean slate."):format(r.paid))
    end
end

local function dispatchLines(playerId)
    local lines = {}
    local calls = Svc:openCalls()
    if #calls == 0 then
        lines[1] = "Dispatch: no open call."
        return lines
    end
    lines[1] = ("Dispatch: %d call(s):"):format(#calls)
    for _, call in ipairs(calls) do
        if call.patient ~= playerId then
            local metres = Open77.players.distance(playerId, call.position)
            lines[#lines + 1] = ("- [%s] %s (id %d) at %s, %s%s"):format(TraumaModel.callTag(call), displayName(call.patient),
                call.patient, fmtPos(call.position), metres and ("%.0f m"):format(metres) or "unknown distance",
                call.responder and (", team " .. displayName(call.responder)) or "")
        end
    end
    return lines
end

local function traumaStatus(playerId)
    local entry = down[playerId]
    local lines = { entry and ("Trauma Team: you are DOWN%s, /respawn in %d s."):format(entry.stable and " (stable)" or "",
        secondsLeft(entry)) or "Trauma Team: you are on your feet." }
    for _, line in ipairs(Svc:statusLines(playerId)) do lines[#lines + 1] = line end
    if isMedicOnDuty(playerId) then
        for _, line in ipairs(dispatchLines(playerId)) do lines[#lines + 1] = line end
        lines[#lines + 1] = "/tti take [id] answers a call; /trauma av spawns the AV on the Afterlife street pad; E on a body: Stabilise, then Evacuate."
    end
    sayLines(playerId, lines)
end

RegisterCommand("trauma", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /trauma must be used by a player in game, not from the console")
    end
    local sub = (args[1] or ""):lower()
    if sub == "av" then
        traumaAv(source, (args[2] or ""):lower())
    elseif sub == "factures" or sub == "bills" then
        listBills(source)
    elseif sub == "payer" or sub == "pay" then
        payBills(source)
    else
        traumaStatus(source)
    end
end, false)

-- The nearest enabled kiosk within `radius` metres of a player, or nil.
local function nearestKiosk(playerId, radius)
    local best, bestD
    for _, k in ipairs(TraumaConfig.kiosks) do
        if k.enabled ~= false then
            local d = Open77.players.distance(playerId, k.position)
            if d and d <= radius and (not bestD or d < bestD) then best, bestD = k, d end
        end
    end
    return best
end

-- The kiosk's plan menu from a command: the same open77_actions request the prompt makes.
local function openKiosk(playerId)
    local kiosk = nearestKiosk(playerId, TraumaConfig.actions.subscribe.maxDistance)
    if not kiosk then
        return false
    end
    local op, why = TraumaPorts.actions.request(playerId, TraumaConfig.actions.subscribe.id, kiosk.id)
    if not op then
        say(playerId, TraumaModel.textFor(why))
    end
    return true
end

-- /contrat: the plan status, or the kiosk's menu when standing at one.
RegisterCommand("contrat", function(source)
    if source == 0 then
        return print("[rp_trauma] /contrat must be used by a player in game, not from the console")
    end
    if down[source] then
        return say(source, "Sign it when you are back on your feet.")
    end
    if openKiosk(source) then
        return
    end
    local lines = Svc:statusLines(source)
    lines[#lines + 1] = "Trauma Team plans are sold at the kiosks (/tti plans): stand at one and press E."
    sayLines(source, lines)
end, false)

-- /tti [plans | calls | take [id] | assist <id> | drop | pay | autorenew on|off | buy]
RegisterCommand("tti", function(source, args)
    if source == 0 then
        return print("[rp_trauma] /tti must be used by a player in game, not from the console; the console uses tti.*")
    end
    local verb = (args[1] or ""):lower()
    if verb == "plans" then
        sayLines(source, Svc:planLines())
    elseif verb == "buy" or verb == "subscribe" then
        if down[source] then
            return say(source, "Sign it when you are back on your feet.")
        end
        if not openKiosk(source) then
            say(source, "Stand at a Trauma Team kiosk first (/tti plans lists them).")
        end
    elseif verb == "calls" then
        if not isMedicOnDuty(source) then
            return say(source, TraumaModel.textFor("off_duty"))
        end
        sayLines(source, dispatchLines(source))
    elseif verb == "take" then
        local call, why = Svc:take(source, TraumaModel.playerId(args[2]))
        if not call then
            say(source, TraumaModel.textFor(why))
        end
        pushMedicState(source)
    elseif verb == "assist" then
        local call, why = Svc:assist(source, TraumaModel.playerId(args[2]))
        say(source, call and ("You joined the team on call #%d."):format(call.id) or TraumaModel.textFor(why))
    elseif verb == "drop" then
        Svc:leaveTeam(source, "dropped the call")
        say(source, "You are off your calls.")
    elseif verb == "pay" then
        payBills(source)
    elseif verb == "autorenew" then
        local on = (args[2] or ""):lower()
        if on ~= "on" and on ~= "off" then
            return say(source, "Usage: /tti autorenew on|off")
        end
        local ok, why = Svc:setAutoRenew(source, on == "on")
        say(source, ok and ("Auto-renewal %s."):format(on) or (why == "no_plan" and "You hold no Trauma Team plan." or TraumaModel.textFor(why)))
    else
        traumaStatus(source)
        Wait(0)
        say(source, "/tti plans | buy (at a kiosk) | pay | autorenew on|off; medics: calls | take [id] | assist <id> | drop")
    end
end, false)

-- ---------------------------------------------------------------------------
-- Exports (synchronous, never yield)
-- ---------------------------------------------------------------------------

exports("isDown", function(playerId)
    local id = playerIdArg(playerId)
    return id ~= nil and down[id] ~= nil
end)

-- An active Trauma Team plan (any tier).
exports("hasContract", function(playerId)
    local id = playerIdArg(playerId)
    return id ~= nil and Svc:hasPlan(id)
end)

-- { tier, label, untilAt, autoRenew, priority } of an active plan, or nil.
exports("planOf", function(playerId)
    local id = playerIdArg(playerId)
    if not id then
        return nil
    end
    local plan, tier = Svc:planOf(id)
    if not plan or not tier then
        return nil
    end
    return { tier = plan.tier, label = tier.label, untilAt = plan.untilAt, autoRenew = plan.autoRenew, priority = tier.priority }
end)

-- Eddies a connected player owes in unpaid invoices (cache).
exports("owed", function(playerId)
    local id = playerIdArg(playerId)
    return id and Svc:owedBy(id) or 0
end)

-- The open calls: { { id, patient, priority, tier, state, responder, position } }.
exports("calls", function()
    local out = {}
    for _, call in ipairs(Svc:openCalls()) do
        out[#out + 1] = { id = call.id, patient = call.patient, priority = call.priority, tier = call.tierKey or false,
            state = call.state, responder = call.responder or false, stable = call.stable,
            position = { x = call.position.x, y = call.position.y, z = call.position.z } }
    end
    return out
end)

-- Exports never charge a fee: the caller owns the money decision.
exports("heal", function(playerId, byPlayerId)
    local id = playerIdArg(playerId)
    if not id then
        return nil, "invalid_player_id"
    end
    if not Open77.players.get(id) then
        return nil, "player_not_found"
    end
    return doHeal(id, playerIdArg(byPlayerId))
end)

exports("revive", function(playerId, byPlayerId)
    local id = playerIdArg(playerId)
    if not id then
        return nil, "invalid_player_id"
    end
    if not Open77.players.get(id) then
        return nil, "player_not_found"
    end
    return doRevive(id, playerIdArg(byPlayerId))
end)

-- Hooks of the Trauma Team actions. A hook is an export NAME given to open77_actions; any
-- resource can call an export, so each one checks that its caller is open77_actions (and the
-- mutating ones also `verify` the operation). validate is synchronous; the others may yield.
exports("ttiValidate", function(ctx) return Svc:validate(ctx) end)
exports("ttiReserve", function(ctx) return Svc:reserve(ctx) end)
exports("ttiCommit", function(ctx) return Svc:commit(ctx) end)
exports("ttiCancel", function(ctx) return Svc:cancelHook(ctx) end)

-- ---------------------------------------------------------------------------
-- Client sync, job events, lifecycle
-- ---------------------------------------------------------------------------

RegisterNetEvent("rp_trauma:clientReady", function()
    if type(source) ~= "number" or source < 1 then
        return
    end
    pushMedicState(source)
    local entry = down[source]
    if entry and entry.held then
        TriggerClientEvent("rp_trauma:hold", source, true, secondsLeft(entry), entry.stable == true)
    end
end)

AddEventHandler("rp_jobs:duty", function(playerId, jobName, onDuty)
    local id = tonumber(playerId)
    if id then
        pushMedicState(id)
        Svc:onDutyChanged(id)
    end
end)

AddEventHandler("rp_jobs:changed", function(playerId, jobName)
    local id = tonumber(playerId)
    if id then
        pushMedicState(id)
        Svc:onDutyChanged(id)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    local id = tonumber(playerId)
    if not id then
        return
    end
    readyAt[id] = nowMono()
    seenAlive[id] = false
    -- Down when they left: the entry is back, the alive phase of their spawn holds the body at
    -- the saved spot (the connect "dead" phase is ignored by the grace below).
    resumeDown(id, "reconnect")
    -- The connect phases have settled by now; a ready player who is not dead was seen alive.
    SetTimeout(CONNECT_GRACE_SECONDS * 1000, function()
        if readyAt[id] and not Open77.players.isDead(id) then
            seenAlive[id] = true
        end
        -- Back down but no alive phase came after the entry (it can come first): held now.
        if readyAt[id] then
            CreateThread(function() holdIfAlive(id) end)
        end
    end)
    Svc:onReady(id)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = tonumber(playerId)
    if not id then
        return
    end
    seenAlive[id] = nil
    readyAt[id] = nil
    local entry = down[id]
    if entry then
        down[id] = nil
        -- No escape from the down state by leaving: the saved entry stays (written again here, in
        -- case an earlier write failed) and holds the player down when they are back. The live
        -- call closes so no medic flies to an empty spot; a new one goes out on their return.
        saveDown(id, entry)
        TriggerClientEvent("rp_trauma:downClear", -1, id)
        Svc:onUp(id, "left")
        log("player %d disconnected while down%s", id, entry.saved and ": still down when they come back" or "")
    end
    Svc:onDisconnected(id)
    removeAv(id)
    cooldowns[id] = nil
    busy[id] = nil
    stageClear(id)
end)

local SUGGESTIONS = {
    { command = "/soin", help = "Patch up a hurt patient within 5 m (Trauma Team on duty)",
      parameters = { { name = "playerId", help = "Patient id (/id)" } } },
    { command = "/reanimer", help = "Revive a down patient within 5 m (Trauma Team on duty)",
      parameters = { { name = "playerId", help = "Patient id (/id)" } } },
    { command = "/911", help = "Alert Trauma Team and the NCPD with your position",
      parameters = { { name = "message", help = "What is happening" } } },
    { command = "/medic", help = "Medics on duty and their distance" },
    { command = "/respawn", help = "While down: give up and wake up at Vik's clinic (billed by your plan)" },
    { command = "/trauma", help = "Status; av | av off (medic, on the Afterlife street pad); factures | payer",
      parameters = { { name = "action", help = "av, av off, factures, payer" } } },
    { command = "/contrat", help = "Your Trauma Team plan (at a kiosk: the plan menu)" },
    { command = "/tti", help = "Trauma Team: plans | buy | pay | autorenew on|off; medics: calls | take [id] | assist <id> | drop",
      parameters = { { name = "action", help = "plans, buy, pay, autorenew, calls, take, assist, drop" } } },
}

local function publishSuggestions(target)
    local ok, reason = Open77.chat.addSuggestions(target, SUGGESTIONS)
    if not ok then
        log("addSuggestions(%s) failed: %s", tostring(target), tostring(reason))
    end
end

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source < 1 then
        return
    end
    publishSuggestions(source)
end)

-- The Trauma Team service needs the coordinator, rp_inventory (items) and open77_actions
-- (prompts); the down state, the medic acts and the AV run without them.
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log("still waiting for %s (the Trauma Team service starts once it runs)", what)
        end
    end
end

local function bootService()
    waitFor("open77_transactions (ready)", function() return (TraumaLedger.ready()) end)
    local info = TraumaLedger.info()
    log("coordinator ready (store=%s)", tostring(info and info.store))
    waitFor("rp_inventory", function() return TraumaPorts.running("rp_inventory") end)
    for _ = 1, 60 do
        if Svc:defineItems() then break end
        Wait(1000)
    end
    Svc.ready = true
    for _, id in ipairs(Open77.players.all()) do
        CreateThread(function() Svc:onReady(id) end)
    end
    waitFor("open77_actions", function() return TraumaPorts.running("open77_actions") end)
    local targets = Svc:declare()
    log("ready: %d plans, %d kiosk and patient targets, job %s, society %s", #TraumaConfig.planOrder, targets,
        TraumaConfig.job, TraumaConfig.society)
end

AddEventHandler("open77_actions:ready", function()
    if not Svc.actionsReady then return end
    CreateThread(function()
        local targets = Svc:declare()
        log("open77_actions restarted: actions and %d targets declared again", targets)
    end)
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and Svc.ready then
        CreateThread(function() Svc:defineItems() end)
        return
    end
    if name ~= RESOURCE then
        return
    end
    publishSuggestions(-1)
    for _, id in ipairs(Open77.players.all()) do
        pushMedicState(id)
    end
    local queued, why = Open77.database.ready(function()
        Open77.database.update(SQL_CONTRACTS, {}, function()
            Open77.database.update(SQL_BILLS, {}, function() end)
        end)
    end)
    if not queued then
        log("no database (%s): the 1.x import reads the kvp fallback only", tostring(why))
    end
    CreateThread(function()
        local ok, err = pcall(bootService)
        if not ok then
            log("Trauma Team service boot failed: %s", tostring(err))
        end
    end)
    log("started: down=%d s, hospital bill=%d, fees heal=%d revive=%d stabilise=%d evacuate=%d, plans %s, hospital at %s, av=%s",
        Config.downSeconds, TraumaConfig.fees.hospital, TraumaConfig.fees.heal, TraumaConfig.fees.revive,
        TraumaConfig.fees.stabilise, TraumaConfig.fees.evacuate, table.concat(TraumaConfig.planOrder, "/"),
        fmtPos(Config.hospital.respawn), Config.av.record)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then
        return
    end
    -- The resource is going away: nobody stays frozen or posed. A saved body keeps its down
    -- health (no heal: a restart is no way up) and is held down again by the next start; a body
    -- that could not be saved is freed at full health, as before.
    local kept = 0
    for id, entry in pairs(down) do
        if entry.pose then stageRelease(id, entry.pose) end
        Open77.players.setFrozen(id, false)
        if persistEnabled() and entry.saved then
            -- Regeneration stays off: measured live, a stable patient regenerated to full health
            -- in the seconds of a restart. The next start holds them again (and sets it back on
            -- when they get up).
            kept = kept + 1
        else
            Open77.stats.setHealthRegenEnabled(id, true)
            Open77.stats.restoreHealth(id)
        end
        TriggerClientEvent("rp_trauma:hold", id, false, 0)
    end
    down = {}
    for medic in pairs(avByMedic) do
        removeAv(medic)
    end
    Svc:shutdown()
    log("stopped: every held player unfrozen, %d down state(s) kept for the next start", kept)
end)

-- ---------------------------------------------------------------------------
-- Integrator console (restricted: the console, or the ACL command.tti.*)
-- ---------------------------------------------------------------------------

local function reply(source, message)
    print("[rp_trauma] " .. message)
    local pid = TraumaModel.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = "TRAUMA", text = message }) end
end

local function argPlayer(source, value)
    local pid = TraumaModel.playerId(value)
    if not pid or not Open77.players.name(pid) then
        reply(source, "unknown player id " .. tostring(value))
        return nil
    end
    return pid
end

-- trauma.release <playerId>: an operator frees a down player at full health, no bill (console).
RegisterCommand("trauma.release", function(source, args)
    if source ~= 0 then return end
    local id = playerIdArg(args[1])
    if not id or not down[id] then return log("trauma.release: player %s is not down", tostring(args[1])) end
    if Open77.players.isDead(id) then
        local ok, why = Open77.players.revive(id, { health = 1.0, graceMs = Config.reviveGraceMs })
        if not ok then return log("trauma.release %d: revive refused: %s", id, tostring(why)) end
    end
    releaseHold(id, 1.0, "released", nil)
    say(id, "An operator got you back on your feet.")
    log("trauma.release %d: hold released by the console", id)
end, true)

RegisterCommand("tti.status", function(source)
    local s = Svc.stats
    local calls, doubts = 0, 0
    for _ in pairs(Svc.calls) do calls = calls + 1 end
    for _ in pairs(Svc.doubts) do doubts = doubts + 1 end
    reply(source, ("ready=%s actions=%s targets=%s calls=%d doubts=%d | plans=%d renewals=%d stabilised=%d evacuated=%d " ..
        "consents=%d declined=%d invoiced=%d paid=%d unbilled=%d legacy=%d refusals=%d"):format(tostring(Svc.ready),
        tostring(Svc.actionsReady), tostring(Svc.targetCount), calls, doubts, s.plans, s.renewals, s.stabilised,
        s.evacuated, s.consents, s.declined, s.invoiced, s.invoicesPaid, s.unbilled, s.legacy, s.refusals))
    for _, call in ipairs(Svc:openCalls()) do
        reply(source, ("call #%d %s patient %d priority %d state %s stable=%s responder %s"):format(call.id,
            TraumaModel.callTag(call), call.patient, call.priority, call.state, tostring(call.stable),
            tostring(call.responder)))
    end
end, true)

-- tti.setup <playerId>: the trauma job, on duty.
RegisterCommand("tti.setup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local ok, why = TraumaPorts.sync("rp_jobs", "setJob", pid, TraumaConfig.job, 0)
    reply(source, ("setJob %d %s: %s %s"):format(pid, TraumaConfig.job, tostring(ok), tostring(why or "")))
    local on, dwhy = TraumaPorts.sync("rp_jobs", "setDuty", pid, true, { job = TraumaConfig.job })
    reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
end, true)

-- tti.act <medicId> <stabilise|evacuate> <patientId>: the request the body's prompt makes.
RegisterCommand("tti.act", function(source, args)
    local medic = argPlayer(source, args[1])
    local patient = medic and argPlayer(source, args[3])
    if not patient then return end
    local action = TraumaConfig.actions[args[2] or ""]
    if not action or args[2] == "subscribe" then return reply(source, "usage: tti.act <medic> stabilise|evacuate <patient>") end
    local op, why, info = TraumaPorts.actions.request(medic, action.id, "tti_patient_" .. patient)
    reply(source, op and ("%s: op %s state %s"):format(args[2], tostring(op.opId), tostring(op.state))
        or ("%s refused: %s (stage %s)"):format(args[2], tostring(why), tostring(info and info.stage)))
end, true)

-- tti.file <playerId>: the holder's file as the coordinator and the cache see it.
RegisterCommand("tti.file", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local subject = Svc:subjectOf(pid)
        if not subject then return reply(source, "no subject") end
        Svc.plans[subject] = nil
        Svc:loadFile(subject)
        local plan = Svc.plans[subject]
        reply(source, ("player %d subject %s plan=%s until=%s autoRenew=%s owed=%d"):format(pid, subject,
            type(plan) == "table" and plan.tier or "none", type(plan) == "table" and tostring(plan.untilAt) or "-",
            type(plan) == "table" and tostring(plan.autoRenew) or "-", Svc.owed[subject] or 0))
        for _, e in ipairs(Svc.receipts[subject] or {}) do
            reply(source, ("receipt %s %s: %s"):format(e.kind, e.opId, e.text or ""))
        end
    end)
end, true)
