-- Optional example: loaded on the CLIENT by the server's resource set.
-- This resource owns only its own HUD claims and overlay, never anyone else's.
if not Open77.screen or not Open77.screen.loadingState then
    print('[loading-screen] This client does not support native loading observation.')
    return
end

-- Server resources prepare before native/UI effects are permitted.
AddEventHandler('onClientResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    local overlay, why = Open77.webui.create({
        entry = 'web/index.html', layer = 'modal', zIndex = 100,
        visible = true, transparent = true, fps = 30,
    })
    if not overlay then print('[loading-screen] ' .. tostring(why)); return end

    -- Keep the page alive with an empty transparent DOM between loads. This avoids
    -- starting Chromium after the load has begun. No keyboard/cursor focus is taken.
    local ready, lastRevision, active = false, -1, false
    local function apply(state)
        if not state or state.revision < lastRevision then return end
        lastRevision = state.revision
        if state.active ~= active then
            active = state.active
            Open77.hud.setVisible('all', not active)
        end
        if ready then overlay:send('loading:state', state) end
    end
    local function refresh()
        local state, err = Open77.screen.loadingState()
        if state then apply(state)
        else print('[loading-screen] ' .. tostring(err)) end
    end

    -- Register first, then initialize. Works when the resource starts mid-load.
    AddEventHandler('open77:loadingScreen:changed', apply)
    for _, event in ipairs({'started', 'finished'}) do
        AddEventHandler('open77:loadingScreen:' .. event, function(state)
            print('[loading-screen] ' .. event .. ' ' .. Open77.json.encode(state))
        end)
    end
    overlay:on('ui:ready', function() ready = true; refresh() end)
    refresh()
    -- Resource stop/reload automatically destroys the page and releases HUD claims.
end)
