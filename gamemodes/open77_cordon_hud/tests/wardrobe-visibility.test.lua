local handlers, pages = {}, {}
function AddEventHandler(name, fn) handlers[name] = fn end
function GetCurrentResourceName() return "open77_cordon_hud" end
function CreateThread() end
local function noop() end
local phase = "ready"
Open77 = {session={characterBootstrap=function() return {phase=phase} end},
    log={info=noop,error=error}}
WebUI = {create=function(options)
    local page = {visible=options.visible}
    function page:show() self.visible=true end
    function page:hide() self.visible=false end
    pages[options.entry]=page
    return page
end}
CordonMatch={attach=noop,detach=noop}
CordonCombat={attach=noop,detach=noop,push=noop,onState=noop}
CordonWall={attach=noop,detach=noop}
CordonTacmap={attach=noop,detach=noop,onState=noop,setOpen=noop,isOpen=function() return false end}
dofile("resources/gamemodes/open77_cordon_hud/client/main.lua")
handlers.onClientResourceStart("open77_cordon_hud")
CordonHud.route({self={state="staging"}})
assert(pages["web/match.html"].visible)
handlers["open77:wardrobe:visibility"](true)
assert(not pages["web/match.html"].visible and not CordonHud.canPresent())
CordonHud.route({self={state="staging"}}) -- network pushes cannot reopen it
assert(not pages["web/match.html"].visible)
handlers["open77:wardrobe:visibility"](false)
assert(pages["web/match.html"].visible)
handlers["open77:wardrobe:visibility"](true)
handlers.onClientResourceStop("open77_wardrobe_ui")
assert(pages["web/match.html"].visible)
phase="creator_open"
CordonHud.refreshPresentation()
assert(not pages["web/match.html"].visible)
handlers["open77:wardrobe:visibility"](false)
assert(not pages["web/match.html"].visible)
print("Cordon wardrobe: modal overlap, incoming state, close, resource stop and creator gating passed")
