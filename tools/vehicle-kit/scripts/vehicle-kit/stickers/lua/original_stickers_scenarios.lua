-- Offline scenarios for stickers_main.lua on the ORIGINAL sticker catalogue (st_ocook.py output),
-- run by test_stickers.py through a real Lua 5.4. Generic: nothing here names a model or a theme.
-- Globals set by the test: CATALOGUE (generated stickers.lua), MAIN (stickers_main.lua), MODE
-- ('full', 'strict' or 'none', as in stickers_main_scenarios.lua), RESOURCE (the resource name).
-- Sets RESULT to 'ok' or to the failures.
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
function GetCurrentResourceName() return RESOURCE end
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
handlers.onResourceStart(RESOURCE)
local C = LightRpVehicleStickers

-- The lab command takes the catalogue's own name: two sticker packs on one server must not both
-- register /sticker.
check(type(C.command) == 'string' and C.command ~= 'sticker', 'the original catalogue names its own command')
check(commands[C.command] and commands[C.command].restricted == true, '/' .. tostring(C.command) .. ' must be restricted')
eq(commands.sticker, nil, 'the original pack does not take /sticker')
check(C.maxDecalsPerCar == 12 and C.maxDecalsPerSticker <= 12, 'cap of 12 decals per car')

-- Every sticker: listed for its model (and its stage / sound records), its own decals counted.
check(#C.stickers >= 1, 'stickers present')
local prefix = 'open77\\assets\\' .. RESOURCE .. '\\'
for _, s in ipairs(C.stickers) do
    eq(s.decals, #s.parts, s.id .. ' decals = parts')
    check(s.decals >= 1 and s.decals <= C.maxDecalsPerSticker, s.id .. ' decal count in 1..cap')
    local found = false
    for _, row in ipairs(exported.stickersFor(s.model .. '_o77s2a5')) do
        if row.id == s.id then found = row.decals == s.decals end
    end
    check(found, s.id .. ' listed for its model with its decal count')
    for _, p in ipairs(s.parts) do
        check(p.decal:sub(1, #prefix) == prefix, 'decal path in the pack: ' .. p.decal)
        check(p.record:find('^Vehicle%.o77_os_') ~= nil, 'decal record name: ' .. p.record)
        check(type(p.component) == 'string' and #p.component > 0, 'component')
    end
    check(s.record:find('^Vehicle%.o77_sticker_os_') ~= nil, 'holder record name: ' .. s.record)
end

-- A set that fits trims of its body (`models`, primary first): listed for each, accepted on each,
-- refused on a record outside the list.
for _, s in ipairs(C.stickers) do
    if s.models then
        eq(s.models[1], s.model, s.id .. ' models start with model')
        check(#s.models >= 2 and #s.models <= 64, s.id .. ' models: 2 to 64 records')
        for _, r in ipairs(s.models) do
            local found = false
            for _, row in ipairs(exported.stickersFor(r)) do if row.id == s.id then found = true end end
            check(found, s.id .. ' listed for its trim ' .. r)
            eq(exported.check(r, { s.id }, 0), s.decals, s.id .. ' fits its trim ' .. r)
        end
        local row = exported.sticker(s.id)
        eq(row and #row.models, #s.models, s.id .. ' sticker() lists its records')
    end
end

-- Budget rule on the first sticker: livery + set, 12 at most, 13 refused.
local a = C.stickers[1]
eq(exported.check(a.model, { a.id }, 0), a.decals, 'one set')
eq(exported.check(a.model, { a.id }, 12 - a.decals), 12, '12 accepted')
eq(select(2, exported.check(a.model, { a.id }, 12 - a.decals + 1)), 'over_budget', '13 refused')
eq(select(2, exported.check(a.model, { a.id, a.id }, 0)), 'duplicate_sticker', 'duplicate')
eq(select(2, exported.check('Vehicle.nope', { a.id }, 0)), 'unknown_model', 'unknown model')
for _, s in ipairs(C.stickers) do
    if s.model ~= a.model then
        eq(select(2, exported.check(a.model, { s.id }, 0)), 'wrong_model', 'other model')
        break
    end
end
local union = exported.decalsOf({ a.id })
eq(#union, a.decals, 'decalsOf one set')

-- Registration and the lab command.
if MODE == 'none' then
    eq(#registrations, 0, 'nothing registered without natives')
else
    eq(#registrations, MODE == 'strict' and 2 or 1, 'registration attempts')
    local rows = registrations[#registrations]
    eq(#rows, #C.stickers, 'registered rows')
    for _, r in ipairs(rows) do
        check(math.type(r.decals) == 'integer' and (type(r.model) == 'string' or type(r.model) == 'table'),
            'row shape ' .. tostring(r.id))
        local s
        for _, x in ipairs(C.stickers) do if x.id == r.id then s = x end end
        if s and s.models then
            check(type(r.model) == 'table' and #r.model == #s.models and r.model[1] == s.model,
                'a set on trims registers its records as a list: ' .. r.id)
        else
            check(type(r.model) == 'string', 'a set on one record registers it as a string: ' .. tostring(r.id))
        end
        if MODE == 'strict' then check(r.parts == nil and r.record == nil, 'strict rows are bare') end
        if MODE == 'full' then check(type(r.parts) == 'table' and #r.parts == r.decals, 'full rows carry parts') end
    end
    cars[3] = { record = a.model .. '_o77s1' }
    commands[C.command].fn(0, { a.id, '3' }, '/' .. C.command .. ' ' .. a.id .. ' 3')
    check(applied[3] and #applied[3] == 1 and applied[3][1] == a.id, '/' .. C.command .. ' sets the sticker')
    commands[C.command].fn(0, { 'clear', '3' }, '/' .. C.command .. ' clear 3')
    eq(applied[3], nil, '/' .. C.command .. ' clear')
end

RESULT = #failures == 0 and 'ok' or table.concat(failures, '\n')
