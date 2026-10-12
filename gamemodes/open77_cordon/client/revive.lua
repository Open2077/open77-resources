-- REVIVE -- the player-facing half, which had never been written.
--
-- Everything else was already here: `S.beginRevive` with its squad and reach
-- checks (server/squads.lua:123), the hold timer completed on the mode's tick,
-- the notices, the strings, and the HUD's own revive bar. The only path to any
-- of it was the OPERATOR command `br.revive <healerId> <downedId>`, which exists
-- to prove the mechanism without an interface -- so in a real match, nobody
-- could ever pick a squadmate up. In a squad battle royale that is not a missing
-- polish item; it removes the reason squads exist.
--
-- WHY A POI AND NOT A KEYBIND. `open77_interactions` owns the vanilla-looking
-- prompt and `open77_worldui` renders the ring plus the card, exactly as the
-- loot crates do (client/main.lua:476). Reusing that path means the revive
-- prompt looks and behaves like every other prompt in the mode, obeys the same
-- near-distance rule the owner asked for on loot, and costs no new surface.
--
-- WHY THE BODY AND NOT THE PLAYER. A downed player STOPS PUBLISHING SNAPSHOTS
-- (PlayerReplication.cpp:1735), so his live position is not an answer. The
-- server sends `body`, captured once at death, and the prompt is anchored
-- there. That is also why the platform's own reach check re-derives distance
-- from the HEALER's replicated position against that same body: the client's
-- claim that it is standing on it is a hint, never proof (squads.lua:114).

local REVIVE_POI_RADIUS   = 1.2
local REVIVE_PROMPT_DIST  = 2.5     -- matches cfg().reviveReachMetres
local REVIVE_NEAR_METRES  = 12.0    -- a downed squadmate is worth seeing further
                                    -- than a crate: it is the one thing in the
                                    -- match you are supposed to run towards.

local pois = {}          -- [playerId] = handle
local holding = nil      -- playerId requested/being revived by us, if any
local authoritativeRevive = nil
local usingItem = false
local canRevive = false
local desired, pending, installed = {}, {}, {}
local stopped = false
local context = nil

local function sameBody(a, b)
    return a and a.context == b.context and a.x == b.x and a.y == b.y and a.z == b.z
end

local function call(resource, name, ...)
    if type(Open77.exports) ~= "table" or type(Open77.exports.call) ~= "function" then
        return nil, "exports_unavailable"
    end
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    local ok, result = pcall(function() return promise:await() end)
    if not ok then return nil, "await_failed" end
    if type(result) ~= "table" or result.ok ~= true then
        return nil, (type(result) == "table" and result.error) or "call_failed"
    end
    return result
end

local function removePoi(playerId)
    local handle = pois[playerId]
    if handle == nil then return end
    pois[playerId], installed[playerId] = nil, nil
    local token = {}
    pending[playerId] = token
    call("open77_worldui", "remove", handle)
    if pending[playerId] == token then pending[playerId] = nil end
end

-- The prompt fires with the POI's id, so the downed player's id has to survive
-- the round trip through worldui. It is encoded in the id and read back here
-- rather than kept in a side table, because a side table and a POI can drift
-- apart and an id cannot.
AddEventHandler("cordon:revive:start", function(payload)
    if not canRevive or stopped then return end
    local id = type(payload) == "table" and payload.interactionId or nil
    if type(id) ~= "string" then return end
    local downedId = tonumber(id:match("revive_(%d+)$"))
    if downedId == nil or pois[downedId] == nil or installed[downedId] ~= desired[downedId] then return end

    if usingItem or (authoritativeRevive and authoritativeRevive.pending) then return end
    if holding ~= nil then
        TriggerEvent("cordon:revive:cancel")
        return
    end
    holding = downedId
    -- The server owns the hold: it starts a timer, checks the reach again on
    -- every tick, and completes or cancels. This client says "begin", nothing
    -- more -- a client that counted the seconds itself would be a client that
    -- could revive instantly.
    TriggerServerEvent("cordon:revive", downedId)
end)

-- Cancelling. The server cancels on its own when the healer walks out of reach
-- or the window expires, but it cannot see a player who simply changed his
-- mind. The prompt is a tap: a second tap requests cancellation; releasing F
-- does nothing. Recovery already submitted to the native client is finalizing.
AddEventHandler("cordon:revive:cancel", function()
    if holding == nil or (authoritativeRevive and authoritativeRevive.pending) then return end
    TriggerServerEvent("cordon:reviveCancel", holding)
    holding = nil
end)

AddEventHandler("cordon:state:local", function(payload)
    if type(payload) ~= "table" or stopped then return end

    local wanted = {}
    local squad = payload.squad
    local self_ = type(payload.self) == "table" and payload.self or {}
    local nextRevive = type(self_.revive) == "table" and self_.revive.role == "healer" and self_.revive or nil
    if authoritativeRevive and not nextRevive then holding = nil end
    authoritativeRevive = nextRevive
    usingItem = type(self_.use) == "table"
    canRevive = payload.participant == true and self_.alive == true
        and (self_.state == nil or self_.state == "alive")
        and (payload.phase == nil or payload.phase == "live" or payload.phase == "extraction")
    context = tostring(payload.matchId) .. ":" .. tostring(self_.playerId) .. ":" .. tostring(squad and squad.id)
    if canRevive and type(squad) == "table" and type(squad.members) == "table" then
        for _, member in ipairs(squad.members) do
            -- `downed` is the server's word for "still saveable", and it is not
            -- the same as `alive == false`: a squadmate who has bled out is also
            -- not alive, and offering to revive him would be a lie.
            if member.downed == true and type(member.body) == "table"
                and type(member.playerId) == "number" and member.playerId ~= self_.playerId then
                local body = { context = context, x = member.body.x, y = member.body.y, z = member.body.z }
                wanted[member.playerId] = sameBody(desired[member.playerId], body) and desired[member.playerId] or body
            end
        end
    end

    -- Publish the entire desired set before the first export can yield. Old
    -- handlers must consult this set again after every await, never their payload.
    desired = wanted
    if holding and (desired[holding] == nil or installed[holding] ~= desired[holding]) then
        TriggerServerEvent("cordon:reviveCancel", holding)
        holding = nil
    end
    for playerId in pairs(pois) do
        if installed[playerId] ~= desired[playerId] then removePoi(playerId) end
    end

    for playerId in pairs(desired) do
        local member = desired[playerId]
        if not stopped and member and pois[playerId] == nil and pending[playerId] == nil then
            local token = member
            pending[playerId] = token
            local created = call("open77_worldui", "create", {
                id = "revive_" .. tostring(playerId),
                position = { x = member.x, y = member.y, z = member.z },
                -- Same four styles worldui accepts as the loot POI; an invented
                -- one is a POI that never appears. `objective` rather than
                -- `interaction` on purpose: this is the thing in the match you
                -- are meant to go to, and it should not read as scenery.
                style = "objective",
                radius = REVIVE_POI_RADIUS,
                maxDistance = REVIVE_NEAR_METRES,
                promptDistance = REVIVE_PROMPT_DIST,
                -- Literal, short, and no i18n: the strings table lives in the
                -- HUD resource, which is a separate VM, and open77_interactions
                -- caps label text.
                label = "Revive",
                -- "F", for the same reason as the loot prompt: the game
                -- binds Choice1 to IK_F (r6/config/inputUserMappings.xml:1175)
                -- and this string is only a label. A revive prompt naming the
                -- wrong key is worse than a loot one -- it is read while a
                -- squadmate is bleeding out.
                key = "F",
                icon = "DIALOG",
                event = "cordon:revive:start",
            })
            if created ~= nil and created.handle ~= nil then
                if not stopped and desired[playerId] == token and canRevive then
                    pois[playerId], installed[playerId] = created.handle, token
                else
                    -- Keep the per-player reservation through removal: worldui
                    -- reuses the logical id, so a late remove must not erase a
                    -- newer prompt created with that same id.
                    call("open77_worldui", "remove", created.handle)
                end
            end
            if pending[playerId] == token then pending[playerId] = nil end
        end
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= "open77_cordon" then return end
    stopped, canRevive, desired = true, false, {}
    holding = nil
    for playerId in pairs(pois) do removePoi(playerId) end
end)

-- ---------------------------------------------------------------------------
-- THE GESTURE, AND WHY THERE IS SO LITTLE OF IT.
--
-- The ask was "the ally should play an animation that matches". Three findings
-- decide the shape of the answer, and all three were established before a line
-- of this was written. They are kept here so nobody pays for them twice.
--
-- 1. NOTHING AN EMOTE DOES REACHES ANOTHER PLAYER.
--    `AvatarPresentation::Continuous::pose` is deliberately absent from the
--    wire (`client/src/network/PlayerReplication.cpp:280-320` says so and says
--    why), the player snapshot's flag bits 0..12 are locomotion, weapon and
--    combat only (`networking/include/op77/Networking/Protocol.hpp:960-975`),
--    and a client resource cannot address a remote player's proxy body either:
--    the client `Open77.players` table has life, health and vehicle seat and no
--    playerId -> entity mapping (`scripting/src/ResourceHost.cpp:10380-10388`).
--    Whatever plays here, the enemy on the roof does not see it. The half of
--    the revive he DOES see is the healer's holstered weapon, and that is done
--    on the server (`server/squads.lua`, `S.beginRevive`).
--
-- 2. THE REACHABLE CLIP VOCABULARY IS ONE WORKSPOT, AND IT IS A SMOKING ONE.
--    `Open77.animations.play` is the workspot channel: the body is mounted into
--    a device and `SendJumpToAnimEnt` resolves the clip name INSIDE THE WORKSPOT
--    TREE BOUND TO THAT DEVICE. Open77 ships exactly one device,
--    `cyberm\entities\workspot_anim.ent`, and it references exactly one
--    workspot -- `base\workspots\common\ground\generic__stand_cigar__stand_around__01.workspot`
--    (`assets/wolvenkit/cyberm/entities/workspot_anim.ent.json`; it is the only
--    `.workspot` in the file). The one clip documented as working,
--    `stand__rh_cigar__weight_right__01__smoke__01`, belongs to that family, and
--    so does everything else reachable: look_left, look_right, scratch_nose,
--    smoke. There is no kneel in it. The 23,044 names in
--    `docs/data/emote-animations.txt` are a catalogue of what EXISTS, not of
--    what this device can play --
--    `docs/research/movement-and-animation-replication.md:3042-3070` states the
--    bound as an inference and adds, in as many words, "do not build on it
--    until an `emote.probe` measures it".
--
--    So a clip name asked for here that is not in that tree does not fail
--    quietly: the mount SUCCEEDS and the clip does not resolve, which leaves the
--    healer standing over his dying friend smoking a cigarette. That is exactly
--    the "wrong animation is worse than none" case, and it is why the clip name
--    is a config key that is EMPTY by default.
--
-- 3. THE HOLD IS ALREADY THE RIGHT LENGTH AND ALREADY AUTHORITATIVE.
--    So when a clip does become reachable, nothing here has to change but the
--    string: the server says when the hold starts and how long it lasts, this
--    stops on every exit, and a watchdog guarantees the player is never left
--    mounted in a workspot -- which in a battle royale is a dead player.
-- ---------------------------------------------------------------------------

--- How far the healer may drift before the gesture is abandoned.
---
--- Deliberately much tighter than the server's own reach check, which allows
--- `reviveReachMetres + 1.5` (~4 m) -- that grace exists to tolerate replication
--- lag on the healer's position, not to let a man walk around while he picks
--- somebody up. Standing still does not produce a metre of drift, so this only
--- fires when the player actually leaves.
local REVIVE_ANCHOR_METRES  = 1.0
local PRESENTATION_POLL_MS  = 100

--- nil, or { downedId, untilMs, origin, emoted }.
local presentation = nil

local function nowMs()
    return Open77.time.monotonic() * 1000
end

--- The configured clip, or nil. Nil is the default and the correct default:
--- see finding 2 above.
local function reviveClip()
    local clip = ((Config and Config.squads) or {}).reviveAnimation
    if type(clip) ~= "string" or clip == "" then return nil end
    return clip
end

local function selfState()
    local ok, state = pcall(Open77.character.state)
    if not ok or type(state) ~= "table" then return nil end
    return state
end

--- Idempotent, and called from every exit. A body left mounted in a workspot is
--- the one failure mode of this whole file that costs a life, so the teardown is
--- reachable from the deadline, from drift, from the server's cancel, from the
--- explicit cancellation and from the resource stopping.
local function stopPresentation()
    local active = presentation
    presentation = nil
    if active == nil or not active.emoted then return end
    pcall(Open77.animations.stop, 0)
end

-- The server accepted the hold. THIS is the first moment the client may believe
-- it is reviving anything.
RegisterNetEvent("cordon:revive:hold", function(payload)
    if type(payload) ~= "table" or payload.self == true then return end
    local downedId = tonumber(payload.downedId)
    if downedId == nil then return end
    local holdMs = tonumber(payload.holdMs) or 5000

    stopPresentation()
    -- `holding` was set optimistically on the key press; re-seating it on the
    -- authority's word costs nothing and makes the two agree.
    holding = downedId

    local state = selfState()
    if state == nil then return end
    -- Never mount a body that is not standing on its own feet. A workspot on a
    -- dead or seated player is a body the engine and this resource both think
    -- they own.
    if state.alive == false then return end
    if type(state.vehicle) == "table" and state.vehicle.mounted == true then return end

    local emoted = false
    local clip = reviveClip()
    if clip ~= nil then
        local ok, played = pcall(Open77.animations.play, 0, clip)
        emoted = ok and played == true
    end

    presentation = {
        downedId = downedId,
        untilMs  = nowMs() + holdMs,
        origin   = state.position,
        emoted   = emoted,
    }
end)

-- Explicit tap-to-cancel. A second handler on the same local event rather than a
-- line inside the first: the cancel above owns the SERVER's side of letting go,
-- this owns the body's, and neither should be able to break the other.
AddEventHandler("cordon:revive:cancel", function()
    if not (authoritativeRevive and authoritativeRevive.pending) then stopPresentation() end
end)

-- The server cancels for reasons this client cannot see -- damage to either
-- party, the healer stepping out of reach, the window expiring, the body bleeding
-- out. All of them arrive as a notice, and without this the gesture would run to
-- its deadline over a revive that stopped seconds ago.
RegisterNetEvent("cordon:notice", function(payload)
    if type(payload) ~= "table" then return end
    if payload.kind == "reviveCancelled" or payload.kind == "reviveRefused" then
        holding = nil
        stopPresentation()
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= "open77_cordon" then return end
    stopPresentation()
end)

CreateThread(function()
    while true do
        Wait(PRESENTATION_POLL_MS)
        local active = presentation
        if active ~= nil then
            if holding ~= active.downedId or nowMs() >= active.untilMs then
                -- `holding` is cleared by the state push when the body is gone
                -- (revived, bled out, match over) and by explicit cancellation, so
                -- this one test covers completion and every quiet ending. The
                -- deadline is the backstop that fires even if nothing else does.
                stopPresentation()
            elseif active.origin ~= nil then
                local state = selfState()
                local here = state ~= nil and state.position or nil
                if here ~= nil then
                    local dx = here.x - active.origin.x
                    local dy = here.y - active.origin.y
                    local dz = here.z - active.origin.z
                    if (dx * dx) + (dy * dy) + (dz * dz) >
                        REVIVE_ANCHOR_METRES * REVIVE_ANCHOR_METRES then
                        -- Walking away ends BOTH halves. The server would get
                        -- there on its own once the distance passed its own
                        -- grace, but a revive you have visibly abandoned should
                        -- not keep ticking in your squadmate's HUD.
                        stopPresentation()
                        TriggerServerEvent("cordon:reviveCancel", active.downedId)
                        holding = nil
                    end
                end
            end
        end
    end
end)
