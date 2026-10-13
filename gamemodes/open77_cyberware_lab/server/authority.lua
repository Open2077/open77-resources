-- Who may act on whom. Self-service stays open: a player may run every lab
-- action on themselves. An action on another player, or on the whole server
-- (friendly fire, a load batch), needs the server console (source 0) or the
-- ACL right `command.cyberlab.others` (granted in acl.jsonc; an `admin` role
-- holding `command.*` covers it). Every entry point applies it: the /cyberlab
-- command, its dash/slam/reflex subcommands and the panel's net events, so a
-- client cannot bypass the rule by sending an event itself.
CyberwareLabAuthority = {
    RIGHT = "command.cyberlab.others",
    REASON = "operator_required",
}

local function playerId(value)
    local id = tonumber(value)
    return id and id >= 1 and id <= 9007199254740991 and id % 1 == 0 and id or nil
end

-- The console, or a player holding the right. Fails closed: no ACL service,
-- an ACL error or any other answer than true is a refusal.
function CyberwareLabAuthority.isOperator(issuer)
    if tonumber(issuer) == 0 then return true end
    local id = playerId(issuer)
    if not id or type(Open77) ~= "table" or type(Open77.acl) ~= "table" or not Open77.acl.isAllowed then
        return false
    end
    local ok, allowed = pcall(Open77.acl.isAllowed, id, CyberwareLabAuthority.RIGHT)
    return ok and allowed == true
end

-- nil when `issuer` may act on `target`, else the refusal reason. A nil
-- `target` is a server-wide action: only an operator runs it.
function CyberwareLabAuthority.refuse(issuer, target)
    local self = playerId(issuer)
    if self and target ~= nil and tonumber(target) == self then return nil end
    if CyberwareLabAuthority.isOperator(issuer) then return nil end
    return CyberwareLabAuthority.REASON
end

-- The reply text for a refusal: the reason first, then what would allow it.
function CyberwareLabAuthority.message(reason)
    if reason ~= CyberwareLabAuthority.REASON then return reason end
    return reason .. ": acting on another player needs the server console or the "
        .. CyberwareLabAuthority.RIGHT .. " right"
end
