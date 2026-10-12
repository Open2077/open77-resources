-- tests/compat/json.lua: a small strict JSON decoder for the offline suites (Open77's
-- `json` / Open77.io.readJson are platform natives the fake host does not have).
-- CompatJson.decode(text) -> value | nil, error. Objects -> tables, arrays -> 1-based tables,
-- null -> CompatJson.null (a sentinel, so arrays keep their length).

CompatJson = { null = setmetatable({}, { __tostring = function() return "null" end }) }

local function decode(text)
    local pos = 1
    local function fail(msg) error(("json: %s at byte %d"):format(msg, pos), 0) end
    local function ws()
        pos = text:find("[^ \t\r\n]", pos) or (#text + 1)
    end
    local value
    local function str()
        pos = pos + 1
        local out = {}
        while true do
            local c = text:sub(pos, pos)
            if c == "" then fail("unterminated string") end
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local e = text:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[e] then
                    out[#out + 1] = map[e]
                    pos = pos + 2
                elseif e == "u" then
                    local hex = text:sub(pos + 2, pos + 5)
                    if not hex:match("^%x%x%x%x$") then fail("bad \\u escape") end
                    out[#out + 1] = utf8.char(tonumber(hex, 16))
                    pos = pos + 6
                else
                    fail("bad escape")
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = text:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            ws()
            if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while true do
                ws()
                if text:sub(pos, pos) ~= '"' then fail("expected a key") end
                local k = str()
                ws()
                if text:sub(pos, pos) ~= ":" then fail("expected ':'") end
                pos = pos + 1
                obj[k] = value()
                ws()
                local d = text:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then fail("expected ',' or '}'") end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            ws()
            if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while true do
                arr[#arr + 1] = value()
                ws()
                local d = text:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then fail("expected ',' or ']'") end
            end
        elseif c == '"' then
            return str()
        elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4 return CompatJson.null
        else
            local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" then fail("unexpected character " .. c) end
            pos = pos + #num
            return math.tointeger(tonumber(num)) or tonumber(num)
        end
    end
    local result = value()
    ws()
    if pos <= #text then fail("trailing data") end
    return result
end

function CompatJson.decode(text)
    local ok, result = pcall(decode, text)
    if ok then return result end
    return nil, result
end
