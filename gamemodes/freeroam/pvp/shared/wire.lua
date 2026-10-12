-- Lossless dictionary encoding: send scoreboard field names once, rather than
-- once per player. Short string keys preserve optional fields and false values.
DeathmatchWire = {}
function DeathmatchWire.packRows(rows)
    if type(rows) ~= "table" or #rows <= 24 then return rows end
    local columns, indices, records = {}, {}, {}
    for i, row in ipairs(rows) do
        local record = {}
        for key, value in pairs(row) do
            if not indices[key] then
                columns[#columns + 1] = key
                indices[key] = tostring(#columns)
            end
            record[indices[key]] = value
        end
        records[i] = record
    end
    return { columns = columns, records = records }
end

function DeathmatchWire.unpackRows(packed)
    if type(packed) ~= "table" or not packed.columns or not packed.records then return packed end
    local rows = {}
    for i, record in ipairs(packed.records) do
        local row = {}
        for index, value in pairs(record) do
            local key = packed.columns[tonumber(index)]
            if key then row[key] = value end
        end
        rows[i] = row
    end
    return rows
end

-- Net-event strings have a 16 KiB limit. Split only at UTF-8 boundaries;
-- the receiver concatenates before JSON decoding (names may contain Unicode).
function DeathmatchWire.fragments(value)
    local parts, first = {}, 1
    while first <= #value do
        local last = math.min(first + 8191, #value)
        while last < #value do
            local nextByte = value:byte(last + 1)
            if nextByte < 128 or nextByte >= 192 then break end
            last = last - 1
        end
        parts[#parts + 1] = value:sub(first, last)
        first = last + 1
    end
    return { stateFragments = parts }
end
