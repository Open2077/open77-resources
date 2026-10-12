-- Viewer commands, server half.
--
-- The editor authors a placement; these are how a player looks at one. Four
-- restricted commands, one per job:
--
--   /remote-camera.cameras [filter]          every camera this resource owns
--   /remote-camera.hud <key> [x y w h]       draw it in a native HUD rectangle
--   /remote-camera.webui <key> [x y w h]     draw it behind a transparent page
--   /remote-camera.off                       close what these commands opened
--
-- They exist because the service's own surface is a Lua export and an operator
-- on a live server has a chat box, not a Lua prompt. Everything they do is done
-- through `RemoteCameraService`, with this resource's own owner and generation, exactly
-- like the editor: no private path into the authority.
--
-- The transport requires `command.<name>` for a restricted command, so an
-- operator hands these out per player through the normal ACL management. A
-- viewer is still admitted by the service itself -- a `granted` camera is only
-- presented to a player who holds a grant, and the grant this file makes is
-- recorded so `/remote-camera.off` can take it back.

local OWNER = GetCurrentResourceName()
local GENERATION = GetCurrentResourceGeneration()

local DEFAULT_RECT = { x = 80, y = 100, width = 640, height = 360 }
local MAX_RECT_EXTENT = 16384
local MAX_LISTED = 24

-- playerId -> array of { view = id, camera = id, key = camera key, granted = bool }
local watching = {}

local function service() return RemoteCameraService end

local function output(source, raw, success, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
    return text
end

local function playerReady(player)
    if player == nil or player <= 0 then return false, "player_required" end
    if Open77.players.position(player) == nil then return false, "player_not_ready" end
    return true
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function cameraRows()
    local rows = service().list(OWNER, GENERATION)
    if type(rows) ~= "table" then return nil, tostring(rows) end
    return rows
end

-- A camera key carries its owner's prefix -- the editor's are `editor.<placement
-- key>` -- while the key an operator reads is the placement's. Exact match first,
-- then a unique suffix match, so both spellings work and an ambiguous one is
-- refused rather than guessed at.
local function findCamera(key)
    local rows, reason = cameraRows()
    if not rows then return nil, reason end
    local suffix = "." .. key
    local partial
    for _, row in ipairs(rows) do
        if row.key == key then return row end
        if type(row.key) == "string" and #row.key > #suffix and row.key:sub(-#suffix) == suffix then
            if partial then return nil, "ambiguous_key" end
            partial = row
        end
    end
    if partial then return partial end
    local known = {}
    for _, row in ipairs(rows) do
        if #known < 6 then known[#known + 1] = tostring(row.key) end
    end
    return nil, "unknown_key (known: " .. (#known > 0 and table.concat(known, ", ") or "none") .. ")"
end

-- A rect is optional on the command line and always four numbers when given.
local function parseRect(args, first)
    if args[first] == nil then return DEFAULT_RECT end
    local rect = {}
    local names = { "x", "y", "width", "height" }
    for index, name in ipairs(names) do
        local value = tonumber(args[first + index - 1])
        if not finite(value) or math.abs(value) > MAX_RECT_EXTENT then return nil, "invalid_rect" end
        rect[name] = value
    end
    if rect.width <= 0 or rect.height <= 0 then return nil, "invalid_rect" end
    return rect
end

-- A HUD view is authorized like a lease: ready, in the camera's bucket, and
-- holding an **explicit** grant. A camera has no public mode of its own, so the
-- grant is always made -- and always recorded, because `/remote-camera.off` is the only
-- thing that will take it back.
local function grantFor(camera, player)
    local granted, reason = service().setAccess(OWNER, GENERATION, camera.id, player, { view = true })
    if granted ~= true then return false, tostring(reason) end
    return true
end

local function openFor(player, key, surface, rect)
    local camera, reason = findCamera(key)
    if not camera then return nil, reason end
    if camera.enabled == false then return nil, "disabled" end
    local allowed, grantReason = grantFor(camera, player)
    if not allowed then return nil, grantReason end
    local view, viewReason = service().openView(OWNER, GENERATION, player, camera.id, rect, surface)
    if not view then
        -- A refused view must not leave the grant behind: it was made for this
        -- presentation and nothing else names it.
        service().setAccess(OWNER, GENERATION, camera.id, player, { view = false })
        return nil, tostring(viewReason)
    end
    local mine = watching[player]
    if not mine then
        mine = {}
        watching[player] = mine
    end
    mine[#mine + 1] = { view = view, camera = camera.id, key = camera.key, granted = true }
    return view
end

local function closeAll(player)
    local mine = watching[player]
    if not mine then return 0 end
    watching[player] = nil
    local closed = 0
    for _, entry in ipairs(mine) do
        local ok = service().closeView(OWNER, GENERATION, entry.view)
        if ok == true then closed = closed + 1 end
        if entry.granted then
            service().setAccess(OWNER, GENERATION, entry.camera, player, { view = false })
        end
    end
    return closed
end

local function describeRow(row)
    local position = row.position
    local housing = " housing=none"
    if row.housing then
        -- `reason` is the last sync's failure, and a call that failed without
        -- naming one must not print as the string "nil".
        housing = " housing=" .. tostring(row.housing.model)
        if row.housing.reason then housing = housing .. " (refused: " .. tostring(row.housing.reason) .. ")" end
    end
    return ("%s  key=%s  pos=(%.1f, %.1f, %.1f)  bucket=%s%s")
        :format(tostring(row.id), tostring(row.key), position.x, position.y, position.z,
            tostring(row.bucket), housing)
end

-- Why a panel is not on screen is the question an operator actually has, so the
-- screen listing answers it: the placement, and this caller's own viewer state
-- with the service's reason.
local function describeScreen(screen, player)
    local placement = screen.placement
    local state, reason = "not_a_viewer", nil
    local snapshot = service().getScreen(OWNER, GENERATION, screen.id)
    if type(snapshot) == "table" and type(snapshot.viewers) == "table" then
        for _, entry in ipairs(snapshot.viewers) do
            if tonumber(entry.playerId) == player then
                state, reason = entry.state or "pending", entry.reason
            end
        end
    end
    local position = placement.position
    return ("%s  screen of camera=%s  pos=(%.1f, %.1f, %.1f)  %.2fx%.2f %s  radius=%s access=%s  you=%s%s")
        :format(tostring(screen.id), tostring(screen.cameraId),
            position.x, position.y, position.z, placement.width, placement.height,
            tostring(placement.model), tostring(placement.radius), tostring(placement.access),
            tostring(state), reason and (" (" .. tostring(reason) .. ")") or "")
end

local function playerBucket(player)
    local position = Open77.players.position(player)
    return position and position.bucket or nil
end

local function listCommand(source, args, raw)
    local player = tonumber(source)
    local ok, reason = playerReady(player)
    if not ok then return output(source, raw, false, "remote-camera.cameras refused: " .. tostring(reason)) end
    local rows, listReason = cameraRows()
    if not rows then return output(source, raw, false, "remote-camera.cameras failed: " .. tostring(listReason)) end
    local filter = args and args[1]
    local shown = 0
    for _, row in ipairs(rows) do
        if filter == nil or tostring(row.key):find(filter, 1, true) then
            if shown >= MAX_LISTED then break end
            shown = shown + 1
            output(source, raw, true, describeRow(row))
        end
    end
    if shown == 0 then
        return output(source, raw, true, filter and ("no camera matches " .. tostring(filter)) or "no cameras")
    end
    -- The caller's own bucket is what decides whether a view can be opened at
    -- all, so it is reported beside the cameras' buckets rather than left to be
    -- discovered through a refusal.
    output(source, raw, true, ("%d camera(s)%s; you are in bucket %s")
        :format(shown, filter and (" matching " .. tostring(filter)) or "", tostring(playerBucket(player))))

    local screens = service().listScreens(OWNER, GENERATION)
    if type(screens) == "table" then
        local listed = 0
        for _, screen in ipairs(screens) do
            if listed >= MAX_LISTED then break end
            listed = listed + 1
            output(source, raw, true, describeScreen(screen, player))
        end
        output(source, raw, true, ("%d screen(s)"):format(listed))
    end

    -- Views are what the commands above open, and their state is the only place
    -- a failed client binding shows up: `pending` means the client never
    -- answered, `failed` carries the reason it gave.
    local views = service().listViews(OWNER, GENERATION, player)
    if type(views) == "table" then
        local listed = 0
        for _, view in ipairs(views) do
            if listed >= MAX_LISTED then break end
            listed = listed + 1
            output(source, raw, true, ("%s  view of camera=%s  %s  %dx%d at %d, %d  state=%s%s")
                :format(tostring(view.id), tostring(view.cameraId), tostring(view.surface),
                    view.rect.width, view.rect.height, view.rect.x, view.rect.y,
                    tostring(view.state), view.reason and (" (" .. tostring(view.reason) .. ")") or ""))
        end
        output(source, raw, true, ("%d view(s) for you"):format(listed))
    end
    return nil
end

local function watchCommand(source, args, raw, surface)
    local player = tonumber(source)
    local ok, reason = playerReady(player)
    if not ok then return output(source, raw, false, "remote-camera." .. surface .. " refused: " .. tostring(reason)) end
    local key = args and args[1]
    if type(key) ~= "string" then
        return output(source, raw, false, ("usage: /remote-camera.%s <camera key> [x y width height]"):format(surface))
    end
    local rect, rectReason = parseRect(args or {}, 2)
    if not rect then return output(source, raw, false, "refused: " .. tostring(rectReason)) end
    local view, viewReason = openFor(player, key, surface, rect)
    if not view then
        local detail = tostring(viewReason)
        if detail == "wrong_bucket" then
            -- The one refusal an operator can act on: the camera's bucket is not
            -- theirs, so say which is which instead of leaving them guessing.
            local camera = findCamera(key)
            detail = ("wrong_bucket (camera %s, you %s)"):format(
                tostring(camera and camera.bucket), tostring(playerBucket(player)))
        end
        return output(source, raw, false, ("remote-camera.%s refused for %s: %s"):format(surface, key, detail))
    end
    local where = surface == "webui" and "behind a transparent page" or "in a HUD rectangle"
    return output(source, raw, true, ("view %s opened for %s %s (%d x %d at %d, %d)")
        :format(tostring(view), key, where, rect.width, rect.height, rect.x, rect.y))
end

local function offCommand(source, args, raw)
    local player = tonumber(source)
    local ok, reason = playerReady(player)
    if not ok then return output(source, raw, false, "remote-camera.off refused: " .. tostring(reason)) end
    local closed = closeAll(player)
    if closed == 0 then return output(source, raw, true, "nothing open") end
    return output(source, raw, true, ("closed %d view(s)"):format(closed))
end

-- The capture budget is the one refusal an operator can fix from the game: every
-- source a client holds is a full extra scene render, and past the limit the
-- client refuses and the service can only report that it asked. The number is
-- pushed to clients, so the change lands on its own.
local function slotsCommand(source, args, raw)
    local player = tonumber(source)
    local ok, reason = playerReady(player)
    if not ok then return output(source, raw, false, "remote-camera.slots refused: " .. tostring(reason)) end
    if RemoteCameraSlots == nil then return output(source, raw, false, "remote-camera.slots unavailable") end
    if args == nil or args[1] == nil then
        return output(source, raw, true, ("capture slots per client: %s (default %s, range %s-%s); " ..
            "change it with /remote-camera.slots <n>"):format(tostring(RemoteCameraSlots.get()), tostring(RemoteCameraSlots.default),
            tostring(RemoteCameraSlots.minimum), tostring(RemoteCameraSlots.maximum)))
    end
    local wanted = tonumber(args[1])
    if not finite(wanted) or wanted % 1 ~= 0 then
        return output(source, raw, false, "usage: /remote-camera.slots [n]")
    end
    local accepted, message = RemoteCameraSlots.set(wanted)
    if accepted ~= true then return output(source, raw, false, "remote-camera.slots refused: " .. tostring(message)) end
    return output(source, raw, true, ("capture slots per client: %s -> %s%s")
        :format(tostring(RemoteCameraSlots.get()), tostring(wanted), message ~= "" and (" (" .. message .. ")") or ""))
end

-- A player who leaves keeps nothing: the service drops their records by roster,
-- and this side drops the grants it made so a reconnect starts clean.
AddEventHandler("open77:playerLeft", function(player)
    player = tonumber(player)
    if player then closeAll(player) end
end)

RegisterCommand("remote-camera.cameras", function(source, args, raw)
    local ok, err = pcall(listCommand, source, args, raw)
    if not ok then output(source, raw, false, "remote-camera.cameras failed: " .. tostring(err)) end
end, true)

RegisterCommand("remote-camera.hud", function(source, args, raw)
    local ok, err = pcall(watchCommand, source, args, raw, "hud")
    if not ok then output(source, raw, false, "remote-camera.hud failed: " .. tostring(err)) end
end, true)

RegisterCommand("remote-camera.webui", function(source, args, raw)
    local ok, err = pcall(watchCommand, source, args, raw, "webui")
    if not ok then output(source, raw, false, "remote-camera.webui failed: " .. tostring(err)) end
end, true)

RegisterCommand("remote-camera.off", function(source, args, raw)
    local ok, err = pcall(offCommand, source, args, raw)
    if not ok then output(source, raw, false, "remote-camera.off failed: " .. tostring(err)) end
end, true)

RegisterCommand("remote-camera.slots", function(source, args, raw)
    local ok, err = pcall(slotsCommand, source, args, raw)
    if not ok then output(source, raw, false, "remote-camera.slots failed: " .. tostring(err)) end
end, true)
