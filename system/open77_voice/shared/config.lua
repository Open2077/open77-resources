VoiceConfig = VoiceConfig or {
    -- Local capture preference for the reference client policy. The dedicated
    -- server's enabled/quality/reach defaults come exclusively from server.jsonc
    -- (or an explicit authoritative resource call); this shared package must
    -- never silently overwrite an owner's global VOIP configuration.
    enabled = true,
    -- Mouth-only, native audio envelope. No effect on body animations or audio.
    lipSyncEnabled = true,

    -- The client may REQUEST scopes; the server still computes recipients.
    -- "all" speaks to proximity and every channel where CanSpeak is granted,
    -- so radio/phone and nearby speech can coexist in one encoded frame.
    pushToTalkKey = "V",
    transmitIntent = "all",

    -- Personal reach presets. `normal = nil` deliberately resolves to the
    -- canonical default advertised by the connected server, so an owner can
    -- tune normal speech without republishing this resource. Requests are
    -- clamped by server policy; they never disable proximity.
    proximityModes = {
        whisper = 3.0,
        normal = nil,
        shout = 40.0,
    },
    proximityModeOrder = { "whisper", "normal", "shout" },

    -- Disabled by default to avoid stealing a Cyberpunk gameplay binding.
    -- Set to an unused A-Z/0-9/action key to enable the reference edge-polling
    -- cycle, or bind `cycleProximityMode` from another input package.
    cycleProximityKey = nil,
    pollMilliseconds = 10,
    talkerPollMilliseconds = 50,
}
