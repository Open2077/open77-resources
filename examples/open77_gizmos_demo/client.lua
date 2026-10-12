-- Opt-in editor laboratory. The server's restricted /gizmo.demo command
-- dispatches local preview actions; this resource never grants server authority.
local G = Open77.gizmos
local current, prop, pending
local counts = {}

local function report(name, value, reason)
    print(('GIZMO %s %s %s'):format(name, json.encode(value), tostring(reason or '')))
end

local function clear()
    pending = nil
    if current then G.destroy(current); current = nil end
end

local function open(options)
    clear()
    options.snap = options.snap or {translation=.25, rotation=15, scale=.1}
    options.timeoutMs = 120000
    local id, why = G.create(options)
    if not id then return report('create-failed', false, why) end
    current = id
    local ok, reason = G.activate(id)
    report('activate', {ok=ok, state=G.get(id)}, reason)
    if not ok then G.destroy(id); current = nil end
end

for _, name in ipairs({'created','activated','configured','hover','dragStart','change',
    'dragEnd','undo','redo','commit','cancel','targetLost','error','deactivated','destroyed','settled'}) do
    AddEventHandler('open77:gizmo:'..name, function(state)
        counts[name] = (counts[name] or 0) + 1
        if name ~= 'change' and name ~= 'hover' then report(name, state) end
    end)
end

local function ahead()
    local state, reason = Open77.character.state()
    if not state or not state.alive or not state.attached then return nil, reason or 'player_not_ready' end
    local p = state.position
    -- Use the active camera bearing when available; no forced camera mode.
    local camera = Open77.camera.view()
    local f = camera and camera.forward or state.forward or {x=0,y=1,z=0}
    return {x=p.x+f.x*3, y=p.y+f.y*3, z=p.z+.8}
end

local function dispatch(action, kind, id, z)
    if action == 'clear' then
        clear()
        if prop then Open77.props.remove(prop); prop = nil end
        return report('cleared', G.list())
    elseif action == 'state' then
        return report('state', {active=G.active(), owned=G.list(), events=counts,
            character=Open77.character.state()})
    elseif action == 'virtual' then
        local p, why = ahead()
        if not p then return report('not-ready',false,why) end
        return open({transform={position=p}, mode=kind or 'translate'})
    elseif action == 'target' or action == 'targetData' then
        return open({target={kind=kind, id=id or '0'},preview=action~='targetData'})
    elseif action == 'localProp' then
        clear()
        if prop then Open77.props.remove(prop); prop=nil end
        local p, why = ahead()
        if not p then return report('not-ready',false,why) end
        prop, why = Open77.props.create({model='furniture.chair.metal',position=p,yaw=0})
        if not prop then return report('prop-failed',false,why) end
        local token = {}
        pending = token
        CreateThread(function()
            for _=1,100 do
                if pending ~= token then return end
                local caps = G.capabilities({kind='localProp',id=prop})
                if caps then return open({target={kind='localProp',id=prop}}) end
                Wait(100)
            end
            pending = nil
            report('prop-stream-timeout',false)
        end)
        return
    end
    if not current then return report('no-active-handle', false) end
    local ok, why
    if action == 'set' then
        local x, y, zz = tonumber(kind), tonumber(id), tonumber(z)
        if not x or not y or not zz then return report('usage',false,'set <x> <y> <z>') end
        ok, why = G.setTransform(current,{position={x=x,y=y,z=zz}})
    elseif action == 'mode' then ok, why = G.update(current,{mode=kind})
    elseif action == 'space' then ok, why = G.update(current,{space=kind})
    elseif action == 'commit' then ok, why = G.commit(current)
    elseif action == 'cancel' then ok, why = G.cancel(current)
    elseif action == 'undo' then ok, why = G.undo(current)
    elseif action == 'redo' then ok, why = G.redo(current)
    elseif action == 'activate' then ok, why = G.activate(current)
    else return report('usage',false,'virtual | localProp | target <kind> <id> | set <x> <y> <z> | mode | space | undo | redo | commit | cancel | state | clear') end
    report(action,{ok=ok,state=G.get(current)},why)
end
AddEventHandler('gizmos:demo', dispatch)
RegisterNetEvent('gizmos:demo:run', dispatch)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    clear()
    if prop then Open77.props.remove(prop); prop=nil end
end)
