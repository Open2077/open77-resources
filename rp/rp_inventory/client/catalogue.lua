-- rp_inventory / client: the item catalogue (world-interaction row B1).
--
-- The server announces the catalogue's head (schema, version, hash, page count) on join and
-- after definitions change; this client fetches the pages one at a time, verifies the FNV-1a 64
-- hash over the reassembled list (shared/schema.lua) and only then swaps its copy. Pages are
-- small (<= 64 entries, <= 24 KiB) and rate-limited by the server; nothing rides a state bag.
-- The panel does not depend on it (the server pushes labels with every state): it is the
-- catalogue a client-side feature reads for labels, weights, categories and prop/hand mappings.

local catalogue = { version = -1, hash = nil, items = {} }
local download = nil   -- { head, pages = {}, next, timer }

local function requestNext()
    if not download then return end
    local index = download.next
    if index > download.head.pages then
        local items, reason = RpItemSchema.assemble(download.head, download.pages)
        if items then
            catalogue = { version = download.head.version, hash = download.head.hash, items = items }
            TriggerEvent("rp_inventory:catalogueReady", catalogue.version)
        else
            print("[rp_inventory] catalogue v" .. tostring(download.head.version) .. " rejected: " .. tostring(reason))
        end
        download = nil
        return
    end
    TriggerServerEvent("rp_inventory:catalogueRequest", download.head.version, index)
    local expected = download
    SetTimeout(5000, function()
        -- No answer (dropped, or the server's quota): ask once more for the same page.
        if download == expected and download.next == index then
            TriggerServerEvent("rp_inventory:catalogueRequest", download.head.version, index)
        end
    end)
end

RegisterNetEvent("rp_inventory:catalogue", function(head)
    if type(head) ~= "table" or head.schema ~= RpItemSchema.VERSION then return end
    if head.version == catalogue.version and head.hash == catalogue.hash then return end
    if download and download.head.version == head.version and download.head.hash == head.hash then return end
    if type(head.pages) ~= "number" or head.pages < 0 or head.pages > RpItemSchema.LIMITS.maxPages then return end
    download = { head = head, pages = {}, next = 1 }
    requestNext()
end)

RegisterNetEvent("rp_inventory:cataloguePage", function(page)
    if not download or type(page) ~= "table" then return end
    if page.v ~= download.head.version or page.i ~= download.next then return end
    download.pages[page.i] = page
    download.next = download.next + 1
    requestNext()
end)

-- Client exports: the verified copy only (nil before the first complete download).
exports("catalogueItem", function(itemId)
    return catalogue.items[itemId]
end)

exports("catalogueVersion", function()
    return catalogue.version, catalogue.hash
end)

-- B7: the panel script (client/main.lua) reads the verified copy through this global, to show
-- "durability 12/20" and quality scales next to what the server pushes. nil before the first
-- complete download; the panel then shows the raw values.
RpInvClientCatalogue = {
    item = function(itemId) return catalogue.items[itemId] end,
    version = function() return catalogue.version, catalogue.hash end,
}
