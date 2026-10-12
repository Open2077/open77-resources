-- rp_economy / server/mint.lua: the money printing allowlist (A13 decision 6).
--
-- Every credit that comes from no wallet is a MINT from a `sys:` account named after the
-- resource that asked for it: `sys:<resource>:<label>` (legacy add -> label `legacy`, an NPC
-- buyer -> the label the caller gives). Every debit into `sys:` is a BURN. The journal therefore
-- says who printed and who destroyed money; this file decides whether a mint may happen.
--
-- Budget: per resource, the NET amount minted (mint minus burn) in a fixed window of
-- EconomyConfig.mint.windowSeconds may not exceed the resource's cap. Burns restore budget, so a
-- resource that moves money between players (remove A, add B) never reaches its cap; only money
-- creation does. Nothing mints by default: an unlisted resource gets `mint_denied`.
--
-- A budget taken for an operation that later fails (definitively not committed) is given back,
-- in the same window only.

Mint = { windows = {} }

local function now() return Open77.time.unix() end

local function bucketOf(t) return math.floor(t / EconomyConfig.mint.windowSeconds) end

local function window(key)
    local bucket = bucketOf(now())
    local w = Mint.windows[key]
    if not w or w.bucket ~= bucket then
        w = { bucket = bucket, net = 0 }
        Mint.windows[key] = w
    end
    return w
end

-- Cap of a mint source: a caller resource, or `rp_economy:<label>` for this resource's own.
function Mint.capOf(key)
    local own = key:match("^rp_economy:(.+)$")
    if own then return EconomyConfig.mint.internal[own] end
    return EconomyConfig.mint.callers[key]
end

-- The budget key of a sys account `sys:<resource>:<label>` minted by this facade.
function Mint.keyOf(resource, label)
    if resource == "rp_economy" then return "rp_economy:" .. label end
    return resource
end

-- Takes `amount` of the source's budget. Returns a token for release, or nil, reason.
function Mint.take(key, amount)
    local cap = Mint.capOf(key)
    if cap == nil or cap == false then return nil, "mint_denied" end
    local w = window(key)
    if w.net + amount > cap then return nil, "mint_cap" end
    w.net = w.net + amount
    return { key = key, amount = amount, bucket = w.bucket, sign = 1 }
end

-- A burn by `key` (never refused). Returns a token for release.
function Mint.burn(key, amount)
    local w = window(key)
    w.net = w.net - amount
    return { key = key, amount = amount, bucket = w.bucket, sign = -1 }
end

-- Undoes a token whose operation was definitively not committed.
function Mint.release(token)
    if not token then return end
    local w = Mint.windows[token.key]
    if w and w.bucket == token.bucket then
        w.net = w.net - token.sign * token.amount
    end
end

-- Net minted in the current window (diagnostics, /economy_status).
function Mint.net(key)
    local w = Mint.windows[key]
    if not w or w.bucket ~= bucketOf(now()) then return 0 end
    return w.net
end

-- A resource name as an account segment: [A-Za-z0-9_.-], at most 40 bytes.
function Mint.segment(name)
    local clean = tostring(name or "unknown"):gsub("[^A-Za-z0-9_.%-]", "_")
    return clean:sub(1, 40)
end
