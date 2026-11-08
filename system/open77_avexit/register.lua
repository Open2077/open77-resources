-- open77_avexit -- register.lua
-- Runs on both sides. The server learns the package's clips and their lengths
-- (what `Open77.locomotion.playClip` may play); the client the graph and the
-- four variants in the preloaded archive. A client whose archive is missing
-- or another revision says so here, and its players keep the native exit and
-- boarding.
--
-- THE RESULT IS PUBLISHED (1.1.1): `exports.open77_avexit:Status()` answers
-- `{ ok, style, reason, side }` on either side, so open77_avdoor knows on this
-- game whether its clips can play at all -- and does not hold a body still for
-- a step that draws nothing. A game started without this server's archive
-- (Staging, 2026-10-29: the launcher prepared it for another copy of the
-- server, whose mods were older) says here which world its launcher prepared
-- it for (`Open77.session.launcherContext`).
local side = IsDuplicityVersion ~= nil and IsDuplicityVersion() and 'server' or 'client'
local style, reason = Open77.locomotion.register('package.json')

local status = { ok = style ~= nil, style = style, reason = style == nil and tostring(reason) or nil, side = side }
if exports ~= nil then
    local published, failure = pcall(exports, 'Status', function() return status end)
    if not published then
        Open77.log.warn(('the AV exit package\'s status could not be published on the %s (%s): open77_avdoor '
            .. 'takes the package as there'):format(side, tostring(failure)))
    end
end

--- What the launcher told this game at its start, for the log (client only).
local function launcherWords()
    local session = Open77.session
    if side ~= 'client' or type(session) ~= 'table' or type(session.launcherContext) ~= 'function' then return '' end
    local read, context = pcall(session.launcherContext)
    if not read or type(context) ~= 'table' then return '' end
    if context.launched ~= true then
        return '; this game was not started by the Open77 launcher (Steam, a shortcut): the launcher lays a '
            .. 'world\'s mods only for a game it starts'
    end
    local digest = type(context.modsDigest) == 'string' and context.modsDigest ~= '' and context.modsDigest:sub(1, 12)
        or 'none'
    return ('; the launcher started this game for server %s at %s, with the mods of digest %s -- when that is not '
        .. 'this server\'s (its log: "Required mods: ... digest="), the server list gave out another copy\'s mods'):format(
        tostring(context.serverId ~= '' and context.serverId or '?'),
        tostring(context.connectEndpoint ~= '' and context.connectEndpoint or '?'), digest)
end

if style == nil then
    Open77.log.error(('the AV exit package was not registered on the %s: %s -- exits and boardings are not '
        .. 'animated%s'):format(side, tostring(reason), launcherWords()))
    return
end
Open77.log.info(('AV exit package registered on the %s: style %s (Rosalind Myers, q305; sq012\'s Excalibur boarding; '
    .. 'Corpo V\'s, q000; clips enter, step, sit, step_m, couch)'):format(side, tostring(style)))
