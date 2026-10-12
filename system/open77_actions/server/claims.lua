-- =============================================================================
-- open77_actions -- server/claims.lua
-- =============================================================================
-- The claims service for shared targets: a salvage node, a crate on the
-- ground, a truck slot, later a seat (B6).
--
--   * bucket-scoped -- the same key in two routing buckets is two claims;
--   * one winner    -- `acquire` on a held, unexpired key refuses with the
--                      holder, never queues and never steals;
--   * expiring      -- every claim carries a deadline, so a holder that forgets
--                      cannot pin a node forever; the sweep reports what lapsed;
--   * released on every terminal path -- the engine releases by token, by
--                      holder (an operation) and by owner (a resource), and
--                      the tests assert nothing outlives its operation.
--
-- Pure: time comes from the injected `now()`, so the offline suite drives it.
-- Global: Open77ActionsClaims.
-- =============================================================================

local Claims = {}
Claims.__index = Claims
Open77ActionsClaims = Claims

local MAX_CLAIMS = 8192

function Claims.new(options)
    options = options or {}
    return setmetatable({
        now = options.now or function() return 0 end,
        byKey = {},       -- ["<bucket>|<key>"] = entry
        byToken = {},     -- [token] = entry
        counter = 0,
        size = 0,
    }, Claims)
end

local function slot(bucket, key) return tostring(bucket) .. "|" .. key end

function Claims:_drop(entry)
    if self.byToken[entry.token] ~= entry then return false end
    self.byToken[entry.token] = nil
    if self.byKey[entry.slot] == entry then self.byKey[entry.slot] = nil end
    self.size = self.size - 1
    return true
end

-- The live entry for a key, or nil. An expired entry is dropped on read, so a
-- lapsed claim can be re-acquired before the sweep runs.
function Claims:holder(bucket, key)
    local entry = self.byKey[slot(bucket, key)]
    if entry == nil then return nil end
    if entry.expiresAt <= self.now() then
        self:_drop(entry)
        return nil
    end
    return entry
end

--- acquire(bucket, key, holder, ttlMs, owner?, meta?) -> token | nil, "target_claimed", entry
function Claims:acquire(bucket, key, holder, ttlMs, owner, meta)
    if type(key) ~= "string" or #key == 0 or #key > 160 then return nil, "invalid_target" end
    if type(holder) ~= "string" or #holder == 0 then return nil, "invalid_target" end
    bucket = math.tointeger(tonumber(bucket)) or 0
    ttlMs = math.tointeger(tonumber(ttlMs)) or 30000
    if ttlMs < 1 then ttlMs = 1 end
    local current = self:holder(bucket, key)
    if current ~= nil then
        if current.holder == holder then
            -- Re-acquiring your own claim renews it; it never mints a second token.
            current.expiresAt = self.now() + ttlMs
            return current.token
        end
        return nil, "target_claimed", current
    end
    if self.size >= MAX_CLAIMS then return nil, "target_claimed" end
    self.counter = self.counter + 1
    local entry = {
        token = "c" .. self.counter,
        slot = slot(bucket, key),
        bucket = bucket, key = key, holder = holder, owner = owner,
        acquiredAt = self.now(), expiresAt = self.now() + ttlMs, meta = meta,
    }
    self.byKey[entry.slot] = entry
    self.byToken[entry.token] = entry
    self.size = self.size + 1
    return entry.token
end

function Claims:get(token)
    local entry = self.byToken[token]
    if entry == nil then return nil end
    if entry.expiresAt <= self.now() then
        self:_drop(entry)
        return nil
    end
    return entry
end

function Claims:renew(token, ttlMs)
    local entry = self:get(token)
    if entry == nil then return nil, "claim_lost" end
    entry.expiresAt = self.now() + (math.tointeger(tonumber(ttlMs)) or 30000)
    return true
end

function Claims:release(token)
    local entry = self.byToken[token]
    if entry == nil then return false end
    return self:_drop(entry)
end

function Claims:releaseHolder(holder)
    local count = 0
    for _, entry in pairs(self.byToken) do
        if entry.holder == holder then
            if self:_drop(entry) then count = count + 1 end
        end
    end
    return count
end

function Claims:releaseOwner(owner)
    local count = 0
    for _, entry in pairs(self.byToken) do
        if entry.owner == owner then
            if self:_drop(entry) then count = count + 1 end
        end
    end
    return count
end

--- Drops every lapsed claim and returns them, so the engine can cancel the
--- operation that lost its claim (`claim_lost`) instead of finding out later.
function Claims:sweep()
    local now, lapsed = self.now(), {}
    for _, entry in pairs(self.byToken) do
        if entry.expiresAt <= now then lapsed[#lapsed + 1] = entry end
    end
    for _, entry in ipairs(lapsed) do self:_drop(entry) end
    return lapsed
end

function Claims:count() return self.size end

function Claims:list(bucket)
    local out = {}
    local now = self.now()
    for _, entry in pairs(self.byToken) do
        if (bucket == nil or entry.bucket == bucket) and entry.expiresAt > now then
            out[#out + 1] = {
                token = entry.token, bucket = entry.bucket, key = entry.key,
                holder = entry.holder, owner = entry.owner,
                remainingMs = math.max(0, entry.expiresAt - now),
            }
        end
    end
    table.sort(out, function(l, r) return l.token < r.token end)
    return out
end

return Claims
