local running=true
local resource=Open77.resource.name()
local controller=PlayerAttachmentController.new({
    now=function() return Open77.time.monotonic()*1000 end,
    send=function(name,...) return TriggerServerEvent('open77:playerAttachments:'..name,...) end,
    stop=function(id) Open77.playerInteractions._attachment(id) end,
    present=function(s) return Open77.playerInteractions._attachment(s.id,s) end,
    emit=function(name,...) TriggerEvent(name,...) end,
})
RegisterNetEvent('open77:playerAttachments:state',controller.receiveState)
RegisterNetEvent('open77:playerAttachments:snapshot',controller.receiveSnapshot)
exports('getAttachment',controller.get)
AddEventHandler('onClientResourceStop',function(name)
    if name==resource then running=false; controller.shutdown() end
end)
CreateThread(function()
    while running do controller.tick(Open77.animations._context()); Wait(50) end
end)
