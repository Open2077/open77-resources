-- op77_map3d configuration. Everything under `page` is sent to the map page and
-- deep-merged over its defaults (ui/src/config.ts lists every key); the rest is
-- client behaviour. A server can also change the page at runtime:
--   exports.op77_map3d:setConfig({ theme = { accent = "#3FE0D0" } })   -- client
Map3DConfig = {
    -- The key that opens the city map (rebindable in the game's key settings).
    key = { id = "op77_map3d.open", name = "City map (3D)", key = "M" },
    -- Minimap zoom, held to zoom continuously (rebindable). The numpad names need a client
    -- that knows them (Unstable 167+); older ones get `fallback` instead.
    zoomKeys = {
        zoomIn = { id = "op77_map3d.zoomIn", name = "Minimap: zoom in", key = "NUMPADPLUS", fallback = "PAGEUP" },
        zoomOut = { id = "op77_map3d.zoomOut", name = "Minimap: zoom out", key = "NUMPADMINUS", fallback = "PAGEDOWN" },
    },

    -- Take over from the game's own map and minimap while this resource runs.
    replaceNativeMap = true,     -- the game's map key/menu is blocked (input.actions)
    pauseMenuMap = true,         -- the pause menu's CITY MAP opens this map (open77_pause providers)
    pauseMenuPriority = 100,     -- against other map providers: the highest wins
    hideNativeMinimap = true,    -- the vanilla HUD minimap is hidden (ui.vanilla.hud)

    -- The waypoint is shared with the game: setting one here also places the native
    -- waypoint (other resources reading Open77.blips.waypoint() see it), and a native
    -- waypoint placed by another resource becomes this map's destination.
    mirrorNativeWaypoint = true,

    -- Print open/close and waypoint changes (with their origin) to the client log.
    debug = false,

    -- How often the player's position reaches the page (Hz).
    playerRate = 30,

    -- WebUI surface frame rates (fixed when the surface is created; 60 at most). The
    -- minimap has its own small surface, the open map a full-screen one hidden while
    -- closed. page.minimap.fps / page.map.idleFps cap how often the page redraws.
    fps = { minimap = 60, map = 60, holo = 30 },

    -- Surface order: the minimap and the holo GPS under the gamemode's interfaces
    -- (LightRP's page is 720), the open map above them.
    zIndex = { minimap = 700, holo = 699, map = 781 },
    -- Hide the minimap and the holo GPS while another interface holds the cursor
    -- (inventory, F1 menu, phone...).
    hideUnderMenus = true,
    -- How long the open map's surface stays up after closing, for its closing animation
    -- (the page's own is 240 ms). 0 hides it at once.
    closeAnimationMs = 260,

    -- Other players near you shown as blips (category "player").
    nearbyPlayers = { enabled = true, radius = 350, interval = 1.0, color = "#3FE0D0" },

    -- Page settings (theme, minimap, full map, GPS, categories, texts).
    page = {
        theme = {
            accent = "#FFCC00",
            buildingEdge = "#FFCC00",
            roadEdge = "#FFCC00",
            terrainGrid = "#FFCC00",
        },
        minimap = {
            enabled = true,
            anchor = "top-right",
            size = 264,
            shape = "chamfer",   -- chamfer | circle | square
            tilt = 10,           -- degrees from straight down on foot
            vehicleTilt = 54,    -- in a vehicle (GTA-like)
            rotate = true,
        },
        map = {
            title = "NIGHT CITY",
            subtitle = "CITY MAP",
            initialPitch = 42,
            doubleClickWaypoint = true,
        },
        gps = {
            enabled = true,
            units = "metric",    -- metric | imperial
            avoidHighways = false,
        },
        categories = {
            { id = "player", label = "Players", icon = "user", color = "#3FE0D0" },
            { id = "service", label = "Services", icon = "store" },
            { id = "job", label = "Jobs", icon = "briefcase" },
            { id = "mission", label = "Missions", icon = "mission", color = "#FF2E3C" },
            { id = "vehicle", label = "Vehicles", icon = "car", color = "#7FB4D6" },
            { id = "housing", label = "Housing", icon = "home", color = "#8FE04A" },
            { id = "default", label = "Other", icon = "pin" },
        },
    },
}
