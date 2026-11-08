-- Offline scenarios for stickers_main.lua (run by test_stickers.py through a real Lua 5.4).
-- Globals set by the test: CATALOGUE (generated stickers.lua), MAIN (stickers_main.lua), MODE
-- ('full': the server takes every field; 'strict': it refuses unknown fields like the paint
-- profile parser; 'none': no wave-2 natives). Sets RESULT to 'ok' or to the failures.
local failures = {}
local function check(cond, message) if not cond then failures[#failures + 1] = message end end
local function eq(got, want, message)
    check(got == want, ('%s: got %s, want %s'):format(message, tostring(got), tostring(want)))
end

-- ---- host stubs ------------------------------------------------------------------------------
local exported, handlers, commands, printed = {}, {}, {}, {}
local registrations = {}
local cars, applied = {}, {}
function exports(name, fn) exported[name] = fn end
function AddEventHandler(name, fn) handlers[name] = fn end
function GetCurrentResourceName() return 'lightrp_vehicle_stickers' end
function RegisterCommand(name, fn, restricted) commands[name] = { fn = fn, restricted = restricted } end
function TriggerClientEvent() end
print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end
Open77 = { vehicles = {
    get = function(id) return cars[id] end,
    getPlayerSeat = function() return nil end,
} }
if MODE ~= 'none' then
    Open77.vehicles.registerStickers = function(rows)
        registrations[#registrations + 1] = rows
        if MODE == 'strict' then
            for _, r in ipairs(rows) do
                for k in pairs(r) do
                    if k ~= 'id' and k ~= 'label' and k ~= 'group' and k ~= 'model' and k ~= 'decals' then
                        return false, 'invalid_sticker:' .. r.id .. '.' .. k
                    end
                end
            end
        end
        return true
    end
    Open77.vehicles.setStickers = function(id, ids) applied[id] = ids; return true end
    Open77.vehicles.getStickers = function(id) return applied[id] end
    Open77.vehicles.getDecalBudget = function() return 0, 12 end
end

local function run(path)
    local fh = assert(io.open(path, 'rb'))
    local source = fh:read('a')
    fh:close()
    check(source:sub(1, 3) ~= '\239\187\191', path .. ' starts with a BOM')
    assert(load(source, '@' .. path))()
end

run(CATALOGUE)
run(MAIN)
handlers.onResourceStart('lightrp_vehicle_stickers')

for _, name in ipairs({ 'stickersFor', 'sticker', 'check', 'decalsOf' }) do
    check(type(exported[name]) == 'function', 'export ' .. name .. ' missing')
end
check(commands.sticker and commands.sticker.restricted == true, '/sticker must be restricted')
local started = false
for _, line in ipairs(printed) do
    if line:find('stickers on', 1, true) and line:find('decal records', 1, true) then started = true end
end
check(started, 'start line missing')

local thrax = 'Vehicle.v_standard2_chevalier_thrax_player'
local list = exported.stickersFor(thrax)
check(#list >= 4, 'the Thrax has stickers')
local byId = {}
for _, s in ipairs(list) do
    byId[s.id] = s
    check(s.decals >= 1 and s.decals <= LightRpVehicleStickers.maxDecalsPerSticker, s.id .. ' decal count')
    check(type(s.label) == 'string' and type(s.group) == 'string', s.id .. ' shape')
end
-- A stage or engine-sound record of the model lists the same stickers.
eq(#exported.stickersFor(thrax .. '_o77s2a5'), #list, 'stage+sound record')
eq(#exported.stickersFor(thrax .. '_o77a3'), #list, 'sound record')
eq(#exported.stickersFor('Vehicle.v_standard2_archer_hella_police'), 0, 'unknown model')

-- Budget rule: livery + the stickers' own counts, 12 at most.
local a, b = 'st.thrax.valentinos_01', 'st.thrax.maelstrom_01a'
check(byId[a] and byId[b], 'expected Thrax stickers present')
if byId[a] and byId[b] then
    eq(exported.check(thrax, { a }, 0), byId[a].decals, 'one sticker')
    eq(exported.check(thrax, { a, b }, 0), byId[a].decals + byId[b].decals, 'two stickers')
    eq(select(2, exported.check(thrax, { a, b }, 12 - byId[a].decals - byId[b].decals + 1)), 'over_budget', '13 refused')
    eq(exported.check(thrax, { a, b }, 12 - byId[a].decals - byId[b].decals), 12, '12 accepted')
    eq(select(2, exported.check(thrax, { a, a }, 0)), 'duplicate_sticker', 'duplicate')
    eq(select(2, exported.check(thrax, { 'st.colby.valentinos_01a' }, 0)), 'wrong_model', 'other model')
    eq(select(2, exported.check(thrax, { 'st.thrax.nope_01' }, 0)), 'unknown_sticker', 'unknown sticker')
    eq(select(2, exported.check('Vehicle.nope', { a }, 0)), 'unknown_model', 'unknown model')
end

-- decalsOf: the union, each decal record once (route A list / route B records).
local all, seen, total = {}, {}, 0
for _, s in ipairs(LightRpVehicleStickers.stickers) do
    if s.model == thrax then all[#all + 1] = s.id; total = total + s.decals end
end
local union = exported.decalsOf(all)
check(#union <= total, 'union not larger than the sum')
for _, d in ipairs(union) do
    check(not seen[d.record], 'decal twice in the union: ' .. d.record)
    seen[d.record] = true
    check(d.decal:find('^open77\\assets\\lightrp_vehicle_stickers\\') ~= nil, 'decal path in the pack: ' .. d.decal)
    check(type(d.component) == 'string' and #d.component > 0, 'component')
end
eq(select(2, exported.decalsOf({ 'st.thrax.nope_01' })), 'unknown_sticker', 'decalsOf unknown')
local one = exported.sticker(a)
check(one and one.record == 'Vehicle.o77_sticker_' .. a:gsub('%.', '_'), 'holder record name')
one.parts[1].record = 'tampered'
check(exported.sticker(a).parts[1].record ~= 'tampered', 'sticker() returns a copy')

-- Registration.
if MODE == 'none' then
    eq(#registrations, 0, 'nothing registered without natives')
    cars[3] = { record = thrax }
    commands.sticker.fn(0, { a, '3' }, '/sticker ' .. a .. ' 3')
    eq(applied[3], nil, 'no setStickers without natives')
else
    eq(#registrations, MODE == 'strict' and 2 or 1, 'registration attempts')
    local rows = registrations[#registrations]
    eq(#rows, #LightRpVehicleStickers.stickers, 'registered rows')
    for _, r in ipairs(rows) do
        check(type(r.id) == 'string' and type(r.label) == 'string' and type(r.group) == 'string'
            and type(r.model) == 'string' and math.type(r.decals) == 'integer', 'row shape ' .. tostring(r.id))
        if MODE == 'strict' then check(r.parts == nil and r.record == nil, 'strict rows are bare') end
        if MODE == 'full' then check(type(r.parts) == 'table' and #r.parts == r.decals, 'full rows carry parts') end
    end
    cars[3] = { record = thrax .. '_o77s1' }
    commands.sticker.fn(0, { a, '3' }, '/sticker ' .. a .. ' 3')
    commands.sticker.fn(0, { b, '3' }, '/sticker ' .. b .. ' 3')
    commands.sticker.fn(0, { a, '3' }, '/sticker ' .. a .. ' 3')
    check(applied[3] and #applied[3] == 2 and applied[3][1] == b and applied[3][2] == a, '/sticker adds once, last on top')
    commands.sticker.fn(0, { 'clear', '3' }, '/sticker clear 3')
    eq(applied[3], nil, '/sticker clear')
end

RESULT = #failures == 0 and 'ok' or table.concat(failures, '\n')
