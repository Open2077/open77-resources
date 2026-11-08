-- =============================================================================
-- open77_avdoor -- client/standin.lua
-- =============================================================================
-- THE STAND-IN, MADE AHEAD (1.7.5). The step up (client/enter.lua) and the
-- step out (client/walkout.lua) play on the platform's third-person stand-in,
-- the body Open77 draws for this player in third person. The first third
-- person of a game session has to make that body -- spawned beside the player,
-- dressed, its equipment worn, driven onto the player while hidden -- and the
-- platform gives that 3 s (`prepareTimeoutSeconds`, PerspectiveArbiter.hpp):
-- past it, it restores first person (`prepare_timeout`) and asks again 3 s
-- later (`retryCooldown`). On the laptop at 4 to 18 frames a second the first
-- boarding of a session went exactly that way (Staging, 2026-10-29, 07:04:48
-- UTC): third person asked at the key, first person restored 3.6 s later, third
-- person shown at 7.3 s -- after 1.7.4 had given up at 7.0 s and seated the
-- body plainly. The second boarding, its stand-in made by the exit before it,
-- drew third person 1.9 s after the key and played the step.
--
-- Once made, the stand-in is kept for the session: a commit to first person
-- only parks it (`SelfView::Suspend(true)`; nothing in the arbiter tears it
-- down), and it follows the player, hidden, until the next third person. So it
-- is made AHEAD, out of sight. The arbiter builds a body behind the first-person
-- view (`Preparing`, then `HoldingCurrent`: the build parked, first person
-- still on screen), and a request let go while it is still there changes
-- nothing on screen -- "the key pressed twice before the stand-in was ready",
-- since Stable 157 -- while the body is re-parked, not torn down, and goes on
-- being built. This half asks for third person once, a few seconds after the
-- server has heard it (`STAND_IN.AFTER_MS`, or as soon as a door card comes
-- up), and lets it go the frame the arbiter answers `holding_current`. The
-- first boarding then finds the stand-in made.
--
-- Never when this screen has drawn the stand-in already this session (the
-- arbiter answered `body = proxy`: the player's own third person, a boarding,
-- an exit), nor while the body sits in a vehicle, is down, boards or steps
-- out, nor while another resource holds the view or the world decides it (a
-- vehicle, a scene, a menu). A boarding or an exit that starts while a try is
-- in flight takes the view over (`Yield`): its own request stands, and this
-- one is never let go under it. A try with no `holding_current` within
-- `LET_GO_BY_MS` is let go all the same and made again `RETRY_MS` later, at
-- most `TRIES` times a session. A client that shows third person after the
-- request was let go (an older one: it plays every switch out once asked) is
-- said once and not tried again. Every try is a few lines of the client log,
-- with every answer the arbiter gave through it.
-- =============================================================================

local M = AvDoor
local S = {}
M.StandIn = S

-- Refusals that do not pass (the server's policy, the manifest, the host).
local PERMANENT = {
    refused_by_policy = true,
    ['permission_denied:perspective.policy'] = true,
    perspective_unavailable_on_this_host = true,
}

-- The arbiter's reasons for a first person the player chose, or nobody: the
-- only ones a try starts from. Every other reason is a world state (a vehicle,
-- a scene, the pre-game UI, death, a slide), a fault, or a lock.
local CHOSEN = { player_preference = true, default_policy = true, none = true }

local seen, seenWhy = false, nil   -- this screen has drawn the stand-in this session
local warmed, warmedIn = false, nil -- made ahead: let go in time, first person kept
local off = nil                     -- why making it ahead is off for the session
local tries = 0
local upAt = nil                    -- the server heard this client (the hello's answer)
local cardAt = nil                  -- a door card came up
local nextAt = nil                  -- the next try no sooner than this
local run = nil                     -- the try in flight
local blockedKey = nil              -- what a due try waits for, once said
local lateUntil, lateFrom = nil, nil -- after a try: third person shown for it later is said
-- THE STYLE FIRST (1.7.6): the server's word on this player's exit style.
-- Giving a style rebuilds the body every game draws -- this player's own
-- stand-in included (Staging, 2026-10-29: the stand-in made ahead at 18:41:59
-- UTC was despawned 0.24 s after the style came with the first boarding's key,
-- 18:44:27, and the step waited 8.6 s for a new one). So nothing is made ahead
-- before the style, and a style that comes after it makes it again.
local styleOk, styleReason = nil, nil
local rewarm = false                -- the style came while a try was in flight
local offForStyle = false           -- `off` came from a style refusal (a style given lifts it)
-- After a style came, the platform's rebuild is given this long before a try.
local REBUILT_MS = 1500
-- Style refusals that do not pass: no step will play, nothing to make ahead.
local STYLE_FINAL = {
    style_owned_elsewhere = true, locomotion_package_unavailable = true,
    locomotion_unavailable_on_this_host = true, error = true, off = true,
}
-- How long after a try third person shown for its request is watched for.
local LATE_WATCH_MS = 10000
local live = false

local function cfg() return M.StandInSettings() end

local function readState()
    local perspective = Open77.perspective
    if type(perspective) ~= 'table' or type(perspective.state) ~= 'function' then return nil end
    local read, state = pcall(perspective.state)
    if read and type(state) == 'table' then return state end
    return nil
end

local function describe(state)
    if state == nil then return 'not read' end
    return ('%s, %s, %s, body %s'):format(tostring(state.mode),
        state.settled == true and 'settled' or tostring(state.transition), tostring(state.reason),
        tostring(state.body))
end

local function alive()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.isAlive) ~= 'function' then return true end
    local read, answer = pcall(character.isAlive)
    return not read or answer ~= false
end

local function busy()
    if M.Enter ~= nil and type(M.Enter.Active) == 'function' and M.Enter.Active() then return 'a boarding' end
    if type(M.ExitBusy) == 'function' and M.ExitBusy() then return 'an exit' end
    return nil
end

--- What any reader of the arbiter saw: a stand-in drawn here is a stand-in made.
-- @param state table|nil `Open77.perspective.state()`
-- @param where string|nil for the log
function S.Note(state, where)
    if seen or type(state) ~= 'table' or state.body ~= 'proxy' then return end
    seen, seenWhy = true, where or 'third person on this screen'
    if not warmed then
        Open77.log.info(('stand-in: drawn on this screen (%s): made for this session, nothing to make ahead')
            :format(seenWhy))
    end
end

--- Whether the next third person should come within a second or two: the
--- stand-in drawn already, or made ahead.
function S.Ready() return seen or warmed end

--- The server heard this client: the try is due `AFTER_MS` later.
function S.Up(now)
    if upAt == nil then upAt = now or M.Now() end
end

--- A door card came up (`NEAR_CARD`: the try is due now).
function S.CardUp(now)
    if cardAt == nil then cardAt = now or M.Now() end
end

--- Forget what was made: the next try starts afresh.
local function remake(now, why)
    local had = warmed or seen
    warmed, seen, seenWhy, warmedIn = false, false, nil, nil
    tries, lateUntil = 0, nil
    if offForStyle then off, offForStyle = nil, false end
    nextAt = (now or M.Now()) + REBUILT_MS
    if had then
        Open77.log.info(('stand-in: %s -- the platform rebuilds this player\'s body for it, the stand-in with it: '
            .. 'made ahead again'):format(why))
    end
end

--- The server's word on this player's exit style (client/walkout.lua).
-- @param ok boolean
-- @param reason string|nil
function S.Style(ok, reason, now)
    now = now or M.Now()
    local was = styleOk
    styleOk, styleReason = ok == true, reason ~= nil and tostring(reason) or nil
    if ok == true and was ~= true then
        if run ~= nil and not run.done then
            rewarm = true
        else
            remake(now, 'the exit style came')
        end
    end
end

--- A boarding or an exit takes the view: a try in flight stops without
--- letting go of a request that is now that step's.
-- @param why string
function S.Yield(why)
    if run == nil or run.done then return end
    run.yielded = why or 'a step'
end

--- A due try waits: said once a cause (`key`), with what was read then.
local function blocked(key, why)
    if blockedKey == key then return end
    blockedKey = key
    Open77.log.info(('stand-in: made ahead once %s'):format(why))
end

local function letGo(r, now, why)
    r.letGoAt, r.letGoWhy = now, why
    r.building = why:find('holding_current', 1, true) ~= nil
    local perspective = Open77.perspective
    local ok = false
    if type(perspective) == 'table' and type(perspective.clearThirdPersonOverride) == 'function' then
        local read, answer = M.Native('perspective.clearThirdPersonOverride', perspective.clearThirdPersonOverride)
        ok = read and answer ~= false
    end
    Open77.log.info(('stand-in: third person let go %.2fs after it was asked (try %d): %s%s'):format(
        (now - r.since) / 1000.0, r.try, why, ok and '' or ' -- the release was refused'))
end

local function finish(r, now)
    if r.done then return end
    r.done = true
    if run == r then run = nil end
    if rewarm then
        -- The style came during this try: what it built is rebuilt.
        rewarm = false
        Open77.log.info(('stand-in: try %d is over, but the exit style came during it'):format(r.try))
        return remake(now, 'the exit style came during a try')
    end
    local s = cfg()
    local trail = #r.states > 0 and table.concat(r.states, '; ') or 'nothing read yet'
    if r.yielded ~= nil then
        if r.letGoAt ~= nil and r.building and r.failed == nil then
            -- Let go in time, and the body was being built: made ahead, even if
            -- the step that took the view comes before it is ready.
            warmed, warmedIn = true, (r.letGoAt - r.since) / 1000.0
            Open77.log.info(('stand-in: made ahead (try %d, let go %.2fs after the ask); %s took the view %.2fs '
                .. 'later, the body built behind first person (the arbiter: %s)'):format(r.try, warmedIn, r.yielded,
                (now - r.letGoAt) / 1000.0, trail))
            return
        end
        -- The step's own third person builds the body from here.
        Open77.log.info(('stand-in: %s took the view %.2fs into try %d -- its own third person stands, this try '
            .. 'lets nothing go under it (the arbiter: %s)'):format(r.yielded, (now - r.since) / 1000.0, r.try, trail))
        return
    end
    if r.early then
        Open77.log.info(('stand-in: there already -- the platform began to show third person %.2fs into try %d, '
            .. 'and was turned back at once (it may have shown for a moment): nothing to make (the arbiter: %s)')
            :format((r.letGoAt - r.since) / 1000.0, r.try, trail))
        return
    end
    if r.shown then
        off = 'this client showed third person after the request was let go'
        Open77.log.warn(('stand-in: this client showed third person after the request was let go (an older client: '
            .. 'it plays every switch out once asked) -- not made ahead again this session; the first boarding '
            .. 'makes it (the arbiter: %s)'):format(trail))
        return
    end
    if r.failed ~= nil then
        nextAt = now + s.retry
        Open77.log.warn(('stand-in: not made ahead on try %d of %d (%s)%s (the arbiter: %s)'):format(r.try, s.tries,
            r.failed, tries < s.tries and (': tried again in %.0fs'):format(s.retry / 1000.0)
                or ': the first boarding makes it', trail))
        return
    end
    warmed, warmedIn = true, (r.letGoAt - r.since) / 1000.0
    lateUntil, lateFrom = now + LATE_WATCH_MS, now
    Open77.log.info(('stand-in: made ahead -- the platform built it behind first person, never shown, and keeps it '
        .. 'parked for the session (try %d, let go %.2fs after the ask; first person all through the %.1fs '
        .. 'watched after): the first boarding draws third person within a second or two (the arbiter: %s)')
        :format(r.try, warmedIn, s.confirm / 1000.0, trail))
end

--- One try, frame by frame: the arbiter's answers until it builds the body
--- behind first person, then first person watched for `CONFIRM_MS`.
local function follow(r)
    local s = cfg()
    while live and run == r and not r.done do
        Wait(0)
        if run ~= r or r.done then return end
        local now = M.Now()
        if r.yielded ~= nil then return finish(r, now) end
        local state = readState()
        local line = describe(state)
        if line ~= r.line then
            r.line = line
            if #r.states < 12 then r.states[#r.states + 1] = ('%.2fs %s'):format((now - r.since) / 1000.0, line) end
        end
        if state ~= nil and state.body == 'proxy' then S.Note(state, 'try ' .. r.try) end
        local transition = state ~= nil and (state.settled == true and 'settled' or tostring(state.transition))
            or 'unread'
        if r.letGoAt == nil then
            if state ~= nil and state.mode == 'fpp' and transition == 'holding_current' then
                letGo(r, now, 'the platform builds the body behind first person (holding_current)')
            elseif state ~= nil and (state.mode == 'tps' or transition == 'committing' or transition == 'revealing') then
                -- Its reveal began: the body was there already (or built within
                -- a frame). Let go at once; the platform turns the view back.
                seen, seenWhy = true, 'made already'
                r.early = true
                letGo(r, now, ('the stand-in was there already: the platform began to show third person (%s)')
                    :format(line))
            elseif state ~= nil and state.reason == 'prepare_timeout' then
                r.failed = 'the platform gave up building the body (prepare_timeout)'
                letGo(r, now, r.failed)
            elseif now - r.since >= s.letGoBy then
                r.failed = ('no holding_current within %.1fs (%s)'):format(s.letGoBy / 1000.0, line)
                letGo(r, now, r.failed)
            end
        else
            if state ~= nil and state.mode == 'tps' and not r.early and r.failed == nil and not r.shown then
                r.shown = true
            end
            if now - r.letGoAt >= s.confirm then return finish(r, now) end
        end
        if now - r.since > s.letGoBy + s.confirm + 2000 then
            if r.letGoAt == nil then
                r.failed = 'the try ran out'
                letGo(r, now, r.failed)
            end
            return finish(r, now)
        end
    end
end

local function begin(now, state)
    local perspective = Open77.perspective
    if type(perspective) ~= 'table' or type(perspective.setThirdPerson) ~= 'function'
        or type(perspective.clearThirdPersonOverride) ~= 'function' then
        off = 'no Open77.perspective.setThirdPerson / clearThirdPersonOverride on this client'
        Open77.log.warn(('stand-in: %s -- not made ahead; the first boarding makes it'):format(off))
        return
    end
    local s = cfg()
    tries = tries + 1
    blockedKey = nil
    local read, ok, reason = M.Native('perspective.setThirdPerson', perspective.setThirdPerson, true, true)
    if not read or ok ~= true then
        reason = tostring(read and reason or ok)
        if PERMANENT[reason] then
            off = ('third person refused: %s'):format(reason)
            Open77.log.warn(('stand-in: %s -- not made ahead (no boarding step is seen on this screen either)')
                :format(off))
            return
        end
        nextAt = now + s.retry
        Open77.log.warn(('stand-in: third person refused on try %d of %d (%s): tried again in %.0fs'):format(tries,
            s.tries, reason, s.retry / 1000.0))
        return
    end
    local r = { since = now, try = tries, states = {}, line = nil }
    run = r
    Open77.log.info(('stand-in: made ahead, try %d of %d -- third person asked out of sight (the view: %s), let go '
        .. 'the moment the platform builds the body behind first person (%.1fs at most)'):format(r.try, s.tries,
        describe(state), s.letGoBy / 1000.0))
    CreateThread(function()
        local ran, failure = pcall(follow, r)
        if not ran then
            Open77.log.error('stand-in: the try failed: ' .. tostring(failure))
            if r.letGoAt == nil and r.yielded == nil then letGo(r, M.Now(), 'an error') end
            r.failed = r.failed or 'an error'
            finish(r, M.Now())
        end
    end)
end

--- Every pass of the watch (100 ms): whether a try is due, and its start.
-- @param now number
-- @param seat table|nil this body's seat
function S.Tick(now, seat)
    if not live then return end
    local s = cfg()
    -- A reveal of a let-go request after its try was watched: an older client
    -- plays the switch out once its body is ready, however long that took.
    if lateUntil ~= nil then
        if now > lateUntil then
            lateUntil = nil
        else
            local late = readState()
            if late ~= nil and late.mode == 'tps' and late.resourceForced ~= true and late.reason == 'resource_forced'
                and busy() == nil then
                lateUntil = nil
                off = 'this client showed third person for a request already let go'
                Open77.log.warn(('stand-in: this client showed third person %.1fs after the try was over (%s): an '
                    .. 'older client that plays every switch out -- not made ahead again this session')
                    :format((now - (lateFrom or now)) / 1000.0, describe(late)))
            end
        end
    end
    if not s.warm or off ~= nil or warmed or seen or run ~= nil then return end
    -- Reading the view is how a stand-in drawn by the player's own third
    -- person is noticed: nothing to make then.
    local state = readState()
    if state ~= nil then S.Note(state, 'third person on this screen') end
    if seen then return end
    if tries >= s.tries or upAt == nil then return end
    -- THE STYLE FIRST (1.7.6): a body made before it would be thrown away.
    local missing = type(M.AnimMissing) == 'function' and M.AnimMissing() or false
    local walk = type(M.WalkOutSettings) == 'function' and M.WalkOutSettings() or nil
    if walk ~= nil and not walk.off and not missing and styleOk ~= true then
        if styleOk == false and STYLE_FINAL[tostring(styleReason)] then
            off = ('no exit style for this player (%s): no step plays on the stand-in'):format(tostring(styleReason))
            offForStyle = true
            Open77.log.info(('stand-in: %s -- not made ahead'):format(off))
            return
        end
        return blocked('style', ('this player has the exit style (the server gives it once the player is ready: it '
            .. 'rebuilds the body)%s'):format(styleOk == false and (', refused for now: ' .. tostring(styleReason)) or ''))
    end
    local due = upAt + s.after
    if s.nearCard and cardAt ~= nil then due = math.min(due, cardAt) end
    if nextAt ~= nil then due = math.max(due, nextAt) end
    if now < due then return end
    if seat ~= nil then return blocked('seat', 'the body is out of its seat') end
    local step = busy()
    if step ~= nil then return blocked('step', ('%s is over'):format(step)) end
    if not alive() then return blocked('down', 'the body is up again') end
    if state == nil then return blocked('unread', 'the arbiter answers') end
    if state.mode ~= 'fpp' or state.settled ~= true then
        return blocked('view', ('the view has settled in first person (now: %s)'):format(describe(state)))
    end
    if state.resourceForced == true then
        return blocked('lock', ('no resource holds the view any more (one holds %s)'):format(
            tostring(state.resourcePerspective)))
    end
    if not CHOSEN[tostring(state.reason)] then
        return blocked('world:' .. tostring(state.reason), ('the view is the player\'s again (now: %s)')
            :format(describe(state)))
    end
    begin(now, state)
end

function S.Status()
    return { seen = seen, seenWhy = seenWhy, warmed = warmed, warmedIn = warmedIn, off = off, tries = tries,
        running = run ~= nil, style = styleOk, styleReason = styleReason }
end

function S.Start()
    live = true
    local s = cfg()
    Open77.log.info(('stand-in: %s'):format(s.warm and ('made ahead %.1fs after the server hears this client%s, '
        .. 'out of sight (at most %d tries, %.0fs apart)'):format(s.after / 1000.0,
        s.nearCard and ' or as a door card comes up' or '', s.tries, s.retry / 1000.0)
        or 'not made ahead (STAND_IN.WARM off): the first boarding makes it'))
end

function S.Stop()
    live = false
    local r = run
    run = nil
    if r ~= nil and not r.done and r.letGoAt == nil and r.yielded == nil then
        -- The host lets a stopped resource's lock go too; this is the polite one.
        local perspective = Open77.perspective
        if type(perspective) == 'table' and type(perspective.clearThirdPersonOverride) == 'function' then
            pcall(perspective.clearThirdPersonOverride)
        end
    end
    if r ~= nil then r.done = true end
end
