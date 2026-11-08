-- =============================================================================
-- open77_avdoor -- client/shots.lua
-- =============================================================================
-- WHAT THE SCREEN SHOWED (1.5.1). Ten Staging tests of the exit were read from
-- logs, and twice the logs said "nothing wrong" of an exit the owner saw go
-- wrong: they measured where the body stood, not what was drawn. So during each
-- exit this game plays or draws, it takes a few small pictures of its own frame
-- -- `Open77.screen.capture`, the game's back buffer alone, copied inside the
-- game's own Present: never the desktop, never another window, never Open77's
-- overlays -- and keeps them on this machine, in this resource's client store
-- (`Open77.kvp`: red4ext/plugins/Open77/storage/kvp/server-<address>/
-- open77_avdoor.kvp under the game's folder), for the last `DIAG.KEEP` exits.
-- Nothing is sent anywhere. scripts/avdoor/read_avdoor_shots.py writes them out
-- as JPEG files, each with what this half knew when it was taken (the body's
-- place, heading and ground, the view, the clip's time).
--
-- One picture at a time (the host allows one capture in flight a resource),
-- each its own resume; a picture larger than a store value may be (64 KiB) is
-- taken again smaller once. The player's own exit and another player's drawn
-- here are sets of their own, side by side (two players stepping out of one
-- hull). A refusal (no permission, no capture on this host, a format it cannot
-- read) switches the pictures off for the session, in one line; so do
-- `FAILS_OFF` pictures in a row not taken.
--
-- WRITTEN AFTER THE EXIT, NEVER DURING IT. Every call into the store reads the
-- whole file and writes it again -- through a temporary file and a flush to
-- the disk -- on the game's own thread (scripting/src/KvpStore.cpp): a hitch in
-- the middle of the step it pictures. So the pictures are held in memory
-- through the exit and written once no exit runs on this screen (its fade, its
-- guard, its clip, another player's step drawn here: `M.ExitBusy`) and none
-- has been taken for `QUIET_MS` -- one store call a resume, `WRITE_GAP_MS`
-- apart; an exit that never ends waits `WRITE_LATEST_MS` at most.
-- =============================================================================

local M = AvDoor
local S = {}
M.Shots = S

-- A store value is at most 64 KiB; the picture keeps under it with room.
local MAX_BYTES = 60 * 1024
-- The store's index of the sets it keeps, oldest first.
local INDEX_KEY = 'shots'
-- The store is written once no picture has been taken for this long, nothing
-- is due within it, and no exit runs here.
local QUIET_MS = 2500
-- One store call a resume, this far apart.
local WRITE_GAP_MS = 250
-- Pictures of an exit that never ends (by this screen's reckoning) are written
-- after this long all the same, between pictures.
local WRITE_LATEST_MS = 20000
-- This many pictures in a row not taken: off for the session.
local FAILS_OFF = 5

local queue = {}        -- { at, label, set, meta }, by time
local current = {}      -- the set being pictured, by kind ('own', 'view')
local sets = {}         -- sets with pictures not yet all in the store, oldest first
local kept = nil        -- the set ids in the store, oldest first (read once)
local swept = false     -- pictures left by sets the index no longer names: dropped once a session
local off = nil         -- why the pictures are off, once said
local worker = nil
local taken, refused, written, failedInARow = 0, 0, 0, 0
local lastShotAt, lastWriteAt = nil, nil

local function settings()
    local block = type(M.Settings) == 'table' and M.Settings.DIAG or nil
    if type(block) ~= 'table' or block.SHOTS ~= true then return nil end
    return {
        scale = M.Number(block.SCALE, 0.05, 1.0, 0.25),
        quality = math.floor(M.Number(block.QUALITY, 10, 95, 55)),
        keep = math.floor(M.Number(block.KEEP, 1, 6, 2)),
    }
end

local function kvp()
    local store = Open77.kvp
    if type(store) ~= 'table' or type(store.set) ~= 'function' then return nil end
    return store
end

local function switchOff(why)
    if off ~= nil then return end
    off = why
    queue = {}
    Open77.log.info(('diag pictures off for this session: %s'):format(why))
end

--- The set ids the store keeps, oldest first (the store read once a session).
local function readIndex()
    if kept ~= nil then return kept end
    kept = {}
    local store = kvp()
    if store == nil or type(store.get) ~= 'function' then return kept end
    local read, text = pcall(store.get, INDEX_KEY, '')
    if read and type(text) == 'string' then
        for id in text:gmatch('[^,]+') do kept[#kept + 1] = id end
    end
    return kept
end

local function writeIndex()
    local store = kvp()
    if store == nil then return end
    pcall(store.set, INDEX_KEY, table.concat(kept or {}, ','))
end

--- Whether a set is being pictured or written now (never let go while it is).
local function inUse(id)
    for _, set in pairs(current) do
        if set ~= nil and set.id == id and not set.dropped then return true end
    end
    for _, set in ipairs(sets) do
        if set.id == id and not set.dropped then return true end
    end
    return false
end

--- Lets go of a set's pictures and their words in the store.
local function dropStored(id)
    local store = kvp()
    if store ~= nil and type(store.clear) == 'function' then pcall(store.clear, 'shot:' .. id .. ':') end
end

--- Lets go of the oldest set in the store that is not being pictured or written.
-- @return boolean whether one was let go
local function dropOldest()
    local list = readIndex()
    for index, id in ipairs(list) do
        if not inUse(id) then
            table.remove(list, index)
            dropStored(id)
            writeIndex()
            return true
        end
    end
    return false
end

--- Pictures in the store of sets its index does not name (a session that
--- stopped mid-write): let go of, once a session.
local function sweep()
    if swept then return end
    swept = true
    local store = kvp()
    if store == nil or type(store.keys) ~= 'function' then return end
    local read, keys = pcall(store.keys, 'shot:', 2048)
    if not read or type(keys) ~= 'table' then return end
    local named = {}
    for _, id in ipairs(readIndex()) do named[id] = true end
    local orphans = {}
    for _, key in ipairs(keys) do
        local id = tostring(key):match('^shot:([^:]+):')
        if id ~= nil and not named[id] then orphans[id] = true end
    end
    local n = 0
    for id in pairs(orphans) do
        dropStored(id)
        n = n + 1
    end
    if n > 0 then Open77.log.info(('diag pictures: %d set(s) the store no longer named let go'):format(n)) end
end

--- A new exit to picture. `kind`: 'own' (this player's exit) or 'view' (another
--- player's, drawn here); `what` says which, for the pictures' words. Nothing
--- is read from or written to the store here (the exit is starting).
-- @param kind string
-- @param what string
function S.Begin(kind, what)
    local cfg = settings()
    if cfg == nil or off ~= nil then return end
    if kvp() == nil then return switchOff('no Open77.kvp on this client') end
    local screen = Open77.screen
    if type(screen) ~= 'table' or type(screen.capture) ~= 'function' then
        return switchOff('no Open77.screen.capture on this client')
    end
    kind = kind == 'view' and 'view' or 'own'
    -- The set this kind pictured before: its pictures still due are let go
    -- (the pictures it has are written all the same).
    local before = current[kind]
    if before ~= nil then
        before.closed = true
        local keep = {}
        for _, entry in ipairs(queue) do if entry.set ~= before then keep[#keep + 1] = entry end end
        queue = keep
        current[kind] = nil
    end
    local now = M.Now()
    local id = ('%s%d'):format(kind == 'view' and 'v' or 'o', now % 100000000)
    local set = { id = id, kind = kind, n = 0, since = now, what = tostring(what or ''), pending = {}, lines = {},
        indexed = false, closed = false, dropped = false, wordsDirty = false, stored = 0 }
    current[kind] = set
    sets[#sets + 1] = set
    Open77.log.info(('diag pictures: %s (%s), set %s -- written to this machine once the exit is over'):format(
        kind == 'view' and 'another player\'s exit drawn here' or 'this player\'s exit', set.what, id))
end

--- A picture of the current exit of `kind` ('own' unless said) `delayMs` from
--- now, labelled; `meta(now)` is asked for its words when it is taken.
-- @param label string
-- @param delayMs number
-- @param meta function|nil
-- @param kind string|nil
function S.Take(label, delayMs, meta, kind)
    local set = current[kind == 'view' and 'view' or 'own']
    if set == nil or set.dropped or off ~= nil or settings() == nil then return end
    queue[#queue + 1] = { at = M.Now() + math.max(0, tonumber(delayMs) or 0), label = tostring(label),
        set = set, meta = meta }
    table.sort(queue, function(a, b) return a.at < b.at end)
end

--- What the picture's words say: `k=v;k=v`.
local function words(entry, now, picture)
    local parts = { 'label=' .. entry.label, ('ms=%d'):format(now - entry.set.since), 'what=' .. entry.set.what }
    if picture ~= nil then
        parts[#parts + 1] = ('size=%dx%d'):format(tonumber(picture.width) or 0, tonumber(picture.height) or 0)
    end
    if type(entry.meta) == 'function' then
        local read, extra = pcall(entry.meta, now)
        if read and type(extra) == 'table' then
            for _, pair in ipairs(extra) do parts[#parts + 1] = tostring(pair) end
        end
    end
    return (table.concat(parts, ';'):gsub('[\r\n\t]', ' '))
end

--- One picture: taken, awaited, and held in memory for the store.
local function shoot(entry, cfg)
    local screen = Open77.screen
    local function capture(quality)
        local read, promise, reason = M.Native('screen.capture', screen.capture, { format = 'jpeg', quality = quality, scale = cfg.scale,
            maxBytes = MAX_BYTES, includeOverlay = false })
        if not read then return nil, tostring(promise) end
        if promise == nil then return nil, tostring(reason or 'refused') end
        -- THE HOST'S PROMISE IS A USERDATA (`Open77.Promise`, scripting/src/
        -- ResourceHost.cpp): 1.5.2 asked for a table and took every picture on
        -- the laptop for "no promise" (Staging, 2026-10-28, 01:54:15.093).
        local kind = type(promise)
        if kind ~= 'table' and kind ~= 'userdata' then return nil, 'no promise (' .. kind .. ')' end
        local got, picture, why = pcall(function() return promise:await() end)
        if not got then return nil, tostring(picture) end
        if type(picture) ~= 'table' or type(picture.bytes) ~= 'string' then return nil, tostring(why or 'no picture') end
        return picture
    end
    local at = M.Now()
    local picture, why = capture(cfg.quality)
    if picture == nil and tostring(why):find('capture_too_large', 1, true) ~= nil and not entry.set.dropped then
        picture, why = capture(math.max(10, math.floor(cfg.quality * 0.6)))
    end
    lastShotAt = M.Now()
    if picture == nil then
        refused = refused + 1
        failedInARow = failedInARow + 1
        local reason = tostring(why)
        if reason:find('permission_denied', 1, true) or reason:find('unavailable_on_this_host', 1, true)
            or reason:find('format_unsupported', 1, true) then
            return switchOff(('the capture was refused (%s)'):format(reason))
        end
        Open77.log.info(('diag picture %s of set %s not taken: %s'):format(entry.label, entry.set.id, reason))
        if failedInARow >= FAILS_OFF then
            switchOff(('%d pictures in a row not taken (the last: %s)'):format(failedInARow, reason))
        end
        return
    end
    failedInARow = 0
    if entry.set.dropped then return end
    local set = entry.set
    local n = set.n + 1
    set.n = n
    -- The words are of the moment it was asked for.
    set.pending[#set.pending + 1] = { n = n, label = entry.label, bytes = picture.bytes,
        words = words(entry, at, picture), at = at }
    taken = taken + 1
    Open77.log.info(('diag picture %d of set %s (%s, %.1fs in): %dx%d, %.1f KB, %d us on the game\'s frame'):format(n,
        set.id, entry.label, (at - set.since) / 1000.0, tonumber(picture.width) or 0, tonumber(picture.height) or 0,
        #picture.bytes / 1024.0, math.floor(tonumber(picture.copyMicros) or 0)))
end

--- The oldest picture not yet written: when it was taken, or nil.
local function oldestPending()
    local oldest = nil
    for _, set in ipairs(sets) do
        local first = set.pending[1]
        if first ~= nil and (oldest == nil or first.at < oldest) then oldest = first.at end
    end
    return oldest
end

--- Whether an exit is under way on this screen (its fade, guard, clip, or
--- another player's step drawn here).
local function busy()
    if type(M.ExitBusy) ~= 'function' then return false end
    local ran, yes = pcall(M.ExitBusy)
    return ran and yes == true
end

--- Whether the store may be written now.
-- @param now number
local function writable(now)
    if lastWriteAt ~= nil and now - lastWriteAt < WRITE_GAP_MS then return false end
    if lastShotAt ~= nil and now - lastShotAt < QUIET_MS then return false end
    local due = queue[1]
    if due ~= nil and due.at - now < QUIET_MS then return false end
    if not busy() then return true end
    local oldest = oldestPending()
    return oldest ~= nil and now - oldest >= WRITE_LATEST_MS
end

--- One call into the store (or none): the sweep, a set's place in the index, a
--- picture, or a set's words. Sets with nothing left to write are let go of.
-- @return boolean whether the store was touched
local function flushStep(cfg)
    local store = kvp()
    if store == nil then return false end
    -- Sets with nothing to write, or let go of: forgotten here.
    local live = {}
    for _, set in ipairs(sets) do
        local done = #set.pending == 0 and not set.wordsDirty and (set.closed or current[set.kind] ~= set)
        if not set.dropped and not done then live[#live + 1] = set end
    end
    sets = live
    local set = nil
    for _, s in ipairs(sets) do
        if #s.pending > 0 or s.wordsDirty then
            set = s
            break
        end
    end
    if set == nil then return false end
    if not swept then
        sweep()
        return true
    end
    if not set.indexed then
        local list = readIndex()
        -- A set id this store already names (another session's exit at the same
        -- clock): a new one, before anything of it is written.
        local named = {}
        for _, id in ipairs(list) do named[id] = true end
        local id, n = set.id, 0
        while named[id] do
            n = n + 1
            id = ('%s%s'):format(set.id, string.char(96 + n))
        end
        set.id = id
        if #list >= cfg.keep and dropOldest() then return true end
        list[#list + 1] = set.id
        writeIndex()
        set.indexed = true
        return true
    end
    local function keep(k, value)
        local read, ok, failure = pcall(store.set, k, value)
        if not read then return false, tostring(ok) end
        return ok == true, failure
    end
    local shot = set.pending[1]
    if shot ~= nil then
        table.remove(set.pending, 1)
        local key = ('shot:%s:%02d'):format(set.id, shot.n)
        local ok, failure = keep(key, shot.bytes)
        if not ok and tostring(failure):find('quota', 1, true) ~= nil and dropOldest() then
            ok, failure = keep(key, shot.bytes)
        end
        if not ok then
            Open77.log.info(('diag picture %d of set %s not kept: %s'):format(shot.n, set.id, tostring(failure)))
            return true
        end
        written = written + 1
        set.stored = set.stored + 1
        set.lines[#set.lines + 1] = ('%02d\t%s'):format(shot.n, shot.words)
        set.wordsDirty = true
        return true
    end
    -- THE SET'S WORDS, one value, once its pictures are in.
    local ok, failure = keep(('shot:%s:words'):format(set.id), table.concat(set.lines, '\n'))
    set.wordsDirty = false
    if ok then
        Open77.log.info(('diag pictures of set %s (%s): %d in this machine\'s store'):format(set.id, set.what, set.stored))
    else
        Open77.log.info(('diag pictures of set %s: their words not kept: %s'):format(set.id, tostring(failure)))
    end
    return true
end

function S.Start()
    if worker ~= nil then return end
    local handle = { live = true }
    worker = handle
    CreateThread(function()
        while handle.live do
            Wait(50)
            if not handle.live then break end
            local now = M.Now()
            local entry = queue[1]
            if entry ~= nil and now >= entry.at then
                table.remove(queue, 1)
                local cfg = settings()
                if cfg ~= nil and off == nil and not entry.set.dropped then
                    local ran, failure = pcall(shoot, entry, cfg)
                    if not ran then Open77.log.warn('a diag picture failed: ' .. tostring(failure)) end
                end
            elseif #sets > 0 and writable(now) then
                local cfg = settings() or { keep = 2 }
                local ran, touched = pcall(flushStep, cfg)
                if not ran then
                    Open77.log.warn('a diag picture write failed: ' .. tostring(touched))
                    lastWriteAt = now
                elseif touched then
                    lastWriteAt = now
                end
            end
        end
    end)
end

--- Stops the pictures; those still in memory are written now (the exit is
--- over: the resource is stopping), a few at most.
function S.Stop()
    if worker ~= nil then worker.live = false end
    worker = nil
    queue = {}
    local cfg = settings() or { keep = 2 }
    for _ = 1, 24 do
        local ran, touched = pcall(flushStep, cfg)
        if not ran or not touched then break end
    end
end

--- What the console's status line shows.
function S.Status()
    local held = 0
    for _, set in ipairs(sets) do held = held + #set.pending end
    return { on = settings() ~= nil and off == nil, off = off, taken = taken, refused = refused, written = written,
        held = held, due = #queue, own = current.own ~= nil and current.own.id or nil,
        view = current.view ~= nil and current.view.id or nil }
end
