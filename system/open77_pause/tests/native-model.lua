-- Run from the repository root with Lua 5.4. Real service contracts and user
-- sequences are tested here; actual rendering/input remain an in-game gate.
dofile('resources/system/open77_pause/shared/strings.lua')
dofile('resources/system/open77_pause/client/native.lua')
-- Match the resource host's sandbox, not the standalone interpreter's globals.
setmetatable, getmetatable = nil, nil
local topics, scenes, images = {}, {}, {}
local view=Open77NativePause.new(function(op, ...)
    local value={...}
    if op=='present' then scenes[#scenes+1]=value[1]
    elseif op=='image' then images[#images+1]=value end
    return true
end)
for _,topic in ipairs({'pause:closed','pause:action','settings:open','settings:closed','settings:set','privacy:set'}) do
    view:on(topic,function(value) topics[#topics+1]={topic=topic,value=value} end)
end
local function last(topic)
    for i=#topics,1,-1 do if topics[i].topic==topic then return topics[i].value end end
end
local function event(kind,id,text,generation,x,value)
    view:event({kind=kind,id=id or '',text=text or '',generation=generation or view.generation,x=x or 0,y=0,value=value or 0})
    assert(view:flush())
end
local function ids(scene)
    local result={}
    for _,node in ipairs(scene.nodes) do result[#result+1]=node.id..'/'..node.parent..'/'..node.kind end
    return table.concat(result,'\n')
end
local function visibleText()
    local result={}
    for _,node in ipairs(scenes[#scenes].nodes) do if node.visible~=false then result[#result+1]=node.text end end
    return table.concat(result,' ')
end
view:send('settings:tabs',{tabs={{id='video'},{id='voice'},{id='keybinds'}}})
assert(view:optionText('UI-Settings-Video-QualitySetting-Off')==PauseStrings.settings.off,'untranslated setting token remained visible')
assert(view:optionText('1920 x 1080')=='1920 x 1080','readable setting data was rewritten')
view:send('pause:state',{connected=true,server='Server',endpoint='127.0.0.1:11778',client={version='test'},player='Test'})
view:send('pause:open',{generation=1})
assert(view:flush())
assert(not visibleText():find('127.0.0.1',1,true),'address must start hidden')
view:rememberAddresses({nested={resourceBaseUrl='https://assets.private.test:444/files/'}})
for _,address in ipairs({'127.0.0.1:11778','10.20.30.40','localhost:11778','example.test:443',
    '[2001:db8::1]:11778','2001:db8::1','::1','[::ffff:192.0.2.1]:80','[fe80::1%ethernet_1]',
    'assets.private.test','ASSETS.PRIVATE.TEST:444'}) do
    assert(view:private('before '..address..' after')=='before [address hidden] after','privacy leak: '..address)
end
for _,ordinary in ipairs({'v1.2.3','1.999.3.4','256.0.0.1','12:34:56','a::b::c','example.test',
    'unrelated-assets.private.test','assets.private.test.other',':::','[not-an-ip]'}) do
    assert(view:private(ordinary)==ordinary,'privacy false positive: '..ordinary)
end
local before=ids(scenes[#scenes])
event('hover','map')
assert(before==ids(scenes[#scenes]),'moving focus rebuilt widget identities')
event('click','privacy')
assert(last('privacy:set').visible and visibleText():find('127.0.0.1',1,true),'privacy toggle loses raw endpoint')
event('click','quit-session')
assert(view.pending=='quit-session' and view.focus=='cancel','confirmation must default to cancel')
event('key','','ESCAPE')
assert(not view.pending and view.open,'escape must cancel confirmation first')
event('click','quit-game')
event('click','confirm')
assert(last('pause:action').action=='quit-game','distinct destructive action')
event('key','','ESCAPE')
event('click','settings')
assert(last('settings:open').tab=='video')
view:send('settings:values',{tab='video',done=true,sections={{group='/video/display',title='display',entries={
    {name='Brightness',label='Brightness',type='int',value=50,min=0,max=100,step=5},
    {name='Fullscreen',type='bool',value=0},
    {name='Resolution',type='list',value=0,options={'1280 x 720','1920 x 1080','2560 x 1440'}},
    {name='Locked',type='bool',value=0,disabled=true},
}}}})
assert(view:flush())
event('click','/video/display|Fullscreen')
assert(last('settings:set').value==1,'toggle did not reach service')
local count=#topics
event('click','/video/display|Locked')
assert(#topics==count,'disabled option wrote to service')
local slider=view.controls['/video/display|Brightness']
event('click','/video/display|Brightness','',nil,slider.x+slider.width)
assert(last('settings:set').value==100,'slider maximum')
event('key','','LEFT')
assert(last('settings:set').value==95,'slider step')
event('press','/video/display|Brightness','',nil,slider.x)
event('move','','',nil,slider.x+slider.width/2)
assert(last('settings:set').value==50,'slider drag')
event('release')
count=#topics
event('move','','',nil,slider.x+slider.width)
assert(#topics==count,'pointer release retained slider capture')
event('click','/video/display|Resolution')
event('text','','1440')
event('key','','ENTER')
assert(last('settings:set').value==2 and not view.dropdown,'dropdown search/select')
event('click','filter')
event('text','','Bright')
assert(#view:rows()==1,'settings filter')
event('key','','ESCAPE')
assert(view.page=='settings' and view.filter=='','escape clears filter')
event('key','','ESCAPE')
assert(view.page=='main' and last('settings:closed'),'escape backs out of settings')
event('click','settings')
event('click','tab:keybinds')
view:send('settings:values',{tab='keybinds',done=true,sections={{group='keybinds',title='keybinds',entries={
    {name='resource|action',label='Action',type='keybind',value='F2',default='F2',rebound=true}
}}}})
assert(view:flush())
event('click','keybinds|resource|action')
event('key','','é')
assert(last('settings:set').value=='é' and not view.capture,'logical AZERTY capture')
event('click','keybinds|resource|action')
count=#topics
event('key','','ESCAPE')
assert(#topics==count and view.page=='settings','capture cancellation wrote a key or closed settings')
event('click','reset:keybinds|resource|action')
assert(last('settings:set').value=='__default__','reset sentinel')
event('click','tab:voice')
view:send('settings:values',{tab='voice',done=true,sections={{group='voice',title='voice',entries={
    {name='InputLevel',label='Microphone',type='meter',value=0,min=0,max=100,threshold=25},
    {name='TransmitState',label='Microphone state',type='info',value='Ready'}
}}}})
assert(view:flush())
before=ids(scenes[#scenes])
view:send('voice:levels',{input=77,state='Transmitting',threshold=30})
assert(view:flush())
assert(before==ids(scenes[#scenes]) and visibleText():find('Transmitting',1,true),'meter update recreated tree or lost state')
view:send('pause:close',{generation=2})
assert(view:flush())
view:send('pause:open',{generation=3})
count=#topics
event('closed','','',2)
assert(view.open and #topics==count,'stale close acknowledged a reopened menu')
view:send('pause:close',{generation=4,immediate=true})
event('closed','','',4)
assert(last('pause:closed').generation==4,'current close lost its generation')
local transferred=0
view:afterClose(function() transferred=transferred+1 end)
event('unmounted','','',3)
assert(transferred==0,'stale unmount transferred native focus')
event('unmounted','','',4)
event('unmounted','','',4)
assert(transferred==1,'handoff must wait for unmount and run once')
view:afterClose(function() transferred=transferred+1 end)
view:send('pause:open',{generation=5})
event('unmounted','','',4)
assert(transferred==1,'reopening retained a menu handoff')
view:send('privacy:state',{visible=false})
view.error='Failure at 192.0.2.18:11778 or assets.private.test'
assert(view:flush())
assert(not visibleText():find('192.0.2.18',1,true) and not visibleText():find('assets.private.test',1,true),'error text leaks address')
view:send('privacy:state',{visible=true})
assert(view:flush())
assert(visibleText():find(view.error,1,true),'privacy toggle did not restore original error')
event('image-ready','server')
event('image-ready','platform')
assert(view.logoReady,'late platform image hid server branding')
for _,scene in ipairs(scenes) do
    assert(#scene.nodes<=1024,'scene exceeds transport limit')
    local seen={}
    for _,node in ipairs(scene.nodes) do
        assert(not seen[node.id] and #node.id<=128,'duplicate or oversized widget identity')
        assert(node.parent=='' or seen[node.parent]=='canvas','invalid parent')
        seen[node.id]=node.kind
    end
end
print('Native pause model: navigation, confirmations, settings, dropdown, key capture, privacy, retained updates and stale close passed')

-- A native tree must fit the actual host's 10,000-instruction hook interval,
-- including privacy formatting. A callback may close it at any yield.
local published={}
local sliced=Open77NativePause.new(function(op,scene)
    if op=='present' then published[#published+1]=scene end
    return true
end)
sliced:send('pause:open',{generation=100})
sliced:send('settings:tabs',{tabs={{id='video'},{id='graphics'},{id='audio'},
    {id='voice'},{id='controls'},{id='keybinds'},{id='gameplay'}}})
sliced:send('pause:state',{connected=true,endpoint='192.0.2.12:11828',player='Tester',server='Test server'})
local instructions,peak,yields=0,0,0
sliced.frameYield=function()
    peak=math.max(peak,instructions)
    instructions=0
    yields=yields+1
end
local function measuredFlush()
    instructions=0
    debug.sethook(function() instructions=instructions+100 end,'',100)
    assert(sliced:flush())
    debug.sethook()
    peak=math.max(peak,instructions)
end
measuredFlush()
sliced:event({kind='hover',id='scrim',generation=100})
assert(sliced.focus=='resume','background hover stole keyboard navigation focus')
sliced:activate('settings')
local entries={}
for i=1,8 do entries[i]={name='Setting'..i,label='Visible setting '..i,type='int',value=50,min=0,max=100,step=1} end
sliced:send('settings:values',{tab=sliced.tab,done=true,sections={{group='test',title='test',entries=entries}}})
measuredFlush()
for i=1,8 do entries[i]={name='Setting'..i,label='Visible setting '..i,type='list',value=1,options={'Low','Medium','High'}} end
sliced:send('settings:values',{tab=sliced.tab,done=true,sections={{group='test',title='test',entries=entries}}})
measuredFlush()
assert(yields>1 and peak<10000,'native render exceeded a host instruction slice: '..peak)
local previous=#published
local interrupted=false
sliced.frameYield=function()
    if interrupted then return end
    interrupted=true
    sliced:send('pause:close',{generation=101,immediate=true})
    sliced:setFocus(false)
end
sliced.dirty=true
sliced.renderCache=nil -- force construction so this fixture interrupts a yield
assert(sliced:flush())
assert(interrupted and #published==previous+1 and published[#published].generation==101 and not published[#published].open,
    'in-flight render resurrected a closed menu or lost the close generation')
sliced.frameYield=nil
assert(sliced:flush())
assert(not published[#published].open,'closed menu reopened after render resumed')
print('Native pause cooperative rendering: instruction peak '..peak..', close during render passed')

-- Long key registries and device lists must remain reachable with the physical
-- wheel, including high-resolution fractional deltas and capture cancellation.
view:send('pause:open',{generation=20})
view:activate('settings')
view:selectTab('keybinds')
local bindings={}
for i=1,31 do bindings[i]={name='action'..i,label='Action '..i,type='keybind',value='F2',default='F2'} end
view:send('settings:values',{tab='keybinds',done=true,sections={{group='bindings',title='keybinds',entries=bindings}}})
assert(view:flush())
event('wheel','','',nil,nil,0)
assert(view.scroll==0,'zero wheel input scrolled the list')
event('wheel','','',nil,nil,-.5)
assert(view.scroll==0,'fractional wheel input jumped early')
event('wheel','','',nil,nil,-.5)
assert(view.scroll==2 and visibleText():find('Action 10',1,true),'wheel did not reach later key bindings')
event('wheel','','',nil,nil,-100)
assert(view.scroll==23 and visibleText():find('Action 31',1,true),'wheel did not clamp to the final key binding')
event('click','bindings|action31')
event('wheel','','',nil,nil,100)
assert(view.scroll==23 and view.capture,'wheel moved the row during key capture')
event('key','','ESCAPE')
event('wheel','','',nil,nil,100)
assert(view.scroll==0,'wheel did not return to the first key binding')
view:event({kind='press',id='scrollbar',generation=view.generation,x=1395,y=844})
assert(view.drag and view.scroll==23,'scrollbar click did not reach the bottom')
view:event({kind='move',generation=view.generation,x=1395,y=294})
assert(view.scroll==0,'scrollbar drag did not return to the top')
view:event({kind='release',generation=view.generation})
assert(not view.drag,'scrollbar kept its pointer capture after release')
event('hover','tab:video','',nil,100)
event('key','','TAB')
local keyboardFocus=view.focus
event('hover','tab:video','',nil,100)
assert(view.focus==keyboardFocus,'stationary hover stole keyboard focus after redraw')
event('hover','tab:video','',nil,101)
assert(view.focus=='tab:video','moving the mouse failed to restore pointer focus')
local options={}
for i=1,24 do options[i]='Device '..i end
view:selectTab('video')
view:send('settings:values',{tab='video',done=true,sections={{group='devices',title='display',entries={{name='Output',type='list',value=0,options=options}}}}})
assert(view:flush())
event('click','devices|Output')
event('wheel','','',nil,nil,-100)
assert(view.dropdown.scroll==16 and visibleText():find('Device 24',1,true),'wheel did not reach final dropdown option')
event('click','option:23')
assert(last('settings:set').value==23 and not view.dropdown,'scrolled dropdown selection failed')
print('Native pause scrolling: long key registry, capture, fractional wheel, dropdown and keyboard/pointer focus passed')

for _,tab in ipairs({'keybinds','voice'}) do
    view:selectTab(tab)
    view:send('settings:values',{tab=tab,done=true,sections={{group=tab,title=tab,entries={
        {name=tab=='voice' and 'PushToTalkKey' or 'resource|action',type='keybind',value='N'}
    }}}})
    assert(view:flush())
    local key=tab..'|'..(tab=='voice' and 'PushToTalkKey' or 'resource|action')
    for button=1,5 do
        if button%2==0 then event('click',key)
        else event('key','','HOME'); event('key','','ENTER') end
        assert(view.capture,'click failed to enter mouse/key capture')
        event('key','','MOUSE'..button)
        assert(not view.capture and last('settings:set').group==tab and last('settings:set').value=='MOUSE'..button,
            'mouse button did not reach '..tab..' setting service')
    end
end
print('Native pause mouse capture: all five buttons forwarded for mappings and voice PTT')

-- A warm page must not rebuild hundreds of icon rectangles for every hover.
-- Count scheduler yields (one frame each in the real host), and compare the
-- retained output with a cold render after changes to mutable row values.
local perfScene, perfYields, perfInstructions, perfPeak = nil,0,0,0
local perf=Open77NativePause.new(function(op,scene)
    if op=='present' then perfScene=scene end
    return true
end)
perf.frameYield=function()
    perfPeak=math.max(perfPeak,perfInstructions)
    perfInstructions=0
    perfYields=perfYields+1
end
perf:send('settings:tabs',{tabs={{id='video'},{id='graphics'},{id='audio'},
    {id='voice'},{id='controls'},{id='keybinds'},{id='gameplay'}}})
perf:send('pause:open',{generation=1})
perf:activate('settings')
perf:selectTab('keybinds')
perf:send('settings:values',{tab='keybinds',done=true,sections={{group='bindings',title='keybinds',entries=bindings}}})
local function perfFlush()
    perfYields,perfInstructions=0,0
    debug.sethook(function() perfInstructions=perfInstructions+100 end,'',100)
    assert(perf:flush())
    debug.sethook()
    perfPeak=math.max(perfPeak,perfInstructions)
    return perfYields
end
local coldYields=perfFlush()
local hoverYields=0
for i=1,8 do
    perf:event({kind='hover',id='bindings|action'..i,generation=1,x=i,y=0})
    hoverYields=math.max(hoverYields,perfFlush())
end
assert(hoverYields<=2,'warm hover still spans too many frames: '..hoverYields)
assert(perfPeak<10000,'retained render exceeded host instruction slice: '..perfPeak)
local sceneBefore=perfScene
perf:send('pause:state',{connected=true,ping=15})
assert(not perf.dirty and perf:flush() and perfScene==sceneBefore,'hidden connection card repainted settings')
bindings[8].value,bindings[8].rebound='MOUSE5',true
perf.dirty=true
perfFlush()
local retained=perfScene
perf.renderCache=nil
perf.dirty=true
perfFlush()
assert(#retained.nodes==#perfScene.nodes,'retained tree lost nodes')
for i,node in ipairs(retained.nodes) do
    for key,value in pairs(node) do
        assert(perfScene.nodes[i][key]==value,'stale retained node property: '..node.id..'.'..key)
    end
    for key,value in pairs(perfScene.nodes[i]) do assert(node[key]==value,'missing retained node property') end
end
assert(perf.controls['bindings|action8'].row.entry.value=='MOUSE5','retained control has stale action data')
local topology=ids(perfScene)
perf:event({kind='wheel',generation=1,value=-1})
local scrollYields=perfFlush()
assert(ids(perfScene)==topology,'scrolling rebuilt the retained keybinding widgets')
assert(perf.controls['bindings|action10'] and not perf.controls['bindings|action1'],'scroll retained an offscreen action')
assert(scrollYields<=8,'scroll still spans too many frames: '..scrollYields)
assert(perfPeak<10000,'scroll exceeded a host instruction slice: '..perfPeak)
print('Native pause retained rendering: cold '..coldYields..' frames, hover '..hoverYields..
    ' frames, scroll '..scrollYields..' frames, instruction peak '..perfPeak)

local function sameAsCold()
    local warm=perfScene
    perf.renderCache=nil
    perf.dirty=true
    perfFlush()
    assert(#warm.nodes==#perfScene.nodes,'cached settings changed tree shape')
    for i,node in ipairs(warm.nodes) do
        for key,value in pairs(node) do assert(perfScene.nodes[i][key]==value,'cached setting lost '..node.id..'.'..key) end
        for key,value in pairs(perfScene.nodes[i]) do assert(node[key]==value,'cached setting omitted '..key) end
    end
end
for _,kind in ipairs({'int','list','meter','bool','info'}) do
    perf:selectTab('voice')
    local changing={}
    for i=1,8 do changing[i]={name='Value'..i,label='Setting '..i,type=kind,value=0,
        min=0,max=100,options={'Low','Medium','High'}} end
    perf:send('settings:values',{tab='voice',done=true,sections={{group='voice',title='voice',entries=changing}}})
    perfFlush()
    for i=1,8 do
        changing[i].value=1
        changing[i].disabled=i%2==0
        changing[i].threshold=kind=='meter' and 50 or nil
    end
    perf.dirty=true
    perfFlush()
    sameAsCold()
    assert(perfPeak<10000,kind..' cached refresh exceeded host instruction slice: '..perfPeak)
end
perf.sections[1].entries[1].label='assets.settings.test'
perf.dirty=true
perfFlush()
perf:send('pause:state',{endpoint='assets.settings.test:11828'})
assert(perf.dirty,'learning a private address did not invalidate cached settings')
perfFlush()
sameAsCold()
assert(perfPeak<10000,'privacy refresh exceeded host instruction slice: '..perfPeak)
print('Native pause retained values: sliders, lists, meters, flags, info and privacy match cold rendering; peak '..perfPeak)
