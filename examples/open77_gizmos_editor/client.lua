local G=Open77.gizmos
local editing
local function close(notify)
    local old=editing;editing=nil
    if not old then return end
    if old.handle then G.destroy(old.handle) end
    if notify then TriggerServerEvent('gizmoEditor:cancel',old.token) end
end
RegisterNetEvent('gizmoEditor:open',function(ticket)
    close(true)
    local session={token=ticket.token};editing=session
    CreateThread(function()
        -- Canonical prop creation precedes the editor message, but native
        -- projection/asset streaming is asynchronous.
        for _=1,100 do
            if editing~=session then return end
            if G.capabilities(ticket.target) then
                local why
                session.handle,why=G.create({target=ticket.target,timeoutMs=ticket.timeoutMs,
                    snap={translation=.25,rotation=15,scale=.1}})
                local ok
                if session.handle then ok,why=G.activate(session.handle) end
                if not ok then print('GIZMO EDITOR could not open '..tostring(why));close(true) end
                return
            end
            Wait(100)
        end
        print('GIZMO EDITOR target did not stream');close(true)
    end)
end)
AddEventHandler('open77:gizmo:commit',function(state)
    if not editing or state.id~=editing.handle then return end
    local token=editing.token
    -- Destroy only the terminal handle: commit has already requested native
    -- restoration. The authoritative update arrives through normal replication.
    close(false)
    TriggerServerEvent('gizmoEditor:commit',token,state.transform)
end)
AddEventHandler('open77:gizmo:cancel',function(state)
    if editing and state.id==editing.handle then close(true) end
end)
AddEventHandler('open77:gizmo:error',function(state)
    if editing and state.id==editing.handle then close(true) end
end)
RegisterNetEvent('gizmoEditor:result',function(token,ok,why)
    if editing and editing.token==token then close(false) end
    print(('GIZMO EDITOR %s: %s'):format(ok and 'saved' or 'refused',tostring(why)))
end)
RegisterNetEvent('gizmoEditor:close',function() close(false) end)
AddEventHandler('onClientResourceStop',function(name)
    if name==GetCurrentResourceName() then close(true) end
end)
