local rows = {}
for i = 1, 128 do
    rows[i] = { id = i, name = 'Player "' .. i .. '" é', active = i % 2 == 0,
        bot = false, rank = i, kills = 0, damage = 123.5 }
    if i % 3 == 0 then rows[i].optional = "bot label" end
end
local packed = DeathmatchWire.packRows(rows)
assert(#packed.records == 128 and #packed.columns == 8)
local restored = DeathmatchWire.unpackRows(packed)
for i, row in ipairs(rows) do
    for key, value in pairs(row) do assert(restored[i][key] == value) end
    for key, value in pairs(restored[i]) do assert(row[key] == value) end
end
local small = { rows[1] }
assert(DeathmatchWire.packRows(small) == small)
assert(DeathmatchWire.unpackRows(small) == small)
local text = string.rep("é😀\"", 8000)
local parts = DeathmatchWire.fragments(text).stateFragments
assert(table.concat(parts) == text)
for _, part in ipairs(parts) do assert(#part <= 8192 and utf8.len(part)) end
