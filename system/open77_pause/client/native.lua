-- INK view model. Service messages stay identical to client/main.lua; engine
-- widgets and their lifetimes belong to Open77Pause.reds, never to Lua.
Open77NativePause = {}
local View = {}
local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end
local function label(e) return e.label or tostring(e.name):gsub('(%l)(%u)', '%1 %2'):gsub('_', ' ') end
-- Small native silhouettes. Raj does not contain the arrow/reset glyphs;
-- these rectangles render at every font/locale and need no external texture.
local icons = {
    left={'...#...','..##...','.###...','#######','.###...','..##...','...#...'},
    right={'...#...','...##..','...###.','#######','...###.','...##..','...#...'},
    up={'...#...','..###..','.#####.','...#...','...#...','...#...','...#...'},
    down={'...#...','...#...','...#...','...#...','.#####.','..###..','...#...'},
    clear={'##...##','.##.##.','..###..','...#...','..###..','.##.##.','##...##'},
    reset={'..####.','.##..##','##....#','###...#','......#','.#...##','..####.'},
    search={'.####..','##..##.','#....#.','#....#.','##..##.','.#####.','.....##'},
    video={'#######','#.....#','#.....#','#.....#','#######','...#...','..###..'},
    graphics={'...#...','..###..','.##.##.','##...##','.##.##.','..###..','...#...'},
    audio={'...##..','..###.#','#####.#','#####.#','#####.#','..###.#','...##..'},
    voice={'..###..','..#.#..','..#.#..','#.###.#','##...##','.#####.','...#...'},
    controls={'.#####.','##...##','#.#...#','####.##','#.#...#','##...##','.#####.'},
    keybinds={'#######','#.....#','#.#.#.#','#.....#','#.###.#','#.....#','#######'},
    gameplay={'...#...','.#.#.#.','..###..','#######','..###..','.#.#.#.','...#...'},
    settings={'.#...#.','.#####.','##...##','#..#..#','##...##','.#####.','.#...#.'},
    map={'###.###','#.###.#','#..#..#','#..#..#','#..#..#','#.###.#','###.###'},
    exit={'####...','#..#...','#..#.#.','#..####','#..#.#.','#..#...','####...'},
}
local function removeLast(text)
    local at = utf8.offset(text, -1)
    return at and text:sub(1, at - 1) or ''
end
local function ipv4(host)
    local a,b,c,d = host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    return a and #a<=3 and #b<=3 and #c<=3 and #d<=3 and
        tonumber(a)<=255 and tonumber(b)<=255 and tonumber(c)<=255 and tonumber(d)<=255
end
local function ipv6(host)
    host = host:gsub('%%[%w_.%-]+$', '')
    local tail = host:match('([%d.]+)$')
    if host:find('.',1,true) then
        if not tail or not ipv4(tail) then return false end
        host = host:sub(1,#host-#tail)..'0:0'
    end
    if host:find('[^%x:]') or host:find(':::',1,true) then return false end
    local compressed = host:find('::',1,true)
    if compressed and host:find('::',compressed+2,true) then return false end
    if (host:sub(1,1)==':' and host:sub(1,2)~='::') or
        (host:sub(-1)==':' and host:sub(-2)~='::') then return false end
    local count=0
    for part in host:gmatch('[^:]+') do
        if #part>4 then return false end
        count=count+1
    end
    return compressed and count<8 or not compressed and count==8
end
function View:rememberAddresses(payload)
    if type(payload)~='table' then return end
    for key,value in pairs(payload) do
        if type(value)=='table' then self:rememberAddresses(value)
        elseif type(value)=='string' and ({endpoint=true,serveraddress=true,ipaddress=true,resourcebaseurl=true})[tostring(key):lower()] then
            local authority=value:lower():gsub('^%s+',''):gsub('^%a[%w+.-]*://',''):match('^[^/%s?#]+')
            if authority then
                authority=authority:gsub('^.*@','')
                local host=authority:match('^%[([^%]]+)%]') or authority:gsub(':%d+$','')
                if not self.knownAddresses[authority] or not self.knownAddresses[host] then
                    self.privacyRevision=(self.privacyRevision or 0)+1
                end
                self.knownAddresses[authority]=true
                self.knownAddresses[host]=true
            end
        end
    end
end
function View:private(value)
    value=tostring(value or '')
    if value=='' or self.addresses then return value end
    local hidden=self:t('session.addressHidden')
    -- Transform only display strings. Settings values, queries and network
    -- payloads retain their originals so the checkbox is fully reversible.
    value=value:gsub('%[([^%]]+)%]:?%d*',function(host)
        if ipv6(host) then return hidden end
        return nil
    end)
    return (value:gsub('[%w_%.:%%%-]+',function(token)
        local candidate=token:gsub('%.$','')
        local suffix=token:sub(#candidate+1)
        local host,port=candidate:match('^(.-):(%d+)$')
        local lower=candidate:lower()
        local hostname=host and host:lower() or lower
        local address=ipv6(candidate) or ipv4(candidate) or
            host and #port<=5 and (ipv4(host) or host:match('^[%w][%w.%-]*%.[%a][%w%-]*$')) or
            hostname=='localhost' and (not port or #port<=5) or
            self.knownAddresses[lower] or self.knownAddresses[hostname]
        return address and hidden..suffix or token
    end))
end
function View:t(path, values)
    local text = self.strings
    for part in path:gmatch('[^.]+') do text = type(text) == 'table' and text[part] or nil end
    text = type(text) == 'string' and text or path
    return (text:gsub('{(%w+)}', function(key) return tostring(values and values[key] or '{' .. key .. '}') end))
end
function View:optionText(value)
    local text=tostring(value or self:t('settings.blank'))
    -- Some ConfigVar choices return an untranslated localization token as both
    -- display and fallback. Keep the stored value intact; show its readable tail.
    local tail=text:match('^UI%-Settings%-.+%-([^%-]+)$')
    if tail then
        if tail=='Off' then return self:t('settings.off') end
        if tail=='On' then return self:t('settings.on') end
        return tail:gsub('(%l)(%u)','%1 %2'):gsub('_',' ')
    end
    return text
end
function View:on(topic, callback) self.handlers[topic] = callback end
function View:emit(topic, payload)
    if self.handlers[topic] then self.handlers[topic](payload or {}) end
end
function View:setFocus(focus)
    -- Closing can interrupt a cooperative render. Publish just its metadata
    -- against the last complete tree before asking INK to unmount; never start
    -- a second renderer from a service callback.
    if not focus and self.lastScene then
        local scene={}
        for key,value in pairs(self.lastScene) do scene[key]=value end
        self.revision=self.revision+1
        scene.revision,scene.generation=self.revision,self.generation
        scene.open,scene.immediate,scene.textInput,scene.keyCapture=false,true,false,false
        self.transport('present',scene)
    end
    return self.transport('focus', focus == true)
end
function View:selectTab(id)
    self.tab, self.sections, self.done = id, {}, false
    self.filter, self.scroll, self.dropdown, self.capture, self.wheelRemainder = '', 0, nil, nil, 0
    self.focus, self.typing, self.note = 'tab:' .. id, false, ''
    self:emit('settings:open', {tab=id})
    self.dirty = true
end
function View:send(topic, payload)
    payload = payload or {}
    if topic == 'pause:strings' then self.strings = payload
    elseif topic == 'pause:state' then
        local privacyRevision=self.privacyRevision
        self.state = payload; self:rememberAddresses(payload)
        -- The connection card is on the main page. Its one-second ping update
        -- must not enqueue work while a settings page is being manipulated.
        if self.page=='settings' and privacyRevision==self.privacyRevision then return true end
    elseif topic == 'settings:tabs' then self.tabs = payload.tabs or {}
    elseif topic == 'privacy:state' then self.addresses = payload.visible == true
    elseif topic == 'pause:open' then
        self.open, self.generation, self.immediate = true, payload.generation or self.generation, false
        self.page, self.pending, self.dropdown, self.capture, self.typing = 'main', nil, nil, nil, false
        self.focus, self.error = 'resume', payload.error or ''
        self.transfer = nil
    elseif topic == 'pause:close' then
        self.open, self.generation, self.immediate = false, payload.generation or self.generation, payload.immediate == true
        self.dropdown, self.capture, self.typing, self.drag = nil, nil, false, nil
    elseif topic == 'settings:values' and payload.tab == self.tab then
        self.sections, self.done = payload.sections or {}, payload.done ~= false
        self.dropdown = nil
    elseif topic == 'voice:feedback' then self.note = payload.message or ''
    elseif topic == 'voice:levels' then
        for _, section in ipairs(self.sections) do
            if section.group == 'voice' then
                for _, entry in ipairs(section.entries or {}) do
                    if entry.name == 'InputLevel' then entry.value, entry.threshold = payload.input, payload.threshold
                    elseif entry.name == 'OutputLevel' then entry.value = payload.output
                    elseif entry.name == 'TransmitMode' then entry.value = payload.mode
                    elseif entry.name == 'TransmitState' then entry.value = payload.state
                    elseif entry.name == 'VoiceReach' and payload.proximity then
                        entry.value = self:t('voice.reachValue', {metres=math.floor(payload.proximity + .5)})
                    end
                end
            end
        end
    elseif topic == 'pause:branding' then
        local accent = payload.accentColor
        self.accent = type(accent) == 'string' and accent:match('^#%x%x%x%x%x%x$') and accent or '#22D8E2'
        local source = payload.logo or table.concat(payload.logoChunks or {})
        if source ~= self.logo then
            self.logo, self.logoReady = source, false
            local ok = self.transport('image', 'server', source)
            if not ok and source ~= '' then self:emit('pause:logo-error') end
        end
    end
    self.dirty = true
    return true
end
function View:rows()
    local result = {}
    local query = self.filter:lower():match('^%s*(.-)%s*$')
    for _, section in ipairs(self.sections) do
        for _, entry in ipairs(section.entries or {}) do
            local supported = entry.type == 'int' or entry.type == 'bool' or entry.type == 'list' or
                entry.type == 'keybind' or entry.type == 'meter' or entry.type == 'info'
            if supported and (query == '' or (label(entry) .. ' ' .. entry.name):lower():find(query, 1, true)) then
                result[#result + 1] = {key=section.group .. '|' .. entry.name, group=section.group,
                    title=section.title, entry=entry}
            end
        end
    end
    return result
end
function View:apply(row, value)
    if row.entry.disabled then return end
    row.entry.value = value
    self:emit('settings:set', {group=row.group, name=row.entry.name, value=value})
    if row.group:sub(1, 1) == '/' then self.refreshAt = self.clock() + 700 end
    self.dirty = true
end
function View:adjust(row, step)
    local e = row.entry
    if e.disabled then return end
    if e.type == 'bool' then self:apply(row, step > 0 and 1 or 0)
    elseif e.type == 'list' and #(e.options or {}) > 1 then
        self:apply(row, clamp((tonumber(e.value) or 0) + step, 0, #e.options - 1))
    elseif e.type == 'int' then
        self:apply(row, clamp((tonumber(e.value) or 0) + step * (tonumber(e.step) or 1), e.min or 0, e.max or 100))
    end
end
function View:back()
    if self.capture then self.capture = nil
    elseif self.dropdown then self.dropdown = nil; self.typing = false
    elseif self.pending then self.pending = nil; self.focus = 'resume'
    elseif self.page == 'settings' and self.filter ~= '' then self.filter = ''; self.scroll = 0; self.typing = true; self.focus = 'filter'
    elseif self.page == 'settings' then
        self.page, self.typing, self.focus = 'main', false, 'settings'
        self:emit('settings:closed')
    else self.open, self.immediate = false, false end
    self.dirty = true
end
function View:activate(id, point)
    if self.dropdown and id ~= 'dropdown-filter' and not id:match('^option:') then
        self.dropdown, self.typing = nil, false; self.dirty = true; return
    end
    if id=='scrollbar' then
        if point then self:dragTo(self.controls[id],point) end
        return
    end
    self.focus, self.typing = id, id == 'filter' or id == 'dropdown-filter'
    local control = self.controls[id]
    if control and control.disabled then return end
    if id == 'resume' or id == 'scrim' then self.open, self.immediate = false, false
    elseif id == 'map' then self:emit('pause:action', {action='map'})
    elseif id == 'settings' then
        self.page = 'settings'
        for _, tab in ipairs(self.tabs) do
            if tab.enabled ~= false and (not self.tab or tab.id == self.tab) then self:selectTab(tab.id); break end
        end
        if not self.tab and self.tabs[1] then self:selectTab(self.tabs[1].id) end
    elseif id == 'back' or id == 'cancel' then self:back()
    elseif id == 'vanilla' then self:emit('pause:vanilla-settings')
    elseif id == 'privacy' then
        self.addresses = not self.addresses; self:emit('privacy:set', {visible=self.addresses})
    elseif id == 'quit-session' or id == 'quit-game' then self.pending, self.focus = id, 'cancel'
    elseif id == 'confirm' and self.pending then self:emit('pause:action', {action=self.pending})
    elseif id:sub(1, 4) == 'tab:' then self:selectTab(id:sub(5))
    elseif id == 'filter-clear' then self.filter, self.scroll, self.focus, self.typing = '', 0, 'filter', true
    elseif id == 'scroll-up' then self.scroll = math.max(0, self.scroll - 1)
    elseif id == 'scroll-down' then self.scroll = math.min(math.max(0, #self:rows() - 8), self.scroll + 1)
    elseif id:sub(1, 7) == 'option:' and self.dropdown then
        self:apply(self.dropdown.row, tonumber(id:sub(8)))
        self.focus, self.dropdown, self.typing = self.dropdown.row.key, nil, false
    elseif control and control.row then
        local row, e = control.row, control.row.entry
        if control.reset then self:apply(row, '__default__')
        elseif control.step then self:adjust(row, control.step)
        elseif e.type == 'bool' then self:apply(row, tonumber(e.value) == 1 and 0 or 1)
        elseif e.type == 'keybind' then self.capture = row
        elseif e.type == 'list' and #(e.options or {}) > 1 then
            self.dropdown = {row=row, query='', selected=tonumber(e.value) or 0, scroll=0}
            self.focus = 'dropdown-filter'; self.typing = true
        elseif e.type == 'int' and point then self:slider(control, point.x) end
    end
    self.dirty = true
end
function View:slider(control, x)
    local e = control.row.entry
    local lo, hi, step = e.min or 0, e.max or 100, math.max(1, e.step or 1)
    local value = lo + math.floor((clamp((x - control.x) / control.width, 0, 1) * (hi-lo)) / step + .5) * step
    self:apply(control.row, clamp(value, lo, hi))
end
function View:dragTo(control, point)
    if not control then return end
    if control.scrollbar then
        local ratio=clamp(((point.y or 0)-control.y-control.thumb/2)/math.max(1,control.height-control.thumb),0,1)
        self.scroll=math.floor(ratio*math.max(0,#self:rows()-8)+.5)
        self.dirty=true
    else self:slider(control,point.x) end
end
function View:options()
    local result = {}
    if self.dropdown then
        for index, text in ipairs(self.dropdown.row.entry.options or {}) do
            local display=self:optionText(text)
            if display:lower():find(self.dropdown.query:lower(), 1, true) then
                result[#result + 1] = {index=index-1, text=display}
            end
        end
    end
    return result
end
function View:key(key, modifiers)
    if self.capture then
        if key ~= 'ESCAPE' then self:apply(self.capture, key) end
        self.capture = nil; self.dirty = true; return
    end
    if key == 'ESCAPE' then self:back(); return end
    if self.typing and key == 'BACKSPACE' then
        if self.dropdown then self.dropdown.query = removeLast(self.dropdown.query); self.dropdown.scroll = 0
        else self.filter = removeLast(self.filter); self.scroll = 0 end
        self.dirty = true; return
    end
    if self.typing and key == 'A' and modifiers and modifiers & 2 ~= 0 then
        self.replaceText = true; return
    end
    if self.dropdown then
        local options, active = self:options(), 1
        for i, option in ipairs(options) do if option.index == self.dropdown.selected then active = i end end
        if key == 'UP' then active = active - 1 elseif key == 'DOWN' then active = active + 1
        elseif key == 'PAGEUP' then active = active - 8 elseif key == 'PAGEDOWN' then active = active + 8
        elseif key == 'HOME' then active = 1 elseif key == 'END' then active = #options
        elseif key == 'ENTER' then
            if options[active] then self:activate('option:' .. options[active].index) end
            return
        else return end
        active = clamp(active, 1, math.max(1, #options))
        if options[active] then self.dropdown.selected = options[active].index end
        self.dropdown.scroll = clamp(self.dropdown.scroll, math.max(0, active-8), math.max(0, active-1))
        self.dirty = true; return
    end
    if key == 'ENTER' or key == 'SPACE' and not self.typing then self:activate(self.focus); return end
    if not self.typing and self.page == 'settings' and not self.pending and
        (key == 'UP' or key == 'DOWN' or key == 'HOME' or key == 'END' or key == 'PAGEUP' or key == 'PAGEDOWN') then
        local rows, editable, current = self:rows(), {}, nil
        for i,row in ipairs(rows) do
            local e=row.entry
            if not e.disabled and (e.type=='int' or e.type=='bool' or e.type=='keybind' or e.type=='list' and #(e.options or {})>1) then
                editable[#editable+1]={row=row,index=i}
                if row.key==self.focus then current=#editable end
            end
        end
        if #editable>0 and (current or key=='HOME' or key=='END' or key=='PAGEUP' or key=='PAGEDOWN') then
            local target=current or 1
            if key=='HOME' then target=1 elseif key=='END' then target=#editable
            elseif key=='PAGEUP' then target=target-8 elseif key=='PAGEDOWN' then target=target+8
            else target=target+(key=='DOWN' and 1 or -1) end
            if target>=1 and target<=#editable or key~='UP' and key~='DOWN' then
                local selected=editable[clamp(target,1,#editable)]
                self.focus=selected.row.key
                self.scroll=clamp(self.scroll,math.max(0,selected.index-8),math.max(0,selected.index-1))
                self.dirty=true; return
            end
        end
    end
    if key == 'LEFT' or key == 'RIGHT' then
        local control = self.controls[self.focus]
        if control and control.row then self:adjust(control.row, key == 'RIGHT' and 1 or -1) end
        return
    end
    local nextIndex, index = nil, 0
    for i, id in ipairs(self.focusables) do if id == self.focus then index = i end end
    if key == 'UP' then nextIndex = index - 1
    elseif key == 'DOWN' or key == 'TAB' then nextIndex = index + (key == 'TAB' and modifiers and modifiers & 1 ~= 0 and -1 or 1)
    elseif not self.typing and key == 'HOME' then nextIndex = 1
    elseif not self.typing and key == 'END' then nextIndex = #self.focusables
    elseif not self.typing and key == 'PAGEUP' then self.scroll = math.max(0, self.scroll - 8)
    elseif not self.typing and key == 'PAGEDOWN' then self.scroll = math.min(math.max(0, #self:rows()-8), self.scroll + 8) end
    if nextIndex and #self.focusables > 0 then
        self.focus = self.focusables[(nextIndex-1) % #self.focusables + 1]
        self.typing = self.focus == 'filter'
    end
    self.dirty = true
end
function View:event(event)
    if event.generation ~= self.generation then return end
    if event.kind == 'closed' then
        if not self.open then self:emit('pause:closed', {generation=self.generation}) end
    elseif event.kind == 'mounted' then self.mounted = true
    elseif event.kind == 'unmounted' then
        self.mounted = false
        self:emit('pause:unmounted', {generation=self.generation})
        local transfer = self.transfer
        self.transfer = nil
        if transfer and not self.open then transfer() end
    elseif event.kind == 'image-ready' then
        if event.id == 'server' then self.logoReady = true; self.dirty = true end
    elseif event.kind == 'image-error' then self:emit('pause:logo-error')
    elseif event.kind == 'blur' then self.drag, self.capture = nil, nil; self.dirty = true
    elseif self.open then
        if event.kind == 'key' then
            self.keyboardNavigation=true
            self:key(event.text, math.floor(event.value or 0))
        elseif event.kind == 'text' and self.typing then
            if self.dropdown then self.dropdown.query = (self.replaceText and '' or self.dropdown.query) .. event.text; self.dropdown.scroll = 0
            else self.filter = (self.replaceText and '' or self.filter) .. event.text; self.scroll = 0 end
            self.replaceText, self.dirty = false, true
        elseif event.kind == 'click' then self.keyboardNavigation=false; self.drag = nil; self:activate(event.id, event)
        elseif event.kind == 'hover' then
            local moved=self.pointerX~=event.x or self.pointerY~=event.y
            self.pointerX,self.pointerY=event.x,event.y
            if not self.capture and not self.dropdown and (moved or not self.keyboardNavigation) and
                self.controls[event.id] and not self.controls[event.id].disabled and not self.controls[event.id].scrollbar then
                self.keyboardNavigation=false
                if self.focus~=event.id then self.focus = event.id; self.dirty = true end
            end
        elseif event.kind == 'press' then
            local control = self.controls[event.id]
            if control and not control.disabled and (control.scrollbar or control.row and control.row.entry.type == 'int') then
                self.drag = control; self:dragTo(control, event)
            end
        elseif event.kind == 'move' and self.drag then self:dragTo(self.drag, event)
        elseif event.kind == 'release' then self.drag = nil
        elseif event.kind == 'wheel' and not self.capture and self.page=='settings' then
            self.wheelRemainder=(self.wheelRemainder or 0)+(tonumber(event.value) or 0)
            local detents=math.floor(math.abs(self.wheelRemainder))*(self.wheelRemainder<0 and -1 or 1)
            if detents==0 then return end
            self.wheelRemainder=self.wheelRemainder-detents
            local step = -2*detents
            if self.dropdown then self.dropdown.scroll = clamp(self.dropdown.scroll + step, 0, math.max(0, #self:options()-8))
            else self.scroll = clamp(self.scroll + step, 0, math.max(0, #self:rows()-8)) end
            self.dirty = true
        end
    end
end

function View:render()
    local nodes, controls, focusables = {}, {}, {}
    self.controls, self.focusables = controls, focusables
    local previousCache, cache = self.renderCache or {}, {}
    self.renderCache = cache
    local constructed = 0
    -- Retain complete visual fragments. Only changed rows/buttons execute Lua
    -- drawing code; copying cached node arrays is a bounded native table.move.
    -- Keep just the current tree so visiting/scrolling pages cannot grow a cache.
    local function fragment(id, stamp, draw)
        local candidate = previousCache[id]
        local saved = candidate
        if saved then
            for key,value in pairs(stamp) do
                if saved.stamp[key] ~= value then saved = nil; break end
            end
            if saved then
                for key,value in pairs(saved.stamp) do
                    if stamp[key] ~= value then saved = nil; break end
                end
            end
        end
        if not saved then
            local outerNodes, outerControls, outerFocusables = nodes, controls, focusables
            local outerPrevious, outerCache = previousCache, cache
            nodes, controls, focusables = {}, {}, {}
            previousCache, cache = candidate and candidate.children or {}, {}
            draw()
            saved = {stamp=stamp,nodes=nodes,controls=controls,focusables=focusables,children=cache}
            nodes, controls, focusables = outerNodes, outerControls, outerFocusables
            previousCache, cache = outerPrevious, outerCache
        end
        cache[id] = saved
        table.move(saved.nodes,1,#saved.nodes,#nodes+1,nodes)
        table.move(saved.focusables,1,#saved.focusables,#focusables+1,focusables)
        for key,value in pairs(saved.controls) do controls[key]=value end
    end
    local accent, white, muted = self.accent, '#E4E8EF', '#82919E'
    local width = self.page == 'settings' and not self.pending and 1440 or 600
    local function node(id, kind, x, y, w, h, color, text, parent, extra)
        local n = {id=id, kind=kind, parent=parent or 'panel', x=x, y=y, width=w, height=h,
            color=color or white, text=self:private(text)}
        for key,value in pairs(extra or {}) do n[key]=value end
        nodes[#nodes+1] = n
        -- The system resource shares a bounded Lua slice. Yield before its
        -- 10,000-instruction watchdog can retire the presenter coroutine.
        constructed=constructed+1
        if self.frameYield and constructed%24==0 then self.frameYield() end
        return n
    end
    local function text(id, value, x, y, w, size, color, extra)
        local n = node(id, 'text', x,y,w,size*1.35,color,value,nil,extra)
        n.fontSize = size
        return n
    end
    local function icon(id, name, x, y, color)
        fragment(id,{name=name,x=x,y=y,color=color},function()
        for row,bits in ipairs(icons[name] or icons.settings) do
            local start=1
            while start<=#bits do
                local first,last=bits:find('#+',start)
                if not first then break end
                node(id..':'..row..':'..first,'rect',x+(first-1)*3,y+(row-1)*3,(last-first+1)*3,3,color)
                start=last+1
            end
        end
        end)
    end
    local function button(id, value, x,y,w,h, options)
        options = options or {}
        controls[id] = options
        options.x, options.width = x,w
        if not options.disabled then focusables[#focusables+1]=id end
        local active, selected = self.focus == id, options.selected
        local owner=self.idOwner or self
        local widgetKey=options.widgetKey or id
        if not self.ids[widgetKey] then owner.nextId=owner.nextId+1; self.ids[widgetKey]=owner.nextId end
        local stable = tostring(self.ids[widgetKey])
        local ink=options.disabled and '#687886' or selected and accent or white
        fragment('button:'..stable,{action=id,value=value,x=x,y=y,w=w,h=h,active=active,
            selected=selected,disabled=options.disabled,icon=options.icon,size=options.size,
            accent=accent,addresses=self.addresses,privacy=self.privacyRevision,strings=self.strings},function()
        node('button:' .. stable, 'rect',x,y,w,h,selected and accent or active and '#344552' or '#19232D','',nil,
            {opacity=selected and .16 or active and .95 or .65,interactive=not options.disabled,action=id,cut=6})
        text('button-label:' .. stable, value,x+(options.icon and 48 or 14),y+(h-(options.size or 22)*1.35)/2,math.max(1,w-(options.icon and 62 or 28)),options.size or 22,ink,{bold=selected==true})
        node('button-focus:' .. stable,'rect',x,y,3,h,accent,'',nil,{visible=selected or active})
        node('button-underline:'..stable,'rect',x+8,y+h-2,w-16,2,accent,'',nil,{visible=active and not selected})
        if options.icon then icon('button-icon:'..stable,options.icon,x+(value=='' and (w-21)/2 or 14),y+(h-21)/2,ink) end
        end)
    end
    node('scrim','rect',0,0,1920,1080,'#05080C','', '', {opacity=.35,interactive=true,action='scrim'})
    node('panel','canvas',0,0,width,1080,white,'','')
    node('panel-background','rect',0,0,width,1080,'#0B0E14','',nil,{opacity=.93,cut=12})
    node('rule','rect',0,0,width,3,accent)
    node('platform-logo','image',40,38,210,34,white,'',nil,{image='platform'})
    text('platform-wordmark','OPEN // 77',40,35,210,26,accent,{bold=true})
    node('server-logo','image',278,30,180,50,white,'',nil,{image='server',visible=self.logoReady})
    text('chip',self:t('chip'):upper(),width-126,40,110,17,accent)
    local state, blank = self.state, self:t('session.blank')
    local function private(value)
        return self:private(value or blank)
    end
    if self.pending then
        local key = self.pending == 'quit-session' and 'quitSession' or 'quitGame'
        text('confirm-title',self:t('confirm.' .. key .. 'Title'),40,158,510,35,accent,{bold=true})
        text('confirm-body',self:t('confirm.' .. key .. 'Body'),40,226,500,23,white,{wrap=true,height=130})
        button('cancel',self:t('confirm.no'),40,398,245,54)
        button('confirm',self:t('confirm.yes'),305,398,245,54)
    elseif self.page == 'main' then
        node('session-card','rect',40,104,520,280,'#131922','',nil,{cut=10})
        text('session-head',self:t('session.eyebrow'):upper(),60,120,355,15,muted)
        text('session-name',private(state.server or state.endpoint or self:t('session.none')),60,143,350,25,white,{bold=true})
        text('session-phase',self:t(state.connected and 'session.live' or 'session.offline'),450,126,95,15,accent)
        local client = state.client or {}
        local cells = state.connected and {
            {'player',tostring(state.player or blank) .. (state.playerId and ' #' .. state.playerId or '')},
            {'ping',tostring(state.ping or blank) .. ' ' .. self:t('session.milliseconds')},
            {state.players and 'players' or 'tick',state.players and tostring(state.players) .. (state.capacity and ' / ' .. state.capacity or '') or tostring(state.tickRate or blank) .. ' ' .. self:t('session.tickUnit',{rate=state.snapshotRate or blank})},
            {'serverVersion',(state.serverVersion or blank)..(state.serverProtocol and
                ' · p'..tostring(state.serverProtocol.major or '?')..'.'..tostring(state.serverProtocol.minor or '?') or '')},
            {'endpoint',self.addresses and (state.endpoint or blank) or self:t('session.addressHidden')},
            {'client',tostring(client.version or blank) .. ' · p' .. tostring(client.protocolMajor or '?') .. '.' .. tostring(client.protocolMinor or '?')},
        } or {{'client',client.version or blank}}
        for i, cell in ipairs(cells) do
            local col = i <= 4 and (i-1)%2 or 0
            local y = 188 + (i <= 4 and math.floor((i-1)/2)*50 or 100+(i-5)*32)
            text('cell-label'..i,self:t('session.'..cell[1]):upper(),60+col*245,y,235,13,muted)
            text('cell-value'..i,private(cell[2]),60+col*245,y+17,i>4 and 470 or 235,18,white)
        end
        if not state.connected then text('session-hint',self:t('session.hint'),60,264,460,20,muted,{wrap=true}) end
        local labels = {resume='resume',map='map',settings='settings',['quit-session']='quitSession',['quit-game']='quitGame'}
        local menuIcons = {resume='right',map='map',settings='settings',['quit-session']='exit',['quit-game']='exit'}
        for i,id in ipairs({'resume','map','settings','quit-session','quit-game'}) do
            button(id,self:t('menu.'..labels[id]),40,414+(i-1)*72,520,58,{size=30,icon=menuIcons[id],disabled=id=='quit-session' and not state.connected})
        end
        button('privacy',(self.addresses and '[x] ' or '[ ] ')..self:t('session.showAddresses'),40,892,520,44,{size=16})
        text('error',private(self.error),40,810,520,20,accent,{wrap=true})
    else
        node('sidebar-divider','rect',312,106,1,874,'#293743')
        text('settings-title',self:t('tabs.'..tostring(self.tab)),344,102,990,38,white,{bold=true})
        button('back',self:t('settings.back'),40,108,250,48,{icon='left'})
        text('categories-label',self:t('settings.categories'):upper(),40,180,250,14,muted)
        for i,tab in ipairs(self.tabs) do
            button('tab:'..tab.id,self:t('tabs.'..tab.id),40,214+(i-1)*64,250,54,
                {icon=tab.id,selected=self.tab==tab.id,disabled=tab.enabled==false,size=21})
        end
        button('vanilla',self:t('settings.vanilla'),40,806,250,58,{icon='settings',size=15})
        text('vanilla-hint',self:t('settings.vanillaHint'),40,880,248,17,muted,{wrap=true,height=90})
        button('filter',self.filter ~= '' and self.filter or self:t('settings.filterPlaceholder'),344,172,968,48,{icon='search',size=20})
        button('filter-clear','',1324,172,44,48,{icon='clear',disabled=self.filter==''})
        -- Cache comparisons cost instructions too. Split the sidebar from the
        -- rows even when almost no new nodes needed to be constructed.
        constructed=0
        if self.frameYield then self.frameYield() end
        local rows = self:rows()
        self.scroll = clamp(self.scroll,0,math.max(0,#rows-8))
        for slot=1,8 do
            local row = rows[self.scroll+slot]
            if row then
                local e, y = row.entry, 242+(slot-1)*82
                local indent = e.sub and 16 or 0
                local previous = rows[self.scroll+slot-1]
                local stamp={entry=e,key=row.key,title=row.title,previous=previous and previous.group,
                    focus=(self.focus==row.key or self.focus=='prev:'..row.key or
                        self.focus=='next:'..row.key or self.focus=='reset:'..row.key) and self.focus or '',
                    capture=self.capture and self.capture.key==row.key or false,
                    accent=accent,addresses=self.addresses,privacy=self.privacyRevision,strings=self.strings}
                for key,value in pairs(e) do stamp['entry:'..key]=value end
                fragment('row:'..slot,stamp,function()
                node('row-background'..slot,'rect',336,y-2,1032,76,slot%2==1 and '#18212A' or '#111A22','',nil,{opacity=.45})
                text('row-group'..slot,(slot==1 or not previous or previous.group~=row.group) and self:t('groups.'..tostring(row.title)) or '',350,y+2,930,13,accent)
                text('row-label'..slot,label(e),350+indent,y+23,462-indent,21, e.disabled and muted or white,{wrap=true,height=48})
                local tags = {}
                if e.disabled then tags[#tags+1]=self:t('tag.locked') end
                if e.policy=='restart' then tags[#tags+1]=self:t('tag.restart') end
                if e.policy=='checkpoint' then tags[#tags+1]=self:t('tag.checkpoint') end
                if e.inGame==false then tags[#tags+1]=self:t('tag.menuOnly') end
                if e.visible==false then tags[#tags+1]=self:t('tag.hidden') end
                text('row-tags'..slot,table.concat(tags,' / '),350+indent,y+56,462,12,muted)
                local value = tostring(e.value or self:t('settings.blank'))
                if e.type=='bool' then value=self:t(tonumber(e.value)==1 and 'settings.on' or 'settings.off')
                elseif e.type=='list' then value=self:optionText((e.options or {})[(tonumber(e.value) or 0)+1])
                elseif e.type=='int' or e.type=='meter' then
                    local scale=tonumber(e.scale) or 1
                    value=(scale>1 and string.format(scale>=100 and '%.2f' or '%.1f',(tonumber(e.value) or 0)/scale) or tostring(e.value or 0))..(e.suffix or '')
                end
                if self.capture and self.capture.key==row.key then value=self:t('keybind.press') end
                if e.type=='info' then text('info'..slot,value,836,y+25,510,19,accent,{wrap=true,height=50})
                elseif e.type=='meter' or e.type=='int' then
                    text('value'..slot,value,1220,y+13,140,20,accent)
                    local ratio=clamp(((tonumber(e.value) or 0)-(e.min or 0))/math.max(1,(e.max or 100)-(e.min or 0)),0,1)
                    node('track'..slot,'rect',836,y+51,514,5,'#344552')
                    node('fill'..slot,'rect',836,y+51,514*ratio,5,accent)
                    if e.threshold then node('threshold'..slot,'rect',836+514*clamp(e.threshold/100,0,1),y+45,2,17,white) end
                    if e.type=='int' then
                        node('slider'..slot,'rect',836,y+33,514,39,white,'',nil,{opacity=.001,interactive=not e.disabled,action=row.key})
                        controls[row.key]={row=row,x=836,width=514,disabled=e.disabled}
                        if not e.disabled then focusables[#focusables+1]=row.key end
                        node('thumb'..slot,'rect',832+514*ratio,y+46,8,15,self.focus==row.key and white or accent)
                    end
                else
                    button(row.key,value,880,y+19,432,46,{widgetKey='row-main:'..slot,row=row,icon=e.type=='keybind' and 'keybinds' or nil,disabled=e.disabled or e.type=='list' and #(e.options or {})<2,size=20})
                    if e.type=='list' then
                        button('prev:'..row.key,'',826,y+19,44,46,{widgetKey='row-prev:'..slot,icon='left',row=row,step=-1,disabled=e.disabled or (tonumber(e.value) or 0)<=0})
                        button('next:'..row.key,'',1322,y+19,44,46,{widgetKey='row-next:'..slot,icon='right',row=row,step=1,disabled=e.disabled or (tonumber(e.value) or 0)>=#(e.options or {})-1})
                    elseif e.type=='keybind' and e.default then
                        button('reset:'..row.key,'',1322,y+19,44,46,{widgetKey='row-reset:'..slot,icon='reset',row=row,reset=true,disabled=e.rebound~=true})
                    end
                end
                node('divider'..slot,'rect',350,y+77,1000,1,'#25323C')
                end)
            end
        end
        local overflow=math.max(0,#rows-8)
        button('scroll-up','',1380,242,36,42,{icon='up',disabled=self.scroll==0})
        button('scroll-down','',1380,850,36,42,{icon='down',disabled=self.scroll>=overflow})
        local thumb=math.max(32,550*math.min(1,8/math.max(1,#rows)))
        controls.scrollbar={scrollbar=true,y=294,height=550,thumb=thumb,disabled=overflow==0}
        node('scroll-hit','rect',1384,294,26,550,white,'',nil,{opacity=.001,visible=overflow>0,interactive=overflow>0,action='scrollbar'})
        node('scroll-track','rect',1396,294,3,550,'#344552','',nil,{visible=overflow>0})
        node('scroll-thumb','rect',1393,294+(550-thumb)*self.scroll/math.max(1,overflow),9,thumb,accent,'',nil,{visible=overflow>0})
        text('note',self.note,344,918,1018,18,accent)
        text('row-count',#rows>0 and self:t('settings.range',{first=self.scroll+1,last=math.min(#rows,self.scroll+8),total=#rows}) or '',344,966,600,16,muted)
        text('scroll-hint',overflow>0 and self:t('settings.scrollHint') or '',950,966,412,16,muted)
        if #rows==0 then text('empty',self:t(not self.done and 'settings.loading' or self.filter~='' and 'settings.noMatch' or 'settings.empty',{query=self.filter}),350,270,990,22,muted,{wrap=true,height=120})
        elseif not self.done then text('loading',self:t('settings.loading'),344,918,1018,18,muted) end
    end
    node('footer-rule','rect',40,1008,width-80,1,'#344552')
    text('legend',self:t('legend.escape')..'  '..self:t('legend.close')..'      TAB  '..self:t('legend.navigate')..'      '..self:t('legend.enter')..'  '..self:t('legend.select'),40,1030,width-80,16,muted)
    if self.dropdown then
        node('dropdown-mask','rect',0,0,width,1080,'#040609','',nil,{opacity=.75,interactive=true,action='dropdown-close'})
        node('dropdown-panel','rect',754,156,472,624,'#111923','',nil,{cut=10})
        button('dropdown-filter',self.dropdown.query ~= '' and self.dropdown.query or self:t('settings.find'),770,172,440,44)
        local options = self:options()
        self.dropdown.scroll=clamp(self.dropdown.scroll,0,math.max(0,#options-8))
        for slot=1,8 do
            local option=options[self.dropdown.scroll+slot]
            if option then button('option:'..option.index,option.text,770,230+(slot-1)*62,440,52,{widgetKey='dropdown-option:'..slot,size=19,selected=option.index==self.dropdown.selected}) end
        end
        text('dropdown-count',#options>0 and self:t('settings.range',{first=self.dropdown.scroll+1,last=math.min(#options,self.dropdown.scroll+8),total=#options}) or '',770,742,430,16,muted)
        if #options==0 then text('dropdown-empty',self:t('settings.findNoMatch'),770,248,420,21,muted) end
    end
    self.revision=self.revision+1
    return {nodes=nodes,generation=self.generation,revision=self.revision,open=self.open,
        immediate=self.immediate,panelWidth=width,textInput=self.typing,keyCapture=self.capture~=nil}
end
function View:flush()
    if self.refreshAt and self.clock() >= self.refreshAt and not self.dropdown and not self.capture and not self.drag then
        self.refreshAt=nil
        if self.open and self.page=='settings' and self.tab then self:emit('settings:open',{tab=self.tab}) end
    end
    if not self.dirty or self.rendering then return true end
    self.dirty=false
    self.rendering=true
    -- Service callbacks may run at a yield. Keep page/selection identity stable
    -- for the whole tree, and discard it if an open/close or navigation replaced
    -- it. Values arriving meanwhile leave dirty=true for the following frame.
    local snapshot={}
    for key,value in pairs(self) do snapshot[key]=value end
    snapshot.idOwner=self
    local dropdown=self.dropdown
    if dropdown then
        snapshot.dropdown={}
        for key,value in pairs(dropdown) do snapshot.dropdown[key]=value end
    end
    local scene=snapshot:render()
    self.rendering=false
    if self.generation~=snapshot.generation or self.open~=snapshot.open or
        self.page~=snapshot.page or self.tab~=snapshot.tab or self.pending~=snapshot.pending or
        self.dropdown~=dropdown or self.addresses~=snapshot.addresses then
        self.dirty=true
        return true
    end
    self.revision=self.revision+1
    scene.revision=self.revision
    self.controls,self.focusables,self.renderCache=snapshot.controls,snapshot.focusables,snapshot.renderCache
    if dropdown then dropdown.scroll=snapshot.dropdown.scroll end
    local ok, reason=self.transport('present',scene)
    if ok then self.lastScene=scene end
    if not ok then self.dirty=true end
    return ok,reason
end
function View:afterClose(callback)
    -- Called by an action from the mounted menu. Only its actual unmount permits
    -- a second native menu request; a focus request is not a teardown receipt.
    self.transfer=callback
end
function Open77NativePause.new(transport)
    local view={transport=transport,clock=GetGameTimer or function() return 0 end,handlers={},strings=PauseStrings or {},state={},tabs={},sections={},done=true,
        page='main',open=false,generation=0,revision=0,scroll=0,filter='',focus='resume',typing=false,
        accent='#22D8E2',logo='',logoReady=false,addresses=false,knownAddresses={},note='',error='',controls={},focusables={},ids={},nextId=0,dirty=true}
    -- The resource sandbox deliberately removes setmetatable/getmetatable.
    -- This private presenter needs only bound methods, no metatable capability.
    for name,method in pairs(View) do view[name]=method end
    return view
end
function Open77NativePause.create()
    local transport=Open77.pauseMenu._native
    local ok,reason=transport('create')
    if not ok then return nil,reason end
    local view=Open77NativePause.new(transport)
    view.frameYield=function() Wait(0) end
    CreateThread(function()
        Wait(0) -- main.lua registers every service callback before readiness.
        transport('image','platform','builtin:open77')
        view:emit('pause:ready')
        while true do
            for index,event in ipairs(transport('poll') or {}) do
                view:event(event)
                if index%4==0 then Wait(0) end
            end
            local sent,err=view:flush()
            if not sent then print('Open77 native pause: '..tostring(err)) end
            Wait(0)
        end
    end)
    return view
end
