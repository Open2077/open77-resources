-- =============================================================================
-- open77_media -- tests/placement_test.lua
-- =============================================================================
-- Pins the arithmetic behind the placement controls: which way "left" is, what a
-- turn does to a heading, and what happens to a nudge that asks for something
-- silly.
--
-- Why this is a suite and not three lines of confidence: a nudge that moves a set
-- the wrong way is not a crash, not a log line and not an exception anywhere. It
-- is a cabinet that slides right while the operator holds LEFT, on a set that may
-- be three kilometres away, and the only instrument that can see it is a person
-- standing in front of it. The convention it depends on -- yaw 0 faces +Y and
-- grows counter-clockwise -- is the engine's, and it is the same one
-- `facingPlacement` in server/main.lua uses to put a set down in front of the
-- player, so a disagreement between the two would be visible as a television that
-- spawns behind you and then moves the wrong way.
--
-- Standalone:  lua tools/lua-test/run.lua <repo-root>
-- =============================================================================

local passed = 0
local failures = {}
local function check(condition, message)
    if condition then
        passed = passed + 1
    else
        failures[#failures + 1] = message or "assertion failed"
    end
end

local TOLERANCE = 1.0e-6
local function near(left, right, tolerance)
    return math.abs((tonumber(left) or 0) - (tonumber(right) or 0)) <= (tolerance or TOLERANCE)
end

local function at(x, y, z, bucket)
    return { x = x, y = y, z = z, bucket = bucket }
end

-- =============================================================================
-- Shape
-- =============================================================================

check(type(Open77MediaPlacement) == "table", "the placement module is published")
check(Open77MediaPlacement.Step > 0, "the default step is positive")
check(Open77MediaPlacement.RotationStep > 0, "the default turn is positive")
check(#Open77MediaPlacement.Directions == 6, "six nudge directions are offered")
for _, direction in ipairs({ "left", "right", "forward", "back", "up", "down" }) do
    check(Open77MediaPlacement.IsDirection(direction), direction .. " is a known direction")
end
for _, junk in ipairs({ "north", "", "Forward", nil, 3 }) do
    check(not Open77MediaPlacement.IsDirection(junk),
        tostring(junk) .. " is not a direction")
end
check(Open77MediaPlacement.IsTurn("left") and Open77MediaPlacement.IsTurn("right"),
    "left and right are turns")
check(not Open77MediaPlacement.IsTurn("up"), "up is not a turn")

-- =============================================================================
-- Forward is the set's own forward, on the engine's heading convention
-- =============================================================================
-- yaw 0 faces +Y, and yaw grows counter-clockwise, so:
--
--     yaw   0   faces +Y        yaw  90   faces -X
--     yaw 180   faces -Y        yaw 270   faces +X
--
-- Getting this backwards is the failure this suite exists for, so all four
-- quadrants are pinned rather than just the one the spawn path happens to use.

local forwardCases = {
    { yaw = 0, x = 0, y = 1, label = "north" },
    { yaw = 90, x = -1, y = 0, label = "west" },
    { yaw = 180, x = 0, y = -1, label = "south" },
    { yaw = 270, x = 1, y = 0, label = "east" },
}
for _, case in ipairs(forwardCases) do
    local moved = Open77MediaPlacement.Nudge(at(0, 0, 0), case.yaw, "forward", 1.0)
    check(moved ~= nil, string.format("a nudge at yaw %d is accepted", case.yaw))
    if moved ~= nil then
        check(near(moved.x, case.x) and near(moved.y, case.y) and near(moved.z, 0),
            string.format("forward at yaw %d (%s) is %.2f,%.2f (got %.2f,%.2f)",
                case.yaw, case.label, case.x, case.y, moved.x, moved.y))
    end
end

-- Right is forward turned a quarter turn clockwise: at yaw 0 the set's right is
-- +X, at yaw 90 it is +Y, and so on. A set turned to face a room must still move
-- where its own buttons say.
local rightCases = {
    { yaw = 0, x = 1, y = 0 },
    { yaw = 90, x = 0, y = 1 },
    { yaw = 180, x = -1, y = 0 },
    { yaw = 270, x = 0, y = -1 },
}
for _, case in ipairs(rightCases) do
    local moved = Open77MediaPlacement.Nudge(at(0, 0, 0), case.yaw, "right", 1.0)
    check(moved ~= nil and near(moved.x, case.x) and near(moved.y, case.y),
        string.format("right at yaw %d is %.2f,%.2f (got %s,%s)", case.yaw, case.x, case.y,
            moved and tostring(moved.x) or "nil", moved and tostring(moved.y) or "nil"))
end

-- And the two are opposites, which is what makes the pair usable: a left press
-- after a right press returns the set to where it was.
for _, yaw in ipairs({ 0, 17.5, 90, 213 }) do
    local start = at(100.0, -50.0, 3.0)
    local right = Open77MediaPlacement.Nudge(start, yaw, "right", 0.75)
    local back = Open77MediaPlacement.Nudge(right, yaw, "left", 0.75)
    check(back ~= nil and near(back.x, start.x, 1.0e-4) and near(back.y, start.y, 1.0e-4)
            and near(back.z, start.z, 1.0e-4),
        string.format("right then left is where it started at yaw %s", tostring(yaw)))
    local forward = Open77MediaPlacement.Nudge(start, yaw, "forward", 0.75)
    local again = Open77MediaPlacement.Nudge(forward, yaw, "back", 0.75)
    check(again ~= nil and near(again.x, start.x, 1.0e-4) and near(again.y, start.y, 1.0e-4),
        string.format("forward then back is where it started at yaw %s", tostring(yaw)))
end

-- =============================================================================
-- Height is the world's z, and only up/down touch it
-- =============================================================================

local lifted = Open77MediaPlacement.Nudge(at(4.0, 5.0, 6.0), 45.0, "up", 2.0)
check(lifted ~= nil and near(lifted.x, 4.0) and near(lifted.y, 5.0) and near(lifted.z, 8.0),
    "up raises the set without moving it sideways")
local dropped = Open77MediaPlacement.Nudge(at(4.0, 5.0, 6.0), 45.0, "down", 2.0)
check(dropped ~= nil and near(dropped.x, 4.0) and near(dropped.y, 5.0) and near(dropped.z, 4.0),
    "down lowers the set without moving it sideways")

for _, direction in ipairs({ "left", "right", "forward", "back" }) do
    local moved = Open77MediaPlacement.Nudge(at(4.0, 5.0, 6.0), 231.0, direction, 3.0)
    check(moved ~= nil and near(moved.z, 6.0),
        string.format("a sideways nudge (%s) does not change the height", direction))
end

-- =============================================================================
-- Distance: defaulted, honoured, clamped, and refused
-- =============================================================================

local defaulted = Open77MediaPlacement.Nudge(at(0, 0, 0), 0, "forward")
check(defaulted ~= nil and near(defaulted.y, Open77MediaPlacement.Step),
    "a nudge with no distance uses the default step")

local explicit = Open77MediaPlacement.Nudge(at(0, 0, 0), 0, "forward", 12.5)
check(explicit ~= nil and near(explicit.y, 12.5), "an explicit distance is applied")

local clamped = Open77MediaPlacement.Nudge(at(0, 0, 0), 0, "forward",
    Open77MediaPlacement.MaximumStep * 100)
check(clamped ~= nil and near(clamped.y, Open77MediaPlacement.MaximumStep),
    string.format("a distance past the ceiling is clamped to %.1f m",
        Open77MediaPlacement.MaximumStep))

for _, bad in ipairs({ 0, -1, -0.25 }) do
    local moved, reason = Open77MediaPlacement.Nudge(at(0, 0, 0), 0, "forward", bad)
    check(moved == nil and reason == "distance_must_be_positive",
        string.format("a distance of %s is refused (%s)", tostring(bad), tostring(reason)))
end

local nowhere, noPosition = Open77MediaPlacement.Nudge(nil, 0, "forward")
check(nowhere == nil and noPosition == "no_position", "a nudge with no position is refused")
local sideways, unknown = Open77MediaPlacement.Nudge(at(0, 0, 0), 0, "sideways")
check(sideways == nil and unknown == "unknown_direction",
    "an invented direction is refused by name")

local tooHigh = Open77MediaPlacement.Nudge(at(0, 0, Open77MediaPlacement.MaximumHeight), 0, "up")
check(tooHigh == nil, "a set cannot be raised out of the world")
local tooLow = Open77MediaPlacement.Nudge(at(0, 0, Open77MediaPlacement.MinimumHeight), 0, "down")
check(tooLow == nil, "a set cannot be lowered out of the world")

-- =============================================================================
-- The caller's table is not the one that moves
-- =============================================================================
-- The server applies a nudge by patching the prop's transform and only then
-- records the new position. If this returned the caller's own table mutated, a
-- refused `setTransform` would leave the entry -- the only view `media.list` has
-- -- reporting a set standing where the prop never went.

local original = at(1.0, 2.0, 3.0, 42)
local moved = Open77MediaPlacement.Nudge(original, 0, "forward", 1.0)
check(near(original.x, 1.0) and near(original.y, 2.0) and near(original.z, 3.0),
    "the caller's position is untouched")
check(moved ~= original, "the nudge returns a new table")
check(moved.bucket == 42, "the routing bucket is carried through a nudge")
check(Open77MediaPlacement.Nudge(at(1, 2, 3, nil), 0, "up", 1.0).bucket == nil,
    "a position with no bucket stays without one")

-- =============================================================================
-- Turning
-- =============================================================================

local left = Open77MediaPlacement.Turn(10.0, "left", 15.0)
check(left ~= nil and near(left, 25.0), "turning left adds degrees")
local right = Open77MediaPlacement.Turn(10.0, "right", 15.0)
check(right ~= nil and near(right, 355.0),
    string.format("turning right subtracts and wraps (got %s)", tostring(right)))

local defaultTurn = Open77MediaPlacement.Turn(0.0, "left")
check(defaultTurn ~= nil and near(defaultTurn, Open77MediaPlacement.RotationStep),
    "a turn with no angle uses the default")

local wrapped = Open77MediaPlacement.Turn(350.0, "left", 20.0)
check(wrapped ~= nil and near(wrapped, 10.0), "a turn past north wraps rather than refusing")
local negative = Open77MediaPlacement.Turn(0.0, "right", 30.0)
check(negative ~= nil and near(negative, 330.0), "a heading never goes negative")

local clampedTurn = Open77MediaPlacement.Turn(0.0, "left", Open77MediaPlacement.MaximumTurn * 10)
check(clampedTurn ~= nil and near(clampedTurn, Open77MediaPlacement.MaximumTurn),
    "a turn past the ceiling is clamped")

for _, bad in ipairs({ 0, -5 }) do
    local turned, reason = Open77MediaPlacement.Turn(0.0, "left", bad)
    check(turned == nil and reason == "degrees_must_be_positive",
        string.format("a turn of %s degrees is refused", tostring(bad)))
end
local spin, spinReason = Open77MediaPlacement.Turn(0.0, "sideways")
check(spin == nil and spinReason == "unknown_turn", "an invented turn is refused by name")

check(Open77MediaPlacement.Wrap(360.0) == 0.0, "a full turn comes back as zero")
check(near(Open77MediaPlacement.Wrap(-10.0), 350.0), "a negative heading wraps forward")
check(near(Open77MediaPlacement.Wrap(725.0), 5.0), "a heading beyond two turns wraps")

-- Four quarter turns on the spot return the heading to where it started, which
-- is the property the menu's TURN button relies on when it is held.
local heading = 37.0
for _ = 1, 4 do
    heading = Open77MediaPlacement.Turn(heading, "left", 90.0)
end
check(near(heading, 37.0), "four quarter turns return the heading")

-- =============================================================================
-- The rectangle's own front, and the yaw that turns it on the player
-- =============================================================================
-- `QuadFront` and `FacingYaw` are what `facingPlacement` in server/main.lua uses
-- to set a screen down facing the person who spawned it. They are pinned here for
-- the same reason the nudge axes are: a wrong answer is not a crash and not a log
-- line. It is a monitor spawned edge-on, which in game reads as no screen at all
-- -- because a panel presented along the viewer's own line of sight is a sliver a
-- few pixels wide -- and the only instrument that can see it is a person standing
-- in front of it.

local function quadOf(right, up)
    return {
        offset = { 0.0, 0.0, 0.0 },
        right = right,
        up = up,
        width = 1.0,
        height = 1.0,
    }
end

-- The axis, for both conventions the catalogue holds.
local tvFrontX, tvFrontY, tvFrontZ = Open77MediaPlacement.QuadFront(
    quadOf({ 1.0, 0.0, 0.0 }, { 0.0, 0.0, 1.0 }))
check(tvFrontX ~= nil and near(tvFrontX, 0.0) and near(tvFrontY, 1.0) and near(tvFrontZ, 0.0),
    string.format("a right=+X up=+Z rectangle faces +Y (got %s, %s, %s)",
        tostring(tvFrontX), tostring(tvFrontY), tostring(tvFrontZ)))

local monitorFrontX, monitorFrontY = Open77MediaPlacement.QuadFront(
    quadOf({ 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }))
check(monitorFrontX ~= nil and near(monitorFrontX, -1.0) and near(monitorFrontY, 0.0),
    string.format("a right=+Y up=+Z rectangle faces -X (got %s, %s)",
        tostring(monitorFrontX), tostring(monitorFrontY)))

check(Open77MediaPlacement.QuadFront(nil) == nil, "no quad has no front")
check(Open77MediaPlacement.QuadFront({}) == nil, "a quad with no axes has no front")
check(Open77MediaPlacement.QuadFront(quadOf({ 0.0, 0.0, 0.0 }, { 0.0, 0.0, 0.0 })) == nil,
    "a degenerate rectangle has no front")
-- A hand-authored record may write a raw direction rather than a unit one.
local rawFrontX, rawFrontY = Open77MediaPlacement.QuadFront(
    quadOf({ 0.0, 3.0, 0.0 }, { 0.0, 0.0, 5.0 }))
check(near(rawFrontX, -1.0) and near(rawFrontY, 0.0),
    string.format("a raw (un-normalised) pair of axes still gives a unit front (got %s, %s)",
        tostring(rawFrontX), tostring(rawFrontY)))

-- The yaw each family needs. A caller at heading 0 looks along +Y and the set is
-- put down 1.1 m along that, so the glass has to point back at -Y.
local function yawFor(right, up, heading)
    local fx, fy = Open77MediaPlacement.QuadFront(quadOf(right, up))
    return Open77MediaPlacement.FacingYaw(fx, fy, heading)
end

check(near(yawFor({ 1.0, 0.0, 0.0 }, { 0.0, 0.0, 1.0 }, 0.0), 180.0),
    "a +Y-facing television is turned half a turn to face the caller")
check(near(yawFor({ 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }, 0.0), 90.0),
    "a -X-facing monitor is turned a quarter turn to face the caller")
check(near(yawFor({ 0.0, -1.0, 0.0 }, { 0.0, 0.0, 1.0 }, 0.0), 270.0),
    "a +X-facing panel is turned the other quarter turn")
check(near(yawFor({ -1.0, 0.0, 0.0 }, { 0.0, 0.0, 1.0 }, 0.0), 0.0),
    "a +Y-facing rectangle needs no turn at all")

-- The caller's own heading is carried through, which is the property that makes
-- this usable: a set spawned while facing north is placed the same way relative to
-- the player as one spawned facing east.
for _, heading in ipairs({ 0.0, 37.0, 90.0, 180.0, 271.5, 359.0 }) do
    local tv = yawFor({ 1.0, 0.0, 0.0 }, { 0.0, 0.0, 1.0 }, heading)
    local monitor = yawFor({ 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }, heading)
    check(near(tv, Open77MediaPlacement.Wrap(heading + 180.0)),
        string.format("at heading %s the television takes the half turn (got %s)",
            tostring(heading), tostring(tv)))
    check(near(monitor, Open77MediaPlacement.Wrap(heading + 90.0)),
        string.format("at heading %s the monitor takes the quarter turn (got %s)",
            tostring(heading), tostring(monitor)))
end

-- And the property the two halves have to satisfy together: after the turn, the
-- front really does look back down the caller's forward. Checked by rotating the
-- front by the yaw the way `FacingYaw` says and comparing with the caller's own
-- forward, negated -- so a sign error anywhere in the chain fails here rather than
-- in game.
for _, heading in ipairs({ 0.0, 45.0, 120.0, 300.0 }) do
    local radians = math.rad(heading)
    local wantX, wantY = math.sin(radians), -math.cos(radians)
    for _, axes in ipairs({ { { 1.0, 0.0, 0.0 }, { 0.0, 0.0, 1.0 } },
                            { { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 } } }) do
        local fx, fy = Open77MediaPlacement.QuadFront(quadOf(axes[1], axes[2]))
        local yaw = Open77MediaPlacement.FacingYaw(fx, fy, heading)
        local turned = math.rad(yaw)
        local outX = fx * math.cos(turned) - fy * math.sin(turned)
        local outY = fx * math.sin(turned) + fy * math.cos(turned)
        check(near(outX, wantX, 1.0e-6) and near(outY, wantY, 1.0e-6),
            string.format("at heading %s a turned front looks back at the caller (got %.6f, %.6f; want %.6f, %.6f)",
                tostring(heading), outX, outY, wantX, wantY))
    end
end

-- A front with no horizontal component is a panel standing on its side, and one
-- that is not a direction at all cannot be answered: both say so rather than
-- returning a number that would turn the prop somewhere arbitrary.
check(Open77MediaPlacement.FacingYaw(0.0, 0.0, 0.0) == nil, "a vertical front has no yaw")
check(Open77MediaPlacement.FacingYaw(nil, 1.0, 0.0) == nil, "a missing front has no yaw")
check(Open77MediaPlacement.FacingYaw(1.0, nil, 0.0) == nil, "a half-stated front has no yaw")

-- Diagonal fronts, so the arithmetic is not only ever asked about the axes.
check(near(Open77MediaPlacement.FacingYaw(1.0, 1.0, 0.0), 225.0),
    "a front at 45 degrees is turned 225 degrees onto a caller at heading 0")

-- =============================================================================
-- The stand-off: how far in front of the caller a screen is set down
-- =============================================================================
-- A fixed distance was right for as long as the catalogue was furniture, and it
-- stopped being right the day it grew a 100 ft screen: the picture sits `offset`
-- in FRONT of the prop's origin -- the catalogue is emphatic that the origin is
-- behind the glass, it is where the body would be -- and the panel is
-- `quad.height` tall. At the old 1.1 m the cinema's centre would be 1.9 m BEHIND
-- the person who spawned it, so they would be standing inside their own screen.
--
-- The rule is one screen-height in front of the picture's own centre, floored at
-- the old distance, and the two things that can go wrong with it are both
-- silent: a floor that shifted the furniture by half a metre, and a height term
-- that a cinema record can miss. Both are pinned below against the catalogue's
-- own measured numbers.
check(Open77MediaPlacement.MinimumStandoff == 1.1,
    "the stand-off floor is still the 1.1 m the furniture family was tuned to")

-- Nothing to measure: no quad, or a quad with no height, is the floor rather
-- than an error -- the caller is placing a prop and the prop does not care.
check(near(Open77MediaPlacement.FacingDistance(nil, 0.0, 1.0, 0.0), 1.1),
    "a record with no quad is set down at the floor")
check(near(Open77MediaPlacement.FacingDistance({ height = 0.0, offset = { 0, 1, 0 } }, 0.0, 1.0, 0.0), 1.1),
    "a quad with no height is set down at the floor")

-- The worked cases, from the catalogue as it is: `depth + height`, floored.
-- Every furniture record is below the floor, which is the point -- this rule
-- moves nothing that already fitted in a room.
local standoffs = {
    -- id,             height,   offset along the front,  expected metres
    { "tv.large",      1.0146,   0.111389,              1.1260 },
    { "tv.16x9",       0.6600,   0.115394,              1.1000 },
    { "monitor.c",     0.5970,   0.104400,              1.1000 },
    { "surveillance",  0.3774,   0.168836,              1.1000 },
    { "cinema.100ft",  17.3421,  3.032077,             20.3742 },
    { "cinema.150ft",  26.0131,  4.548115,             30.5612 },
}
for _, case in ipairs(standoffs) do
    local id, height, depth, expected = case[1], case[2], case[3], case[4]
    -- Composed through the module rather than read from a record: the test states
    -- the two terms and the answer, so a change to either term fails here.
    local quad = {
        height = height,
        offset = { 0.0, depth, 0.5 },
    }
    local got = Open77MediaPlacement.FacingDistance(quad, 0.0, 1.0, 0.0)
    check(near(got, expected, 1.0e-3),
        string.format("record '%s' is set down %.4f m ahead (got %.4f): one screen height in front of the picture, floored at 1.1", id, expected, got))
end

-- Monotonic where it matters: the bigger the picture, the further away, so no
-- panel in the catalogue can be spawned closer than a smaller one.
local small = Open77MediaPlacement.FacingDistance({ height = 1.0, offset = { 0, 0.1, 0 } }, 0.0, 1.0, 0.0)
local big = Open77MediaPlacement.FacingDistance({ height = 20.0, offset = { 0, 3.0, 0 } }, 0.0, 1.0, 0.0)
check(big > small, "a taller panel is set down further away than a shorter one")

-- Glass behind the origin cannot pull the stand-off under the floor. The cinema
-- records are the ones that could have done it -- their offsets are metres long --
-- so the clamp is checked rather than assumed.
check(near(Open77MediaPlacement.FacingDistance({ height = 0.5, offset = { 0, -5.0, 0 } }, 0.0, 1.0, 0.0), 1.1),
    "a picture behind the prop's origin does not pull the stand-off below the floor")

-- Without a front there is no depth term to take, and the height term still
-- stands: this is what a record with degenerate axes gets, and it must not fall
-- back to the floor and put a 17 m panel on the caller.
check(near(Open77MediaPlacement.FacingDistance({ height = 2.0, offset = { 0, 9.0, 0 } }, nil, nil, nil), 2.0),
    "a front that cannot be read drops the depth term and keeps the height term")

TestResult = {
    passed = passed,
    failed = #failures,
    failures = failures,
}
