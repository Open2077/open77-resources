-- Engine tests for open77_braindance/shared/sequence.lua (pure Lua 5.4, no game).
-- Run: pwsh resources/system/open77_braindance/tests/run-lua.ps1
local S = BraindanceSequence or dofile((BraindanceRoot or ".") .. "/shared/sequence.lua")
local passed = 0
local function check(cond, msg) if not cond then error(msg, 2) end passed = passed + 1 end

local function kinds(actions)
    local out = {}
    for _, a in ipairs(actions) do
        out[#out + 1] = a.kind == "phase" and ("phase:" .. a.phase) or (a.kind .. (a.name and (":" .. a.name) or "")
            .. (a.locked ~= nil and (":" .. tostring(a.locked)) or "") .. (a.hidden ~= nil and (":" .. tostring(a.hidden)) or ""))
    end
    return table.concat(out, ",")
end

-- Validation
check(S.normalize(nil).preset == "braindance", "default preset")
check(select(2, S.normalize({ preset = "nope" })) == "unknown_preset", "unknown preset")
check(select(2, S.normalize({ bogus = 1 })) == "unknown_option:bogus", "unknown option")
check(select(2, S.normalize({ flashMs = -1 })) == "invalid_flashMs", "negative ms")
check(select(2, S.normalize({ flashMs = 1.5 })) == "invalid_flashMs", "fractional ms")
check(select(2, S.normalize({ holdMs = 30001 })) == "invalid_holdMs", "hold cap")
check(select(2, S.normalize({ maxHoldMs = 500 })) == "invalid_maxHoldMs", "max hold floor")
check(select(2, S.normalize({ flashEffect = "a b" })) == "invalid_flashEffect", "effect name")
check(select(2, S.normalize({ revealEffects = { "a", "b", "c", "d", "e" } })) == "invalid_revealEffects", "too many reveal effects")
check(select(2, S.normalize({ color = { r = 300 } })) == "invalid_color", "color range")
check(select(2, S.normalize({ hold = "yes" })) == "invalid_hold", "bool option")
check(select(2, S.normalize({ sounds = { black = "bad name" } })) == "invalid_sounds", "sound name")
check(S.normalize({ flash = false }).flashMs == 0, "no flash, no flash time")
local p = S.normalize({ preset = "glitch", holdMs = 10 })
check(p.holdMs == 10 and p.flashEffect == "transition_glitch_loop_braindance", "override on preset")
p.revealEffects[1] = "mutated"
check(S.PRESETS.glitch.revealEffects[1] == "time_skip_glitch", "presets are copied")

-- Enter braindance, automatic hold, overlay stays, then exit.
local seq = assert(S.new("c1", { preset = "braindance", sounds = { black = "ui_black" } }, 0))
check(kinds(seq:tick(0)) == "lock:true,hud:true,phase:flash,effect:braindance_entering", "start actions")
check(kinds(seq:tick(2599)) == "", "flash holds")
local a = seq:tick(2600)
check(kinds(a) == "phase:darkening,fadeOut", "darkening at flashMs")
check(a[2].durationMs == 450, "fade-out duration")
check(kinds(seq:tick(3500)) == "", "waits for the native fade")
seq:covered()
check(kinds(seq:tick(3600)) == "stopEffect:braindance_entering,perspective,phase:black,sound:ui_black", "black after covered")
check(seq:snapshot().phase == "black", "snapshot black")
check(kinds(seq:tick(4799)) == "", "hold 1200 ms")
a = seq:tick(4800)
check(kinds(a) == "phase:revealing,effect:braindance_fpp,effect:braindance_sound_vision_mode,fadeIn", "reveal with overlay")
seq:revealed()
check(kinds(seq:tick(4900)) == "phase:active,lock:false,hud:false", "active hands controls back")
check(kinds(seq:tick(60000)) == "", "overlay stays")
check(seq:exit(), "exit accepted")
check(not seq:exit(), "second exit refused")
a = seq:tick(60050)
check(kinds(a) == "stopEffect:braindance_fpp,stopEffect:braindance_sound_vision_mode,lock:true,hud:true,phase:exiting,effect:transition_glitch_loop_braindance", "exit start: " .. kinds(a))
check(kinds(seq:tick(60749)) == "", "exit flash")
check(kinds(seq:tick(60750)) == "phase:darkening,fadeOut", "exit darkening")
seq:covered()
local exitBlack = seq:tick(60800)
check(kinds(exitBlack) == "stopEffect:transition_glitch_loop_braindance,perspective,phase:black,sound:ui_black", "exit black")
check(exitBlack[2].firstPerson == false, "third person restored in the exit black")
check(seq:snapshot().leg == "exit", "exit leg")
check(kinds(seq:tick(61400)) == "phase:revealing,effect:eyes_opening_05s,fadeIn", "exit reveal")
seq:revealed()
check(kinds(seq:tick(61500)) == "stopEffect:eyes_opening_05s,lock:false,hud:false,phase:finished", "finished")
check(seq.done, "done")

-- Manual hold: black until resume, bounded by maxHoldMs.
seq = assert(S.new("c2", { preset = "transition", hold = true, maxHoldMs = 5000 }, 0))
seq:tick(0); seq:tick(2600); seq:covered()
check(kinds(seq:tick(3000)):find("phase:black", 1, true), "black")
check(kinds(seq:tick(7999)) == "", "holds until resume")
check(seq:resume(), "resume accepted")
check(kinds(seq:tick(8000)) == "phase:revealing,effect:eyes_opening_05s,fadeIn", "resume reveals")
seq:revealed()
check(kinds(seq:tick(8100)) == "stopEffect:eyes_opening_05s,lock:false,hud:false,phase:finished", "transition ends")

seq = assert(S.new("c3", { preset = "transition", hold = true, maxHoldMs = 5000 }, 0))
seq:tick(0); seq:tick(2600); seq:covered(); seq:tick(3000)
a = seq:tick(8000)
check(a[1].phase == "revealing" and a[1].info.timedOut == true, "max hold safety")

-- Cancel restores at once.
seq = assert(S.new("c4", { preset = "braindance" }, 0))
seq:tick(0)
a = seq:cancel(100, "test")
check(kinds(a) == "restore,stopEffect:braindance_entering,lock:false,hud:false,phase:cancelled", "cancel: " .. kinds(a))
-- cancel while in first person gives the camera back
local fp = assert(S.new("c7", { preset = "braindance" }, 0)); fp:tick(0); fp:tick(2600); fp:covered(); fp:tick(3000)
check(kinds(fp:cancel(3100)):find("perspective", 1, true), "cancel releases first person")
check(a[#a].info.reason == "test", "cancel reason")
check(#seq:cancel(200) == 0, "cancel twice")

-- No flash, no lock, no hud.
seq = assert(S.new("c5", { preset = "glitch", flash = false, lockMovement = false, hideHud = false }, 0))
check(kinds(seq:tick(0)) == "phase:flash,phase:darkening,fadeOut", "no flash goes straight to darkening")

-- Exit while still entering: finishes instead of becoming active.
seq = assert(S.new("c6", { preset = "braindance", holdMs = 0 }, 0))
seq:tick(0); seq:tick(2600); seq:covered(); seq:tick(3000)
seq:exit()
seq:revealed()
check(kinds(seq:tick(3100)):find("phase:finished", 1, true), "exit before active finishes")

-- A loading cycle keeps the screen black, then a settle, bounded by maxLoadingWaitMs.
seq = assert(S.new("c8", { preset = "transition", holdMs = 100, loadingSettleMs = 500, maxLoadingWaitMs = 10000 }, 0))
seq:tick(0); seq:tick(2600); seq:covered(); seq:tick(3000)
seq:setLoading(true, 3050)
check(kinds(seq:tick(5000)) == "", "loading keeps black")
seq:setLoading(false, 6000)
check(kinds(seq:tick(6200)) == "", "settle after loading")
check(kinds(seq:tick(6500)):find("phase:revealing", 1, true), "reveal after settle")
seq = assert(S.new("c9", { preset = "transition", holdMs = 100, maxLoadingWaitMs = 3000 }, 0))
seq:tick(0); seq:tick(2600); seq:covered(); seq:tick(3000)
seq:setLoading(true, 3050)
check(kinds(seq:tick(5999)) == "", "still loading")
check(kinds(seq:tick(6000)):find("phase:revealing", 1, true), "loading wait is bounded")
seq = assert(S.new("c10", { preset = "transition", holdMs = 100, waitForLoading = false }, 0))
seq:tick(0); seq:tick(2600); seq:covered(); seq:tick(3000)
seq:setLoading(true, 3050)
check(kinds(seq:tick(3100)):find("phase:revealing", 1, true), "waitForLoading=false ignores loading")
check(select(2, S.normalize({ maxLoadingWaitMs = 70000 })) == "invalid_maxLoadingWaitMs", "loading wait cap")

BraindanceSequenceTestsPassed = passed
print(("sequence_test: %d checks passed"):format(passed))
