local C=Aetherfall
local prefix="asset:open77_aetherfall_assets/"
AetherfallScene={}
-- bucket: the arena instance (training grounds or duel) the prop belongs to; the duel's by default.
local function create(model,position,options,bucket)
    options=options or {}
    options.model=prefix..model
    options.position=position
    options.bucket=bucket or C.bucket
    options.streamingRadius=150
    options.physics=options.physics or "none"
    options.collision=options.collision==true
    local id,reason=Open77.props.create(options)
    if not id then print("[aetherfall-scene] "..model.." refused: "..tostring(reason)) end
    return id
end
-- Permanent architecture, floor collision and lighting are authored in NCWE
-- and preloaded by open77_aetherfall_world. Only gameplay props are replicated.
function AetherfallScene.wand(player,position,bucket)
    local id=create("wand",position,nil,bucket)
    if not id then return end
    -- RightHand is the wrist frame. Centre the +Z wand shaft in the imported
    -- curled fingers, rather than treating the slot as a weapon grip socket.
    local ok,reason=Open77.props.attach(id,{parentType="player",parentId=player,bone="RightHand",
        offset={x=-0.045,y=0.019,z=0.055},rotation={x=-9,y=-140,z=0}})
    if not ok then
        Open77.props.remove(id)
        print("[aetherfall-scene] wand attach refused: "..tostring(reason))
        return
    end
    return id
end
function AetherfallScene.sigil(position,radius,ttl,bucket)
    return create("sigil",{x=position.x,y=position.y,z=C.arena.center.z+.075},
        {scale=radius,ttlMs=ttl},bucket)
end
function AetherfallScene.ward(player,position,ttl,bucket)
    local id=create("ward",position,{ttlMs=ttl},bucket)
    if not id then return end
    -- Root binding follows each client's rendered body every frame and keeps
    -- the shell upright through the casting animation's spine/hand movement.
    local ok,reason=Open77.props.attach(id,{parentType="player",parentId=player,
        offset={x=0,y=0,z=1.05}})
    if not ok then
        Open77.props.remove(id)
        print("[aetherfall-scene] ward attach refused: "..tostring(reason))
        return
    end
    return id
end
