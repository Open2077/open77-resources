local page
local enabled = true
-- True once the plugin confirmed it is drawing the plates itself. When it is,
-- this resource creates no page at all: see the long note at the bottom.
local nativeRender = false

local function pushSnapshot()
    if not page then return end
    if not enabled then
        page:send("nameplates:update", { players = {} })
        return
    end
    local players, reason = Open77.nameplates.snapshot()
    if players == nil then
        print("[open77_nameplates] snapshot failed: " .. tostring(reason))
        return
    end
    page:send("nameplates:update", { players = players })
end

exports("setEnabled", function(value)
    enabled = value ~= false
    if nativeRender then
        -- The native drawer has no idea what "enabled" means here; turning it
        -- off is turning it off.
        Open77.nameplates.render(enabled)
        return true
    end
    pushSnapshot()
    return true
end)

exports("isEnabled", function() return enabled end)

exports("set", function(playerId, options)
    return Open77.nameplates.set(tostring(playerId), options or {})
end)

exports("remove", function(playerId)
    return Open77.nameplates.remove(tostring(playerId))
end)

exports("clear", function()
    return Open77.nameplates.clear()
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    -- Native drawing first, and no page at all when it works.
    --
    -- `stream` had already taken Lua out of the per-frame path -- the plugin
    -- projected and published every frame -- and plates still trailed the world.
    -- A battle test measured one 418 px (about 15 degrees of view) behind the
    -- body it labelled during a camera whip, with the ground circle and the
    -- interaction prompt trailing by different amounts again. What was left is
    -- the CEF chain itself: IPC, a page repaint on the page's own timer, an
    -- offscreen raster, a shared-texture handoff, then the composite. Every
    -- stage buffers, and the staleness tracked each page's declared frame rate.
    --
    -- `render()` draws the plate in the frame that presents it, from a
    -- projection taken on the same frame. There is nothing left to buffer.
    -- The page below stays as the fallback for a client too old to have it.
    -- `and` rather than a bare call: a client older than the native drawer has
    -- no `render` at all, and indexing nil would take the whole resource down
    -- instead of falling back to the page.
    local rendered = Open77.nameplates.render ~= nil and Open77.nameplates.render(true)
    if rendered then
        nativeRender = true
        Open77.nameplates.render(enabled)
        return
    end

    local reason
    page, reason = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 60,
        zIndex = 640,
        transparent = true,
        visible = true
    })
    if not page then
        print("[open77_nameplates] WebUI failed: " .. tostring(reason))
        return
    end
    page:on("nameplates:ready", pushSnapshot)

    -- Per-frame delivery, native.
    --
    -- This used to be a `while page do pushSnapshot(); Wait(33) end` loop: the
    -- projection was already native (Open77.nameplates.snapshot returns screen
    -- coordinates), but *relaying* it rode the Lua scheduler, so plates lagged,
    -- froze and slid behind the camera when it moved quickly. Nothing on a
    -- per-frame path may pass through Lua.
    --
    -- `stream` hands the same already-projected vector to the same
    -- `nameplates:update` event, published by C++ every frame. Lua now only
    -- decides *what* is labelled; C++ decides where it is on screen this frame.
    local streamed, streamError = Open77.nameplates.stream(page)
    if not streamed then
        -- Older client without the native stream: fall back to polling rather
        -- than showing nothing at all.
        print("[open77_nameplates] native stream unavailable (" ..
            tostring(streamError) .. "); falling back to the Lua poll loop")
        CreateThread(function()
            while page do
                pushSnapshot()
                Wait(33)
            end
        end)
    end
end)

-- Native world exit clears both draw and stream ownership. The Lua resource
-- may survive that transition, so restore its existing request at world entry.
AddEventHandler("open77:worldReady", function()
    if nativeRender then
        Open77.nameplates.render(enabled)
    elseif page then
        Open77.nameplates.stream(page)
        pushSnapshot()
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if nativeRender then
        -- Release is idempotent and the host calls it anyway on stop; asking
        -- explicitly is what keeps a reload from leaving one frame painted.
        Open77.nameplates.render(false)
        nativeRender = false
        return
    end
    -- Stop the native stream explicitly. Generation teardown would release it
    -- anyway, but leaving a stream pointed at a page that is about to be
    -- destroyed is exactly the kind of dangling reference worth not writing.
    Open77.nameplates.stopStream()
    page = nil
end)
