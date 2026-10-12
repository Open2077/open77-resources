-- Pure clock helpers shared by the authoritative server and its projection.
-- Keeping the arithmetic here makes the wire protocol easy to test/reuse.

Open77WeatherClock = {}

local DAY_SECONDS = 24 * 60 * 60

function Open77WeatherClock.normalize(seconds)
    seconds = tonumber(seconds) or 0
    return ((seconds % DAY_SECONDS) + DAY_SECONDS) % DAY_SECONDS
end

function Open77WeatherClock.fromHms(hour, minute, second)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second or 0)
    if hour == nil or minute == nil or second == nil or
       hour % 1 ~= 0 or minute % 1 ~= 0 or second % 1 ~= 0 or
       hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59 then
        return nil, "invalid_time"
    end
    return hour * 3600 + minute * 60 + second
end

function Open77WeatherClock.toHms(seconds)
    local whole = math.floor(Open77WeatherClock.normalize(seconds))
    local hour = math.floor(whole / 3600)
    local minute = math.floor((whole % 3600) / 60)
    return hour, minute, whole % 60
end

function Open77WeatherClock.at(baseSeconds, anchorMs, rate, frozen, nowMs)
    local elapsed = frozen and 0 or math.max(0, (nowMs - anchorMs) / 1000)
    return Open77WeatherClock.normalize(baseSeconds + elapsed * rate)
end

-- Forward distance on a 24-hour dial. Midnight therefore remains a normal
-- positive step instead of looking like a 23-hour rewind.
function Open77WeatherClock.forwardDelta(target, origin)
    return Open77WeatherClock.normalize(target - origin)
end

function Open77WeatherClock.parse(text)
    if type(text) ~= "string" then return nil, "invalid_time" end
    local hour, minute, second = string.match(text, "^(%d%d?):(%d%d):?(%d*)$")
    if hour == nil then return nil, "expected_HH:MM_or_HH:MM:SS" end
    return Open77WeatherClock.fromHms(hour, minute, second ~= "" and second or 0)
end
