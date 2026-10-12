-- THE string table for the pause menu.
--
-- Every player-facing word this resource owns lives here and nowhere else --
-- not in index.html, not inline in its JavaScript, not in a Lua print that
-- reaches the screen. The page paints its static labels from `data-t` and asks
-- for the rest through `PauseText.t` / `PauseText.fmt`; the client script reads
-- the same table directly, because `shared_script` runs it in the same Lua
-- state as `client/main.lua` (ResourceHost.cpp:868 prepends shared scripts to
-- the client list, so this file is loaded first).
--
-- `{name}` is a placeholder, substituted by `fmt` on either side.
--
-- WHAT IS DELIBERATELY ABSENT, because it is data rather than language:
--
--   * every engine setting's label and every option name in a dropdown. They
--     come from the engine, already localised, on the `meta:` line the script
--     bridge now emits (Open77SettingLabel / Open77SettingOption in
--     client/redscript/Open77ScriptBridge.reds). Before that line existed the
--     page carried a hand-written English table of twenty names and camel-case
--     split the rest, which is exactly the hardcoding this file forbids;
--   * audio device names, which Windows supplies;
--   * key names and the human name a resource gave its own key mapping;
--   * server names, player names, endpoints and versions.
--
-- A missing key renders as its own dotted path. That is ugly ON PURPOSE: a
-- blank label hides the mistake, a visible `settings.filterPlaceholder` does
-- not, and the second one gets fixed.

PauseStrings = {
    locale = "en",

    -- Masthead and the dialog's accessible name.
    chip = "Paused",
    dialogLabel = "Pause menu",
    mapUnavailable = "The city map could not open ({reason}). Close other menus and try again.",

    -- The keyboard legend along the bottom of the panel. Split label/key so the
    -- key can keep its own type treatment without HTML in a string.
    legend = {
        close = "CLOSE",
        navigate = "NAVIGATE",
        adjust = "ADJUST",
        select = "SELECT",
        escape = "ESC",
        updown = "\u{2191} \u{2193}",
        leftright = "\u{2190} \u{2192}",
        enter = "ENTER",
    },

    session = {
        eyebrow = "Session",
        none = "No session",
        connecting = "Connecting\u{2026}",
        connected = "Connected",
        offline = "OFFLINE",
        live = "LIVE",
        hint = "Not connected. Join a world from the server browser.",
        player = "Player",
        ping = "Ping",
        players = "Players",
        tick = "Tick",
        serverVersion = "Server ver",
        endpoint = "Endpoint",
        showAddresses = "Show IP addresses",
        addressHidden = "[address hidden]",
        client = "Client",
        milliseconds = "ms",
        -- `snap` is the snapshot rate; both figures are engine data.
        tickUnit = "Hz \u{b7} snap {rate}",
        blank = "\u{2014}",
    },

    menu = {
        resume = "RESUME",
        map = "CITY MAP",
        settings = "SETTINGS",
        quitSession = "QUIT SESSION",
        quitGame = "QUIT GAME",
    },

    -- Copy shown before each destructive action. Written out per action rather
    -- than derived from the label, so each one says what actually happens.
    confirm = {
        yes = "CONFIRM",
        no = "CANCEL",
        quitSessionTitle = "Quit session",
        quitSessionBody = "You will be disconnected and returned to the server " ..
            "browser. Your character stays on the server.",
        quitGameTitle = "Quit game",
        quitGameBody = "Cyberpunk 2077 will close. If you are in a session you " ..
            "will be disconnected first.",
    },

    settings = {
        title = "Settings",
        categories = "Settings categories",
        loading = "Loading\u{2026}",
        back = "BACK",
        vanilla = "FULL GAME SETTINGS",
        vanillaHint = "Opens the game's own settings screen. The world pauses " ..
            "while it is open.",
        empty = "Nothing adjustable here yet. The full game settings cover this " ..
            "category.",
        noCategories = "No categories available.",
        noMatch = "Nothing here matches \u{201c}{query}\u{201d}.",
        filterLabel = "Filter settings in this category",
        filterPlaceholder = "FILTER",
        filterClear = "Clear the filter",
        range = "{first} - {last} / {total}",
        scrollHint = "MOUSE WHEEL / PAGE UP / PAGE DOWN",
        on = "ON",
        off = "OFF",
        previous = "Previous {name}",
        next = "Next {name}",
        find = "FIND",
        findNoMatch = "no match",
        blank = "\u{2014}",
    },

    -- Tab names, keyed by the id `TABS` declares in client/main.lua. The panel
    -- heading is derived from the same word rather than stored twice.
    tabs = {
        video = "VIDEO",
        graphics = "GRAPHICS",
        audio = "AUDIO",
        voice = "VOICE",
        controls = "CONTROLS",
        keybinds = "KEY BINDINGS",
        gameplay = "GAMEPLAY",
    },

    -- Section headings inside a tab. One key per engine group a tab renders --
    -- the group PATH is not a heading: `/graphics/advanced` is a routing
    -- detail, and it is what the page used to print.
    groups = {
        display = "DISPLAY",
        brightness = "BRIGHTNESS",
        upscaling = "UPSCALING & FRAME GENERATION",
        effects = "EFFECTS",
        quality = "QUALITY",
        raytracing = "RAY TRACING",
        crowds = "CROWDS",
        system = "SYSTEM",
        volume = "VOLUME",
        audioMisc = "AUDIO OUTPUT",
        audioRange = "DYNAMIC RANGE",
        voice = "VOICE CHAT",
        keybinds = "REGISTERED ACTIONS",
        controlsGeneral = "GENERAL",
        mouse = "MOUSE",
        mouseTpp = "MOUSE \u{b7} THIRD PERSON",
        pad = "CONTROLLER",
        padCamera = "CONTROLLER CAMERA",
        padCameraTpp = "CONTROLLER CAMERA \u{b7} THIRD PERSON",
        vehicle = "VEHICLE",
        gameplayMisc = "GAMEPLAY",
        difficulty = "DIFFICULTY",
        hud = "HUD",
        performance = "PERFORMANCE",
        interface = "INTERFACE",
        hudElements = "HUD ELEMENTS",
    },

    -- Row tags. Each one answers "why did nothing visibly happen?" before the
    -- player has to ask -- the engine tells us, so the row says so.
    tag = {
        restart = "RESTART",
        restartHint = "Takes effect the next time the game starts.",
        checkpoint = "RELOAD",
        checkpointHint = "Takes effect after the world is reloaded.",
        menuOnly = "MENU ONLY",
        menuOnlyHint = "The engine only applies this from the main menu. " ..
            "Changing it here is stored and used at the next launch.",
        locked = "LOCKED",
        lockedHint = "The engine has this locked right now \u{2014} usually " ..
            "because the option it depends on is off.",
        hidden = "HIDDEN",
        hiddenHint = "The game's own settings screen does not offer this one.",
        unavailable = "UNAVAILABLE",
        unavailableHint = "This machine reports no options for it.",
    },

    -- VOICE. These rows are built by the client script from the native voice
    -- status, not by the engine's settings tree, so their labels live here.
    voice = {
        transmitMode = "Transmit mode",
        transmitState = "Microphone state",
        pushToTalkKey = "Push-to-talk key",
        inputDevice = "Microphone",
        outputDevice = "Output device",
        inputVolume = "Microphone volume",
        outputVolume = "Voice volume",
        reach = "Voice reach",
        captureEnabled = "Microphone enabled",
        activation = "Voice activation",
        activationThreshold = "Activation threshold",
        microphoneTest = "Test microphone (local loopback)",
        inputLevel = "Microphone level",
        outputLevel = "Voice output level",
        thresholdMarker = "Activation threshold",

        systemDefault = "Windows communications default",
        modeActivation = "VOICE ACTIVATION",
        modePushToTalk = "PUSH-TO-TALK \u{b7} HOLD {key}",
        stateDisabled = "MICROPHONE DISABLED",
        stateTransmitting = "TRANSMITTING",
        stateReadyActivation = "READY \u{b7} SPEAK ABOVE THRESHOLD",
        stateReadyPushToTalk = "READY \u{b7} HOLD {key} TO TRANSMIT",
        reachValue = "SERVER MANAGED \u{b7} {metres} m",

        saved = "SAVED",
        microphoneTestUpdated = "MICROPHONE TEST UPDATED",
        failed = "VOICE SETTING FAILED \u{b7} {reason}",
        restoreWaiting = "VOICE RESTORE WAITING \u{b7} {reason}",
        restored = "VOICE PREFERENCES RESTORED",
        restoreGaveUp = "VOICE DEVICE NOT RESTORED \u{b7} SAVED SELECTION RETAINED",
    },

    keybind = {
        press = "PRESS KEY / MOUSE BUTTON",
        resetTitle = "Reset to default ({key})",
        resetLabel = "Reset {name} to default",
    },
}
