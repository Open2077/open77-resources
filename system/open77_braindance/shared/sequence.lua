-- open77_braindance: the sequence engine shared by the client runtime and the tests.
--
-- A sequence is a timeline of phases. The engine is pure: it never calls the
-- game. `tick(now)` returns the actions the runtime must perform (play an
-- authored player effect, fade the native screen, report a phase), and the
-- runtime answers with `covered()` / `revealed()` when the native fade it
-- started has actually finished. Time is integer milliseconds.
--
--   start ─► flash ─► darkening ─► black ─(hold / resume)─► revealing ─► active ─► exiting ─► … ─► finished
--                                                                     └─► finished (transition presets)
--
-- `black` is the moment a script can do anything invisible: move the player,
-- swap a bucket, spawn a set, change the weather. With `hold = true` the screen
-- stays black until `resume()` (bounded by `maxHoldMs`, so a script that forgets
-- never leaves a player staring at black).

local Sequence = {}

local PHASES = {
    "start", "flash", "darkening", "black", "revealing", "active",
    "exiting", "finished", "cancelled",
}

-- Authored on the player entity templates (player_ma_fpp / player_wa_fpp,
-- `entEffectDesc` names), so `Open77.vfx.playEntity(name, {entity = "1"})`
-- plays them exactly as the game does. Screen-space effects only.
local EFFECTS = {
    braindance_entering = "Braindance launch: white-out ramp with chromatic aberration and its own sound (6 s)",
    braindance_fpp = "Braindance overlay loop (4 s loop)",
    transition_glitch_loop_braindance = "Braindance-tinted glitch loop (0.35 s loop)",
    braindance_scrolling = "Braindance scrolling placeholder",
    braindance_sound_vision_mode = "Braindance vision: cyan tint and pixel shimmer (the BD look while active)",
    transition_glitch_loop = "Dialogue-skip glitch loop",
    time_skip_glitch = "Time-skip glitch",
    time_skip_glitch_long = "Time-skip glitch, long",
    fast_travel_glitch = "Fast-travel glitch",
    fast_travel_glitch_long = "Fast-travel glitch, long",
    cyberspace_teleport = "Cyberspace teleport full-screen",
    reboot_glitch = "Reboot glitch",
    personal_link_glitch = "Personal link glitch",
    hacking_glitch_low = "Hacking glitch, low",
    hacking_glitch_medium = "Hacking glitch, medium",
    hacking_glitch_heavy = "Hacking glitch, heavy",
    johnny_took_control = "Relic takeover",
    johnny_gave_back_control = "Relic release",
    blackout = "Blackout",
    blackout_organic = "Blackout, organic",
    eyes_closing = "Eyes closing",
    eyes_closing_fast = "Eyes closing, fast",
    eyes_opening = "Eyes opening (waking up)",
    eyes_opening_05s = "Eyes opening, 0.5 s",
    blink_fast = "Blink, fast",
    blink_slow = "Blink, slow",
    zoom = "Zoom",
    fish_eye = "Fish eye",
}
Sequence.EFFECTS = EFFECTS

-- Presets. Every field can be overridden by the caller.
local PRESETS = {
    -- Put on a braindance: the vanilla launch flash, black, then the BD overlay
    -- stays until exit().
    braindance = {
        flashEffect = "braindance_entering", flashMs = 2600,
        fadeOutMs = 450, holdMs = 1200, fadeInMs = 900,
        revealEffects = { "braindance_fpp", "braindance_sound_vision_mode" }, overlay = true, firstPerson = true,
        exitEffect = "transition_glitch_loop_braindance", exitFlashMs = 700,
        exitFadeOutMs = 350, exitHoldMs = 600, exitFadeInMs = 900,
        exitRevealEffects = { "eyes_opening_05s" },
    },
    -- Use the braindance launch as a transition (teleport, scene change):
    -- flash, black, then back to the normal world with a short wake-up.
    transition = {
        flashEffect = "braindance_entering", flashMs = 2600,
        fadeOutMs = 450, holdMs = 1200, fadeInMs = 900,
        revealEffects = { "eyes_opening_05s" }, overlay = false,
    },
    -- A short glitch cut, for quick scene swaps.
    glitch = {
        flashEffect = "transition_glitch_loop_braindance", flashMs = 500,
        fadeOutMs = 250, holdMs = 400, fadeInMs = 500,
        revealEffects = { "time_skip_glitch" }, overlay = false,
    },
}
Sequence.PRESETS = PRESETS

local LIMITS = {
    flashMs = { 0, 10000 }, fadeOutMs = { 0, 5000 }, holdMs = { 0, 30000 },
    fadeInMs = { 0, 5000 }, maxHoldMs = { 1000, 60000 },
    exitFlashMs = { 0, 10000 }, exitFadeOutMs = { 0, 5000 }, exitHoldMs = { 0, 30000 },
    exitFadeInMs = { 0, 5000 }, maxLoadingWaitMs = { 0, 60000 }, loadingSettleMs = { 0, 5000 },
}

local function isInteger(v) return type(v) == "number" and v == v and v >= -2^53 and v <= 2^53 and math.floor(v) == v end

local function validEffectName(name)
    return type(name) == "string" and #name > 0 and #name <= 64 and name:match("^[%w_]+$") ~= nil
end

local function copyList(list)
    if list == nil then return nil end
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
end

--- Merges a preset with caller options. Returns a normalized option table or nil, reason.
function Sequence.normalize(options)
    if options ~= nil and type(options) ~= "table" then return nil, "options_must_be_a_table" end
    options = options or {}
    local presetName = options.preset or "braindance"
    local preset = PRESETS[presetName]
    if preset == nil then return nil, "unknown_preset" end
    local o = {}
    for k, v in pairs(preset) do o[k] = (type(v) == "table") and copyList(v) or v end
    o.preset = presetName
    o.hold = false
    o.maxHoldMs = 20000
    o.lockMovement = true
    o.hideHud = true
    o.flash = true
    o.color = nil
    o.waitForLoading = true
    o.maxLoadingWaitMs = 20000
    o.loadingSettleMs = 500

    local known = {
        preset = true, hold = true, maxHoldMs = true, lockMovement = true, hideHud = true, flash = true,
        flashEffect = true, flashMs = true, fadeOutMs = true, holdMs = true, fadeInMs = true,
        revealEffects = true, overlay = true, exitEffect = true, exitFlashMs = true, exitFadeOutMs = true,
        exitHoldMs = true, exitFadeInMs = true, exitRevealEffects = true, color = true, sounds = true,
        teleport = true, exitTeleport = true, tag = true, holdOnExit = true, letterbox = true, firstPerson = true,
        waitForLoading = true, maxLoadingWaitMs = true, loadingSettleMs = true,
    }
    for k in pairs(options) do
        if not known[k] then return nil, "unknown_option:" .. tostring(k) end
    end
    for k, v in pairs(options) do
        if k ~= "preset" then o[k] = (type(v) == "table" and (k == "revealEffects" or k == "exitRevealEffects")) and copyList(v) or v end
    end

    for key, range in pairs(LIMITS) do
        local v = o[key]
        if v ~= nil and (not isInteger(v) or v < range[1] or v > range[2]) then
            return nil, "invalid_" .. key
        end
    end
    for _, key in ipairs({ "hold", "lockMovement", "hideHud", "flash", "overlay", "holdOnExit", "firstPerson", "waitForLoading" }) do
        if o[key] ~= nil and type(o[key]) ~= "boolean" then return nil, "invalid_" .. key end
    end
    for _, key in ipairs({ "flashEffect", "exitEffect" }) do
        if o[key] ~= nil and o[key] ~= false and not validEffectName(o[key]) then return nil, "invalid_" .. key end
    end
    for _, key in ipairs({ "revealEffects", "exitRevealEffects" }) do
        local list = o[key]
        if list ~= nil then
            if type(list) ~= "table" or #list > 4 then return nil, "invalid_" .. key end
            for _, name in ipairs(list) do
                if not validEffectName(name) then return nil, "invalid_" .. key end
            end
        end
    end
    if o.color ~= nil then
        local c = o.color
        if type(c) ~= "table" then return nil, "invalid_color" end
        for _, ch in ipairs({ "r", "g", "b" }) do
            if c[ch] ~= nil and (not isInteger(c[ch]) or c[ch] < 0 or c[ch] > 255) then return nil, "invalid_color" end
        end
    end
    if o.sounds ~= nil then
        if type(o.sounds) ~= "table" then return nil, "invalid_sounds" end
        for phase, name in pairs(o.sounds) do
            if type(phase) ~= "string" or not validEffectName(name) then return nil, "invalid_sounds" end
        end
    end
    if o.tag ~= nil and (type(o.tag) ~= "string" or #o.tag > 64) then return nil, "invalid_tag" end
    if o.letterbox ~= nil and (type(o.letterbox) ~= "number" or o.letterbox ~= o.letterbox
        or o.letterbox < 0.01 or o.letterbox > 0.4) then return nil, "invalid_letterbox" end
    if not o.flash then o.flashMs = 0 end
    return o
end

--- A new sequence, not yet started. `id` is opaque.
function Sequence.new(id, options, now)
    local o, reason = Sequence.normalize(options)
    if not o then return nil, reason end
    -- No metatables: the client sandbox has no setmetatable. Methods are copied.
    local self = {}
    for k, v in pairs(Sequence) do
        if type(v) == "function" and k ~= "new" and k ~= "normalize" then self[k] = v end
    end
    self.id = id
    self.options = o
    self.phase = "start"
    self.phaseAt = now
    self.startedAt = now
    self.exitRequested = false
    self.resumeRequested = false
    self.leg = "enter" -- "enter" or "exit"
    self.pending = {}
    self.effects = {} -- effect names currently held by this sequence
    self.waiting = nil -- "covered" | "revealed" | nil
    self.deadline = nil
    return self
end

local function push(self, action) self.pending[#self.pending + 1] = action end

local function setPhase(self, phase, now, info)
    self.phase = phase
    self.phaseAt = now
    push(self, { kind = "phase", phase = phase, leg = self.leg, info = info })
    local sound = self.options.sounds and self.options.sounds[phase]
    if sound then push(self, { kind = "sound", name = sound }) end
end

local function startEffect(self, name, durationMs)
    if not name then return end
    push(self, { kind = "effect", name = name, durationMs = durationMs })
    self.effects[name] = true
end

local function stopEffect(self, name)
    if name and self.effects[name] then
        push(self, { kind = "stopEffect", name = name })
        self.effects[name] = nil
    end
end

local function stopAllEffects(self)
    local names = {}
    for name in pairs(self.effects) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do stopEffect(self, name) end
end

local function legValue(self, enterKey, exitKey)
    if self.leg == "exit" then return self.options[exitKey] end
    return self.options[enterKey]
end

--- Advances the timeline. Returns the list of actions to perform now.
function Sequence:tick(now)
    local o = self.options
    local guard = 0
    while guard < 16 do
        guard = guard + 1
        local before = self.phase
        if self.phase == "start" then
            if o.lockMovement then push(self, { kind = "lock", locked = true }) end
            if o.hideHud then push(self, { kind = "hud", hidden = true, letterbox = o.letterbox }) end
            setPhase(self, "flash", now)
            local effect = legValue(self, "flashEffect", "exitEffect")
            if o.flash and effect then startEffect(self, effect, 0) end
        elseif self.phase == "flash" then
            local ms = legValue(self, "flashMs", "exitFlashMs") or 0
            if not o.flash then ms = 0 end
            if now - self.phaseAt >= ms then
                setPhase(self, "darkening", now)
                push(self, { kind = "fadeOut", durationMs = legValue(self, "fadeOutMs", "exitFadeOutMs") or 0, color = o.color })
                self.waiting = "covered"
            end
        elseif self.phase == "darkening" then
            if self.waiting == nil then
                stopAllEffects(self)
                -- The camera changes while nobody can see it.
                if o.firstPerson then
                    push(self, { kind = "perspective", firstPerson = self.leg == "enter" })
                    self.perspectiveHeld = self.leg == "enter"
                end
                setPhase(self, "black", now, { hold = self:holding() })
                self.resumeRequested = false
            end
        elseif self.phase == "black" then
            local ready
            if self:holding() then
                ready = self.resumeRequested or (now - self.phaseAt >= o.maxHoldMs)
            else
                ready = now - self.phaseAt >= (legValue(self, "holdMs", "exitHoldMs") or 0)
            end
            -- A teleport far away opens the game's own loading cycle: stay black
            -- until it has closed (plus a short settle), bounded by maxLoadingWaitMs.
            if ready and o.waitForLoading then
                local waited = now - self.phaseAt
                if self.loading then
                    if waited < o.maxLoadingWaitMs then ready = false end
                elseif self.loadingEndedAt and now - self.loadingEndedAt < o.loadingSettleMs then
                    ready = false
                end
            end
            if ready then
                setPhase(self, "revealing", now, { timedOut = self:holding() and not self.resumeRequested or nil })
                for _, name in ipairs(legValue(self, "revealEffects", "exitRevealEffects") or {}) do
                    startEffect(self, name, 0)
                end
                push(self, { kind = "fadeIn", durationMs = legValue(self, "fadeInMs", "exitFadeInMs") or 0 })
                self.waiting = "revealed"
            end
        elseif self.phase == "revealing" then
            if self.waiting == nil then
                if self.leg == "enter" and o.overlay and not self.exitRequested then
                    setPhase(self, "active", now)
                    push(self, { kind = "lock", locked = false })
                    push(self, { kind = "hud", hidden = false })
                else
                    self:finish(now, "finished")
                end
            end
        elseif self.phase == "active" then
            if self.exitRequested then
                self.leg = "exit"
                self.resumeRequested = false
                stopAllEffects(self)
                if o.lockMovement then push(self, { kind = "lock", locked = true }) end
                if o.hideHud then push(self, { kind = "hud", hidden = true, letterbox = o.letterbox }) end
                setPhase(self, "exiting", now)
                local effect = o.exitEffect
                if o.flash and effect then startEffect(self, effect, 0) end
                self.phase = "flash"
                self.phaseAt = now
            end
        end
        if self.phase == before then break end
    end
    local actions = self.pending
    self.pending = {}
    return actions
end

function Sequence:holding()
    if self.leg == "exit" then return self.options.holdOnExit == true end
    return self.options.hold == true
end

--- The runtime reports whether the game's loading cycle is active.
function Sequence:setLoading(active, now)
    if self.loading and not active then self.loadingEndedAt = now end
    self.loading = active == true
end

--- The runtime saw the native fade-out complete.
function Sequence:covered()
    if self.waiting == "covered" then self.waiting = nil end
end

--- The runtime saw the native fade-in complete.
function Sequence:revealed()
    if self.waiting == "revealed" then self.waiting = nil end
end

--- Leaves black early (or on demand when `hold = true`). True if it mattered.
function Sequence:resume()
    if self.phase == "black" or self.phase == "darkening" or self.phase == "flash" then
        self.resumeRequested = true
        return true
    end
    return false
end

--- Leaves the braindance (overlay presets). Accepted while active or still entering.
function Sequence:exit(options)
    if self.done or self.exitRequested or self.leg == "exit" then return false end
    if options ~= nil then
        if type(options) ~= "table" then return false end
        if options.hold ~= nil then
            if type(options.hold) ~= "boolean" then return false end
            self.options.holdOnExit = options.hold
        end
    end
    self.exitRequested = true
    return true
end

function Sequence:finish(now, phase, info)
    stopAllEffects(self)
    if self.perspectiveHeld then
        push(self, { kind = "perspective", firstPerson = false })
        self.perspectiveHeld = false
    end
    push(self, { kind = "lock", locked = false })
    push(self, { kind = "hud", hidden = false })
    setPhase(self, phase, now, info)
    self.done = true
end

--- Ends at once: effects stopped, screen restored by the runtime, controls back.
function Sequence:cancel(now, reason)
    if self.done then return {} end
    push(self, { kind = "restore" })
    self:finish(now, "cancelled", { reason = reason or "cancelled" })
    local actions = self.pending
    self.pending = {}
    return actions
end

function Sequence:snapshot()
    return {
        id = self.id, phase = self.phase, leg = self.leg, preset = self.options.preset,
        tag = self.options.tag, hold = self:holding(), overlay = self.options.overlay == true,
        done = self.done == true,
    }
end

Sequence.PHASES = PHASES
BraindanceSequence = Sequence
return Sequence
