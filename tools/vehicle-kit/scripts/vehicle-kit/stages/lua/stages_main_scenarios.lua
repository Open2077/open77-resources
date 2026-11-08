-- Offline scenarios for stages_main.lua (run by test_engine_sounds.py through a real Lua 5.4).
-- Globals set by the test: STAGES (generated stages.lua), SOUNDS (generated engine-sounds.lua, or
-- '' for a stage-only build), MAIN (stages_main.lua), SOUND_NAMES (every record of the sound YAML,
-- one per line), MODE ('full' or 'stages-only'). Sets RESULT to 'ok' or to the failures.
local failures = {}
local function check(cond, message) if not cond then failures[#failures + 1] = message end end
local function eq(got, want, message)
    check(got == want, ('%s: got %s, want %s'):format(message, tostring(got), tostring(want)))
end

-- ---- host stubs (the server API the resource uses) ----------------------------------
local exported, handlers, commands, printed, respawned = {}, {}, {}, {}, {}
local registered = nil
local cars = {}
function exports(name, fn) exported[name] = fn end
function AddEventHandler(name, fn) handlers[name] = fn end
function GetCurrentResourceName() return 'lightrp_vehicle_stages' end
function RegisterCommand(name, fn, restricted) commands[name] = { fn = fn, restricted = restricted } end
function TriggerClientEvent() end
print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end
Open77 = { vehicles = {
    get = function(id) return cars[id] end,
    getPlayerSeat = function() return nil end,
    respawnAs = function(id, record)
        respawned[#respawned + 1] = record
        cars[id].record = record
        return id
    end,
} }
if MODE == 'full' then
    Open77.vehicles.registerEngineSounds = function(catalogue) registered = catalogue; return true end
end

local function run(path)
    local fh = assert(io.open(path, 'rb'))
    local source = fh:read('a')
    fh:close()
    check(source:sub(1, 3) ~= '\239\187\191', path .. ' starts with a BOM')
    assert(load(source, '@' .. path))()
end

run(STAGES)
if SOUNDS ~= '' then run(SOUNDS) end
run(MAIN)
handlers.onResourceStart('lightrp_vehicle_stages')

local hella = 'Vehicle.v_standard2_archer_hella_player'
local maimai = 'Vehicle.v_standard2_makigai_maimai_player'
local kusanagi = 'Vehicle.v_sportbike1_yaiba_kusanagi_player'
-- Two extended (non-dealer) records: a car and a bike trim whose name ends in digits.
local type66 = 'Vehicle.v_sport2_quadra_type66_player'
local kusanagi02 = 'Vehicle.v_sportbike1_yaiba_kusanagi_player_02'
local carModels, bikeModels, extended = 0, 0, 0
for _, model in ipairs(LightRpVehicleStages.models) do
    if model.ladder == 'bike' then bikeModels = bikeModels + 1 else carModels = carModels + 1 end
    if model.extended then extended = extended + 1 end
end
check(extended > 0, 'the build carries extended models')
for _, name in ipairs({ 'stageRecord', 'stageOf', 'composeRecord', 'engineSoundRecord', 'engineSoundOf',
                        'engineSounds', 'ratedTopSpeedKmh' }) do
    check(type(exported[name]) == 'function', 'export ' .. name .. ' missing')
end
check(commands.enginesound and commands.enginesound.restricted == true, '/enginesound must be restricted')
check(commands.perfstage and commands.perfstage.restricted == true, '/perfstage must be restricted')

-- Stages behave as before whatever the build.
eq(exported.stageRecord(hella, 2), hella .. '_o77s2', 'stageRecord base -> s2')
eq(exported.stageRecord(hella .. '_o77s3', 0), hella, 'stageRecord s3 -> 0')
eq(select(2, exported.stageRecord(hella, 4)), 'invalid_stage', 'stage 4 refused')
eq(select(2, exported.stageRecord('Vehicle.v_standard2_archer_hella_police', 1)), 'unknown_record', 'unknown record')
local key, stage, sound = exported.stageOf(hella .. '_o77s1')
check(key == 'hella' and stage == 1 and sound == nil, 'stageOf s1')
-- The extended models stage like the dealer models; the trim suffix (_player_02) is kept.
eq(exported.stageRecord(type66, 3), type66 .. '_o77s3', 'Type-66 stage 3')
eq(exported.stageRecord(type66 .. '_o77s3', 0), type66, 'Type-66 back to stock')
eq(exported.stageRecord(kusanagi02, 1), kusanagi02 .. '_o77s1', 'Kusanagi 02 stage 1')
eq(exported.stageRecord(kusanagi02 .. '_o77s1', 2), kusanagi02 .. '_o77s2', 'Kusanagi 02 stage 1 -> 2')
eq(select(2, exported.stageRecord(kusanagi .. '_o77s1_02', 1)), 'unknown_record', 'a suffix after the stage is not a record')
key, stage = exported.stageOf(kusanagi02 .. '_o77s2')
check(key == 'v_sportbike1_yaiba_kusanagi_player_02' and stage == 2, 'stageOf Kusanagi 02 s2: ' .. tostring(key))
check(type(exported.ratedTopSpeedKmh(type66)) == 'number' and exported.ratedTopSpeedKmh(type66) > 100, 'Type-66 rated top speed')

if MODE == 'stages-only' then
    eq(registered, nil, 'nothing registered without sounds')
    eq(select(2, exported.engineSoundRecord(hella, 's01')), 'unknown_sound', 'no sounds in a stage-only build')
    eq(#exported.engineSounds(hella), 0, 'no sounds listed')
    eq(select(2, exported.stageRecord(hella .. '_o77a1', 1)), 'unknown_record', 'sound records unknown')
else
    -- Every record of the sound YAML, and nothing else, is reachable through composeRecord; a
    -- combination `missing` lists (a TweakDBID collision) is refused, never named.
    local yaml = {}
    local yamlCount = 0
    for name in SOUND_NAMES:gmatch('[^\n]+') do yaml[name] = true; yamlCount = yamlCount + 1 end
    local holes = LightRpEngineSounds.missing or {}
    local function hole(record, st, id)
        for _, missingId in ipairs(holes[record] and holes[record][st] or {}) do
            if missingId == id then return true end
        end
        return false
    end
    local declared = 0
    for _, stages in pairs(holes) do for _, ids in pairs(stages) do declared = declared + #ids end end
    local seen, refused = 0, 0
    for _, model in ipairs(LightRpVehicleStages.models) do
        local class = LightRpEngineSounds.models[model.record].class
        for st = 0, #model.stages do
            for _, s in ipairs(LightRpEngineSounds.sounds) do
                local record, why = exported.composeRecord(model.record, st, s.id)
                if s.class == class and hole(model.record, st, s.id) then
                    check(record == nil and why == 'sound_not_for_stage',
                        ('composeRecord(%s, %d, %s) names a record the pack does not generate'):format(model.key, st, s.id))
                    local canonical = model.record .. '_o77' .. (st > 0 and ('s' .. st) or '') .. 'a' .. s.index
                    check(not yaml[canonical], canonical .. ' is declared missing but in the YAML')
                    refused = refused + 1
                elseif s.class == class then
                    check(record and yaml[record], ('composeRecord(%s, %d, %s) = %s not in the YAML (%s)')
                        :format(model.key, st, s.id, tostring(record), tostring(why)))
                    seen = seen + 1
                else
                    eq(why, 'wrong_class', ('composeRecord(%s, %d, %s) must refuse'):format(model.key, st, s.id))
                end
            end
        end
    end
    eq(seen, yamlCount, 'records reachable from Lua = records in the YAML')
    eq(refused, declared, 'every declared hole refused')
    check(declared > 0, 'the extended build declares its collision holes')

    -- The in-game bug of 2026-11-08: the Deleon stage 3 + s03 record collided with the MaiMai
    -- s1 + s03 one. It is not generated: no export names it, the rest of the matrix stays.
    local deleon = 'Vehicle.v_sport2_villefort_deleon_player'
    local function has(list, id)
        for _, s in ipairs(list) do if s.id == id then return true end end
        return false
    end
    check(hole(deleon, 3, 's03'), 'the Deleon stage 3 + s03 hole is data')
    eq(select(2, exported.composeRecord(deleon, 3, 's03')), 'sound_not_for_stage', 'Deleon s3 + s03 refused')
    eq(exported.composeRecord(deleon, 2, 's03'), deleon .. '_o77s2a3', 'Deleon s2 + s03 exists')
    eq(select(2, exported.stageRecord(deleon .. '_o77s2a3', 3)), 'sound_not_for_stage', 'stage 3 keeping s03: refused')
    eq(exported.stageRecord(deleon .. '_o77s2a3', 1), deleon .. '_o77s1a3', 'stage 1 keeping s03')
    eq(select(2, exported.engineSoundRecord(deleon .. '_o77s3', 's03')), 'sound_not_for_stage', 's03 at stage 3: refused')
    eq(exported.engineSoundRecord(deleon .. '_o77s3', 's04'), deleon .. '_o77s3a4', 's04 at stage 3')
    check(not has(exported.engineSounds(deleon .. '_o77s3'), 's03'), 's03 not listed at stage 3')
    check(has(exported.engineSounds(deleon .. '_o77s2'), 's03'), 's03 listed at stage 2')
    eq(#exported.engineSounds(deleon .. '_o77s3'), 11, 'the Deleon at stage 3 takes 11 sounds')

    -- A stage change keeps the sound, a sound change keeps the stage.
    eq(exported.stageRecord(hella .. '_o77a3', 2), hella .. '_o77s2a3', 'stage keeps the sound')
    eq(exported.stageRecord(hella .. '_o77s2a3', 0), hella .. '_o77a3', 'stage 0 keeps the sound')
    eq(exported.engineSoundRecord(hella .. '_o77s2', 's05'), hella .. '_o77s2a5', 'sound keeps the stage')
    eq(exported.engineSoundRecord(hella .. '_o77s2a5', nil), hella .. '_o77s2', 'factory sound keeps the stage')
    eq(select(2, exported.engineSoundRecord(hella, 's13')), 'wrong_class', 'bike sound on a car')
    eq(select(2, exported.engineSoundRecord(kusanagi, 's01')), 'wrong_class', 'car sound on a bike')
    eq(exported.engineSoundRecord(kusanagi .. '_o77s3', 's15'), kusanagi .. '_o77s3a15', 'bike sound on a bike')
    eq(select(2, exported.engineSoundRecord(hella, 's99')), 'unknown_sound', 'unknown sound')
    key, stage, sound = exported.stageOf(hella .. '_o77s2a12')
    check(key == 'hella' and stage == 2 and sound == 's12', 'stageOf s2a12')
    eq(exported.engineSoundOf(hella .. '_o77a7'), 's07', 'engineSoundOf')
    eq(exported.engineSoundOf(hella .. '_o77s1'), nil, 'engineSoundOf factory')
    eq(exported.composeRecord(hella, 3, nil), hella .. '_o77s3', 'composeRecord factory sound')

    local list = exported.engineSounds(maimai)
    eq(#list, 12, 'a car takes the 12 car sounds')
    local factory = 0
    for _, s in ipairs(list) do if s.factory then factory = factory + 1; eq(s.id, 's01', 'MaiMai factory sound') end end
    eq(factory, 1, 'the MaiMai factory set is in the catalogue once')
    eq(#exported.engineSounds(kusanagi .. '_o77s1'), 4, 'a bike takes the 4 bike sounds')
    eq(#exported.engineSounds(), 16, 'every sound')
    -- Extended models: the sounds of their class, stage and sound kept across changes.
    eq(#exported.engineSounds(type66), 12, 'the Type-66 takes the 12 car sounds')
    eq(#exported.engineSounds(kusanagi02 .. '_o77s3'), 4, 'the Kusanagi 02 takes the 4 bike sounds')
    eq(exported.engineSoundRecord(type66 .. '_o77s2', 's03'), type66 .. '_o77s2a3', 'Type-66 sound keeps the stage')
    eq(exported.stageRecord(type66 .. '_o77s2a3', 1), type66 .. '_o77s1a3', 'Type-66 stage keeps the sound')
    eq(exported.composeRecord(kusanagi02, 3, 's13'), kusanagi02 .. '_o77s3a13', 'Kusanagi 02 compose')
    eq(select(2, exported.engineSoundRecord(kusanagi02, 's01')), 'wrong_class', 'car sound on the Kusanagi 02')
    eq(exported.engineSoundOf(kusanagi02 .. '_o77s3a13'), 's13', 'engineSoundOf Kusanagi 02')
    -- Its factory set (v_car_quadra_type_66_rogue) is not one of the catalogue's: no sound is marked factory.
    local factoryType66 = 0
    for _, s in ipairs(exported.engineSounds(type66)) do if s.factory then factoryType66 = factoryType66 + 1 end end
    eq(factoryType66, 0, 'no catalogue sound is the Type-66 factory set')
    eq(LightRpEngineSounds.models[type66].factorySet, 'v_car_quadra_type_66_rogue', 'Type-66 factory set')

    -- The catalogue handed to the server (contract shape plus models and maxStage).
    check(type(registered) == 'table', 'registerEngineSounds was not called')
    if registered then
        eq(#registered, 16, 'registered sounds')
        local listed, mapped = {}, 0
        for i, entry in ipairs(registered) do
            check(type(entry.id) == 'string' and type(entry.label) == 'string' and type(entry.set) == 'string'
                and math.type(entry.index) == 'integer' and entry.maxStage == 3, 'entry ' .. i .. ' shape')
            local count = #entry.models
            if count > 0 then
                -- the list form: every stage 0..maxStage of every listed record
                for j = 2, count do check(entry.models[j - 1] < entry.models[j], 'models sorted') end
                for _, record in ipairs(entry.models) do listed[record] = true end
            else
                -- the map form, for a sound with a hole: the stages generated, per record
                mapped = mapped + 1
                for record, stages in pairs(entry.models) do
                    count = count + 1
                    listed[record] = true
                    local want = {}
                    for st = 0, 3 do if not hole(record, st, entry.id) then want[#want + 1] = st end end
                    eq(table.concat(stages, ','), table.concat(want, ','), ('stages of %s for %s'):format(record, entry.id))
                end
            end
            eq(count, entry.class == 'car' and carModels or bikeModels, 'models of ' .. tostring(entry.id))
            check(count <= 512, 'a sound covers 512 models at most (MaximumModelsPerSound)')
        end
        check(listed[type66] and listed[kusanagi02], 'the extended models are registered')
        check(registered[1].models ~= registered[2].models, 'each entry owns its models table')
        local s03 = nil
        for _, entry in ipairs(registered) do if entry.id == 's03' then s03 = entry end end
        check(s03 and type(s03.models[deleon]) == 'table' and table.concat(s03.models[deleon], ',') == '0,1,2',
            's03 covers the Deleon at stages 0, 1, 2 only (Covers false at 3)')
        check(mapped > 0 and mapped < #registered, 'only the sounds with a hole use the map form')
        -- The server's Lua->JSON marshaller: 4096 values, depth 16 (LuaResourceRuntime ReadLuaValue).
        local function size(v, depth)
            if type(v) ~= 'table' then return 1, depth end
            local n, deepest = 1, depth
            for _, x in pairs(v) do local m, d = size(x, depth + 1); n = n + m; if d > deepest then deepest = d end end
            return n, deepest
        end
        local nodes, depth = size(registered, 0)
        check(nodes <= 4096 and depth <= 16, ('registerEngineSounds payload %d values, depth %d'):format(nodes, depth))
    end

    -- Lab commands without the wave-2 natives: respawnAs on our own records.
    cars[7] = { record = hella }
    commands.enginesound.fn(0, { 's05', '7' }, '/enginesound s05 7')
    eq(cars[7].record, hella .. '_o77a5', '/enginesound s05')
    commands.perfstage.fn(0, { '2', '7' }, '/perfstage 2 7')
    eq(cars[7].record, hella .. '_o77s2a5', '/perfstage keeps the sound')
    commands.enginesound.fn(0, { 'off', '7' }, '/enginesound off 7')
    eq(cars[7].record, hella .. '_o77s2', '/enginesound off keeps the stage')
    local before = #respawned
    commands.enginesound.fn(0, { 's14', '7' }, '/enginesound s14 7')
    eq(#respawned, before, 'a bike sound is refused before any respawn')
    -- A hole is refused before any respawn: the record does not exist in the game.
    cars[8] = { record = deleon .. '_o77s2a3' }
    before = #respawned
    commands.perfstage.fn(0, { '3', '8' }, '/perfstage 3 8')
    eq(#respawned, before, '/perfstage 3 keeping s03 is refused before any respawn')
    eq(cars[8].record, deleon .. '_o77s2a3', 'the Deleon keeps stage 2 and s03')
    commands.perfstage.fn(0, { '1', '8' }, '/perfstage 1 8')
    eq(cars[8].record, deleon .. '_o77s1a3', '/perfstage 1 keeps s03')
    cars[8].record = deleon .. '_o77s3'
    before = #respawned
    commands.enginesound.fn(0, { 's03', '8' }, '/enginesound s03 8')
    eq(#respawned, before, '/enginesound s03 at stage 3 is refused before any respawn')
end

RESULT = #failures == 0 and 'ok' or table.concat(failures, '\n')
