-- B13. Applies the server's NCPD policy to this client's own PreventionSystem.
--
-- The server decides, the client applies, and that split is forced by the
-- engine: `PreventionSystem` holds ONE heat stage for the one player its game is
-- running, and every method that could change it is REDscript, reachable only
-- through the plugin's script-bridge queue. So there is nothing to arbitrate
-- here -- this resource is a hand, not a head.
--
-- What it is careful about is re-applying. The policy arrives on world entry, on
-- a bucket change, and whenever the server sets something; each of those may
-- repeat a value the client already holds, and the plugin's own state is reset
-- whenever a world goes away. Reapplying the last policy after a world entry is
-- therefore not redundant, it is the only thing that restores it.

local applied = nil -- the last policy this client was told to hold

local function apply(policy, reason)
    local level = tonumber(policy.level) or 0
    local maxLevel = tonumber(policy.maxLevel) or 5
    local enabled = policy.enabled ~= false

    -- Ceiling before level: raising the level first could be clamped by an old
    -- ceiling, and the client would sit one stage below what the server said.
    local ok, failure = Open77.prevention.setMaxWanted(maxLevel)
    if not ok then print("[open77_prevention] max wanted refused: " .. tostring(failure)) end

    ok, failure = Open77.prevention.setEnabled(enabled)
    if not ok then print("[open77_prevention] dispatch toggle refused: " .. tostring(failure)) end

    ok, failure = Open77.prevention.setWanted(level)
    if not ok then
        -- `population_suppressed` is the expected refusal in a suppressed world,
        -- not a fault: the spawn policy is holding the police block on, so a
        -- heat stage would change nothing visible. Say so once per change.
        print(("[open77_prevention] wanted %d refused (%s): %s")
            :format(level, tostring(reason), tostring(failure)))
    end
end

RegisterNetEvent("open77:prevention:policy", function(policy)
    if type(policy) ~= "table" then return end
    applied = policy
    apply(policy, "server")
end)

-- A world entry resets the plugin's request record, so whatever the server last
-- said has to be said again to the engine. Nothing is invented: if the server
-- has never spoken, this client keeps vanilla prevention.
AddEventHandler("open77:playerReset:complete", function()
    if applied ~= nil then apply(applied, "world_entry") end
end)

print("Open77 prevention client ready")
