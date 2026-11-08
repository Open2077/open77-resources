-- One declaration runs on the authoritative server and every client.
local ok, reason = Open77.clothing.register({
    ["Items.Open77_Demo_Coat_Male"] = {slot="OuterChest", body="male", label="Custom coat · male"},
    ["Items.Open77_Demo_Coat_Female"] = {slot="OuterChest", body="female", label="Custom coat · female"},
})
assert(ok, reason)
