-- =============================================================================
-- open77_media -- server/main.lua
-- =============================================================================
-- The authoritative half of the television feature.
--
-- The server owns one thing: which screen exists, which prop carries it, and
-- what it is showing. The entity itself is an ordinary world prop created
-- through `Open77.props`, so streaming, buckets, replication and cleanup are the
-- props channel's business -- this resource never touches an entity and has no
-- opinion about one.
--
-- Three consequences of that split are worth stating, because each one is a
-- question someone will ask:
--
--   * A television is in exactly one routing bucket: its prop's. A player in
--     another bucket does not receive the screen, because they do not receive
--     the prop.
--   * A client that joins late receives the current state in one snapshot, and a
--     client that reconnects re-binds from the same snapshot. There is no
--     per-client accumulation anywhere in this file.
--   * A television whose prop is removed by another resource is detected at the
--     next broadcast, because the registry is rebuilt from `Open77.props.all()`
--     rather than trusted. That is deliberately timer-free: nothing here runs on
--     a tick, so a server with no televisions has no background cost at all.
--
-- =============================================================================

local MAX_URL_LENGTH = 512
local MAX_TITLE_LENGTH = 96

local media = {}      -- mediaId (number) -> entry
local nextMediaId = 1
local byProp = {}     -- prop id (string) -> mediaId

local function output(source, raw, success, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local function number(value)
    local parsed = tonumber(value)
    if parsed == nil then error("number expected: " .. tostring(value), 0) end
    return parsed
end

local function command(name, usage, restricted, handler)
    RegisterCommand(name, function(source, args, raw)
        if restricted and source ~= nil and source > 0
            and not Open77.acl.isAllowed(source, "command." .. name) then
            return output(source, raw, false, "permission_denied:administrator_only")
        end
        local ok, err = pcall(handler, source, args, raw)
        if not ok then
            output(source, raw, false, string.format("%s -- usage: %s", tostring(err), usage))
        end
    end, restricted == true)
end

local function callerPosition(source)
    if source == nil or source <= 0 then
        error("this command requires an in-game caller", 0)
    end
    local position = Open77.players.position(source)
    if position == nil then
        error(string.format("player %d has no fresh position snapshot", source), 0)
    end
    return position
end

-- =============================================================================
-- URL POLICY
-- =============================================================================
-- A television loads whatever URL it is handed, inside a Chromium surface that
-- belongs to the game process. That makes this the one place in the feature
-- where a string from a player reaches a browser, so the allow-list is written
-- as "these schemes, nothing else" rather than "these schemes are blocked".
--
-- `javascript:` is the obvious one. `file:` and `data:` matter more than they
-- look: the surface is confined to this resource's own web root by CEF's
-- allowed-files list, but a `file:` navigation is a different code path from a
-- resource read, and there is no reason for a television to need one. Anything
-- without a scheme at all is refused rather than assumed to be https.
--
-- This is enforced on the server, not in the page. A page-side check is a
-- convenience for the person typing; it is not a boundary, because the same
-- message can be sent with any client.
local function acceptUrl(url)
    -- Absent and empty are the same answer: a set with nothing to show. The
    -- usage string on every caller -- `media.spawn <record> [yaw] [url]`,
    -- `media.place <record> <x> <y> <z> [yaw] [url]` -- offers the URL as
    -- optional, and it is genuinely optional: `acceptUrl(nil)` refusing with
    -- `url_must_be_a_string` made the bracket a lie, so "spawn a television here"
    -- from the console failed with a message about an argument the operator had
    -- deliberately left out. A non-string that is not nil is still refused by
    -- name -- a number or a table in that slot is a mistake worth reading.
    if url == nil then return "" end
    if type(url) ~= "string" then return nil, "url_must_be_a_string" end
    if url == "" then return "" end
    if #url > MAX_URL_LENGTH then return nil, "url_too_long" end

    local scheme = string.match(url, "^([%a][%w+.-]*):")
    if scheme == nil then return nil, "url_needs_a_scheme" end
    scheme = string.lower(scheme)
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "url_scheme_not_allowed"
    end
    -- Control characters and whitespace never appear in a URL a person means to
    -- type, and they are how a string smuggles a second line into a log or a
    -- header. Refused rather than stripped: silently repairing caller input is
    -- how a caller never learns it is wrong.
    if string.match(url, "%s") or string.match(url, "%c") then
        return nil, "url_contains_whitespace"
    end
    if #url < 12 then return nil, "url_too_short" end
    return url
end

local function acceptText(text, maximum, what)
    if text == nil then return nil end
    if type(text) ~= "string" then return nil, what .. "_must_be_a_string" end
    if #text > maximum then return nil, what .. "_too_long" end
    if string.match(text, "%c") then return nil, what .. "_contains_control_characters" end
    return text
end

-- =============================================================================
-- REPLICATION
-- =============================================================================

---A wire record. Deliberately not the internal entry: the client needs the prop
---id, the record id (for the quad) and the playback state, and nothing else.
---No owner, no proposer, no bucket -- a client that wants a bucket wants the
---prop registry.
local function payload(entry)
    -- `quad` is on the wire, not looked up from `records.lua` on the client, and
    -- that is what makes the quad tunable in game: the server holds the effective
    -- rectangle, so `media.quad` can move a screen by a centimetre without a
    -- rebuild, a resource reload or a second person. The record's own numbers are
    -- only the starting point.
    return {
        id = entry.id,
        prop = entry.prop,
        record = entry.record,
        label = entry.label,
        url = entry.url,
        volume = entry.volume,
        muted = entry.muted,
        paused = entry.paused,
        -- The frame the panel carries, and the curtain in front of it. Both are
        -- the page's to draw and the server's to own: an operator closes a
        -- curtain from the menu or the console, every client draws the same
        -- closed curtain, and a join in the middle of a reveal sees the reveal.
        border = entry.border,
        curtain = entry.curtain,
        -- The panel's heading, for the client half of the reveal effect: the
        -- fireworks are placed in the world, in front of the panel, and the
        -- quad's own offset is in the prop's local frame -- so a client that
        -- only knew the position would put them in the wrong place whenever the
        -- screen is not facing north.
        yaw = entry.yaw,
        quad = entry.quad,
        -- The television's world position, so a client can decide which screens
        -- are worth materialising without a second lookup. A client can only
        -- hold a few CEF surfaces (`kMaximumWebSurfaces`, eight per resource),
        -- and a server may hold sixty-four televisions, so the decision has to
        -- be made somewhere and the client is the only party that knows where
        -- the player is standing.
        position = entry.position,
    }
end

---A private copy of a record's quad. Deep, not a reference: the catalogue is
---shared state and one screen tuning itself must not move every other screen
---that happens to use the same record.
local function copyQuad(quad)
    local function axis(value)
        return { value[1], value[2], value[3] }
    end
    return {
        offset = axis(quad.offset),
        right = axis(quad.right),
        up = axis(quad.up),
        width = quad.width,
        height = quad.height,
    }
end

---Every live screen, rebuilt from the props registry rather than from memory.
---
---This is where a television whose prop was removed by someone else disappears:
---the entry is dropped the next time anyone asks for state, with no timer, no
---sweep and nothing running in the background on a server with no televisions.
local function liveEntries()
    local present = {}
    for _, record in ipairs(Open77.props.all()) do
        present[tostring(record.id)] = true
    end

    local result = {}
    local dropped = false
    for id, entry in pairs(media) do
        if present[tostring(entry.prop)] then
            result[#result + 1] = entry
        else
            media[id] = nil
            byProp[tostring(entry.prop)] = nil
            dropped = true
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result, dropped
end

local function snapshotFor(entries)
    local out = {}
    for _, entry in ipairs(entries) do out[#out + 1] = payload(entry) end
    return out
end

---Pushes the whole live set to one player, or to everyone.
---
---Whole-set rather than deltas, and that is not laziness. The set is small by
---construction (`MEDIA_MAX` below), the client diffs it in one line, and a
---delta stream is one more place for a late joiner to end up with a screen that
---exists on the server and not on their machine.
---Everyone connected, through the two doors the rest of the server uses.
---
---`Open77.players.all()` is the server-side enumerator (`players.ids` does not
---exist -- it is the name this resource used first, and the cost of being wrong
---about it was every broadcast: a television spawned, the prop appeared, the
---command reported success, and no client was ever told about it). The
---`GetPlayers` fallback and the `pcall` pair are copied from `open77_sandevistan`
---and `freeroam`, which ask the same question, so a host that answers one of them
---answers all three.
local function connectedPlayers()
    if type(Open77.players) == "table" and type(Open77.players.all) == "function" then
        local ok, ids = pcall(Open77.players.all)
        if ok and type(ids) == "table" then return ids end
    end
    if type(GetPlayers) == "function" then
        local ok, ids = pcall(GetPlayers)
        if ok and type(ids) == "table" then return ids end
    end
    return {}
end

local function broadcast(target)
    local entries = liveEntries()
    local snapshot = snapshotFor(entries)
    if target ~= nil then
        TriggerClientEvent("open77:media:snapshot", target, snapshot)
        return
    end
    for _, player in ipairs(connectedPlayers()) do
        TriggerClientEvent("open77:media:snapshot", player, snapshot)
    end
end

-- =============================================================================
-- AD BLOCKLIST -- the operator's layer
-- =============================================================================
-- The compiled half of the television's ad blocklist lives in the client, in
-- `webui/include/op77/WebUI/AdBlock.hpp`. This is the other half: the rules an
-- operator can add without a build, a signed catalog and every client updating.
--
-- The split of responsibility is worth stating once, because it is the reason
-- this file is small:
--
--   * THIS RESOURCE owns the list. It validates what an operator types, keeps it
--     in the resource's own `data/` directory, and pushes it to the clients in
--     the session whenever it changes.
--   * EACH CLIENT owns delivery. Its Lua half hands the rules to the process
--     that enforces them and reports back what that process did with them. A
--     client that is not running the plugin, or is running one older than the
--     policy message, is a real state and it answers like one.
--   * THE RULES ONLY EVER ADD. Nothing here can unblock what the compiled list
--     refuses -- that direction is enforced in the client's browser host, not
--     requested from it -- which is why a server is allowed to push a list at
--     all.
--
-- The pure policy (the grammar, the refusals, the payload, the store format) is
-- `server/adblock.lua`, so it can be exercised with no engine, no socket and no
-- client. This section only wires it to the world.
local AdBlock = MediaAdBlock

local blockConfig, blockProblems = AdBlock.buildConfig(MediaServerConfig)
for _, problem in ipairs(blockProblems) do
    print("[open77_media] adblock config: " .. tostring(problem))
end

-- The live list, and where it came from. `blockSource` is reported on every push
-- and in every banner, because "which list is in force" is the first question
-- asked of a blocking rule that is not working.
local blockHosts, blockTokens = {}, {}
local blockRevision = 0
local blockSource = "disabled"
-- playerId -> the last receipt that client reported. Kept so `media.adblock.status`
-- can answer the question the push alone cannot: whether it is in FORCE.
local blockReceipts = {}

local function ioAvailable()
    return type(Open77.io) == "table" and type(Open77.io.readJson) == "function"
        and type(Open77.io.writeJson) == "function"
end

local function persistBlocklist()
    if not ioAvailable() then return false, "filesystem_unavailable" end
    local ok, reason = Open77.io.writeJson(blockConfig.dataFile,
        AdBlock.store(blockHosts, blockTokens, blockRevision))
    if not ok then return false, tostring(reason or "write_failed") end
    return true
end

---Reads the live list: the store if there is one, the config seed if there is not.
---
---One owner at a time, and never both -- see `server/config.lua`. A store that
---exists but cannot be read is reported and then treated as the seed, which is
---the only choice that keeps the feature up rather than taking it down with the
---file.
local function loadBlocklist()
    if not blockConfig.enabled then
        blockHosts, blockTokens, blockSource = {}, {}, "disabled"
        return true
    end
    if ioAvailable() and type(Open77.io.exists) == "function" then
        local exists, existenceError = Open77.io.exists(blockConfig.dataFile)
        if exists then
            local value, readError = Open77.io.readJson(blockConfig.dataFile)
            if value ~= nil then
                blockHosts, blockTokens, blockRevision = AdBlock.loadStore(value)
                blockSource = "data/" .. blockConfig.dataFile
                return true
            end
            print(string.format("[open77_media] adblock: %s unreadable (%s); using the config seed",
                blockConfig.dataFile, tostring(readError)))
        elseif existenceError ~= nil and existenceError ~= "not_found" then
            print(string.format("[open77_media] adblock: %s unreadable (%s); using the config seed",
                blockConfig.dataFile, tostring(existenceError)))
        end
    end
    blockHosts = { table.unpack(blockConfig.hosts) }
    blockTokens = { table.unpack(blockConfig.tokens) }
    blockSource = "server/config.lua"
    return true
end

---Sends the list to one client, or to everyone.
---
---Whole list rather than a delta, for the same reason the television snapshot is
---whole: the list is small, a client applies it in one call, and a delta stream
---is one more place for a late joiner to end up with a list that exists on the
---server and not on their machine.
local function pushBlocklist(target)
    if not blockConfig.enabled then return end
    local payload = AdBlock.policy(blockHosts, blockTokens, blockRevision, blockSource)
    if target ~= nil then
        TriggerClientEvent("open77:media:adblock", target, payload)
        return
    end
    for _, player in ipairs(connectedPlayers()) do
        TriggerClientEvent("open77:media:adblock", player, payload)
    end
end

---Persists, bumps the revision, pushes, and answers whoever asked.
---
---Revision is what makes a receipt meaningful: a client reporting revision 4
---while the server is on 5 is a client that has not been told yet, and the two
---states look identical without the number.
local function commitBlocklist(source, raw, summary)
    blockRevision = blockRevision + 1
    local persisted, persistError = persistBlocklist()
    pushBlocklist(nil)
    local text = string.format("adblock revision %d: %s (%s) from %s",
        blockRevision, summary, AdBlock.describe(blockHosts, blockTokens), blockSource)
    if not persisted then
        text = text .. "\n  warning: could not be persisted (" .. tostring(persistError) ..
            "); this list will be lost when the resource restarts"
    end
    output(source, raw, true, text)
end

loadBlocklist()
print(string.format("[open77_media] adblock %s -- %s from %s",
    blockConfig.enabled and "ready" or "disabled",
    AdBlock.describe(blockHosts, blockTokens), blockSource))

-- The receipt. A client reports what its browser host said, and the two facts
-- this makes visible are the ones nothing else can see: a client whose host
-- refused specific entries, and a client whose host is too old to answer at all.
-- Both are logged here and both are shown by `media.adblock.status`.
RegisterNetEvent("open77:media:adblock:receipt", function(payload)
    local source = source
    if source == nil or type(payload) ~= "table" then return end
    local refused = {}
    if type(payload.refused) == "table" then
        for _, entry in ipairs(payload.refused) do refused[#refused + 1] = tostring(entry) end
    end
    local receipt = {
        revision = math.floor(tonumber(payload.revision) or -1),
        applied = payload.applied == true,
        hosts = math.floor(tonumber(payload.hosts) or 0),
        tokens = math.floor(tonumber(payload.tokens) or 0),
        compiled = math.floor(tonumber(payload.compiled) or 0),
        refused = refused,
        detail = tostring(payload.detail or ""),
        -- The revision the host actually holds, when the client got far enough to
        -- read one. A client reporting revision 4 while the server is on 5 is a
        -- client that has not been told yet -- a different state from a client
        -- whose host never answered, and the two are indistinguishable without
        -- this number.
        observed = tonumber(payload.observed),
        -- The server runtime's own clock, and the only one it publishes: `os` is
        -- NOT in this sandbox (`LuaResourceRuntime` withholds `io`, `os`, `debug`
        -- and `package`), so the `os.time` this used to read threw on EVERY
        -- receipt -- which is what the local server logged as "script error:
        -- open77_media/server/main.lua:399: attempt to index a nil value (global
        -- 'os')" while a client was connected, losing the receipt with it.
        -- `GetGameTimer` is the same unit and meaning as the client's
        -- `Open77.time.monotonic`, per its own comment in the runtime prelude.
        at = GetGameTimer(),
    }
    blockReceipts[source] = receipt
    if receipt.applied then
        print(string.format("[open77_media] adblock enforced on player %d: revision %d, %d hosts + %d tokens (+%d compiled), %d refused",
            source, receipt.revision, receipt.hosts, receipt.tokens, receipt.compiled, #refused))
    else
        print(string.format("[open77_media] adblock NOT enforced on player %d: %s",
            source, receipt.detail ~= "" and receipt.detail or "no_receipt"))
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    blockReceipts[tonumber(playerIdStr) or playerIdStr] = nil
end)

---The operator's console surface. Every mutation goes through one of these, so
---there is exactly one place a rule can enter the live list and exactly one path
---that persists it, pushes it and reports it.
command("media.adblock", "media.adblock", true, function(source, args, raw)
    if not blockConfig.enabled then return output(source, raw, true, "adblock disabled in server/config.lua") end
    local lines = {
        string.format("adblock revision %d -- %s from %s", blockRevision,
            AdBlock.describe(blockHosts, blockTokens), blockSource),
    }
    for _, rule in ipairs(blockHosts) do lines[#lines + 1] = "  host  " .. rule end
    for _, token in ipairs(blockTokens) do lines[#lines + 1] = "  token " .. token end
    if #blockHosts + #blockTokens == 0 then
        lines[#lines + 1] = "  (no operator rules; the compiled client list is unaffected)"
    end
    output(source, raw, true, table.concat(lines, "\n"))
end)

command("media.adblock.add", "media.adblock.add [token] <rule>", true, function(source, args, raw)
    if not blockConfig.enabled then return output(source, raw, false, "adblock disabled in server/config.lua") end
    local spec, specError = AdBlock.parseAddArgs(args)
    if spec == nil then return output(source, raw, false, specError) end
    local rule, reason = AdBlock.add(blockHosts, blockTokens, spec.rule, spec.kind)
    if rule == nil then
        -- The refusal is the useful half of this command: it names what was
        -- wrong while the operator is still looking at what they typed.
        return output(source, raw, false, string.format("refused %q: %s", tostring(spec.rule), tostring(reason)))
    end
    commitBlocklist(source, raw, string.format("%s %s", spec.kind, rule))
end)

command("media.adblock.remove", "media.adblock.remove <rule>", true, function(source, args, raw)
    if args.n ~= 1 then error("wrong argument count", 0) end
    if not AdBlock.remove(blockHosts, blockTokens, args[1]) then
        return output(source, raw, false, "no such rule: " .. tostring(args[1]))
    end
    commitBlocklist(source, raw, "removed " .. tostring(args[1]))
end)

command("media.adblock.clear", "media.adblock.clear", true, function(source, args, raw)
    blockHosts, blockTokens = {}, {}
    commitBlocklist(source, raw, "cleared the operator layer")
end)

command("media.adblock.reload", "media.adblock.reload", true, function(source, args, raw)
    loadBlocklist()
    blockRevision = blockRevision + 1
    pushBlocklist(nil)
    output(source, raw, true, string.format("adblock reloaded from %s: %s (revision %d)",
        blockSource, AdBlock.describe(blockHosts, blockTokens), blockRevision))
end)

command("media.adblock.status", "media.adblock.status", true, function(source, args, raw)
    local lines = { string.format("adblock revision %d, %s", blockRevision,
        AdBlock.describe(blockHosts, blockTokens)) }
    local checked = 0
    for _, player in ipairs(connectedPlayers()) do
        local id = tonumber(player) or player
        local receipt = blockReceipts[id]
        checked = checked + 1
        if receipt == nil then
            lines[#lines + 1] = string.format("  player %s: no receipt yet", tostring(id))
        elseif not receipt.applied then
            lines[#lines + 1] = string.format(
                "  player %s: NOT enforced (%s)%s", tostring(id), receipt.detail,
                receipt.observed ~= nil
                    and string.format("; the host holds revision %d", receipt.observed)
                    or "")
        else
            lines[#lines + 1] = string.format(
                "  player %s: revision %d enforced -- %d hosts + %d tokens (+%d compiled), %d refused",
                tostring(id), receipt.revision, receipt.hosts, receipt.tokens, receipt.compiled,
                #receipt.refused)
            for _, refused in ipairs(receipt.refused) do
                lines[#lines + 1] = "      refused " .. refused
            end
        end
    end
    if checked == 0 then lines[#lines + 1] = "  no players connected" end
    output(source, raw, true, table.concat(lines, "\n"))
end)

local MAX_MEDIA = 64

---The volume a television is created at.
---
---75 rather than 100, and rather than silence. A screen is usually put down in
---company, and a screen that starts at full scale is a screen somebody has to walk
---over and turn down before anything else happens -- every time. A screen that
---starts at zero reads as broken. 75 is audible, clearly not maximum, and is the
---same number the page falls back to before the server has said anything, so the
---first frame and every frame after it agree.
local DEFAULT_VOLUME = 75

---Creates a television: one prop, one screen, bound together by prop id.
---
---The prop is created first. If it is refused there is nothing to bind a screen
---to, and reporting that is more useful than a screen that is permanently blank
---because the prop it names does not exist.
---Clamps a caller-supplied facing. The *position* stays server-authoritative --
---this resource reads it from the player snapshot and never accepts one -- but
---the facing is cosmetic, has no authority attached to it, and the server has no
---way to read it (`Open77.players.position` publishes x, y, z and bucket, and
---there is no heading in the snapshot; `prop.pickup` in the props resource hit
---the same wall and records it). So it is accepted from the client and clamped
---to finite degrees, which is the whole of what a yaw can do.
local function acceptYaw(value)
    if value == nil then return 0.0 end
    local yaw = tonumber(value)
    if yaw == nil or yaw ~= yaw or yaw == math.huge or yaw == -math.huge then return 0.0 end
    return math.max(-360.0, math.min(360.0, yaw))
end

---How far in front of the caller a menu-spawned screen is set down.
---
---The arithmetic is `Open77MediaPlacement.FacingDistance` in shared/placement.lua
----- not a constant here, and not because it is a couple of lines. The catalogue
---grew a cinema, and a 100 ft panel set down at a flat 1.1 m would put its own
---centre 1.9 m BEHIND the person who spawned it: they would be standing inside
---their own screen, looking at the back of it. So the distance follows the panel --
---one screen-height in front of the picture's own centre, floored at the old 1.1 m
---so not one furniture record moves -- and it lives in the tested module for the
---same reason every other placement number does: "the screen landed on me" is a
---picture, not a log line, and the only instrument that can see it is a person.

---Where a menu-spawned screen goes, and which way it faces.
---
---The heading arrives from the caller (the client's `character.state().yaw`,
---clamped), because the server cannot read one. The conversion from heading to a
---direction is the project's own, used by the race client's spawn transforms and
---the pursuit roadblocks: forward is `(-sin, cos)`, and a prop's yaw is a
---rotation about Z in degrees.
---
---The set is turned so the rectangle's own front -- the glass -- looks back at
---the caller, which is what the menu promises. Which yaw that is depends on the
---record, because the catalogue holds two axis conventions:
---
---   * the television family is authored facing its own local +Y (the screen
---     mesh of `television_a_16x9` sits at Y 0.1154, 1 cm inside the body's
---     front face at Y 0.1255), so its yaw is the caller's own plus half a turn;
---   * the monitor, device and bare-screen families are authored facing their
---     own local -X (the glass of `monitor_a_screen` spans X -0.0754..-0.0663
---     around an origin at 0), so theirs is a quarter turn from the caller's
---     heading -- and a fixed half turn used to leave every one of them standing
---     edge-on to the person who spawned it: a sliver of a picture, which reads
---     in game as no screen at all.
---
---So this asks the record. `QuadFront` derives the rectangle's own front from its
---`up` and `right` axes and `FacingYaw` turns it onto the caller's line of sight,
---so a new record is placed correctly the moment it is added and the families
---cannot drift apart again. A record that declares `faces` is carried by that
---declaration instead, so the side the picture is actually on is the side turned
---towards the caller, and the client's render gate (`Faces`, in
---client/src/api/ScreenQuad.hpp) is looking at the same side of the same panel.
---
---`media.place` does not go through this: an operator naming coordinates and a
---yaw is stating where the set is and which way it points, and second-guessing
---that would make it impossible to place one deliberately.
---@param record table|nil the catalogue record, for its quad
---@param position table { x, y, z, bucket }
---@param heading number the caller's own heading, degrees
---@return table placed position
---@return number yaw degrees
local function facingPlacement(record, position, heading)
    local radians = math.rad(heading)

    -- The side carrying the picture, if the record states it; otherwise the
    -- rectangle's own front, which is what the placement is really asking about.
    local front = record ~= nil and record.quad ~= nil and record.quad.faces or nil
    local frontX, frontY, faceZ
    if type(front) == "table" then
        frontX, frontY, faceZ = tonumber(front[1]) or 0.0, tonumber(front[2]) or 0.0, tonumber(front[3]) or 0.0
    else
        frontX, frontY, faceZ = Open77MediaPlacement.QuadFront(record ~= nil and record.quad or nil)
    end

    -- A panel whose front is vertical faces -- no picture is on it in this
    -- engine -- and one that is degenerate cannot be answered; both fall back to
    -- the half turn the catalogue used before placement was derived.
    local yaw = nil
    if frontX ~= nil and (frontX ~= 0.0 or frontY ~= 0.0) then
        yaw = Open77MediaPlacement.FacingYaw(frontX, frontY, heading)
    end
    if yaw == nil then yaw = Open77MediaPlacement.Wrap(heading + 180.0) end

    -- How far ahead of the caller the origin goes, from the size of what is hung
    -- on it: see the note on `FacingDistance` above. Derived from the same `front`
    -- this function just turned towards the caller, so the distance and the facing
    -- cannot disagree about which side of the panel the picture is on.
    local distance = Open77MediaPlacement.FacingDistance(
        record ~= nil and record.quad or nil, frontX, frontY, faceZ)

    return {
        x = position.x - math.sin(radians) * distance,
        y = position.y + math.cos(radians) * distance,
        z = position.z,
        bucket = position.bucket,
    }, yaw
end

local function spawn(recordId, position, yaw, url, source)
    local record = Open77MediaRecord(recordId)
    if record == nil then return nil, "unknown_record" end
    if nextMediaId > MAX_MEDIA then return nil, "too_many_televisions" end

    local cleanUrl, urlError = acceptUrl(url)
    if cleanUrl == nil then return nil, urlError end

    local facing = acceptYaw(yaw)
    -- The record's scale, when it declares one, and a bare `scale` is the whole
    -- of what the props API needs: `circa 26` is accepted as a number and turned
    -- into an equal x/y/z by the wrapper, so nothing here has to pick axes for a
    -- panel that is flat in two of them.
    --
    -- It comes from the RECORD and not from a spawn argument on purpose. The quad
    -- the picture is drawn on is the record's, already multiplied by this same
    -- factor, and the two are only correct together -- a caller who could pass a
    -- scale at spawn time could pass one the quad does not know about, which is a
    -- picture the size of a coaster on a screen the size of a building.
    local prop, propError = Open77.props.create({
        model = record.model,
        position = { x = position.x, y = position.y, z = position.z },
        yaw = facing,
        bucket = position.bucket,
        scale = record.scale,
        -- Optional, and only the cinema records set it: a screen watched from
        -- across a lot must not stop streaming at the prop default.
        streamingRadius = record.streamingRadius,
        -- No collision by default, and this is a fix for a specific problem
        -- rather than a preference. A screen put down within arm's reach is one
        -- the player can be pushed out of the world by, or pinned against, with
        -- the props default of static collision -- the menu path sets the set
        -- down 1.1 m ahead so nothing is ever created *through* the caller, and
        -- this keeps the same promise for the console path, where the operator
        -- names the spot. A screen is not something to stand on, so the honest
        -- answer is that it has no collision at all -- and the prop can then be
        -- moved freely with `media.place` if it is in the way visually.
        --
        -- A record may override that, and the cinema panels do: a 30 m screen is
        -- scenery the audience walks up to, and a picture you can stand inside
        -- reads as a bug in the world rather than a feature of the screen. It is
        -- the record's decision because the record is what knows the size -- the
        -- smallest record here is a 16 cm monitor, and giving that a collider
        -- buys nothing a body would ever notice.
        physics = record.collision == true and "static" or "none",
        collision = record.collision == true,
    })
    if prop == nil then return nil, "prop_create_failed:" .. tostring(propError) end

    local id = nextMediaId
    nextMediaId = nextMediaId + 1

    local entry = {
        id = id,
        prop = tostring(prop),
        record = record.id,
        label = record.label,
        url = cleanUrl or "",
        volume = DEFAULT_VOLUME,
        muted = false,
        paused = false,
        border = type(record.border) == "string" and record.border or nil,
        -- Every screen starts with its curtain open. A curtain is what an
        -- operator puts in front of a film they are about to show, not a state a
        -- screen is born in -- and a television that spawned closed would look
        -- like a television that had failed.
        curtain = "open",
        quad = copyQuad(record.quad),
        position = { x = position.x, y = position.y, z = position.z },
        -- Kept because it is now a placement decision rather than a detail: the
        -- menu path derives it from the caller's heading (`facingPlacement`),
        -- and `media.list` reports it so "which way is it pointing" has an
        -- answer that does not need a screenshot.
        yaw = facing,
        source = source,
    }
    media[id] = entry
    byProp[tostring(prop)] = id
    return entry
end

local function remove(id)
    local entry = media[id]
    if entry == nil then return false end
    media[id] = nil
    byProp[tostring(entry.prop)] = nil
    -- The prop goes with the screen. A screen without its prop would be dropped
    -- by the next `liveEntries` anyway, but removing the prop is what actually
    -- takes the television out of the world, and doing it here means "remove"
    -- from the menu does what it says.
    Open77.props.remove(tonumber(entry.prop) or entry.prop, "media_removed")
    return true
end

local function describeEntry(entry)
    return string.format(
        "media=%d prop=%s record=%s pos=%.2f,%.2f,%.2f yaw=%.1f " ..
        "curtain=%s border=%s url=%s volume=%d muted=%s paused=%s",
        entry.id, tostring(entry.prop), tostring(entry.record),
        tonumber(entry.position.x) or 0.0, tonumber(entry.position.y) or 0.0,
        tonumber(entry.position.z) or 0.0,
        tonumber(entry.yaw) or 0.0,
        tostring(entry.curtain or "open"),
        entry.border == nil and "none" or tostring(entry.border),
        entry.url == "" and "(idle screen)" or entry.url,
        entry.volume, tostring(entry.muted), tostring(entry.paused))
end

-- =============================================================================
-- COMMANDS
-- =============================================================================

command("media.records", "media.records", true, function(source, args, raw)
    local counter = {}
    for _, counterEntry in ipairs(Open77MediaCatalogue()) do
        counter[#counter + 1] = counterEntry
    end
    local lines = { string.format("%d television records:", #counter) }
    for _, record in ipairs(counter) do
        lines[#lines + 1] = string.format(
            "  %-12s %-26s %s  (%.2fx%.2f m)",
            record.id, record.label, record.model, record.quad.width, record.quad.height)
    end
    output(source, raw, true, table.concat(lines, "\n"))
end)

command("media.spawn", "media.spawn <record> [yaw] [url]", true, function(source, args, raw)
    if args.n < 1 or args.n > 3 then error("wrong argument count", 0) end
    local position = callerPosition(source)
    local entry, reason = spawn(args[1], position, args[2] and number(args[2]) or 0.0,
        args[3], source)
    if entry == nil then
        return output(source, raw, false, "media spawn failed: " .. tostring(reason))
    end
    broadcast(nil)
    output(source, raw, true, string.format(
        "television %d created here (%s, prop=%s)", entry.id, entry.record, entry.prop))
end)

command("media.place", "media.place <record> <x> <y> <z> [yaw] [url]", true,
    function(source, args, raw)
        if args.n < 4 or args.n > 6 then error("wrong argument count", 0) end
        local position = {
            x = number(args[2]), y = number(args[3]), z = number(args[4]),
            bucket = source ~= nil and source > 0 and callerPosition(source).bucket or 0,
        }
        local entry, reason = spawn(args[1], position, args[5] and number(args[5]) or 0.0,
            args[6], source)
        if entry == nil then
            return output(source, raw, false, "media spawn failed: " .. tostring(reason))
        end
        broadcast(nil)
        output(source, raw, true, string.format(
            "television %d created at %.2f,%.2f,%.2f (%s)", entry.id,
            position.x, position.y, position.z, entry.record))
    end)

command("media.url", "media.url <id> <url>", true, function(source, args, raw)
    if args.n ~= 2 then error("wrong argument count", 0) end
    local entry = media[math.floor(number(args[1]))]
    if entry == nil then return output(source, raw, false, "no such television") end
    local url, urlError = acceptUrl(args[2])
    if url == nil then
        return output(source, raw, false, "url refused: " .. tostring(urlError))
    end
    entry.url = url
    broadcast(nil)
    output(source, raw, true, string.format(
        "television %d now showing %s", entry.id,
        url == "" and "its idle screen" or url))
end)

command("media.title", "media.title <id> <text>", true, function(source, args, raw)
    if args.n ~= 2 then error("wrong argument count", 0) end
    local entry = media[math.floor(number(args[1]))]
    if entry == nil then return output(source, raw, false, "no such television") end
    local label, labelError = acceptText(args[2], MAX_TITLE_LENGTH, "title")
    if label == nil then
        return output(source, raw, false, "title refused: " .. tostring(labelError))
    end
    entry.label = label
    broadcast(nil)
    output(source, raw, true, string.format("television %d is now '%s'", entry.id, label))
end)

command("media.volume", "media.volume <id> <0-100>", true, function(source, args, raw)
    if args.n ~= 2 then error("wrong argument count", 0) end
    local entry = media[math.floor(number(args[1]))]
    if entry == nil then return output(source, raw, false, "no such television") end
    local volume = math.floor(number(args[2]))
    if volume < 0 or volume > 100 then error("volume must be 0..100", 0) end
    entry.volume = volume
    broadcast(nil)
    output(source, raw, true, string.format("television %d volume %d", entry.id, volume))
end)

command("media.mute", "media.mute <id> <on|off>", true, function(source, args, raw)
    if args.n ~= 2 then error("wrong argument count", 0) end
    local entry = media[math.floor(number(args[1]))]
    if entry == nil then return output(source, raw, false, "no such television") end
    local state = string.lower(tostring(args[2]))
    if state ~= "on" and state ~= "off" then error("state must be on or off", 0) end
    entry.muted = state == "on"
    broadcast(nil)
    output(source, raw, true, string.format(
        "television %d muted=%s", entry.id, tostring(entry.muted)))
end)

command("media.pause", "media.pause <id> <on|off>", true, function(source, args, raw)
    if args.n ~= 2 then error("wrong argument count", 0) end
    local entry = media[math.floor(number(args[1]))]
    if entry == nil then return output(source, raw, false, "no such television") end
    local state = string.lower(tostring(args[2]))
    if state ~= "on" and state ~= "off" then error("state must be on or off", 0) end
    entry.paused = state == "on"
    broadcast(nil)
    output(source, raw, true, string.format(
        "television %d paused=%s", entry.id, tostring(entry.paused)))
end)

---The curtain, from the console.
---
---`reveal` is the whole presentation and is what a cinema wants: the curtain
---drops, the panel counts down 3-2-1, the colours go up, and the panels part on
---`LINK START`. It is the race start's own effect -- `race.firework.burst` with
---two `race.flare.smoke` columns, and `sq024_race_countdown` / `sq024_race_start`
----- played by each client at the screen, because that is what the race resource
---does at a start line and there is no reason to build a second one.
command("media.curtain", "media.curtain <id> <open|closed|reveal>", true,
    function(source, args, raw)
        if args.n ~= 2 then error("wrong argument count", 0) end
        local entry = media[math.floor(number(args[1]))]
        if entry == nil then return output(source, raw, false, "no such television") end
        local state = string.lower(tostring(args[2]))
        if state ~= "open" and state ~= "closed" and state ~= "reveal" then
            return output(source, raw, false, "curtain must be open, closed or reveal")
        end
        entry.curtain = state
        broadcast(nil)
        output(source, raw, true, string.format(
            "television %d curtain=%s", entry.id, state))
    end)

command("media.remove", "media.remove <id>", true, function(source, args, raw)
    if args.n ~= 1 then error("wrong argument count", 0) end
    local id = math.floor(number(args[1]))
    if not remove(id) then return output(source, raw, false, "no such television") end
    broadcast(nil)
    output(source, raw, true, string.format("television %d removed", id))
end)

-- =============================================================================
-- PLACEMENT: WHERE THE SET STANDS AND WHICH WAY IT POINTS
-- =============================================================================
-- A television is spawned about a metre in front of the player who asked for it,
-- which is the right default and never quite the right answer: it ends up
-- hovering over a crate, half inside a wall, or a hand's width away from flush
-- with the shelf it was meant to sit on. Fixing that by hand meant
-- `media.remove` and re-spawning until it landed, which throws away the URL and
-- resets the volume -- and there was no way at all to turn a set that had come
-- out facing the wrong way.
--
-- So a set can be nudged and turned. The arithmetic (which way "left" is, what a
-- turn does to the heading) is in `shared/placement.lua`, pure and tested; this
-- is the half that talks to the prop registry.
--
-- The prop is patched, never respawned: `Open77.props.setTransform` changes the
-- transform of the entity that is already there, so every player watching sees
-- the set slide rather than a set disappear and a new one appear, and the screen
-- needs nothing at all -- the quad is in the prop's own frame, so it follows the
-- cabinet for free.

---Applies a placement to a set, and leaves the entry alone if the registry says
---no. Returns the reason on refusal, which is the caller's to report.
---@param entry table the media entry
---@param position table|nil the new position, or nil to keep the current one
---@param yaw number|nil the new heading, or nil to keep the current one
---@return boolean ok
---@return string|nil reason
local function applyPlacement(entry, position, yaw)
    if entry == nil then return false, "no_such_television" end
    local target = position or entry.position
    local facing = yaw or entry.yaw
    if type(target) ~= "table" or facing == nil then
        return false, "no_placement_recorded"
    end
    local ok, reason = Open77.props.setTransform(tonumber(entry.prop) or entry.prop, {
        position = { x = target.x, y = target.y, z = target.z, bucket = target.bucket },
        yaw = facing,
    })
    if not ok then
        return false, "prop_move_rejected:" .. tostring(reason)
    end
    -- Only on success: `media.list` reads these, and a refused move that updated
    -- them would report a set standing somewhere it is not.
    entry.position = {
        x = target.x, y = target.y, z = target.z, bucket = target.bucket,
    }
    entry.yaw = facing
    return true, nil
end

command("media.move", "media.move <id> <forward|back|left|right|up|down> [metres]", true,
    function(source, args, raw)
        if args.n < 2 or args.n > 3 then error("wrong argument count", 0) end
        local entry = media[math.floor(number(args[1]))]
        if entry == nil then return output(source, raw, false, "no such television") end
        local direction = string.lower(tostring(args[2]))
        local metres = args[3] and number(args[3]) or nil
        local position, moveError = Open77MediaPlacement.Nudge(
            entry.position, entry.yaw, direction, metres)
        if position == nil then
            return output(source, raw, false, "move refused: " .. tostring(moveError))
        end
        local ok, reason = applyPlacement(entry, position, nil)
        if not ok then
            return output(source, raw, false, "move refused: " .. tostring(reason))
        end
        broadcast(nil)
        output(source, raw, true, string.format(
            "television %d moved %s to %.2f,%.2f,%.2f (yaw %.1f)", entry.id,
            direction, entry.position.x, entry.position.y, entry.position.z, entry.yaw))
    end)

command("media.rotate", "media.rotate <id> <left|right> [degrees]", true,
    function(source, args, raw)
        if args.n < 2 or args.n > 3 then error("wrong argument count", 0) end
        local entry = media[math.floor(number(args[1]))]
        if entry == nil then return output(source, raw, false, "no such television") end
        local direction = string.lower(tostring(args[2]))
        local degrees = args[3] and number(args[3]) or nil
        local yaw, turnError = Open77MediaPlacement.Turn(entry.yaw, direction, degrees)
        if yaw == nil then
            return output(source, raw, false, "rotate refused: " .. tostring(turnError))
        end
        local ok, reason = applyPlacement(entry, nil, yaw)
        if not ok then
            return output(source, raw, false, "rotate refused: " .. tostring(reason))
        end
        broadcast(nil)
        output(source, raw, true, string.format(
            "television %d turned %s to yaw %.1f", entry.id, direction, entry.yaw))
    end)

-- Live quad tuning, and the reason the quad is on the wire at all.
--
-- The catalogue's rectangles are authored estimates: the props hosts publish no
-- screen dimension and the only way to measure one is to look at it in game.
-- This command is what turns that from "edit a file, reload the resource, walk
-- back, look again" into "nudge it and watch". The geometry is echoed back in a
-- form that can be pasted straight into `shared/records.lua` when it is right.
--
-- `media.quad <id> width=<m> height=<m> offx= offy= offz= rightx= righty= rightz=
--             upx= upy= upz=` -- any subset, in any order.
command("media.quad", "media.quad <id> [width=] [height=] [offx= offy= offz=] [upx= upy= upz=]",
    true, function(source, args, raw)
        if args.n < 2 then error("wrong argument count", 0) end
        local entry = media[math.floor(number(args[1]))]
        if entry == nil then return output(source, raw, false, "no such television") end

        local quad = entry.quad
        local applied = 0
        for index = 2, args.n do
            local key, value = string.match(tostring(args[index]), "^([%a_]+)=(.+)$")
            if key == nil then
                return output(source, raw, false,
                    "expected key=value, got " .. tostring(args[index]))
            end
            local parsed = tonumber(value)
            if parsed == nil then
                return output(source, raw, false, "not a number: " .. tostring(value))
            end
            local target, component = nil, nil
            local head, tail = string.match(key, "^(%a+)([xyz])$")
            if head == "off" then target = quad.offset elseif head == "right" then
                target = quad.right elseif head == "up" then target = quad.up end
            if tail == "x" then component = 1 elseif tail == "y" then component = 2
            elseif tail == "z" then component = 3 end
            if target ~= nil and component ~= nil then
                target[component] = parsed
            elseif key == "width" or key == "height" then
                if not (parsed > 0.01 and parsed <= 100.0) then
                    return output(source, raw, false, key .. " must be 0.01..100 metres")
                end
                quad[key] = parsed
            else
                return output(source, raw, false, "unknown knob: " .. tostring(key))
            end
            applied = applied + 1
        end

        if applied == 0 then return output(source, raw, false, "nothing to change") end
        broadcast(nil)
        output(source, raw, true, string.format(
            "television %d quad: width=%.3f height=%.3f\n  offset = { %.3f, %.3f, %.3f }\n" ..
            "  right  = { %.3f, %.3f, %.3f }\n  up     = { %.3f, %.3f, %.3f }",
            entry.id, quad.width, quad.height,
            quad.offset[1], quad.offset[2], quad.offset[3],
            quad.right[1], quad.right[2], quad.right[3],
            quad.up[1], quad.up[2], quad.up[3]))
    end)

-- Puts a screen back on its record's authored rectangle.
command("media.quad.reset", "media.quad.reset <id>", true, function(source, args, raw)
    if args.n ~= 1 then error("wrong argument count", 0) end
    local entry = media[math.floor(number(args[1]))]
    if entry == nil then return output(source, raw, false, "no such television") end
    local record = Open77MediaRecord(entry.record)
    if record == nil then return output(source, raw, false, "record gone") end
    entry.quad = copyQuad(record.quad)
    broadcast(nil)
    output(source, raw, true, string.format("television %d quad reset", entry.id))
end)

command("media.list", "media.list", true, function(source, args, raw)
    local entries = liveEntries()
    if #entries == 0 then return output(source, raw, true, "no televisions") end
    local lines = { string.format("%d television(s):", #entries) }
    for _, entry in ipairs(entries) do lines[#lines + 1] = "  " .. describeEntry(entry) end
    output(source, raw, true, table.concat(lines, "\n"))
end)

-- =============================================================================
-- CLIENT PROTOCOL
-- =============================================================================

-- Network events do not inherit RegisterCommand's ACL. Check the matching
-- command permission again on every request, including after role revocation.
local function allowControl(source, commandName)
    if source ~= nil and source > 0
        and Open77.acl.isAllowed(source, "command." .. commandName) == true then return true end
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:media:result", source, false, "permission_denied:administrator_only")
    end
    return false
end

local controlCommands = {
    spawn = "media.spawn", quad = "media.quad", -- explicitly refused on this event below
    url = "media.url", title = "media.title", volume = "media.volume",
    muted = "media.mute", paused = "media.pause", curtain = "media.curtain",
    move = "media.move", rotate = "media.rotate", remove = "media.remove",
}

-- A client asks for the current set on join. It is not credited with knowing
-- anything: the answer is the same whole-set snapshot everyone else gets.
RegisterNetEvent("open77:media:ready", function()
    local source = source
    if source == nil then return end
    local entries = liveEntries()
    TriggerClientEvent("open77:media:snapshot", source, snapshotFor(entries))
    -- The blocklist goes out with the snapshot, and for the same reason: a client
    -- that has just joined is exactly the client whose television is about to
    -- load somebody else's page. It is pushed again whenever the list changes, so
    -- this is the join case only.
    pushBlocklist(source)
end)

-- The menu's path to every mutation, so the same validation serves the console
-- and the UI without one being able to do something the other cannot.
--
-- Every branch re-reads the entry from `media` rather than trusting anything in
-- the payload except an id and a value: a client can send any table it likes,
-- and the only fields it is allowed to influence are the four below.
RegisterNetEvent("open77:media:control", function(action, payload)
    local source = source
    if source == nil or type(action) ~= "string" or type(payload) ~= "table" then return end
    local commandName = controlCommands[action]
    if commandName == nil then
        TriggerClientEvent("open77:media:result", source, false, "unknown_action")
        return
    end
    if not allowControl(source, commandName) then return end
    local entry = media[math.floor(tonumber(payload.id) or -1)]
    if entry == nil then
        -- Answered, not swallowed.
        --
        -- This returned in silence, and silence is the reason a volume or mute
        -- complaint could not be settled from a log: a page asking about a
        -- television the server does not have produced no reply, no line, and no
        -- distinction from a request that never arrived at all. The id is the
        -- whole content of the message when it goes wrong, so the answer names
        -- it -- and a client whose row carries no id now says so out loud
        -- instead of looking like a control that does nothing.
        TriggerClientEvent("open77:media:result", source, false,
            "unknown_media_id:" .. tostring(payload.id))
        return
    end

    if action == "spawn" then
        -- Spawning needs a world position and is handled on its own event, so
        -- that a `control` message can never be the thing that creates an
        -- entity. Reaching here with "spawn" means a caller used the wrong
        -- event, and saying so is cheaper than guessing.
        TriggerClientEvent("open77:media:result", source, false, "use_open77_media_spawn")
        return
    end

    if action == "quad" then
        -- Not reachable from the menu and not meant to be: there is no UI for a
        -- screen rectangle and a player nudging one would move a screen other
        -- players are watching. `media.quad` is the operator's path.
        TriggerClientEvent("open77:media:result", source, false, "quad_is_operator_only")
        return
    elseif action == "url" then
        local url, urlError = acceptUrl(payload.url)
        if url == nil then
            TriggerClientEvent("open77:media:result", source, false, tostring(urlError))
            return
        end
        entry.url = url
        -- A link is a play request, so setting one clears a pause.
        --
        -- Leaving it set is what put a black rectangle on a 100 ft screen while
        -- the same link played on the unpaused set beside it: a paused player
        -- never starts, paints nothing, and the page's own recovery refuses to
        -- nudge a player the operator asked to pause. The transport is this
        -- resource's state, so "a new link starts playing" belongs here as well
        -- as in `web/tv.js`; pausing afterwards still does exactly what it did.
        entry.paused = false
    elseif action == "title" then
        local label, labelError = acceptText(payload.title, MAX_TITLE_LENGTH, "title")
        if label == nil then
            TriggerClientEvent("open77:media:result", source, false, tostring(labelError))
            return
        end
        entry.label = label
    elseif action == "volume" then
        local volume = math.floor(tonumber(payload.volume) or -1)
        if volume < 0 or volume > 100 then
            TriggerClientEvent("open77:media:result", source, false, "volume_out_of_range")
            return
        end
        entry.volume = volume
    elseif action == "muted" or action == "paused" then
        if type(payload.value) ~= "boolean" then
            TriggerClientEvent("open77:media:result", source, false, "value_must_be_boolean")
            return
        end
        entry[action] = payload.value
    elseif action == "curtain" then
        -- Three states, and a closed set rather than a colour or a string a page
        -- could invent: `closed` is the curtain in front of the panel, `open` is
        -- it out of the way, and `reveal` is the presentation -- the countdown
        -- and the colours, then the panels part. Every client draws the same
        -- three because the server is the only writer, and a joiner walking in
        -- mid-reveal sees the reveal.
        local value = tostring(payload.value or "")
        if value ~= "open" and value ~= "closed" and value ~= "reveal" then
            TriggerClientEvent("open77:media:result", source, false, "curtain_must_be_open_closed_or_reveal")
            return
        end
        entry.curtain = value
    elseif action == "move" then
        -- The menu's path to the same arithmetic the `media.move` command uses.
        -- Both go through `Open77MediaPlacement`, so the distance clamps and the
        -- axis convention are decided in one place; the only thing this branch
        -- adds is that a payload cannot ask for a nudge larger than the step
        -- ceiling, because this message comes from a client.
        local position, moveError = Open77MediaPlacement.Nudge(entry.position, entry.yaw,
            payload.direction, tonumber(payload.metres) or nil)
        if position == nil then
            TriggerClientEvent("open77:media:result", source, false,
                "move_refused:" .. tostring(moveError))
            return
        end
        local moved, moveReason = applyPlacement(entry, position, nil)
        if not moved then
            TriggerClientEvent("open77:media:result", source, false,
                "move_refused:" .. tostring(moveReason))
            return
        end
    elseif action == "rotate" then
        local yaw, turnError = Open77MediaPlacement.Turn(entry.yaw, payload.direction,
            tonumber(payload.degrees) or nil)
        if yaw == nil then
            TriggerClientEvent("open77:media:result", source, false,
                "rotate_refused:" .. tostring(turnError))
            return
        end
        local turned, turnReason = applyPlacement(entry, nil, yaw)
        if not turned then
            TriggerClientEvent("open77:media:result", source, false,
                "rotate_refused:" .. tostring(turnReason))
            return
        end
    elseif action == "remove" then
        remove(entry.id)
    else
        TriggerClientEvent("open77:media:result", source, false, "unknown_action")
        return
    end

    broadcast(nil)
    TriggerClientEvent("open77:media:result", source, true, describeEntry(media[entry.id] or entry))
end)

-- Spawn from the menu. Kept separate from `control` because it is the only
-- media message that creates a world entity, and it carries its own position
-- instead of naming an existing screen.
RegisterNetEvent("open77:media:spawn", function(payload)
    local source = source
    if source == nil or type(payload) ~= "table" then return end
    if not allowControl(source, "media.spawn") then return end
    local record = tostring(payload.record or "")
    local definition = Open77MediaRecord(record)
    if definition == nil then
        TriggerClientEvent("open77:media:result", source, false, "unknown_record")
        return
    end

    -- The position is the caller's own, read server-side. A client-supplied
    -- position would let any client put a screen anywhere in the world,
    -- including inside someone else's building, and the menu has no need for
    -- that: it spawns where the player is standing.
    local position = Open77.players.position(source)
    if position == nil then
        TriggerClientEvent("open77:media:result", source, false, "no_position_snapshot")
        return
    end

    -- Set down in front of the caller and turned to face them, rather than
    -- created through them. See `facingPlacement`.
    local placed, facing = facingPlacement(definition, position, acceptYaw(payload.yaw))
    local entry, reason = spawn(record, placed, facing, payload.url, source)
    if entry == nil then
        TriggerClientEvent("open77:media:result", source, false, tostring(reason))
        return
    end
    -- The placement is on the record as well as in the world, so `media.list`
    -- -- the only view an operator has -- reports where the set actually is.
    print(string.format("media %d placed: record=%s model=%s at %.2f,%.2f,%.2f yaw=%.1f",
        entry.id, entry.record, record, entry.position.x, entry.position.y,
        entry.position.z, entry.yaw))
    broadcast(nil)
    TriggerClientEvent("open77:media:result", source, true,
        string.format("television %d created", entry.id))
end)

-- The catalogue, for the menu. Served rather than duplicated in the page so a
-- record added here appears in the menu without a second edit.
RegisterNetEvent("open77:media:catalogue", function()
    local source = source
    if source == nil then return end
    if not allowControl(source, "media.records") then return end
    local out = {}
    for _, record in ipairs(Open77MediaCatalogue()) do
        out[#out + 1] = {
            id = record.id,
            label = record.label,
            model = record.model,
            blurb = record.blurb,
            width = record.quad.width,
            height = record.quad.height,
        }
    end
    TriggerClientEvent("open77:media:catalogue", source, out)
end)

print("open77_media ready -- " .. tostring(#Open77MediaCatalogue()) .. " television records")
