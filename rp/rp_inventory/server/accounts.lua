-- rp_inventory / server/accounts.lua: durable account ids for the transactions backend (row B2).
--
-- Pure Lua, no native. Global table: RpInvAccounts. Every container rp_inventory hands to
-- open77_transactions is named here, and only from a DURABLE key:
--
--   char:<subject>        pockets; subject = open77_transactions:subjectOf(playerId): the account
--                         identifier by default (the default character id, A13 3.1.1 / 12.8),
--                         `<accountId>~<n>` for a later character of an override provider;
--                         never the session player id
--   stash:<stashId>       stashes (housing `home:<homeId>`, any caller string of the legacy shape)
--   veh:<PLATE>:<part>    vehicle parts (trunk, cargo, glovebox...); the plate is the durable key,
--                         the runtime vehicle id never is
--   world:<id>            world containers (ground piles, crates); minted, never a prop/drop id
--
-- A key that looks like a session id or a runtime entity id is refused (B8 R3), with the same
-- rule as the coordinator's durable-key lint plus the stash prefixes B8 found in the pack.

RpInvAccounts = {}
local A = RpInvAccounts

local ACCOUNT = "^[A-Za-z0-9_.:@~%-]+$"   -- the coordinator's account charset (model.lua)
local RUNTIME_PREFIXES = {
    trunk = true, vehicle = true, veh = true, glovebox = true, prop = true, entity = true,
    player = true, ped = true, npc = true, drop = true, loot = true,
}

local function check(id)
    if #id > 96 or not id:match(ACCOUNT) then return nil, "invalid_account" end
    return id
end

-- Shared lint: a first key segment that starts with "session" or is all digits.
function A.problem(id)
    if type(id) ~= "string" then return "invalid_account" end
    local ns, key = id:match("^([a-z]+):([^:]+)")
    if not ns then return "invalid_account" end
    if ns == "sys" then return nil end
    if key:match("^session") then return "session_key" end
    if key:match("^%d+$") then return "runtime_id_key" end
    return nil
end

function A.kindOf(id)
    local ns = type(id) == "string" and id:match("^([a-z]+):") or nil
    if ns == "char" or ns == "stash" or ns == "veh" or ns == "world" or ns == "sys"
        or ns == "cash" or ns == "bank" or ns == "soc" then
        return ns
    end
    return nil
end

-- char:<subject>. The subject comes from the coordinator's subject provider (subjectOf), whose
-- keys are [A-Za-z0-9_.@~-], at most 80 bytes.
function A.char(subject)
    if type(subject) ~= "string" or subject == "" then return nil, "no_identifier" end
    if not subject:match("^[A-Za-z0-9_.@~%-]+$") or #subject > 90 then return nil, "invalid_identifier" end
    local id, why = check("char:" .. subject)
    if not id then return nil, why end
    local p = A.problem(id)
    if p then return nil, p end
    return id
end

-- stash:<stashId>. The legacy id rule (^[%w_%-:%.]+$, <= 64) plus the durable-key lint: no
-- session id, no all-digit id, no `trunk:<runtimeId>`-style key (use veh:<plate>:<part>).
function A.stash(stashId)
    if type(stashId) ~= "string" or #stashId == 0 or #stashId > 64 or not stashId:match("^[%w_%-:%.]+$") then
        return nil, "invalid_stash"
    end
    if stashId:match("^session") then return nil, "session_key" end
    if stashId:match("^%d+$") then return nil, "runtime_id_key" end
    local prefix, rest = stashId:match("^([%a]+)[:#](.+)$")
    if prefix and RUNTIME_PREFIXES[prefix:lower()] and rest:match("^%d+$") then return nil, "runtime_id_key" end
    local id, why = check("stash:" .. stashId)
    if not id then return nil, why end
    return id
end

-- Normalised plate (upper case) | nil, reason. Plates are the durable vehicle key (rp_garage).
function A.plate(plate)
    if type(plate) ~= "string" then return nil, "invalid_plate" end
    plate = plate:upper()
    if not plate:match("^[A-Z0-9][A-Z0-9%-]+$") or #plate < 2 or #plate > 16 then return nil, "invalid_plate" end
    if plate:match("^%d+$") then return nil, "runtime_id_key" end
    return plate
end

function A.vehicle(plate, part)
    local p, why = A.plate(plate)
    if not p then return nil, why end
    if type(part) ~= "string" or not part:match("^[%l][%l%d_]*$") or #part > 16 then return nil, "invalid_part" end
    return check("veh:" .. p .. ":" .. part)
end

-- world:<id>. Minted by the coordinator (openWorld: `<serverTag>.<boot>.<n>`, the tag starts with
-- a letter, so the id is never all digits); never a runtime prop or loot id.
function A.world(id)
    if type(id) ~= "string" or not id:match("^[%a][%w_.%-]+$") or #id < 8 or #id > 64 then
        return nil, "invalid_world_id"
    end
    if id:match("^session") then return nil, "session_key" end
    return check("world:" .. id)
end

-- `sys:<name>`: unlimited sources and sinks, journaled (minting, burning, buyers, migration).
function A.sys(name)
    if type(name) ~= "string" or not name:match("^[%w_.%-]+$") or #name > 64 then return nil, "invalid_account" end
    return "sys:" .. name
end

-- Parses any account id this backend accepts. Returns the id or nil, reason.
function A.parse(id)
    local kind = A.kindOf(id)
    if not kind then return nil, "invalid_account" end
    if kind == "sys" then
        local name = id:sub(5)
        return A.sys(name)
    end
    local ok, why = check(id)
    if not ok then return nil, why end
    local p = A.problem(id)
    if p then return nil, p end
    return id
end

return A
