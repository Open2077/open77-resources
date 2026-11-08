-- =============================================================================
-- open77_avdrive -- shared/core.lua
-- =============================================================================
-- What both halves read the same way: the event names, which records fly, the
-- player-facing words, and a millisecond clock.
-- =============================================================================

AvDrive = AvDrive or {}
local M = AvDrive

M.RESOURCE = 'open77_avdrive'
M.VERSION = '1.2.0'
M.Settings = Open77AvDriveConfig or {}

M.Event = {
    -- Client to server: the one key was pressed. The payload is a SUGGESTION of
    -- where to fly -- the client's own map waypoint, or the flag saying the map
    -- could not be read. The server re-derives the seat, the hull and the
    -- record from the connection; the payload only ever names the destination.
    TOGGLE = 'open77_avdrive:toggle',
    -- Server to client: what the pilot reads -- `{ key, kind }`, a text key.
    NOTICE = 'open77_avdrive:notice',
    -- Server to the games of everybody aboard (1.1.0, the arrival):
    -- `{ token, state, pilot, ... }`. 'out': fade the screen out (`ms`,
    -- `timeoutMs`; `paceMs`, 1.2.0: how often the pilot's game says where it
    -- has the aircraft while it is flown under the black -- only the pilot's
    -- game answers); 'measure', to the pilot's game only: the aircraft is over
    -- the pin, measure the ground under it (`x`, `y`, `fromZ`, `settleMs`,
    -- `measureMs`); 'in': the screen back (`ms`, `why`; `ownWaitMs`, 1.2.0:
    -- how long the pilot's game watches for the controls).
    ARRIVE = 'open77_avdrive:arrive',
    -- Client to server (1.1.0): the pilot's game on the arrival --
    -- `{ token, state, ... }`: 'black' (its screen is covered), 'failed' (it
    -- could not fade, or its fade ended under the flight: `reason`), 'pace'
    -- (1.2.0: `drawn`, its copy of the aircraft; `bodyAt` and `body`, its body
    -- and how far from that copy; `owned`; `loading`, `loadingKind`;
    -- `undrawn`, why it has no aircraft to show), 'ground' (`z`, nil when
    -- nothing was met; `reads`, `ms`; `drawnOff`, `body`, `loading`), 'after'
    -- (1.2.0: `owned`, whether it simulates the aircraft once the image is
    -- back; `ms`; `loading`). The server hears only the run's own pilot, and
    -- only for the run's own token: no word moves anything the server did not
    -- plan, and a position in one is never believed past the world's bounds.
    ARRIVE_READY = 'open77_avdrive:arriveReady',
}

M.Command = { STATUS = 'avdrive.status' }

--- Milliseconds on the host's monotonic clock.
function M.Now()
    local time = type(Open77) == 'table' and Open77.time or nil
    if type(time) == 'table' and type(time.monotonic) == 'function' then
        local read, seconds = pcall(time.monotonic)
        if read and type(seconds) == 'number' then return math.floor(seconds * 1000.0) end
    end
    if type(os) == 'table' and type(os.clock) == 'function' then return math.floor(os.clock() * 1000.0) end
    return 0
end

--- Whether a record is one the autopilot flies (`RECORDS`).
-- @param record any
-- @return boolean
function M.Flies(record)
    if type(record) ~= 'string' or record == '' then return false end
    local list = type(M.Settings) == 'table' and M.Settings.RECORDS or nil
    if type(list) ~= 'table' then list = { '^vehicle%.av_', '^vehicle%.max_tac_av$' } end
    local lowered = record:lower()
    for _, pattern in ipairs(list) do
        if type(pattern) == 'string' and pattern ~= '' then
            local read, found = pcall(string.find, lowered, pattern:lower())
            if read and found ~= nil then return true end
        end
    end
    return false
end

-- ── the words ────────────────────────────────────────────────────────────────

M.Strings = {
    en = {
        ['key.toggle'] = 'Toggle the AV autopilot',
        ['engaged'] = 'Autopilot on: flying to your waypoint. Press again to take the controls.',
        ['arriving'] = 'Autopilot on: taking you to your waypoint. Press again to take the controls.',
        ['cancelled'] = 'Autopilot off. You have the controls.',
        ['arrived'] = 'Autopilot: holding at the waypoint. The controls are yours.',
        ['stalled'] = 'Autopilot off: the aircraft could not be flown there. The controls are yours.',
        ['pilotLeft'] = 'Autopilot off: you left the controls.',
        ['timeout'] = 'Autopilot off: the flight took too long.',
        ['notSeated'] = 'You are not sitting in anything to fly.',
        ['notAv'] = 'The autopilot flies aircraft. That is not one.',
        ['noAircraft'] = 'The aircraft you are in could not be read.',
        ['noWaypoint'] = 'Drop a waypoint on the map first.',
        ['waypointUnavailable'] = 'The map could not be read, so there is nowhere to fly.',
        ['tooFar'] = 'That waypoint is too far. Fly closer and try again.',
        ['busy'] = 'That aircraft is already under autopilot.',
        ['notPilot'] = 'Only whoever flies this aircraft can use its autopilot.',
        ['rateLimited'] = 'Slow down and try again in a moment.',
        ['unavailable'] = 'The autopilot is unavailable on this server.',
    },
    fr = {
        ['key.toggle'] = 'Activer ou couper le pilote automatique de l\u{2019}AV',
        ['engaged'] = 'Pilote automatique : cap sur votre point de repère. Appuyez encore pour reprendre les commandes.',
        ['arriving'] = 'Pilote automatique : en route vers votre point de repère. Appuyez encore pour reprendre les commandes.',
        ['cancelled'] = 'Pilote automatique désactivé. Les commandes sont à vous.',
        ['arrived'] = 'Pilote automatique : stationnement au point de repère. Les commandes sont à vous.',
        ['stalled'] = 'Pilote automatique désactivé : l\u{2019}aéronef n\u{2019}a pas pu y être mené. Les commandes sont à vous.',
        ['pilotLeft'] = 'Pilote automatique désactivé : vous avez quitté les commandes.',
        ['timeout'] = 'Pilote automatique désactivé : le vol a duré trop longtemps.',
        ['notSeated'] = 'Vous n\u{2019}êtes assis dans rien à piloter.',
        ['notAv'] = 'Le pilote automatique vole des aéronefs. Ceci n\u{2019}en est pas un.',
        ['noAircraft'] = 'L\u{2019}aéronef dans lequel vous êtes n\u{2019}a pas pu être lu.',
        ['noWaypoint'] = 'Posez d\u{2019}abord un point de repère sur la carte.',
        ['waypointUnavailable'] = 'La carte n\u{2019}a pas pu être lue : nulle part où voler.',
        ['tooFar'] = 'Ce point de repère est trop loin. Approchez et réessayez.',
        ['busy'] = 'Cet aéronef est déjà sous pilote automatique.',
        ['notPilot'] = 'Seul celui qui pilote cet aéronef peut utiliser son pilote automatique.',
        ['rateLimited'] = 'Ralentissez et réessayez dans un instant.',
        ['unavailable'] = 'Le pilote automatique est indisponible sur ce serveur.',
    },
}

-- The engine's own codes that are not the two-letter ones.
local ENGINE_CODES = { jp = 'ja', kr = 'ko', cz = 'cs', ua = 'uk' }

--- A player-facing text in this game's language: its text language, then its
--- locale tag; English when it has none of this resource's languages or has
--- not reported. Empty on a server: the server sends keys, never words.
-- @param key string
-- @return string
function M.Text(key)
    local lang = 'en'
    local session = type(Open77) == 'table' and Open77.session or nil
    if type(session) == 'table' and type(session.locale) == 'function' then
        local read, reported = pcall(session.locale)
        if read and type(reported) == 'table' then
            for _, code in ipairs({ reported.gameLanguage, reported.code }) do
                if type(code) == 'string' and #code >= 2 then
                    local head = code:sub(1, 2):lower()
                    head = ENGINE_CODES[head] or head
                    if M.Strings[head] ~= nil then lang = head break end
                end
            end
        end
    end
    return (M.Strings[lang] or {})[key] or M.Strings.en[key] or key
end
