local root = assert(arg[1])
dofile(root .. '/shared/strings.lua')
local saved, volume, writes, failSave = 35, 100, 0, false
Open77 = {
    webui = { getVolume = function() return volume end,
        setVolume = function(value) volume = value; writes = writes + 1; return true end },
    kvp = { get = function(_, fallback) if saved == nil then return fallback end; return saved end,
        set = function(_, value) if failSave then return false, 'disk_full' end; saved = value; return true end }
}
dofile(root .. '/client/web_audio.lua')
assert(PauseWebAudio.restore() and volume == 35)
assert(PauseWebAudio.section().entries[1].value == 35)
assert(PauseWebAudio.set({name='WebUiVolume',value=0}) and volume == 0 and saved == 0)
volume = 100
assert(PauseWebAudio.restore() and volume == 0, 'saved mute must survive restart')
assert(PauseWebAudio.set({name='WebUiVolume',value=100}) and volume == 100)
failSave = true
assert(not PauseWebAudio.set({name='WebUiVolume',value=20}) and volume == 100 and saved == 100)
local before = writes
for _, value in ipairs({-1,101,0/0,math.huge,1.5,'20',false}) do
    assert(not PauseWebAudio.set({name='WebUiVolume',value=value}))
end
assert(not PauseWebAudio.set({name='OtherVolume',value=10}))
assert(writes == before, 'invalid controls reached native audio')
saved = 'invalid'
assert(PauseWebAudio.restore() and volume == 100)
Open77.webui = nil
assert(PauseWebAudio.section() == nil and not PauseWebAudio.restore())
print('WebUI audio preference: saved mute, restore, range validation and persistence rollback passed')
