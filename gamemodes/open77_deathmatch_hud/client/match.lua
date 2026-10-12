-- The match surface: timer, phase, standings, kill feed, notices, the lobby
-- dock, the enrolment panel, the result banner and the death screen.
--
-- Everything here changes on a human timescale, so the page runs at a low
-- frame rate and this file pushes at 10 Hz. The fast half lives in
-- client/combat.lua. Splitting them is what stops a scoreboard repaint from
-- being on the critical path of a hitmarker.
--
-- Presentation only. Every timer anchor, roster entry, score, instance and
-- team comes from the authoritative gamemode resource; the sole local
-- calculation is counting a pushed millisecond value down between snapshots.

DeathmatchMatch = {}

local page
local ready = false
local panelOpen = false
local boardHeld = false

-- The weapon picker (`/guns`). `gunsAuto` remembers that the SERVER opened it
-- rather than the player, because only an unrequested picker may close itself.
local gunsOpen = false
local gunsAuto = false
local gunsOpenedAt = 0

-- The last payload of each, kept so `dm:ready` can replay them. The page is
-- created on resource start and reports ready some frames later; the server's
-- first-round picker fires the instant a player is armed, which on a fresh
-- connection can easily be the earlier of the two. A `page:send` into a page
-- that has not reported ready is lost, and the symptom -- a picker that never
-- appears for the one player it was written for -- looks like a server bug.
local gunsPayload = nil
local loadoutPayload = nil

-- How long an auto-opened picker is guaranteed to stay up before the
-- protection rule below is allowed to close it. Spawn protection is a tunable
-- and an operator may set it to zero, at which point "close when protection
-- ends" means "never appear at all"; this is the floor that keeps the feature
-- from evaporating on a server that does not use protection.
local GUNS_MIN_VISIBLE_MS = 6000

local state = nil
local anchoredAt = 0
local anchoredRemainingMs = 0
local anchoredDeathAt = 0
local anchoredDeathRemainingMs = 0

local function nowSeconds()
    return Open77.time.monotonic()
end

local function remainingMs()
    if state == nil or anchoredRemainingMs <= 0 then return 0 end
    local elapsed = (nowSeconds() - anchoredAt) * 1000
    return math.max(0, anchoredRemainingMs - elapsed)
end

local function deathRemainingMs()
    if state == nil or state.death == nil or anchoredDeathRemainingMs <= 0 then return 0 end
    local elapsed = (nowSeconds() - anchoredDeathAt) * 1000
    return math.max(0, anchoredDeathRemainingMs - elapsed)
end

local function push()
    if page == nil or not ready or state == nil then return end
    state.remainingMs = remainingMs()
    if state.death ~= nil then state.death.remainingMs = deathRemainingMs() end
    state.panelOpen = panelOpen
    state.boardHeld = boardHeld
    page:send("dm:state", state)
end

-- ONE focus decision for the whole surface, because there are two modals on it
-- now and they can be up at the same time. Two independent `setFocus` callers
-- would race: closing the panel while the picker is still open would hand the
-- player's mouse back to the game with a menu still on screen and no way to
-- click it.
local function syncFocus()
    if page == nil then return end
    local wanted = panelOpen or gunsOpen
    page:setFocus(wanted, wanted)
end

function DeathmatchMatch.setPanel(value)
    value = value == true
    if panelOpen == value then return end
    panelOpen = value
    if page ~= nil then
        syncFocus()
        page:send("dm:panel", { open = value })
    end
    push()
end

function DeathmatchMatch.panelIsOpen()
    return panelOpen
end

--- Open or close the weapon picker.
---
--- `payload` is the server's, and is forwarded verbatim on an open: the kit
--- catalogue, the pick and what the player is actually carrying all come from
--- the authoritative side, and this file adds nothing to them.
function DeathmatchMatch.setGuns(value, payload)
    value = value == true
    if value then
        gunsAuto = type(payload) == "table" and payload.auto == true
        gunsOpenedAt = nowSeconds()
    end
    gunsOpen = value
    local message = type(payload) == "table" and payload or {}
    message.open = value
    gunsPayload = message
    if page ~= nil then
        syncFocus()
        page:send("dm:guns", message)
    end
end

function DeathmatchMatch.gunsIsOpen()
    return gunsOpen
end

-- THE GUARANTEE THAT THE PICKER NEVER COSTS A FIGHT.
--
-- It auto-opens the moment a player is first armed, which is inside the spawn
-- protection that comes with that placement: while it is up they are
-- invulnerable, so standing still reading it costs nothing. The moment that
-- protection is gone they are a target, and a menu over a live round is no
-- longer a courtesy -- so it closes itself.
--
-- Only an AUTO-opened picker does this. A player who typed `/guns` asked for
-- it and keeps it until they close it or pick something.
local function maybeCloseGuns(payload)
    if not gunsOpen or not gunsAuto then return end
    if (nowSeconds() - gunsOpenedAt) * 1000 < GUNS_MIN_VISIBLE_MS then return end
    if payload.phase ~= "active" then return end
    if payload.playerState == "respawning" then return end
    local self = payload.self
    local protection = type(self) == "table" and self.protection or nil
    local remaining = type(protection) == "table"
        and math.max(0, tonumber(protection.remainingMs) or 0) or 0
    if remaining > 0 then return end
    DeathmatchMatch.setGuns(false)
end

RegisterNetEvent("deathmatch:state", function(payload)
    if type(payload) ~= "table" then return end
    state = payload
    anchoredRemainingMs = math.max(0, tonumber(payload.remainingMs) or 0)
    anchoredAt = nowSeconds()
    anchoredDeathRemainingMs = payload.death ~= nil
        and math.max(0, tonumber(payload.death.remainingMs) or 0) or 0
    anchoredDeathAt = anchoredAt
    maybeCloseGuns(payload)
    push()
    -- The combat surface needs the same truth: participation, phase, life
    -- state, team and the spawn-protection window all originate here.
    DeathmatchCombat.onMatchState(payload)
end)

RegisterNetEvent("deathmatch:notice", function(payload)
    if page ~= nil and type(payload) == "table" then page:send("dm:notice", payload) end
end)

RegisterNetEvent("deathmatch:killfeed", function(payload)
    if page ~= nil and type(payload) == "table" then page:send("dm:killfeed", payload) end
end)

RegisterNetEvent("deathmatch:panel", function(open)
    DeathmatchMatch.setPanel(open ~= false)
end)

-- What server/loadout.lua just issued this player. Under `mode = "choice"` the
-- state push carries no round weapon -- there is none -- so this is what the
-- band's weapon card is painted from.
RegisterNetEvent("deathmatch:loadout", function(payload)
    if type(payload) ~= "table" then return end
    loadoutPayload = payload
    if page ~= nil then page:send("dm:loadout", payload) end
end)

-- server/loadout.lua opens the picker: once by itself on a player's first round
-- of the session, and on demand for `/guns`.
RegisterNetEvent("deathmatch:guns", function(payload)
    if type(payload) ~= "table" then return end
    if payload.open == false then
        DeathmatchMatch.setGuns(false)
        return
    end
    -- The enrolment panel and the picker both take the mouse. Two open modals
    -- with one cursor is a surface a player has to fight, so the newer one wins
    -- and the older one goes.
    if panelOpen then DeathmatchMatch.setPanel(false) end
    DeathmatchMatch.setGuns(true, payload)
end)

AddEventHandler("open77:scoreboardShow", function()
    boardHeld = true
    push()
end)

AddEventHandler("open77:scoreboardHide", function()
    boardHeld = false
    push()
end)

AddEventHandler("open77:pauseKey", function()
    -- The picker first: it is the one on top, and ESC should dismiss what the
    -- player can see rather than something behind it.
    if gunsOpen then
        DeathmatchMatch.setGuns(false)
    elseif panelOpen then
        DeathmatchMatch.setPanel(false)
    end
end)

AddEventHandler("deathmatch:panel:toggle", function()
    DeathmatchMatch.setPanel(not panelOpen)
end)

function DeathmatchMatch.attach(target, strings)
    page = target
    ready = false

    page:on("dm:ready", function()
        ready = true
        page:send("dm:strings", strings)
        -- Replay whatever arrived before the page could listen. See the
        -- declarations: on a fresh connection the server arms the player before
        -- CEF finishes loading, and a lost picker looks like a server bug.
        if loadoutPayload ~= nil then page:send("dm:loadout", loadoutPayload) end
        if gunsPayload ~= nil then page:send("dm:guns", gunsPayload) end
        TriggerServerEvent("deathmatch:requestState")
        push()
    end)
    page:on("dm:close", function() DeathmatchMatch.setPanel(false) end)
    page:on("dm:guns", function(payload)
        if type(payload) ~= "table" then return end
        if payload.action == "pick" and type(payload.key) == "string" then
            TriggerServerEvent("deathmatch:chooseGuns", payload.key)
            -- Closed here rather than on the server's answer. The pick is a
            -- preference the server cannot refuse, and a menu that lingers
            -- after a click reads as a click that did not land.
            DeathmatchMatch.setGuns(false)
        elseif payload.action == "close" then
            DeathmatchMatch.setGuns(false)
        end
    end)
    page:on("dm:action", function(payload)
        if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
        if payload.action == "join" then
            TriggerServerEvent("deathmatch:join")
        elseif payload.action == "queue" then
            -- The arena queue. The world's queue station opens this panel (the
            -- server answers `deathmatch:stationQueue` with `deathmatch:panel`)
            -- and this is the click that finally reaches `Arena.enqueue`.
            --
            -- The size is forwarded VERBATIM and is never validated here: the
            -- server owns the format list, refuses an unknown one with
            -- `unknown_format`, and a second list on this side would be a
            -- second thing to keep in step. It is bounded only so a hostile
            -- page cannot make the wire carry a novel.
            local size = payload.size
            if type(size) == "string" and #size > 0 and #size <= 8 then
                TriggerServerEvent("deathmatch:queue", size)
            end
        elseif payload.action == "leaveQueue" then
            TriggerServerEvent("deathmatch:leave", "queue")
        elseif payload.action == "leaveMatch" then
            TriggerServerEvent("deathmatch:leave", "match")
        end
    end)

    CreateThread(function()
        while page ~= nil do
            -- "resolved" carries a clock too: it counts down the standings
            -- interval to the next round, and a frozen number there reads as a
            -- hung server rather than as a pause.
            if state ~= nil and (state.phase == "countdown" or state.phase == "active"
                or state.phase == "resolved" or state.death ~= nil) then
                push()
            end
            -- 10 Hz. Enough for a clock quoted in seconds and a respawn
            -- countdown quoted in tenths; far too slow to be a frame cost.
            Wait(100)
        end
    end)
end

function DeathmatchMatch.detach()
    if page ~= nil and (panelOpen or gunsOpen) then page:setFocus(false, false) end
    page, state = nil, nil
    ready, panelOpen, boardHeld = false, false, false
    gunsOpen, gunsAuto, gunsOpenedAt = false, false, 0
    gunsPayload, loadoutPayload = nil, nil
    anchoredRemainingMs, anchoredDeathRemainingMs = 0, 0
end
