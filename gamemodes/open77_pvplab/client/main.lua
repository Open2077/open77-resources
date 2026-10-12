-- Phase 0 laboratory, client half.
--
-- It exists for one reason: the debug bridge and the server speak different
-- identifiers, and E9-E12 need both. The server owns the canonical NPC id; the
-- bridge commands that can actually see what the ENGINE thinks of a body --
-- `godmode state`, `world.attitude`, `world.ai` -- take an Open77 cyber id,
-- which only exists on a client. `Open77.npcs.entity(npcId)` is exactly that
-- id: `ClientResourceHost` copies `npc.entity.value` straight into the client
-- snapshot, and that value is the same registry the bridge resolves through
-- `EntityService::Lock`.
--
-- Everything here is read-only. `npcs.read` is an inspection permission; a
-- client cannot mutate a canonical NPC and must not try.
--
-- The answer travels as ONE STRING, deliberately. Event arguments are already
-- known to arrive on the far side as strings, and a nested array-of-tables is
-- a bet on a serialisation shape this lab has never measured. A laboratory
-- readout that fails for a reason unrelated to the experiment is worse than a
-- crude one, so the formatting happens here and the server only prints.

local function describeAll()
    local lines = {}
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        lines[#lines + 1] = ("npc=%s entity=%s streamed=%s hp=%s/%s ai=%s policy=%s"):format(
            tostring(npc.id),
            -- Reported even when nil or 0: "streamed in but no entity yet" and
            -- "not streamed at all" are different failures, and omitting the
            -- field would merge them into one silent blank.
            tostring(npc.entity), tostring(npc.streamed),
            tostring(npc.health), tostring(npc.maxHealth),
            tostring(npc.aiMode), tostring(npc.damagePolicy))
    end
    if #lines == 0 then return "none streamed" end
    return table.concat(lines, " | ")
end

RegisterNetEvent("pvplab:ids", function()
    TriggerServerEvent("pvplab:ids:result", describeAll())
end)

-- The stream-in trace. `pvplab.solo` removes and recreates a body, and the
-- cyber id changes with it; a stale id fed to `godmode state` reports on
-- whatever occupies that slot now, which is exactly the kind of mistake that
-- produces a confident wrong answer. This prints the new id as it appears.
AddEventHandler("onNpcReady", function(npcId, entity)
    print(("[pvplab] npc ready id=%s entity=%s -- use this entity id with the bridge")
        :format(tostring(npcId), tostring(entity)))
end)

AddEventHandler("onNpcStreamOut", function(npcId, reason)
    print(("[pvplab] npc stream out id=%s reason=%s (its cyber id is now stale)")
        :format(tostring(npcId), tostring(reason)))
end)

print("[pvplab] client ready -- pvplab.ids maps canonical npc ids to engine cyber ids")

-- ------------------------------------------------------------------ E13 ---
--
-- The engine hit tap. `client/src/network/CombatReplication.cpp` emits these
-- two events off the wrapped `ScriptedPuppet.OnHit`, and they are the whole of
-- the native damage path -- so counting them is how a laboratory session tells
-- "the client rebuild did not take" apart from "the report is sent and the
-- gamemode refuses it". `pvplab.enginewatch` reads the counters.
--
-- These are ADDITIONAL listeners, not a replacement: `open77_deathmatch` listens
-- to the same two events and forwards them to its own handlers. An engine event
-- fans out to every resource that registered for it, so the lab observing
-- costs the gamemode nothing and changes no damage.

AddEventHandler("open77:npcHit", function(npcId, damage, hitZ, weapon, attackKind)
    print(("[pvplab] engine hit OUT npc=%s damage=%s hitZ=%s weapon=%s kind=%s")
        :format(tostring(npcId), tostring(damage), tostring(hitZ),
            tostring(weapon), tostring(attackKind)))
    TriggerServerEvent("pvplab:enginehit", "outgoing", npcId, damage)
end)

AddEventHandler("open77:npcAttackedMe", function(npcId, damage, hitZ, weapon, attackKind)
    print(("[pvplab] engine hit IN  npc=%s damage=%s weapon=%s kind=%s")
        :format(tostring(npcId), tostring(damage), tostring(weapon), tostring(attackKind)))
    TriggerServerEvent("pvplab:enginehit", "incoming", npcId, damage)
end)

-- Who owns the simulation lease, from this client's point of view.
--
-- `locallyAuthoritative` is the client's own answer to "am I the authority",
-- computed from `authorityPlayerId == session.playerId`. With two clients
-- connected exactly one of them may say yes for a given body. Both will still
-- see it fighting, because the lease governs TASKS and not the AI -- and being
-- able to show that difference in one readout is the point of the command.
RegisterNetEvent("pvplab:owner", function()
    local lines = {}
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        lines[#lines + 1] = ("npc=%s owner=%s epoch=%s mine=%s streamed=%s"):format(
            tostring(npc.id), tostring(npc.authorityPlayerId),
            tostring(npc.authorityEpoch), tostring(npc.locallyAuthoritative),
            tostring(npc.streamed))
    end
    TriggerServerEvent("pvplab:owner:result",
        #lines > 0 and table.concat(lines, " | ") or "none streamed")
end)
