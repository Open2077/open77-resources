local v = DeathmatchKabuki.volumes[1]
TestCharacter.yaw = 53
TestEvents["deathmatch:bounds"]({volumes={v},complete=true,inset=.75,zone="ffa"})
assert(coroutine.resume(TestThreads[1]))
assert(#TestCorrections == 1)
assert(TestCorrections[1].z == 124.373550 and TestCorrections[1].heading == 53)
assert(DeathmatchKabuki.contains(v, TestCharacter.position))
assert(coroutine.resume(TestThreads[1]))
assert(#TestCorrections == 1, "Legal positions must not move")
TestCharacter.position.x = v.center.x+v.radius+50
assert(coroutine.resume(TestThreads[1]))
assert(#TestCorrections == 1, "Large escapes belong to server backstop")
TestEvents["deathmatch:boundsClear"]()
TestCharacter.position.x = v.center.x+v.radius+1
assert(coroutine.resume(TestThreads[1]))
assert(#TestCorrections == 1, "Leaving PvP must release the wall")
