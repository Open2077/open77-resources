-- rp_hud: server half.
--
-- Builds one snapshot per player from the exports of the other RP resources
-- (every call in pcall: none of them is a manifest dependency, because this
-- resource ships a client script) and pushes it to that player's client
-- through the net event rp_hud:state. Pushes are throttled to one every
-- RpHudConfig.minPushIntervalMs per player (4 per second by default): a burst
-- of events is coalesced into a single snapshot sent when the window closes.
--
-- Nothing is decided or persisted here: the HUD shows what the other
-- resources own. There is no SQL table.

local Config = RpHudConfig
local RESOURCE = GetCurrentResourceName()

local connected = {}   -- playerId (number) -> true once the player is ready or asked for a snapshot
local throttle = {}    -- playerId (number) -> { lastAt = seconds | nil, pending = boolean }
local pendingSeen = {} -- playerId (number) -> wallet pending fingerprint last pushed (B7 pending watch)
local depSet = {}      -- resource name -> true for the resources whose events feed the panel
for _, name in ipairs(Config.dependencies) do depSet[name] = true end

local function now()
    return Open77.time.monotonic()
end

local function log(fmt, ...)
    print(("[rp_hud] " .. fmt):format(...))
end

-- Runs one export call and swallows the raise a missing resource or export
-- produces. Returns the export's own results, or nil, "unavailable".
local function safe(fn)
    local ok, a, b = pcall(fn)
    if ok then return a, b end
    return nil, "unavailable"
end

local function countConnected()
    local n = 0
    for _ in pairs(connected) do n = n + 1 end
    return n
end

-- --------------------------------------------------------------------------
-- Snapshot
-- --------------------------------------------------------------------------

-- The pending part of one wallet as the page draws it, or nil when nothing is unsettled.
local function pendingView(w)
    if type(w) ~= "table" or (tonumber(w.ops) or 0) == 0 then return nil end
    return {
        incoming = math.floor(tonumber(w.incoming) or 0),       -- not in the balance yet
        outgoing = math.floor(tonumber(w.outgoing) or 0),       -- already subtracted, unconfirmed
        unconfirmed = math.floor(tonumber(w.unconfirmed) or 0), -- already added, unconfirmed
        inDoubt = math.floor(tonumber(w.inDoubt) or 0),
    }
end

-- B3 wallet (rp_economy 2.x walletStatus): balances plus what is still unsettled, and an
-- explicit "unknown" instead of the 0 getBalance answers for a wallet that is not loaded.
-- Returns false when the export is missing (rp_economy 1.x or 2.0 without it): the caller then
-- falls back to getBalance / rp_bank:getAccount.
local function readWallet(playerId, s)
    local status = safe(function()
        return exports.rp_economy:walletStatus(playerId, { minAgeSeconds = (Config.pendingShowAfterMs or 0) / 1000 })
    end)
    if type(status) ~= "table" then return false end
    if status.loaded ~= true then
        s.wallet = { state = tostring(status.reason or "not_loaded") }
        return true
    end
    local cash, bank = status.cash or {}, status.bank or {}
    if type(cash.balance) == "number" then s.cash = math.floor(cash.balance) end
    if type(bank.balance) == "number" then s.account = math.floor(bank.balance) end
    s.wallet = {
        state = status.reason and tostring(status.reason) or "ok",   -- "store_unavailable": cached values
        cash = pendingView(cash),
        account = pendingView(bank),
    }
    return true
end

-- B4 jobs (rp_jobs 2.1 summary): job, grade and duty in one read, and the reason when the file
-- is not available (store offline, still loading) instead of "unemployed". Returns false when
-- the export is missing: the caller falls back to getJob / getGrade / onDuty.
local function readJob(playerId, s)
    local ok, summary, why = pcall(function() return exports.rp_jobs:summary(playerId) end)
    if not ok then return false end
    if type(summary) ~= "table" then
        s.jobState = tostring(why or "unavailable")
        return true
    end
    if type(summary.job) == "string" and summary.job ~= "" then
        s.job = {
            name = summary.job,
            label = (type(summary.label) == "string" and summary.label) or Config.jobLabels[summary.job] or summary.job:upper(),
            grade = type(summary.grade) == "number" and summary.grade or nil,
            gradeLabel = type(summary.gradeLabel) == "string" and summary.gradeLabel or nil,
            onDuty = summary.onDuty == true,
        }
    end
    s.jobState = "ok"
    return true
end

-- Everything the panel shows, read fresh from the owning resources. A field
-- is absent (nil) when its resource is not running, so the page draws "--"
-- instead of a wrong number.
local function snapshot(playerId)
    local s = { id = playerId, at = math.floor(now() * 1000) }

    s.name = Open77.players.name(playerId) or ("citizen " .. tostring(playerId))

    local fullName = safe(function() return exports.rp_identity:fullName(playerId) end)
    if type(fullName) == "string" and fullName ~= "" then
        s.rpName = fullName
    end

    if not readWallet(playerId, s) then
        local cash = safe(function() return exports.rp_economy:getBalance(playerId) end)
        if type(cash) == "number" then
            s.cash = math.floor(cash)
        end

        local account = safe(function() return exports.rp_bank:getAccount(playerId) end)
        if type(account) == "table" and type(account.balance) == "number" then
            s.account = math.floor(account.balance)
        end
    end

    local job = nil
    if not readJob(playerId, s) then
        job = safe(function() return exports.rp_jobs:getJob(playerId) end)
    end
    if type(job) == "string" and job ~= "" then
        local grade = safe(function() return exports.rp_jobs:getGrade(playerId) end)
        local onDuty = safe(function() return exports.rp_jobs:onDuty(playerId) end)
        s.job = {
            name = job,
            label = Config.jobLabels[job] or job:upper(),
            grade = type(grade) == "table" and tonumber(grade.level) or nil,
            gradeLabel = type(grade) == "table" and grade.label or nil,
            onDuty = onDuty == true,
        }
    end

    local needs = safe(function() return exports.rp_needs:get(playerId) end)
    if type(needs) == "table" then
        s.needs = {
            hunger = tonumber(needs.hunger),
            thirst = tonumber(needs.thirst),
            fatigue = tonumber(needs.fatigue),
        }
    end

    local zone = safe(function() return exports.rp_zones:zoneOf(playerId) end)
    if type(zone) == "table" then
        s.zone = { name = zone.name, label = zone.label or zone.name, kind = zone.kind }
    end

    return s
end

-- --------------------------------------------------------------------------
-- Throttled push
-- --------------------------------------------------------------------------

local function send(playerId)
    local t = throttle[playerId]
    if t then
        t.lastAt = now()
        t.pending = false
    end
    if not connected[playerId] then return end
    local ok, reason = TriggerClientEvent("rp_hud:state", playerId, snapshot(playerId))
    if ok == false then
        log("push to player %d refused: %s", playerId, tostring(reason))
    end
end

-- Schedules a snapshot for one player. Immediate when the last one is older
-- than the window; otherwise one flush is armed at the end of the window and
-- every further request until then rides on it.
local function push(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId <= 0 or not connected[playerId] then return end

    local t = throttle[playerId]
    if not t then
        t = { lastAt = nil, pending = false }
        throttle[playerId] = t
    end
    if t.pending then return end

    local elapsedMs = t.lastAt and ((now() - t.lastAt) * 1000) or math.huge
    if elapsedMs >= Config.minPushIntervalMs then
        send(playerId)
        return
    end

    t.pending = true
    SetTimeout(math.max(1, math.ceil(Config.minPushIntervalMs - elapsedMs)), function()
        send(playerId)
    end)
end

local function pushEveryone()
    for playerId in pairs(connected) do
        push(playerId)
    end
end

-- --------------------------------------------------------------------------
-- Consumed events (host-wide bus). Every one of them names the player as its
-- first argument; rp_bank:changed passes nil for an offline recipient or a
-- society, and those have no panel to refresh.
-- --------------------------------------------------------------------------

AddEventHandler("rp_economy:changed", function(playerId) push(playerId) end)
AddEventHandler("rp_bank:changed", function(playerId)
    if playerId ~= nil then push(playerId) end
end)
AddEventHandler("rp_jobs:changed", function(playerId) push(playerId) end)
AddEventHandler("rp_jobs:duty", function(playerId) push(playerId) end)
AddEventHandler("rp_needs:changed", function(playerId) push(playerId) end)
AddEventHandler("rp_zones:entered", function(playerId) push(playerId) end)
AddEventHandler("rp_zones:left", function(playerId) push(playerId) end)
AddEventHandler("rp_identity:changed", function(playerId) push(playerId) end)
-- B3 / B4 events: every cash or bank change of a connected player (a revert included), and every
-- job, grade or duty change (the work epoch moves on each of them).
AddEventHandler("rp_economy:walletChanged", function(kind, playerId)
    if (kind == "cash" or kind == "bank") and playerId ~= nil then push(playerId) end
end)
AddEventHandler("rp_jobs:workEpoch", function(playerId) push(playerId) end)
-- The wallet store went down or came back: every panel's wallet state changed at once.
AddEventHandler("rp_economy:healthChanged", function() pushEveryone() end)

-- --------------------------------------------------------------------------
-- Player lifecycle
-- --------------------------------------------------------------------------

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    connected[playerId] = true
    push(playerId)
    -- The other resources load their rows on the same event, asynchronously:
    -- a second snapshot a few seconds later catches what the first one missed.
    if Config.joinRepushMs and Config.joinRepushMs > 0 then
        SetTimeout(Config.joinRepushMs, function() push(playerId) end)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    connected[playerId] = nil
    throttle[playerId] = nil
    pendingSeen[playerId] = nil
end)

-- The client asks for a snapshot when its page has loaded (and on
-- /interface refresh). `source` is the authenticated sender; a bus event of
-- the same name would arrive without one and is ignored.
RegisterNetEvent("rp_hud:request", function()
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    connected[playerId] = true
    push(playerId)
end)

-- --------------------------------------------------------------------------
-- Resource lifecycle
-- --------------------------------------------------------------------------

AddEventHandler("onResourceStart", function(name)
    if name == RESOURCE then
        for _, playerId in ipairs(Open77.players.all()) do
            connected[playerId] = true
        end
        log("started: %d player(s) online, one snapshot per %d ms per player, keepalive every %d ms",
            countConnected(), Config.minPushIntervalMs, Config.refreshMs or 0)
        pushEveryone()
        return
    end
    if depSet[name] then
        -- The resource came back with an empty cache; let it reload, then refresh everyone.
        SetTimeout(Config.dependencyRepushMs or 4000, function()
            log("%s restarted, refreshing %d panel(s)", name, countConnected())
            pushEveryone()
        end)
    end
end)

-- Pending watch (B7): an atomic credit in flight raises no event until it settles, so ask
-- rp_economy once per poll which players have unsettled operations and re-push those whose set
-- changed (appeared, changed, or settled). A missing export (older rp_economy) disables nothing
-- else: the keepalive still refreshes everyone.
if Config.pendingPollMs and Config.pendingPollMs > 0 then
    CreateThread(function()
        while true do
            Wait(Config.pendingPollMs)
            local now_ = safe(function()
                return exports.rp_economy:pendingPlayers({ minAgeSeconds = (Config.pendingShowAfterMs or 0) / 1000 })
            end)
            if type(now_) == "table" then
                for playerId, fingerprint in pairs(now_) do
                    if connected[playerId] and pendingSeen[playerId] ~= fingerprint then
                        pendingSeen[playerId] = fingerprint
                        push(playerId)
                    end
                end
                for playerId in pairs(pendingSeen) do
                    if now_[playerId] == nil then
                        pendingSeen[playerId] = nil
                        push(playerId)
                    end
                end
            end
        end
    end)
end

-- Keepalive: a slow periodic snapshot so a value that changed without an
-- event (needs decay between rp_needs ticks, a dependency that was down)
-- reaches the panel within refreshMs.
if Config.refreshMs and Config.refreshMs > 0 then
    CreateThread(function()
        while true do
            Wait(Config.refreshMs)
            pushEveryone()
        end
    end)
end
