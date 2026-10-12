-- =============================================================================
-- open77_media -- shared/placement.lua
-- =============================================================================
-- Where "nudge this television" is decided, as arithmetic rather than as a
-- handler body.
--
-- Two reasons this is a file of its own rather than a few lines inside the
-- `media.move` command:
--
--   * the axes are the thing that goes silently wrong. A "left" that moves a set
--     to the right is not a crash and not a log line -- it is a prop that slides
--     the wrong way while the operator holds the button, and the only instrument
--     that can see it is a person. So it is pure, and it is tested
--     (`tests/placement_test.lua`) against the engine's own heading convention
--     rather than against this file's opinion of it.
--   * a nudge is *relative to the set*, not to the world. A television turned to
--     face a room has its own forward, and "forward" on the button has to mean
--     the way the cabinet is facing or the control is useless on any set that is
--     not axis-aligned.
--
-- -----------------------------------------------------------------------------
-- THE HEADING CONVENTION, WHICH IS THE ENGINE'S AND NOT A PREFERENCE
-- -----------------------------------------------------------------------------
-- yaw 0 faces +Y and increases counter-clockwise (docs/research/
-- movement-and-heading.md, and the same convention `Api::Movement`,
-- `facingPlacement` in server/main.lua and every other heading in this project
-- use). So in world components:
--
--     forward = (-sin(yaw), +cos(yaw), 0)
--     right   = (+cos(yaw), +sin(yaw), 0)     -- forward turned a quarter turn
--                                               clockwise, which is what "right"
--                                               means standing behind the set
--     up      = (0, 0, +1)                    -- z is up in this engine's world
--
-- `facingPlacement` in server/main.lua places a set at
-- `x - sin(heading) * distance, y + cos(heading) * distance`, which is this
-- forward vector, and the two are cross-checked in the placement suite: if that
-- helper and this module ever disagree about which way yaw 0 points, one of them
-- is wrong and the suite says so.
-- =============================================================================

Open77MediaPlacement = {}

---How far one nudge moves a set, in metres.
---
---A quarter of a metre: small enough to line a screen up against a wall or a
---counter by eye, large enough that crossing a room is a dozen presses rather
---than a hundred. The command and the menu both take a metres argument, so this
---is the default rather than the only option.
Open77MediaPlacement.Step = 0.25

---How far one rotate turns a set, in degrees. Fifteen degrees is the same
---compromise: a quarter turn takes six presses, and a set that is five degrees
---off the wall can be brought flush.
Open77MediaPlacement.RotationStep = 15.0

---The nudge directions, in the order a UI should offer them. Kept here rather
---than in the menu so the command, the menu and the tests cannot disagree about
---what may be asked for.
Open77MediaPlacement.Directions = { "left", "right", "forward", "back", "up", "down" }

---The ways a set can be turned.
Open77MediaPlacement.Turns = { "left", "right" }

---The largest nudge one request may apply, in metres, and the largest turn, in
---degrees. A bound rather than a validation nicety: the menu is one message
---away from a client, and "move it a kilometre" is a screen nobody can ever
---reach again. A hundred metres still crosses the biggest room in Night City,
---and a full turn is available one press at a time.
Open77MediaPlacement.MaximumStep = 100.0
Open77MediaPlacement.MaximumTurn = 180.0

---How high and low a set may be nudged, in world z. Wide on purpose -- a
---rooftop billboard is a legitimate set -- but finite, so a stuck key cannot
---push a television out of the world's own bounds.
Open77MediaPlacement.MinimumHeight = -500.0
Open77MediaPlacement.MaximumHeight = 1000.0

---A copy of a position, with the bucket carried through.
---
---The bucket is part of where a prop is (it selects the streaming bucket, not a
---coordinate), so a nudge that dropped it would move the set into another part
---of the world as far as the streaming system is concerned while leaving it on
---the same screen as far as the player is concerned.
---@param position table { x, y, z, bucket }
---@return table
local function copyPosition(position)
    return {
        x = tonumber(position.x) or 0.0,
        y = tonumber(position.y) or 0.0,
        z = tonumber(position.z) or 0.0,
        bucket = position.bucket,
    }
end

---True for a direction `Nudge` accepts.
---@param direction any
---@return boolean
function Open77MediaPlacement.IsDirection(direction)
    if type(direction) ~= "string" then return false end
    for _, known in ipairs(Open77MediaPlacement.Directions) do
        if known == direction then return true end
    end
    return false
end

---True for a turn `Turn` accepts.
---@param direction any
---@return boolean
function Open77MediaPlacement.IsTurn(direction)
    if type(direction) ~= "string" then return false end
    for _, known in ipairs(Open77MediaPlacement.Turns) do
        if known == direction then return true end
    end
    return false
end

---A heading brought back into 0..360.
---
---Turned rather than refused: a set rotated past north has simply been rotated,
---and refusing the eleventh press of a quarter-turn button because it left the
---range would be a control that stops working for a reason nobody can see.
---@param degrees number
---@return number
function Open77MediaPlacement.Wrap(degrees)
    local value = tonumber(degrees) or 0.0
    value = value % 360.0
    if value < 0.0 then value = value + 360.0 end
    -- `-0.0` and `360.0` both print as things a person would rather not read in
    -- `media.list`, and `%` can produce either.
    if value == 360.0 then value = 0.0 end
    return value
end

---Where a set ends up after being nudged along its own axes.
---
---`position` and the returned table are plain `{ x, y, z, bucket }`; the caller's
---table is never modified, so a refused `setTransform` leaves the entry the
---server reports pointing at where the set still is.
---@param position table { x, y, z, bucket }
---@param yaw number the set's own heading, degrees, 0 = +Y, counter-clockwise
---@param direction string one of `Directions`
---@param metres number|nil defaults to `Step`; clamped to `MaximumStep`
---@return table|nil moved position, or nil
---@return string|nil the reason when nil
function Open77MediaPlacement.Nudge(position, yaw, direction, metres)
    if type(position) ~= "table" then return nil, "no_position" end
    if not Open77MediaPlacement.IsDirection(direction) then return nil, "unknown_direction" end

    local distance = tonumber(metres) or Open77MediaPlacement.Step
    if distance <= 0.0 then return nil, "distance_must_be_positive" end
    if distance > Open77MediaPlacement.MaximumStep then
        distance = Open77MediaPlacement.MaximumStep
    end

    local out = copyPosition(position)
    if direction == "up" then
        out.z = out.z + distance
    elseif direction == "down" then
        out.z = out.z - distance
    else
        local radians = math.rad(tonumber(yaw) or 0.0)
        -- The set's own forward and right, as the engine defines heading. See
        -- the header: yaw 0 is +Y and yaw grows counter-clockwise.
        local forwardX, forwardY = -math.sin(radians), math.cos(radians)
        local rightX, rightY = math.cos(radians), math.sin(radians)
        if direction == "forward" then
            out.x = out.x + forwardX * distance
            out.y = out.y + forwardY * distance
        elseif direction == "back" then
            out.x = out.x - forwardX * distance
            out.y = out.y - forwardY * distance
        elseif direction == "right" then
            out.x = out.x + rightX * distance
            out.y = out.y + rightY * distance
        else -- left
            out.x = out.x - rightX * distance
            out.y = out.y - rightY * distance
        end
    end

    if out.z < Open77MediaPlacement.MinimumHeight or out.z > Open77MediaPlacement.MaximumHeight then
        return nil, "height_out_of_range"
    end
    return out, nil
end

---The rectangle's own front, in the prop's local frame: `up` crossed into
---`right`.
---
---This is the fourth heading convention in this file and the only one that is
---not the engine's, so it is worth being exact about. A quad is a rectangle: it
---has a `right` axis, an `up` axis, and a normal the record never states. The
---normal is `up x right` (a right-handed frame with z up, where `x` cross `y` is
---`z`), and two families of records independently agree with it:
---
---   * the television family declares `faces = +Y`, and its quads are
---     `right = +X, up = +Z` -- `up x right` = +Y.
---   * the monitor and device families have their glass measured at --X of the
---     mesh's own origin (screen meshes at X --0.075..--0.066 around an origin at
---     0, the housed variants recessed 2-7 mm behind the bezel's --X face), and
---     their quads are `right = +Y, up = +Z` -- `up x right` = --X.
---
---So it is a rule the assets confirm, not a hand-picked handedness. `cross = up x
---right` gives, componentwise,
---
---     (up.y * right.z - up.z * right.y,
---      up.z * right.x - up.x * right.z,
---      up.x * right.y - up.y * right.x)
---
---Normalised, because a hand-authored record may write a raw direction (the
---native side normalises too, see client/src/api/ScreenQuad.hpp's `Faces`).
---@param quad table the rectangle as it is on the wire
---@return number|nil x
---@return number|nil y
---@return number|nil z
function Open77MediaPlacement.QuadFront(quad)
    if type(quad) ~= "table" then return nil, nil, nil end
    local right = quad.right
    local up = quad.up
    if type(right) ~= "table" or type(up) ~= "table" then return nil, nil, nil end

    local rx, ry, rz = tonumber(right[1]) or 0.0, tonumber(right[2]) or 0.0, tonumber(right[3]) or 0.0
    local ux, uy, uz = tonumber(up[1]) or 0.0, tonumber(up[2]) or 0.0, tonumber(up[3]) or 0.0
    local x = uy * rz - uz * ry
    local y = uz * rx - ux * rz
    local z = ux * ry - uy * rx
    local length = math.sqrt(x * x + y * y + z * z)
    if length <= 0.0 then return nil, nil, nil end
    return x / length, y / length, z / length
end

---The yaw a prop must be given so that the rectangle's front is turned back at a
---caller whose own heading is `heading`.
---
---The set is put down *ahead* of the caller and turned to face them, which is
---what the menu promises. The direction the front must end up pointing is
---therefore the caller's forward, negated.
---
---`front` is `QuadFront`'s answer, so this works for every record without a
---`faces` field: a rectangle whose normal runs along X (a monitor, a device
---panel, a bare screen) is turned a quarter turn from the caller's own heading
---rather than presented edge-on, which is what a flat half-turn used to do to
---that whole half of the catalogue. A record that *does* declare `faces` is
---called with that instead, so the side carrying the picture is the side turned
---towards the caller and the render gate below agrees with the placement.
---@param frontX number|nil the front direction, normalised or not
---@param frontY number|nil
---@param heading number the caller's heading, degrees
---@return number|nil yaw degrees, or nil when the front is degenerate
function Open77MediaPlacement.FacingYaw(frontX, frontY, heading)
    local fx = tonumber(frontX)
    local fy = tonumber(frontY)
    if fx == nil or fy == nil or (fx == 0.0 and fy == 0.0) then return nil end

    local radians = math.rad(tonumber(heading) or 0.0)
    -- The prop is set down along the caller's forward, so the glass has to look
    -- back down it: forward is (-sin, cos), so the target is (sin, -cos).
    local targetX, targetY = math.sin(radians), -math.cos(radians)
    -- The rotation that carries the front onto the target. Degrees, matching the
    -- engine's counter-clockwise yaw; `Wrap` folds it into 0..360.
    -- `math.atan(y, x)` is atan2, which is the spelling this project uses
    -- everywhere else (race/client/main.lua's heading reader, the cordon
    -- sweep): Lua 5.4 has no `math.atan2` at all, so the two-argument `atan` is
    -- both the portable form and the local convention.
    local yaw = math.deg(math.atan(targetY, targetX) - math.atan(fy, fx))
    return Open77MediaPlacement.Wrap(yaw)
end

---The least distance a menu-spawned screen is ever set down at, in metres.
---
---Clears the deepest cabinet in the catalogue (the game's televisions measure
---0.18 m front to back and `tv.large` 0.227 m, from their cooked meshes' bounding
---boxes) and the player's own body, about 0.35 m in radius. At zero the set was
---created through the player and read as "nothing spawned": you are inside it, its
---faces are back-face culled, and the picture -- a screen plane 1 cm inside the
---body's front face -- points the way you happen to be facing rather than at you.
Open77MediaPlacement.MinimumStandoff = 1.1

---How far in front of the caller a record's screen is set down, in metres.
---
---The rule, stated so it can be checked against a record: the caller ends up one
---screen-height in front of the picture's own centre. That is a front row -- the
---picture fills about 74 degrees of view at every aspect in the catalogue, because
---the distance grows with the panel -- rather than the middle of a cinema, and it
---is the smallest distance at which the whole of a big screen is inside one
---person's view.
---
---Two terms, because the picture is not at the prop's origin:
---
---   * `depth`, the part of the quad's `offset` that runs along the direction the
---     picture faces -- how far in front of that origin the glass is. Positive for
---     every record in this catalogue (the offsets all point out of the face), and
---     clamped at zero so a hypothetical record with its glass behind its origin
---     cannot pull the stand-off negative.
---   * `height`, the panel's own height: the screen the caller must not be
---     standing in.
---
---Worked for the families, which is the whole of why this is safe to apply to all
---of them: `tv.large` 0.111 + 1.015 = 1.126 m (it was the flat 1.1, and 3 cm is not
---a change), `monitor.c` 0.169 + 0.597 = 0.766 m (floored to the old 1.1), and
---`cinema.100ft` 3.032 + 17.342 = 20.37 m. The floor is what keeps the furniture
---family exactly where it was, so this rule only ever moves a screen that is
---bigger than a person.
---@param quad table|nil the rectangle, for its `height` and `offset`
---@param frontX number|nil the picture's facing direction, in the prop's local frame
---@param frontY number|nil
---@param frontZ number|nil
---@return number metres
function Open77MediaPlacement.FacingDistance(quad, frontX, frontY, frontZ)
    local floor = Open77MediaPlacement.MinimumStandoff
    if type(quad) ~= "table" then return floor end
    local height = tonumber(quad.height) or 0.0
    if not (height > 0.0) then return floor end

    local depth = 0.0
    local offset = quad.offset
    if type(offset) == "table" and frontX ~= nil then
        local fx, fy, fz = tonumber(frontX) or 0.0, tonumber(frontY) or 0.0,
            tonumber(frontZ) or 0.0
        local length = math.sqrt(fx * fx + fy * fy + fz * fz)
        if length > 0.0 then
            local ox, oy, oz = tonumber(offset[1]) or 0.0, tonumber(offset[2]) or 0.0,
                tonumber(offset[3]) or 0.0
            depth = (ox * fx + oy * fy + oz * fz) / length
            if depth < 0.0 then depth = 0.0 end
        end
    end

    local wanted = depth + height
    if wanted < floor then return floor end
    return wanted
end

---The heading a set has after being turned on the spot.
---
---"left" turns the set's own left, which is a positive rotation in a
---counter-clockwise yaw convention: a set turned to its left ends up facing
---further counter-clockwise than it was.
---@param yaw number
---@param direction string one of `Turns`
---@param degrees number|nil defaults to `RotationStep`; clamped to `MaximumTurn`
---@return number|nil heading, or nil
---@return string|nil the reason when nil
function Open77MediaPlacement.Turn(yaw, direction, degrees)
    if not Open77MediaPlacement.IsTurn(direction) then return nil, "unknown_turn" end

    local amount = tonumber(degrees) or Open77MediaPlacement.RotationStep
    if amount <= 0.0 then return nil, "degrees_must_be_positive" end
    if amount > Open77MediaPlacement.MaximumTurn then amount = Open77MediaPlacement.MaximumTurn end

    local value = tonumber(yaw) or 0.0
    if direction == "left" then
        value = value + amount
    else
        value = value - amount
    end
    return Open77MediaPlacement.Wrap(value), nil
end
