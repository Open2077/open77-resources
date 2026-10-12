-- =============================================================================
-- open77_rp_basics -- client/main.lua
-- =============================================================================
-- The control block, and nothing else.
--
-- Input blocking is a client-only API by design: the server decides *that* a
-- player is cuffed and this half decides *what that takes away*. The body is
-- already held by the server freeze, which every observer agrees about; what
-- remains is the control stream on this one machine.
--
-- Three rules the platform already fixed and this file does not re-litigate:
--
--   * **Chat and voice keep working.** `Open77.input.blockAll` consumes the
--     gameplay action stream, and Open77 chat and voice run on focused browser
--     input rather than on that stream. A player who cannot act must still be
--     able to say so -- especially a player somebody else just cuffed.
--   * **The pause menu keeps working.** Menu shortcuts arrive on a different
--     controller. Settings, accessibility and disconnect stay reachable, which
--     is not negotiable for a state another player can put you in.
--   * **A claim is released when this resource stops**, by the host, on every
--     path including a crash. The explicit release below is the courteous case,
--     not the safety net.
--
-- The one thing this half must get right on its own is the re-sync: a client
-- resource reload drops the claim while the server still holds the player, so
-- on start it asks the server what is standing and re-applies it.
-- =============================================================================

local WIRE = "open77:rpbasics:apply"
local RESOURCE = GetCurrentResourceName()

-- What we are currently holding, so we release exactly that and nothing else.
local held = nil           -- nil | "cuff" | "escort" | "search"
local blocked = false

local function available()
    return Open77 ~= nil and Open77.input ~= nil
        and type(Open77.input.blockAll) == "function"
end

local function releaseBlocks()
    if not blocked then return end
    blocked = false
    -- Releasing something never claimed is not an error, so this is safe to run
    -- on every path unconditionally.
    Open77.input.blockAll(false)
    Open77.input.setActionBlocked("Map", false)
    Open77.input.setActionBlocked("Hub", false)
end

local function applyBlocks(mode)
    if not available() then return end

    -- `except = { "Movement" }` is the documented spelling for "everything but
    -- walking". Movement is polled by the locomotion state machine rather than
    -- dispatched as an action, so lifting the movement lever really does leave
    -- an escorted player able to walk while the rest of the stream is gone.
    local spec = nil
    if mode == "escort" then spec = { except = { "Movement" } } end

    local ok, reason = Open77.input.blockAll(spec)
    if not ok then
        Open77.log.error("rp_basics: blockAll refused (" .. tostring(reason) .. ")")
        return
    end
    blocked = true

    -- blockAll deliberately leaves vanilla menus reachable. A cuffed player
    -- reading his own map or opening his inventory is a different question from
    -- a cuffed player being able to quit, so these two are taken explicitly and
    -- the pause menu is not.
    Open77.input.setActionBlocked("Map", true)
    Open77.input.setActionBlocked("Hub", true)
end

local function apply(payload)
    if type(payload) ~= "table" then return end
    local mode = tostring(payload.mode or "free")

    if mode == "free" then
        releaseBlocks()
        if held ~= nil then
            TriggerEvent("open77_rp_basics:localReleased", held)
            held = nil
        end
        return
    end

    if mode ~= "cuff" and mode ~= "escort" and mode ~= "search" then return end

    -- Re-applying is how an escort replaces a cuff: drop what we hold, then
    -- take the new shape. Two claims of our own on the same stream would be one
    -- release short.
    releaseBlocks()
    applyBlocks(mode)
    held = mode
    TriggerEvent("open77_rp_basics:localHeld", mode, payload.officer, payload.expiresAt)
end

RegisterNetEvent(WIRE, apply)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    if not available() then
        Open77.log.error(
            "rp_basics: Open77.input.blockAll is absent on this client build -- a cuffed " ..
            "player would keep his controls. Rebuild the plugin.")
        return
    end
    -- The server still holds whoever was held when this VM went away.
    TriggerServerEvent("open77:rpbasics:sync")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    releaseBlocks()
    held = nil
end)
