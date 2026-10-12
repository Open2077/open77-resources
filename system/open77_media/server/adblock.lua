-- =============================================================================
-- open77_media -- server/adblock.lua
-- =============================================================================
-- The operator's ad-blocklist policy: one grammar, one store, and the payload
-- the server pushes to its clients.
--
-- -----------------------------------------------------------------------------
-- WHY THIS EXISTS AT ALL
-- -----------------------------------------------------------------------------
-- The television's blocklist is compiled into the client -- see
-- `webui/include/op77/WebUI/AdBlock.hpp`, which is where the reasoning for the
-- whole feature lives. A compiled list has a ceiling, and the ceiling is time:
-- a popup network registers a domain on Tuesday, the person running the server
-- sees it in the log on Tuesday evening, and waiting for a build, a signed
-- integrity catalog and every client updating is how a television shows
-- advertising for a fortnight.
--
-- So the list has a second layer, this one, owned by the server: an operator
-- adds a host, and the clients in the session start refusing it within a second.
--
-- -----------------------------------------------------------------------------
-- THE THREE THINGS THIS FILE DECIDES
-- -----------------------------------------------------------------------------
--
--   1. WHAT A RULE IS. `checkHost` and `checkToken` are the grammar, and the
--      refusals are the interesting half: a rule of `com` would stop every page
--      loading and a rule of `co.uk` would blank a country, so both are refused
--      by name rather than stored and discovered later. This is the operator's
--      side of the contract -- it exists so a typo is answered at the console,
--      while the operator is still looking at it.
--
--   2. WHAT IS STORED. One list, with one owner at a time: the live list is
--      `data/adblock.json` once anything has been changed, and the keys in
--      `server/config.lua` until then. See `server/config.lua` for why that is a
--      seed rather than a second layer.
--
--   3. WHAT IS SENT. `policy` is the payload, and it carries the rules only --
--      no paths, no file names, no server state. A client needs the rules and
--      nothing else, and the smaller that surface is the fewer things a client
--      has to defend against.
--
-- -----------------------------------------------------------------------------
-- WHY THE GRAMMAR IS WRITTEN TWICE (AND WHY THAT IS NOT A BUG)
-- -----------------------------------------------------------------------------
-- The client's browser host validates every incoming rule again, in
-- `WebUI::Ads::NormaliseRule`, against the same grammar. That is not an
-- oversight to be tidied away later: a client CANNOT trust a list that arrives
-- over a network, so the validating half has to live where the matching does,
-- and the matching has to live in the host because that is the process that sees
-- the requests. This file exists on top of that for a different reason -- to
-- answer the operator immediately, in the language of the console they are
-- typing into -- and the receipt (see `server/main.lua`) is what catches the
-- case where the two disagree: a rule this file accepted and the host refused
-- comes back named, with the host's reason, and the operator hears about it
-- instead of watching advertisements and wondering.
-- =============================================================================

MediaAdBlock = MediaAdBlock or {}

MediaAdBlock.DEFAULT_CONFIG = {
    -- The layer as a whole. Off means the seed below is not read and nothing is
    -- pushed; the compiled list still protects every client, because that half
    -- is not this server's to turn off.
    enabled = true,
    -- Relative to the resource's own `data/` directory. JSON, because the rest
    -- of the server writes its operator-editable state the same way
    -- (`Open77.io.readJson` / `writeJson`) and a second format would be one more
    -- thing to get wrong.
    dataFile = "adblock.json",
    -- The seed: rules that apply on a server that has never been told otherwise.
    hosts = {},
    tokens = {},
}

-- Wire bounds. Deliberately smaller than the message encoding's own limit
-- (512 each): a list this size is already far past hand-maintained, and a
-- server that can push a thousand rules to every client at once is a server that
-- can make joining expensive.
MediaAdBlock.MAX_HOSTS = 256
MediaAdBlock.MAX_TOKENS = 256

-- ---------------------------------------------------------------------------
-- THE GRAMMAR
-- ---------------------------------------------------------------------------
-- Multi-label suffixes that are a registry rather than a company. Refusing these
-- is what stops an operator meaning `ads.example.co.uk` from writing `co.uk`.
--
-- This is the well-known half of the client's list, and it is deliberately
-- spelled out here rather than derived: these are the entries whose absence
-- would cost somebody a country. The host has the longer list, and a rule that
-- only the host refuses comes back on the receipt.
MediaAdBlock.REGISTRY_SUFFIXES = {
    ["co.uk"] = true, ["org.uk"] = true, ["ac.uk"] = true, ["gov.uk"] = true,
    ["com.au"] = true, ["net.au"] = true, ["org.au"] = true, ["gov.au"] = true,
    ["co.nz"] = true, ["com.br"] = true, ["com.cn"] = true, ["com.hk"] = true,
    ["co.jp"] = true, ["or.jp"] = true, ["ne.jp"] = true,
    ["co.kr"] = true, ["co.in"] = true, ["com.mx"] = true, ["com.ar"] = true,
    ["co.za"] = true, ["com.tr"] = true, ["com.tw"] = true, ["com.sg"] = true,
    ["co.id"] = true, ["co.il"] = true, ["com.pl"] = true, ["com.ua"] = true,
    ["com.es"] = true, ["com.pt"] = true, ["com.it"] = true,
}

-- Labels that are a registry rather than a business. A HOST rule cannot be one of
-- these (it needs two labels); a TOKEN rule matches anywhere in a host, so a
-- token of `com` would refuse every `.com` on the internet.
MediaAdBlock.REGISTRY_LABELS = {
    com = true, net = true, org = true, gov = true, edu = true, mil = true,
    int = true, www = true, http = true, https = true,
    -- Bracket-quoted because it is a Lua keyword: `local = true` is a syntax
    -- error, and this entry is exactly the kind that would be dropped by anyone
    -- "tidying" it into the same shape as its neighbours.
    ["local"] = true,
    internal = true, arpa = true, info = true, biz = true, name = true,
    mobi = true, online = true, site = true,
}

local function trim(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

---The hostname a rule names, or nil and the reason it is not one.
---
---Forgiving about the SHAPE a person pastes -- a whole URL, a leading `*.`, a
---trailing slash, a trailing dot, mixed case -- and strict about what is
---accepted, because the alternative is a blocking rule that silently does
---nothing.
---@return string|nil rule, string|nil reason
function MediaAdBlock.checkHost(raw)
    if type(raw) ~= "string" then return nil, "not_a_string" end
    local text = trim(raw)
    if text == "" then return nil, "empty" end
    if #text > 512 then return nil, "too_long" end

    -- A whole URL: keep the authority and throw the rest away.
    if text:find("://", 1, true) then
        local authority = text:match("^%a[%w+.-]*://([^/?#]*)")
        if authority == nil or authority == "" then return nil, "unreadable_url" end
        authority = authority:gsub("^[^@]*@", "")         -- userinfo
        authority = authority:match("^([^:]*)") or authority -- port
        text = authority
    else
        text = text:match("^[^/?#]*") or ""                -- a path stuck to a host
    end
    text = text:lower()
    while text:sub(1, 1) == "*" or text:sub(1, 1) == "." do text = text:sub(2) end
    while text:sub(-1) == "." do text = text:sub(1, -2) end
    if text == "" then return nil, "empty" end
    if #text > 253 then return nil, "too_long" end

    local labels = 0
    for label in text:gmatch("[^.]+") do
        labels = labels + 1
        if label == "" then return nil, "empty_label" end
        if label:sub(1, 1) == "-" or label:sub(-1) == "-" then return nil, "invalid_hyphen" end
    end
    -- `gmatch` skips empty fields, so `a..b` has to be caught by the count.
    local dots = select(2, text:gsub("%.", ""))
    if dots ~= labels - 1 then return nil, "empty_label" end
    if not text:match("^[a-z0-9][a-z0-9.-]*[a-z0-9]$") then return nil, "invalid_character" end
    if labels < 2 then return nil, "needs_a_domain" end
    if MediaAdBlock.REGISTRY_SUFFIXES[text] then return nil, "registry_suffix" end

    return text
end

---A token that is matched anywhere inside a host, or nil and the reason.
---@return string|nil token, string|nil reason
function MediaAdBlock.checkToken(raw)
    if type(raw) ~= "string" then return nil, "not_a_string" end
    local text = trim(raw):lower()
    if text == "" then return nil, "empty" end
    -- Before the length rule, so `com` is refused for the reason that matters
    -- rather than for being three characters long.
    if MediaAdBlock.REGISTRY_LABELS[text] then return nil, "registry_label" end
    if #text < 4 then return nil, "token_too_short" end
    if #text > 63 then return nil, "token_too_long" end
    if text:find(".", 1, true) then return nil, "token_is_a_host" end
    if not text:match("^[a-z0-9][a-z0-9-]*[a-z0-9]$") then return nil, "invalid_character" end
    return text
end

---Adds one rule of either kind to a working list, in place.
---@param kind string "host" or "token"
---@return string|nil rule, string|nil reason
function MediaAdBlock.add(hosts, tokens, raw, kind)
    if kind == "token" then
        local token, reason = MediaAdBlock.checkToken(raw)
        if token == nil then return nil, reason end
        for _, existing in ipairs(tokens) do
            if existing == token then return token end
        end
        if #tokens >= MediaAdBlock.MAX_TOKENS then return nil, "too_many_tokens" end
        tokens[#tokens + 1] = token
        return token
    end
    local rule, reason = MediaAdBlock.checkHost(raw)
    if rule == nil then return nil, reason end
    for _, existing in ipairs(hosts) do
        if existing == rule then return rule end
    end
    if #hosts >= MediaAdBlock.MAX_HOSTS then return nil, "too_many_hosts" end
    hosts[#hosts + 1] = rule
    return rule
end

---Removes a rule of either kind, naming it the way `add` accepted it.
---@return boolean removed
function MediaAdBlock.remove(hosts, tokens, raw)
    local rule = MediaAdBlock.checkHost(raw) or MediaAdBlock.checkToken(raw) or trim(raw):lower()
    local removed = false
    for index = #hosts, 1, -1 do
        if hosts[index] == rule then table.remove(hosts, index); removed = true end
    end
    for index = #tokens, 1, -1 do
        if tokens[index] == rule then table.remove(tokens, index); removed = true end
    end
    return removed
end

-- ---------------------------------------------------------------------------
-- THE PAYLOAD
-- ---------------------------------------------------------------------------
---The table a client receives: the rules, a revision to report back against,
---and where they came from.
---
---Every entry is re-validated on the way out, not because the list is expected
---to be dirty but because this is the last point at which the server can refuse
---to send something an operator never meant to type. A rule refused here is
---reported in `refused` rather than dropped in silence.
function MediaAdBlock.policy(hosts, tokens, revision, source)
    local out = { hosts = {}, tokens = {}, refused = {} }
    out.revision = math.max(0, math.floor(tonumber(revision) or 0))
    out.source = tostring(source or ""):sub(1, 200)

    for _, raw in ipairs(hosts or {}) do
        local rule, reason = MediaAdBlock.checkHost(raw)
        if rule ~= nil then out.hosts[#out.hosts + 1] = rule
        elseif #out.refused < 32 then out.refused[#out.refused + 1] = tostring(raw) .. ":" .. reason end
    end
    for _, raw in ipairs(tokens or {}) do
        local token, reason = MediaAdBlock.checkToken(raw)
        if token ~= nil then out.tokens[#out.tokens + 1] = token
        elseif #out.refused < 32 then out.refused[#out.refused + 1] = tostring(raw) .. ":" .. reason end
    end
    return out
end

---`37 hosts + 4 tokens` -- for the console and the banner.
function MediaAdBlock.describe(hosts, tokens)
    return string.format("%d host(s) + %d token(s)", #(hosts or {}), #(tokens or {}))
end

-- ---------------------------------------------------------------------------
-- THE STORE
-- ---------------------------------------------------------------------------
---The JSON to persist: the rules, the revision, and nothing else.
function MediaAdBlock.store(hosts, tokens, revision)
    return {
        schemaVersion = 1,
        revision = math.max(0, math.floor(tonumber(revision) or 0)),
        hosts = hosts or {},
        tokens = tokens or {},
    }
end

---Reads a persisted store back. Tolerant of anything: a hand-edited file is a
---normal thing to find, and the alternative -- refusing to load and taking the
---television feature down with it -- trades a wrong list for a broken server.
---@return table hosts, table tokens, number revision
function MediaAdBlock.loadStore(value)
    local hosts, tokens, revision = {}, {}, 0
    if type(value) ~= "table" then return hosts, tokens, revision end
    if type(value.hosts) == "table" then
        for _, raw in ipairs(value.hosts) do
            local rule = MediaAdBlock.checkHost(raw)
            if rule ~= nil and #hosts < MediaAdBlock.MAX_HOSTS then hosts[#hosts + 1] = rule end
        end
    end
    if type(value.tokens) == "table" then
        for _, raw in ipairs(value.tokens) do
            local token = MediaAdBlock.checkToken(raw)
            if token ~= nil and #tokens < MediaAdBlock.MAX_TOKENS then tokens[#tokens + 1] = token end
        end
    end
    revision = math.max(0, math.floor(tonumber(value.revision) or 0))
    return hosts, tokens, revision
end

-- ---------------------------------------------------------------------------
-- CONFIG
-- ---------------------------------------------------------------------------
---Validates `server/config.lua`, reporting each problem and replacing the bad
---value with its default. A typo degrades one field rather than the feature.
---@return table config, table problems
function MediaAdBlock.buildConfig(raw)
    local config = {}
    for key, value in pairs(MediaAdBlock.DEFAULT_CONFIG) do config[key] = value end
    for key, value in pairs(raw or {}) do config[key] = value end
    local problems = {}

    if type(config.enabled) ~= "boolean" then
        problems[#problems + 1] = "enabled must be a boolean"
        config.enabled = MediaAdBlock.DEFAULT_CONFIG.enabled
    end

    if type(config.dataFile) ~= "string" or config.dataFile == "" then
        problems[#problems + 1] = "dataFile must be a file name"
        config.dataFile = MediaAdBlock.DEFAULT_CONFIG.dataFile
    elseif config.dataFile:find("[/\\]") or config.dataFile:find("..", 1, true) then
        -- The store is confined to the resource's `data/` directory by the host,
        -- and a path here would only ever be a mistake being reported later.
        problems[#problems + 1] = "dataFile must be a plain file name"
        config.dataFile = MediaAdBlock.DEFAULT_CONFIG.dataFile
    end

    for _, key in ipairs({ "hosts", "tokens" }) do
        if type(config[key]) ~= "table" then
            problems[#problems + 1] = key .. " must be a table of strings"
            config[key] = {}
        end
    end

    -- The seed is validated exactly like an operator's rule, so a server that
    -- ships a typo hears about it at boot rather than when a client reports it.
    local kept = {}
    for _, candidate in ipairs(config.hosts) do
        local rule, reason = MediaAdBlock.checkHost(candidate)
        if rule == nil then
            problems[#problems + 1] = string.format("host %q: %s", tostring(candidate), tostring(reason))
        elseif #kept < MediaAdBlock.MAX_HOSTS then
            kept[#kept + 1] = rule
        end
    end
    config.hosts = kept

    kept = {}
    for _, candidate in ipairs(config.tokens) do
        local token, reason = MediaAdBlock.checkToken(candidate)
        if token == nil then
            problems[#problems + 1] = string.format("token %q: %s", tostring(candidate), tostring(reason))
        elseif #kept < MediaAdBlock.MAX_TOKENS then
            kept[#kept + 1] = token
        end
    end
    config.tokens = kept

    return config, problems
end

---The command line's grammar, so the console and any future UI cannot disagree.
---`media.adblock.add ads.example.com` and `media.adblock.add token newads`.
---@return table|nil spec, string|nil error
function MediaAdBlock.parseAddArgs(args)
    if args.n ~= 1 and args.n ~= 2 then return nil, "usage: media.adblock.add [token] <rule>" end
    if args.n == 2 then
        if tostring(args[1]):lower() ~= "token" then return nil, "unknown kind: " .. tostring(args[1]) end
        return { kind = "token", rule = args[2] }
    end
    return { kind = "host", rule = args[1] }
end

return MediaAdBlock
