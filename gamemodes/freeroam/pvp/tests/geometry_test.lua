local K = DeathmatchKabuki
local v = K.volumes[1]
assert(v.shape == "cylinder" and math.abs(v.radius - 140.612430451801) < 0.000001)
assert(#K.spawns.ffa == 17)
for _, m in ipairs(K.spawns.ffa) do assert(K.contains(v, m.position)) end
for _, sides in pairs(K.teams) do
    for _, marks in pairs(sides) do
        for _, m in ipairs(marks) do assert(K.contains(v, m.position)) end
    end
end
for _, height in ipairs({ 100, 118.324081, 125.373550, 200 }) do
    assert(K.contains(v, { x = v.center.x, y = v.center.y, z = height }))
    for degree = 0, 359 do
        local angle = math.rad(degree)
        local x = v.center.x + math.cos(angle) * (v.radius + 2)
        local y = v.center.y + math.sin(angle) * (v.radius + 2)
        assert(not K.contains(v, { x = x, y = y, z = height }))
        local px, py, pz = K.projectInto(v, x, y, height, 0.75)
        assert(K.contains(v, { x = px, y = py, z = pz }) and pz == height)
        assert(math.abs(math.sqrt((px-v.center.x)^2+(py-v.center.y)^2) - (v.radius-.75)) < 0.000001)
        assert(math.abs(K.distanceTo(v, {x=x,y=y,z=height})-2) < 0.000001)
    end
end
assert(not K.isSurveyed({shape="cylinder",center=v.center,radius=0}))
assert(not K.isSurveyed({shape="cylinder",center=v.center,radius=math.huge}))
assert(not K.isSurveyed({shape="cylinder",center=v.center,radius=0/0}))
assert(not K.isSurveyed({shape="cylinder",radius=10}))
local box = { min={x=0,y=0,z=0}, max={x=10,y=10,z=10} }
assert(K.contains(box, {x=5,y=5,z=1}) and not K.contains(box,{x=11,y=5,z=1}))
local px,py,pz = K.projectInto(box,11,5,1,.75)
assert(px==9.25 and py==5 and pz==1)
assert(K.copyVolume(v).radius == v.radius and K.copyVolume(v).center ~= v.center)
TestEvents, TestThreads, TestCorrections = {}, {}, {}
TestCharacter = { attached=true, alive=true, heading=37,
    position={ x=v.center.x+v.radius+2, y=v.center.y, z=124.373550 } }
RegisterNetEvent = function(name, callback) TestEvents[name] = callback end
AddEventHandler = function() end
CreateThread = function(callback) TestThreads[#TestThreads+1] = coroutine.create(callback) end
Wait = coroutine.yield
Open77 = {
    character={state=function() return TestCharacter end},
    travel={teleport=function(x,y,z,heading)
        TestCorrections[#TestCorrections+1] = {x=x,y=y,z=z,heading=heading}
        TestCharacter.position={x=x,y=y,z=z}
        return true
    end},
    log={info=function() end, warn=function() end, error=function() end},
    time={monotonic=function() return 100 end},
}
