-- =============================================================================
-- open77_avdoor -- server/boot.lua
-- =============================================================================
-- The exports other server resources use, and the start and the stop. Loaded
-- last, so every part of the server half (main, watch, pad, landing, callout)
-- is in place before anything runs.
--
-- EVERY EXPORT RETURNS VALUES, NEVER FUNCTIONS: arguments and results are
-- copied between resources. `landingSite` WAITS on the games, so it must be
-- called through `Open77.exports.call('open77_avdoor', 'landingSite', ...)`
-- and awaited; the synchronous `exports.open77_avdoor:landingSite(...)`
-- spelling fails a waiting callee. Everything else answers at once and either
-- spelling works.
--
-- WHAT A RESOURCE PUTS UP, IT TAKES DOWN WHEN IT STOPS: a rule (`allow`), a
-- landing call (`callout`) and a pad (`pad`) remember who asked, and that
-- resource's stop takes them away.
-- =============================================================================

local M = AvDoor

local RESOURCE = GetCurrentResourceName()

--- The resource that called the export running now, or nil.
local function caller()
    if type(GetInvokingResource) ~= 'function' then return nil end
    local name = GetInvokingResource()
    if type(name) == 'string' and name ~= '' then return name end
    return nil
end

--- A player id from another resource: a whole number of 1 or more, or nil.
local function playerArg(value)
    local id = tonumber(value)
    if id == nil or id < 1 or id ~= math.floor(id) then return nil end
    return math.tointeger(id) or id
end

--- A hull id from another resource: a number or a decimal string, or nil.
local function hullArg(value)
    if type(value) == 'number' or type(value) == 'string' then
        if #tostring(value) <= 24 then return value end
    end
    return nil
end

--- A short text from another resource, for the journal.
local function textArg(value, length)
    if type(value) ~= 'string' or value == '' then return nil end
    return value:sub(1, length or 80)
end

-- ── the rules ────────────────────────────────────────────────────────────────

--- Puts a rule on a hull: `{ pilots = { playerId, ... } | nil, passengers =
--- false?, reason = 'not_crew'? }`. Absent `pilots`, anybody may fly it (the
--- lock is not asked). Answers whether it was taken.
exports('allow', function(vehicleId, rule)
    local id = hullArg(vehicleId)
    if id == nil or type(rule) ~= 'table' then return false end
    return M.Allow(id, rule)
end)

--- Takes a hull's rule away. Answers whether it had one.
exports('forget', function(vehicleId)
    local id = hullArg(vehicleId)
    if id == nil then return false end
    return M.Forget(id)
end)

--- What the door would say to this player about this hull right now:
--- `{ id, role, seat }`, or nil and the refusal code.
exports('verdict', function(playerId, vehicleId)
    local player, id = playerArg(playerId), hullArg(vehicleId)
    if player == nil then return nil, 'no_player' end
    if id == nil then return nil, 'no_aircraft' end
    local verdict, why = M.Verdict(player, id)
    if verdict == nil then return nil, why end
    return { id = M.KeyOf(verdict.id), role = verdict.role, seat = verdict.seat }
end)

--- Seats a player through the door, judged in full: `true, { id, role, seat }`
--- or `false, reason, detail`. The seat's door opens for the boarding hold.
exports('board', function(playerId, vehicleId)
    local player, id = playerArg(playerId), hullArg(vehicleId)
    if player == nil then return false, 'no_player' end
    if id == nil then return false, 'no_aircraft' end
    local boarded = M.Board(player, id, { door = true })
    if boarded.ok ~= true then return false, boarded.error, boarded.detail end
    return true, { id = M.KeyOf(boarded.value.id), role = boarded.value.role, seat = boarded.value.seat }
end)

--- A hull was created just now: nobody boards it through the door before it
--- settled. Answers how long that is, in milliseconds. (Every aircraft created
--- while this resource runs is marked on its own; this is for a hull a
--- resource seats its pilot in itself, to ask `settleLeft` before it does.)
exports('fresh', function(vehicleId)
    local id = hullArg(vehicleId)
    if id == nil then return 0 end
    return M.Fresh(id)
end)

--- Milliseconds before a body should be seated in the hull, 0 when it may now.
exports('settleLeft', function(vehicleId)
    local id = hullArg(vehicleId)
    if id == nil then return 0 end
    return M.SettleLeft(id)
end)

-- ── the landing call ─────────────────────────────────────────────────────────

--- Starts the landing call on a hull (`CALLOUTS`): `kind` is a
--- `CALLOUTS.KINDS` name, or nil for the one its record makes. `from` is
--- `{ x, y, z, bucket }` for a hull the caller flies itself: the caller then
--- moves the call with `follow`, pose by pose. Answers `true` or `nil, reason`.
exports('callout', function(vehicleId, kind, why, from)
    local id = hullArg(vehicleId)
    if id == nil then return nil, 'no_hull' end
    if kind ~= nil and type(kind) ~= 'string' then return nil, 'bad_kind' end
    return M.Callout.Start(id, kind, textArg(why), type(from) == 'table' and from or nil, caller())
end)

--- Moves a call started with `from` to where its caller just put the hull.
exports('follow', function(vehicleId, at)
    local id = hullArg(vehicleId)
    if id == nil or type(at) ~= 'table' then return false end
    return M.Callout.Follow(id, at)
end)

--- Ends a hull's landing call: it fades out over `FADE_MS`.
exports('hush', function(vehicleId, why)
    local id = hullArg(vehicleId)
    if id == nil then return false end
    return M.Callout.Stop(id, textArg(why) or 'hushed')
end)

-- ── where to come down ───────────────────────────────────────────────────────

--- Where an AV the caller flies may come down near a point: ground, at the
--- point's level, flat under the hull, open to the sky (`LANDING`). WAITS on
--- the games: call it through `Open77.exports.call` and await it.
-- @return table|nil `{ x, y, z, bearing, distance, probes, observer, ms }`
-- @return string|nil why not
exports('landingSite', function(target, options)
    if type(target) ~= 'table' then return nil, 'no_target' end
    local started = M.Now()
    local site, why = M.Landing.Find(target, type(options) == 'table' and options or nil)
    local asker = caller() or '?'
    if site ~= nil then
        Open77.log.info(('landing site for %s: %.1f, %.1f, %.1f (%.0f m on %.0f deg), %d probe(s) '
            .. 'in %d ms, measured by player %s'):format(asker, site.x, site.y, site.z, site.distance, site.bearing,
            site.probes, M.Now() - started, tostring(site.observer or 'the platform\'s nearest')))
    else
        Open77.log.info(('no landing site for %s near %.1f, %.1f, %.1f: %s (%d ms)')
            :format(asker, tonumber(target.x) or 0, tonumber(target.y) or 0, tonumber(target.z) or 0,
                tostring(why), M.Now() - started))
    end
    return site, why
end)

--- Whether `landingSite` can be asked at all on this host.
exports('canSurvey', function()
    return M.Landing.Available()
end)

--- How long `landingSite` may take, in milliseconds: `BUDGET_SECONDS`, and the
--- one probe that may still be out when it runs out (`PROBE_MS`).
exports('surveyBudgetMs', function()
    local cfg = M.Landing.Settings()
    return cfg ~= nil and (cfg.budgetMs + cfg.probeMs) or 0
end)

-- ── the landing pad ──────────────────────────────────────────────────────────

--- Puts the landing pad under a hull the caller flies (`PADS`): the red ring
--- the client draws under an AV it flies itself. Answers `nil, 'platform'` for
--- a record the client pads on its own.
exports('pad', function(vehicleId, options)
    local id = hullArg(vehicleId)
    if id == nil then return nil, 'no_hull' end
    local opts = type(options) == 'table' and options or {}
    return M.Pads.Start(id, {
        record = textArg(opts.record, 120), bucket = tonumber(opts.bucket), why = textArg(opts.why),
        owner = caller(),
    })
end)

--- Takes a hull's landing pad away.
exports('unpad', function(vehicleId, why)
    local id = hullArg(vehicleId)
    if id == nil then return false end
    return M.Pads.Stop(id, textArg(why) or 'taken away')
end)

--- What this resource holds: doors open, rules, players at a door, hulls
--- settling, the watch, the pads and the calls.
exports('status', function()
    return M.Status()
end)

-- ── the pad snap ─────────────────────────────────────────────────────────────

--- The animated boarding (1.7.0): the steps asked, played, seated, the plain
--- boardings and why, the steps under way now.
exports('enterStatus', function()
    return M.EnterServer ~= nil and M.EnterServer.Status() or nil
end)

--- The pad snap: how many pads it knows, what it flies now, what it did.
exports('snapStatus', function()
    return M.Snap ~= nil and M.Snap.Status() or nil
end)

--- Lets a hull the snap flies go now, its freeze off. Answers whether it was flying one.
exports('snapCancel', function(vehicleId, why)
    local id = hullArg(vehicleId)
    if id == nil or M.Snap == nil then return false end
    return M.Snap.Cancel(id, textArg(why) or ('cancelled by ' .. tostring(caller() or 'a resource')))
end)

--- The AV pads nearest to a point, `{ { id, kind, conf, x, y, z, yaw, half, metres }, ... }` (at most 20).
exports('padsNear', function(x, y, n)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil or M.Snap == nil then return {} end
    local out = {}
    for _, near in ipairs(M.Snap.Nearest(x, y, math.min(20, math.max(1, math.floor(tonumber(n) or 5))))) do
        local pad = near.pad
        out[#out + 1] = { id = pad.id, kind = pad.kind, conf = pad.conf, x = pad.x, y = pad.y, z = pad.z,
            yaw = pad.yaw, half = pad.half, metres = near.metres }
    end
    return out
end)

-- ── the start and the stop ───────────────────────────────────────────────────

AddEventHandler('onResourceStop', function(name)
    if name == RESOURCE then
        M.Stop()
        Open77.log.info('stopped: every card, door, pad and landing call taken down')
        return
    end
    -- Another resource stopped: what it put up comes down with it.
    local rules = M.ForgetOwnedBy(name)
    local calls = M.Callout.KillOwnedBy(name, name .. ' stopped')
    local pads = M.Pads.StopOwnedBy(name, name .. ' stopped')
    if rules + calls + pads > 0 then
        Open77.log.info(('%s stopped: %d rule(s), %d landing call(s) and %d pad(s) it put up '
            .. 'taken away'):format(name, rules, calls, pads))
    end
end)

-- ONE DOOR PER SERVER. XyberRP's opx_infinity carries the modules this resource
-- was ported from; with both running, every aircraft has two cards, two exit
-- guards and two landing calls. Said once, when either one starts after the
-- other.
local function twin(name)
    if name ~= 'opx_infinity' then return end
    Open77.log.warn('opx_infinity runs on this server too: if its avdoor module is switched on, every aircraft '
        .. 'answers two doors -- switch one of them off (opx_infinity\'s avdoor module, or this resource)')
end

AddEventHandler('onResourceStart', function(name) twin(name) end)
if type(GetResourceState) == 'function' then
    local read, state = pcall(GetResourceState, 'opx_infinity')
    if read and state == 'started' then twin('opx_infinity') end
end

M.Start()
