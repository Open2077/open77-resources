-- COMBAT MUSIC FOR A PLAYER-VERSUS-PLAYER FIGHT.
--
-- Owner, 2026-09-01: "music is cool when u fight npc -- make sure it's getting
-- added as well for multi when you will be playing against real players."
--
-- WHY THERE IS SILENCE TODAY. Vanilla combat music is a side effect of the
-- ENGINE's own combat state, and the AI is what produces that state: a hostile
-- NPC acquires the player, `PlayerStateMachine.Combat` goes to `InCombat`, and
-- the music system follows. A bot fight therefore gets music for free -- the
-- bots run real engine combat AI, which is the whole point of the change that
-- gave them one. A PLAYER fight has no AI on either end: a remote player is a
-- proxy carrying a no-reaction preset and a neutral attitude group precisely so
-- it never behaves like an enemy NPC, and PvP damage is arbitrated on the
-- SERVER and merely reported back (docs/combat.md). Nothing ever tells the
-- audio system a fight is happening, so nothing plays.
--
-- WHAT THIS FILE DOES: it posts the music events itself, the same way the
-- engine does.
--
-- THE ENGINE'S OWN PATTERN, READ OUT OF THE 2.31 BUILD RATHER THAN GUESSED.
-- `FUN_141337cf0` (Ghidra VA 0x141337CF0, RVA 0x1337CF0) is the prevention-heat
-- handler, and it drives the police chase music in exactly three moves:
--
--   heat 6  post `mus_ow_police_START_silent` once, then `mus_ow_police_calm`
--   heat 7  post the START if it was not posted yet, then `mus_ow_police_tense`
--   heat 8  post `mus_ow_police_STOP_silent` and clear the "started" flag
--
-- A music FAMILY is therefore a container: one `_START_<state>` event opens it,
-- the bare `_<state>` events switch what it plays inside, and one
-- `_STOP_<state>` event closes it. All of them are ordinary Wwise events posted
-- through the audio system, which is exactly what `Open77.sfx.play` queues --
-- a `gameaudioeventsPlaySound` carrying the event name.
--
-- POSTING THE STATE EVENT ALONE IS NOT ENOUGH, and that is the trap this file
-- exists to avoid: the engine posts the START first, every time, and a state
-- setter aimed at a container that is not playing produces silence rather than
-- an error.
--
-- WE OPEN THE CONTAINER BUT WE NEVER CLOSE IT. `Config.music.stop` is the
-- family's quiet STATE, not its `_STOP_` event, and that is deliberate: we
-- cannot tell whether the container we are talking to is one we opened or one
-- the engine already had open for the district. Closing somebody else's would
-- take the open-world music away for as long as it took the engine to notice.
-- Returning it to its quiet state is correct in both cases, and a music
-- container idling at silence is what the engine leaves behind anyway.
--
-- WHY NOT `AudioSystem.NotifyGameTone`. An earlier attempt (client/redscript/
-- Open77MultiplayerPolicy.reds, `Open77CombatMusicApply`) calls it with
-- `BeginCombat` / `EndCombat`. That native -- `FUN_140D222F4`, reached from the
-- RTTI registration at 0x141049680 -- compares its argument against FIFTEEN
-- hard-coded CName hashes and does nothing whatsoever with anything else.
-- Hashing every string in the executable and in `final.redscripts` against
-- those fifteen constants recovers the whole set: EnterSafe, EnterPublic,
-- EnterRestricted, EnterDangerous, EnterCrouch, LeaveCrouch, StartFalling,
-- EnterOnGround, LeaveOnGround, EnterTimeMode, LeaveTimeMode, InLowHealth,
-- InNormalHealth, Scanning, NotScanning. There is no combat tone in it.
-- `NotifyGameTone(n"BeginCombat")` is a no-op, which is why that path was never
-- heard.
--
-- The three event NAMES live in `Config.music` because the family name is the
-- one part of this that could not be settled by reading the build -- see the
-- note there before changing it.

local Config = DeathmatchConfig

-- A connected client can receive a newer resource generation before its native
-- plugin has been restarted. Stay inert on that transition rather than failing
-- the VM, exactly as open77_effects does.
if type(Open77.sfx) ~= "table" or type(Open77.sfx.play) ~= "function" then
    print("[open77_deathmatch] native sfx API unavailable; no PvP combat music")
    return
end

local music = type(Config.music) == "table" and Config.music or {}
local enabled = music.enabled ~= false

-- How long one PvP hit keeps the music going. Long enough that a reload or a
-- chase across the market does not drop it mid-fight, short enough that a
-- finished fight ends.
local HOLD_MS = tonumber(music.holdMs) or 12000
-- How long a bot contact keeps us OUT of the way. See `noteBotContact`.
local BOT_QUIET_MS = tonumber(music.botQuietMs) or 15000

local playing = false        -- our container is open
local lastPvpAtMs = -math.huge
local lastBotAtMs = -math.huge
local inFight = false        -- the server says this player is fighting a round
local localPlayerId = 0

local function nowMs()
    return Open77.time.monotonic() * 1000
end

-- ---------------------------------------------------------------------------
-- Posting
-- ---------------------------------------------------------------------------

-- `entity` is deliberately omitted: `Api::Effects::SfxOptions` defaults it to 1
-- and `ResolveEntity(1)` is the local player, so the event is posted on this
-- client's own body. Music is not spatialised, so the emitter does not matter;
-- what matters is that there IS one, because entity 0 is refused.
local function post(event)
    if type(event) ~= "string" or event == "" then return end
    local handle, reason = Open77.sfx.play(event, {})
    if handle == nil then
        Open77.log.warn(("deathmatch: music event %s refused: %s")
            :format(event, tostring(reason)))
    end
end

-- WHY THE HANDLES ARE RELEASED AT THE START OF A FIGHT AND NOT AT THE END.
--
-- Every `Open77.sfx.play` leaves a resource-owned entry behind, and there are
-- only 64 of them per resource. Three per fight would exhaust the quota after
-- roughly twenty fights and the music would then stop working for the rest of
-- the session, silently -- `sfx.play` would simply return `quota_exceeded`.
--
-- Releasing an entry queues `SoundStopEvent` for its event NAME, so releasing
-- the START handle is a real stop of the music it opened -- which is exactly
-- what makes this the teardown that guarantees nothing survives a reload, and
-- exactly why it must not happen while the music is meant to be audible.
-- Doing it just before the NEXT fight opens is inaudible: by then the container
-- has been sitting at its quiet state for at least `HOLD_MS`.
local function releaseHandles()
    if type(Open77.sfx.clear) == "function" then Open77.sfx.clear() end
end

local function startMusic()
    if playing then return end
    releaseHandles()
    playing = true
    post(music.start)
    post(music.combat)
end

local function stopMusic()
    if not playing then return end
    playing = false
    post(music.stop)
end

-- ---------------------------------------------------------------------------
-- The one decision
-- ---------------------------------------------------------------------------

-- Called from every signal and from the tick, so there is exactly one place
-- that decides whether the music should be up. Four conditions, and each one is
-- a separate requirement:
--
--   inFight        the server says this player is alive and in an active round.
--                  This is what stops the music on death, on elimination, on
--                  round end and on leaving the instance -- all four are the
--                  same fact and the state push already carries it.
--   recent PvP     a fight is one that has produced damage between two PLAYERS.
--                  A round merely running, with the player standing alone, is
--                  not a fight and must not have music.
--   no recent bot  the engine is probably already playing ITS combat music, so
--                  ours would be a second track over the top. See below.
--   enabled        the config switch.
local function evaluate()
    local now = nowMs()
    local want = enabled
        and inFight
        and (now - lastPvpAtMs) < HOLD_MS
        and (now - lastBotAtMs) >= BOT_QUIET_MS
    if want then startMusic() else stopMusic() end
end

local function notePvpContact()
    lastPvpAtMs = nowMs()
    evaluate()
end

-- A BOT WAS INVOLVED, so stand down.
--
-- This is the whole of the no-double-music rule. A bot that is shooting at this
-- player, or being shot by them, has put the ENGINE in combat, and the engine
-- is already playing the track this file exists to supply. This STOPS the music
-- rather than merely declining to start it, because a bot can join a fight that
-- began as pure PvP.
--
-- The quiet window is longer than the PvP hold on purpose: the engine's own
-- combat state persists for a while after the last shot, and coming back in
-- under it would produce exactly the overlap this avoids.
--
-- KNOWN GAP, stated rather than hidden: a bot that has ACQUIRED this player but
-- has not yet traded damage with them puts the engine in combat without
-- producing any of the signals below, so a PvP exchange during that window can
-- overlap the engine's music until the first bot hit lands. Closing it properly
-- needs the `PlayerStateMachine.Combat` blackboard key, which client Lua cannot
-- read -- `Open77.character.state()` has no combat field.
local function noteBotContact()
    lastBotAtMs = nowMs()
    evaluate()
end

-- ---------------------------------------------------------------------------
-- The signals
-- ---------------------------------------------------------------------------

-- An id too long to be a participant id is an NPC id, not a player id. This is
-- the same rule server/scoring.lua applies in `translate`, and for the same
-- reason: a bot's damage reaches its victim under its uint64 NPC id (measured
-- 2026-08-31, `attacker=12884901889`), while a player id is a small session
-- number. Nine digits is the cut in both places; keep them together.
local function isNpcId(raw)
    local digits = tostring(raw):match("^%-?%d+$")
    if digits == nil then return true end          -- unreadable: not a player
    return #(digits:gsub("^%-", "")) > 9
end

-- I DAMAGED ANOTHER PLAYER. This event is PvP by construction and needs no
-- filtering at all: `CombatReplication.cpp` emits it from the loop over PLAYER
-- health states, only when `state.lastAttackerId` is the local player. A hit on
-- a bot produces nothing here at all, which is why the mode had to invent
-- `deathmatch:botHitConfirmed` for its own hitmarker.
AddEventHandler("open77:hitConfirmed", function()
    notePvpContact()
end)

-- SOMEBODY DAMAGED ME, and the attacker decides which kind of contact it was.
-- Attacker 0 is the environment -- fall damage and the bounds backstop -- and
-- is neither.
AddEventHandler("open77:localDamaged", function(attackerId)
    if attackerId == nil then return end
    if isNpcId(attackerId) then
        noteBotContact()
        return
    end
    local id = math.floor(tonumber(attackerId) or 0)
    if id <= 0 or id == localPlayerId then return end
    notePvpContact()
end)

-- The two ENGINE hit observations client/main.lua already forwards to the
-- server. They are used here rather than the server's confirmations because
-- they are this client's own reading of the engine's `gameHitEvent`: they fire
-- before the round trip, so the stand-down happens on the same frame as the
-- shot rather than after it.
AddEventHandler("open77:npcHit", function() noteBotContact() end)
AddEventHandler("open77:npcAttackedMe", function() noteBotContact() end)

-- `open77:npcCrossfire` is deliberately NOT here: it is bot versus bot, with no
-- player on either end, and it does not put this player in engine combat.

-- The round, the life and the instance, all from the one authoritative push.
-- `playerState` is the fragment's own word and it already separates a player
-- counting down a free-for-all respawn ("respawning") and one eliminated in an
-- arena round ("eliminated") from one who is actually fighting ("active").
RegisterNetEvent("deathmatch:state", function(payload)
    if type(payload) ~= "table" then return end
    localPlayerId = math.floor(tonumber(payload.playerId) or 0)
    inFight = payload.participant == true
        and tostring(payload.playerState or "") == "active"
    evaluate()
end)

-- ---------------------------------------------------------------------------
-- The tick
-- ---------------------------------------------------------------------------

-- The signals above can only ever turn the music ON; the two hold windows
-- expire in silence and nothing would notice. 4 Hz is plenty for a fade that
-- nobody is timing, and it costs three comparisons.
CreateThread(function()
    while true do
        evaluate()
        Wait(250)
    end
end)

-- Music still playing after a reload is the bug everybody testing this would
-- hit first, and it is closed here in two moves: the quiet state so the music
-- stops musically, then the handle release, whose `SoundStopEvent` on the START
-- name is what actually guarantees nothing is left running.
AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopMusic()
    releaseHandles()
end)

-- NOTHING IS POSTED ON START, deliberately. The obvious tidy-up -- post the
-- quiet state in case a previous generation left the combat one set -- is the
-- wrong move, because a state event is global: a hot reload during a BOT fight
-- would cut the engine's own music, and hot reloading mid-fight is exactly what
-- testing this looks like. The stop path above and the platform's own release
-- of a stopped resource's handles already cover the ordinary reload.
AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    playing = false
    lastPvpAtMs, lastBotAtMs = -math.huge, -math.huge
    inFight = false
end)
