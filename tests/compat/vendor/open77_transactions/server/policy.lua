-- =============================================================================
-- open77_transactions -- server/policy.lua
-- =============================================================================
-- Who may write, and who may create value (contract section 12, decision 6).
--
-- Writers. A resource that calls a mutating export must be allowed to write
-- every non-`sys:` namespace its lines touch. `writers` is `*` (any running
-- resource) or a list: `rp_inventory, rp_economy:cash+bank+soc,
-- rp_cargo:veh/cargo`. A name without `:` may write every namespace; `ns/part`
-- grants one part of a namespace (`veh:<plate>:cargo`, not `...:trunk`).
--
-- Mints. A line out of a `sys:` account into a real account creates value.
-- Nothing mints by default. Each rule is
--
--     <resource> <sys:account | sys:*> <asset | * | money> <capPerHour>
--
-- separated by `;`. `asset` is an item id, `*` (any item, never money) or
-- `money`. Caps are charged per rule over a sliding hour (per-minute buckets),
-- counting both committed and in-flight mints, so two concurrent commits
-- cannot both fit under one cap. Burning (moving into `sys:`) is never
-- restricted here; the writers list covers it.
--
-- Global: Open77TxPolicy. Pure Lua; the offline suites load it.
-- =============================================================================

Open77TxPolicy = {}
local P = {}
P.__index = P

local HOUR_MS = 3600000
local MINUTE_MS = 60000

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- `*`, or "name[:ns+ns], name2" -> { all = true } | { [name] = true | { ns = true } }
function Open77TxPolicy.parseWriters(text)
    text = trim(tostring(text or ""))
    if text == "*" then return { all = true } end
    local out, problems = { all = false, names = {} }, {}
    for entry in text:gmatch("[^,%s]+") do
        local name, list = entry:match("^([%w_%-%.]+):([%w_/%+]+)$")
        if name then
            local set = {}
            for ns in list:gmatch("[^%+]+") do set[ns] = true end
            out.names[name] = set
        elseif entry:match("^[%w_%-%.]+$") then
            out.names[entry] = true
        else
            problems[#problems + 1] = entry
        end
    end
    return out, problems
end

-- One or more rule strings (the `mint1..mintN` tunables) -> rules, problems.
function Open77TxPolicy.parseRules(texts)
    local rules, problems = {}, {}
    for _, text in ipairs(texts or {}) do
        for entry in tostring(text or ""):gmatch("[^;]+") do
            entry = trim(entry)
            if entry ~= "" then
                local resource, account, asset, cap = entry:match("^([%w_%-%.]+)%s+(sys:[%w_%.@~%-%*]+)%s+([%w_%*]+)%s+(%d+)$")
                local capN = cap and math.tointeger(tonumber(cap))
                local validAsset = asset == "*" or asset == "money" or (asset and asset:match("^[a-z0-9_]+$"))
                if resource and capN and capN >= 0 and validAsset
                    and (account == "sys:*" or not account:find("*", 1, true)) then
                    rules[#rules + 1] = {
                        key = resource .. " " .. account .. " " .. asset,
                        resource = resource, account = account, asset = asset, cap = capN,
                    }
                else
                    problems[#problems + 1] = entry
                end
            end
        end
    end
    return rules, problems
end

function Open77TxPolicy.new(options)
    options = options or {}
    local self = setmetatable({
        writers = { all = true, names = {} },
        rules = {},
        used = {},      -- [ruleKey] = { [minute] = amount }
        inflight = {},  -- [ruleKey] = amount
        tickets = {}, nextTicket = 0,
    }, P)
    if options.writers ~= nil then self:setWriters(options.writers) end
    if options.rules ~= nil then self:setRules(options.rules) end
    return self
end

function P:setWriters(text)
    local writers, problems = Open77TxPolicy.parseWriters(text)
    self.writers = writers
    return problems
end

function P:setRules(texts)
    local rules, problems = Open77TxPolicy.parseRules(texts)
    self.rules = rules
    return problems
end

-- `account` (optional) narrows a namespace grant to one part:
-- `rp_cargo:veh/cargo` may write `veh:<plate>:cargo` and nothing else in veh.
function P:canWrite(resource, namespace, account)
    if self.writers.all then return true end
    local entry = self.writers.names[resource or ""]
    if entry == true then return true end
    if type(entry) ~= "table" then return false end
    if entry[namespace] then return true end
    local part = type(account) == "string" and account:match("^[a-z]+:[^:]+:([^:]+)") or nil
    return part ~= nil and entry[namespace .. "/" .. part] == true
end

local function matches(rule, resource, mint)
    if rule.resource ~= resource then return false end
    if rule.account ~= "sys:*" and rule.account ~= mint.from then return false end
    if mint.envelope then return rule.asset ~= "money" end
    if rule.asset == "money" then return mint.asset == "money" end
    if mint.asset == "money" then return false end
    return rule.asset == "*" or rule.asset == mint.asset
end

function P:_rule(resource, mint)
    for _, rule in ipairs(self.rules) do
        if matches(rule, resource, mint) then return rule end
    end
    return nil
end

function P:_usage(key, now)
    local buckets = self.used[key]
    if not buckets then return 0 end
    local floor = (now - HOUR_MS) // MINUTE_MS
    local sum = 0
    for minute, amount in pairs(buckets) do
        if minute <= floor then buckets[minute] = nil else sum = sum + amount end
    end
    return sum
end

-- Groups the mints of one operation by rule; nil, reason when one has no rule
-- or would exceed its cap.
function P:_charges(resource, mints, now)
    local charges = {}
    for _, mint in ipairs(mints) do
        local rule = self:_rule(resource, mint)
        if not rule then return nil, "mint_denied" end
        if not mint.envelope then charges[rule] = (charges[rule] or 0) + mint.amount end
    end
    for rule, amount in pairs(charges) do
        if self:_usage(rule.key, now) + (self.inflight[rule.key] or 0) + amount > rule.cap then
            return nil, "mint_cap_exceeded"
        end
    end
    return charges
end

-- Reserve-time pre-check: nothing is charged.
function P:check(resource, mints, now)
    if #mints == 0 then return true end
    local charges, why = self:_charges(resource, mints, now)
    if not charges then return nil, why end
    return true
end

-- Commit-time: charges the caps as in flight; returns a ticket (or false
-- when nothing was minted) to settle once the outcome is known.
function P:begin(resource, mints, now)
    if #mints == 0 then return false end
    local charges, why = self:_charges(resource, mints, now)
    if not charges then return nil, why end
    self.nextTicket = self.nextTicket + 1
    local ticket = {}
    for rule, amount in pairs(charges) do
        self.inflight[rule.key] = (self.inflight[rule.key] or 0) + amount
        ticket[#ticket + 1] = { key = rule.key, amount = amount }
    end
    self.tickets[self.nextTicket] = ticket
    return self.nextTicket
end

function P:settle(id, committed, now)
    local ticket = id and self.tickets[id]
    if not ticket then return end
    self.tickets[id] = nil
    for _, charge in ipairs(ticket) do
        self.inflight[charge.key] = math.max(0, (self.inflight[charge.key] or 0) - charge.amount)
        if committed then self:record(charge.key, charge.amount, now) end
    end
end

function P:record(key, amount, at)
    local buckets = self.used[key] or {}
    self.used[key] = buckets
    local minute = at // MINUTE_MS
    buckets[minute] = (buckets[minute] or 0) + amount
end

-- Seeds the window from the journal at boot (sql store mintHistory rows:
-- { resource, from, asset, amount, at }), so a restart does not reset caps.
function P:seed(rows)
    local n = 0
    for _, row in ipairs(rows or {}) do
        local mint = { from = row.from, asset = row.asset, amount = row.amount }
        local rule = self:_rule(row.resource, mint)
        if rule then
            self:record(rule.key, row.amount, row.at)
            n = n + 1
        end
    end
    return n
end

function P:snapshot(now)
    local out = {}
    for _, rule in ipairs(self.rules) do
        out[#out + 1] = {
            resource = rule.resource, account = rule.account, asset = rule.asset, cap = rule.cap,
            used = self:_usage(rule.key, now), inflight = self.inflight[rule.key] or 0,
        }
    end
    return out
end

return Open77TxPolicy
