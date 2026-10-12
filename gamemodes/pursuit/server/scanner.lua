-- Pursuit -- the scanner ping.
--
-- Design §5.5 items 1-3, and the mechanic the whole mode turns on. Without it
-- Pursuit is a straight-line speed contest: the faster car wins, every time,
-- and the map does not matter. With it, the cop is chasing a memory.
--
-- The rule, in one sentence: the cop never learns where the runner IS, only
-- where he WAS the last time the scanner swept.
--
-- Three parts, and all three have to exist or the mechanic is a handicap
-- rather than a trade:
--
--   1. Every `pingIntervalSeconds` the server samples the runner's position and
--      pushes THAT SAMPLE to the cop. The cop's blip jumps there and then goes
--      stale until the next sweep. The blip is POSITION-attached, never
--      entity-attached -- an entity-attached blip would track the runner live
--      and delete the entire design.
--   2. While separation is inside `bustDistance × pressureMultiplier`, the
--      interval shortens by `pressureIntervalFactor`. Closing distance buys
--      information, which is what makes pressure worth applying rather than
--      just a step towards a bust. It never shortens past
--      `minIntervalSeconds`: a fix the cop can drive straight at is not a
--      reward for pressure, it is the end of the mechanic.
--   3. The runner FEELS every sweep: a VFX pulse, an SFX cue and a
--      notification. He knows he has been located and can react. A one-sided
--      version of this mechanic is just a debuff on the cop.
--
-- The server samples and decides; the client draws. `Open77.blips`,
-- `Open77.vfx` and `Open77.sfx` are all client-side APIs (`ui.vanilla.map` and
-- `world.effects`), so this file's whole output is two net events.

local Config = PursuitConfig

local function log(text) Pursuit.log(text) end

-- Per-match scanner state lives on `match.scan`. Fields:
--   lastPingAtMs   when the last successful sweep landed (nil until the first)
--   lastKnown      { x, y, z } -- the sample that was pushed, never a fresh read
--   pings          how many sweeps have landed
--   pressure       whether the last sweep was a pressure (halved) one
--   releasedSeen   the head-start edge, so the opening ping fires exactly once
local function stateOf(match)
    local scan = match.scan
    if scan == nil then
        scan = { pings = 0, pressure = false, releasedSeen = false }
        match.scan = scan
    end
    return scan
end

-- The floor, applied to every interval this file ever returns.
--
-- A separate function because the floor is a RULE, not an implementation
-- detail of the pressure branch: whatever combination of base interval and
-- pressure factor a server owner configures, a fix younger than this is a
-- position rather than a memory, and the mechanic is gone. See
-- `minIntervalSeconds` in shared/config.lua for the measurement behind it.
local function floored(ms)
    local floor = (Config.scanner.minIntervalSeconds or 6.0) * 1000
    if ms < floor then return floor end
    return ms
end

-- The interval to use RIGHT NOW, given the current separation.
--
-- Recomputed every tick rather than fixed at the moment of the last sweep, and
-- that is a deliberate design choice, not an implementation detail: it means
-- closing the distance shortens the wait the cop is already serving, instead of
-- only affecting the sweep after next. Pressure has to pay immediately or it
-- does not read as a reward.
local function intervalMs(match, sep)
    local base = (Config.scanner.pingIntervalSeconds or 12.0) * 1000
    if sep == nil then return floored(base) end
    local t = Pursuit.tuning(match)
    local band = t.bustDistance * (Config.scanner.pressureMultiplier or 3.0)
    if sep <= band then
        return floored(base * (Config.scanner.pressureIntervalFactor or 0.6)), true
    end
    return floored(base), false
end

-- One sweep.
--
-- Returns true when a sample was actually taken and pushed. An unreadable
-- runner does NOT consume the sweep: the cop is owed a fix, and giving him a
-- stale one -- or a silent skipped cycle -- would both be lies of a different
-- kind. The tick simply tries again 200 ms later.
local function sweep(match, now, sep, pressure)
    local scan = stateOf(match)
    if match.runnerId == nil or match.copId == nil then return false end

    local position = Open77.players.position(match.runnerId)
    if position == nil then return false end
    -- Mid-transfer the runner still reports the old dimension. A fix taken
    -- across buckets is a fix on a different world.
    if position.bucket ~= match.bucket then return false end

    scan.lastKnown = { x = position.x, y = position.y, z = position.z }
    scan.lastPingAtMs = now
    scan.pings = scan.pings + 1
    scan.pressure = pressure == true

    -- The cop half: a position, and nothing else. No name, no heading, no
    -- velocity -- every extra field would be information the design says he has
    -- to earn by driving.
    TriggerClientEvent("pursuit:scannerPing", match.copId, {
        matchId = match.id,
        position = scan.lastKnown,
        sequence = scan.pings,
        pressure = scan.pressure,
        -- So the client can size its own staleness fade without a second round
        -- trip, and so a dropped packet does not leave a blip claiming to be
        -- fresher than it is.
        nextInMs = math.floor(intervalMs(match, sep)),
    })

    -- The runner half. Item 3: the mechanic is two-sided or it is a handicap.
    local runner = Config.scanner.runner or {}
    TriggerClientEvent("pursuit:scanned", match.runnerId, {
        matchId = match.id,
        sequence = scan.pings,
        pressure = scan.pressure,
        vfx = runner.vfx,
        vfxDurationSeconds = runner.vfxDurationSeconds,
        sfx = runner.sfx,
        sfxDurationSeconds = runner.sfxDurationSeconds,
    })
    if runner.notify ~= false then
        Pursuit.notify(match.runnerId,
            scan.pressure and "error" or "warning",
            runner.message or "Scanner sweep — you have been located.",
            runner.notifyDurationMs or 2500)
    end

    if Config.debug.verboseScanner then
        log(("match %d scan #%d%s at %.1f,%.1f,%.1f (sep=%s, next in %.1fs)"):format(
            match.id, scan.pings, scan.pressure and " PRESSURE" or "",
            scan.lastKnown.x, scan.lastKnown.y, scan.lastKnown.z,
            sep and ("%.0fm"):format(sep) or "unreadable",
            intervalMs(match, sep) / 1000))
    end
    return true
end

-- --------------------------------------------------------------------- hook --

Pursuit.onMatch("tick", function(match, now)
    if not Config.scanner.enabled then return end
    local scan = stateOf(match)

    -- Nothing sweeps while the cop is held. The head start is the runner's, and
    -- handing the cop a fix during it would spend it for him.
    if not match.copReleased then return end

    local sep = match.separation

    -- The opening fix, on the release edge. Detected here rather than in
    -- `releaseCop` so the scanner owns its own rule and match.lua does not have
    -- to know one exists.
    if not scan.releasedSeen then
        scan.releasedSeen = true
        if Config.scanner.pingOnRelease ~= false then
            sweep(match, now, sep, false)
            return
        end
    end

    local interval, pressure = intervalMs(match, sep)
    if scan.lastPingAtMs == nil or (now - scan.lastPingAtMs) >= interval then
        sweep(match, now, sep, pressure)
    end
end)

-- Put the cop's blip back after his client was republished, WITHOUT sweeping.
--
-- A resource republish destroys the client VM and the blip with it. Taking a
-- fresh sweep to replace it would be the easy fix and it would quietly break
-- the mechanic: the cop would be rewarded with live information every time a
-- server owner saved a file. So this re-sends the sample that was already
-- taken, leaves `lastPingAtMs` alone, and lets the HUD's own `scannerAgeMs`
-- keep reporting exactly how stale it is.
--
-- Returns false rather than raising for every "nothing to restore" case: no
-- scanner, not the cop, no fix taken yet. Before the first sweep the cop is
-- supposed to have no blip at all.
function Pursuit.repushScannerTo(match, playerId)
    if not Config.scanner.enabled then return false end
    if playerId == nil or playerId ~= match.copId then return false end
    local scan = match.scan
    if scan == nil or scan.lastKnown == nil or scan.lastPingAtMs == nil then return false end

    local now = Pursuit.nowMs()
    local interval = intervalMs(match, match.separation)
    TriggerClientEvent("pursuit:scannerPing", playerId, {
        matchId = match.id,
        position = scan.lastKnown,
        sequence = scan.pings,
        pressure = scan.pressure,
        nextInMs = math.floor(math.max(0, scan.lastPingAtMs + interval - now)),
    })
    log(("match %d: scanner blip restored for cop %d at fix #%d (%.1fs old)"):format(
        match.id, playerId, scan.pings, (now - scan.lastPingAtMs) / 1000))
    return true
end

Pursuit.onMatch("resolved", function(match)
    if match.copId ~= nil then
        -- Tell the client to drop the blip. The client also clears on the
        -- resolved matchState it is about to receive, but a mode whose whole
        -- point is a marker that lies must not leave one behind when it stops
        -- lying.
        TriggerClientEvent("pursuit:scannerClear", match.copId, { matchId = match.id })
    end
    match.scan = nil
end)

-- ------------------------------------------------------ the HUD contribution --

-- Installed for match.lua, which folds it into the per-player `matchState`
-- payload. Optional on purpose: `matchStatePayload` checks for nil, so a server
-- running with `scanner.enabled = false` simply omits the key and the HUD hides
-- the readout.
--
-- Returns nil, never 0, before the first sweep. "0.0s ago" would tell the cop
-- his blip is live, which is the one thing the mechanic exists to deny him.
function Pursuit.scannerAgeMs(match, now)
    local scan = match.scan
    if scan == nil or scan.lastPingAtMs == nil then return nil end
    return math.max(0, now - scan.lastPingAtMs)
end

Pursuit.describe = Pursuit.describe or {}
Pursuit.describe.scanner = function(match, now)
    if not Config.scanner.enabled then return "disabled" end
    local scan = match.scan
    if scan == nil or scan.lastPingAtMs == nil then
        return ("no fix yet (released=%s)"):format(tostring(match.copReleased == true))
    end
    local interval = intervalMs(match, match.separation)
    return ("pings=%d age=%.1fs next=%.1fs%s lastKnown=%.1f,%.1f,%.1f"):format(
        scan.pings, (now - scan.lastPingAtMs) / 1000,
        math.max(0, (scan.lastPingAtMs + interval - now)) / 1000,
        scan.pressure and " PRESSURE" or "",
        scan.lastKnown.x, scan.lastKnown.y, scan.lastKnown.z)
end

-- ----------------------------------------------------------------- commands --

-- Force a sweep now instead of waiting out the interval.
--
-- The single most useful affordance in this file for the next session: it turns
-- "watch a blip for eight seconds and judge whether it is stale" into one
-- command and one screenshot. The sweep taken is the SAME code path as a
-- scheduled one, so nothing is weakened by using it.
RegisterCommand("pursuit.ping", function(source, args, raw)
    local wanted = tonumber(args and args[1])
    local swept, skipped = 0, 0
    for matchId, match in pairs(Pursuit.matches) do
        if (wanted == nil or wanted == matchId) and match.state == "active" then
            if sweep(match, Pursuit.nowMs(), match.separation, false) then
                swept = swept + 1
            else
                skipped = skipped + 1
                Pursuit.output(source, raw, false,
                    ("match %d: no fix taken -- runner position unreadable or out of bucket"):format(
                        matchId))
            end
        end
    end
    Pursuit.output(source, raw, swept > 0,
        ("forced %d sweep(s), %d refused; usage: pursuit.ping [matchId]"):format(
            swept, skipped))
end, false)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    if not Config.scanner.enabled then
        return log("scanner DISABLED in config")
    end
    -- The pressure figure is printed THROUGH `floored`, not as the raw
    -- multiplication: if a config change ever drives it into the floor, this
    -- line has to say what the mode will actually do, not what the arithmetic
    -- suggests. A start-up line that disagrees with the running rule is worse
    -- than no line at all.
    local base = (Config.scanner.pingIntervalSeconds or 12.0) * 1000
    local pressed = floored(base * (Config.scanner.pressureIntervalFactor or 0.6))
    log(("scanner ready -- %.1fs interval, %.1fs inside bustDistance x%.1f, floor %.1fs; HUD marks a fix stale at 6.0s, blip icon ages with it"):format(
        base / 1000, pressed / 1000,
        Config.scanner.pressureMultiplier,
        (Config.scanner.minIntervalSeconds or 6.0)))
end)
