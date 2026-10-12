-- Self-only admin model leases. All commands run through the restricted,
-- audited Admin registry; the presentation API enforces resource ownership.
local catalogue, ready, searches, leases = {}, false, {}, {}
local categories = {all=true}
local pageSize = 20
CreateThread(function()
    for line in Open77AdminModels.records:gmatch("[^\r\n]+") do
        local record, category, risk = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
        assert(record and category and risk, "Invalid generated model catalogue")
        catalogue[#catalogue+1] = {record=record, category=category, risk=risk}
        categories[category] = true
        if #catalogue % 64 == 0 then Wait(0) end
    end
    assert(#catalogue == Open77AdminModels.count, "Incomplete model catalogue")
    Open77AdminModels.records = nil
    ready = true
end)

local function feedback(player, ok, message)
    Admin.push(player, "morphState", {ok=ok, message=message})
end

Admin.register("admin.self.morph", {
    help="Morph yourself into a Character.* NPC. Optional appearance; humanoid rigs recommended.",
    params={{name="record"},{name="appearance",optional=true}}, requiresPlayer=true, mutation=true,
    handler=function(player, args, raw)
        if args.n < 1 or args.n > 2 then
            return Admin.output(player, raw, false, "Usage: /admin.self.morph Character.Record [appearance]")
        end
        local ok, revision = SetPlayerModel(player, args[1], {appearance=args[2] or "", resetOnDeath=true})
        local message = ok and ("Preparing " .. args[1] .. " — awaiting client readiness") or ("Morph refused: " .. tostring(revision))
        if ok then leases[player] = revision end
        feedback(player, ok, message)
        Admin.output(player, raw, ok, message)
        return ok, args[1] .. (ok and " requested" or (" " .. tostring(revision)))
    end,
})
Admin.register("admin.self.unmorph", {
    help="Restore your original player appearance (admin-owned morph only).",
    requiresPlayer=true, mutation=true,
    handler=function(player, args, raw)
        if args.n ~= 0 then return Admin.output(player, raw, false, "Usage: /admin.self.unmorph") end
        local ok, reason = ResetPlayerModel(player)
        if ok then leases[player] = nil end
        local message = ok and "Original character restored" or ("Unmorph refused: " .. tostring(reason))
        feedback(player, ok, message)
        Admin.output(player, raw, ok, message)
        return ok, message
    end,
})

Admin.register("admin.self.morph.search", {
    help="Browse the extracted Character catalogue: category, page, optional search text.",
    requiresPlayer=true, mutation=false,
    handler=function(player, args, raw)
        local category, page, query = args[1] or "all", args[2] == nil and 1 or tonumber(args[2]), args[3] or ""
        if args.n > 3 or (ready and not categories[category]) or not page or page ~= page or page < 1 or page > 10000
            or page % 1 ~= 0 or #query > 96 or query:find("[%c]") then
            return Admin.output(player, raw, false, "Invalid catalogue search")
        end
        local ticket = {} -- identity remains unique across disconnect/reconnect
        searches[player] = ticket
        local matches, terms = {}, {}
        for term in query:lower():gmatch("%S+") do terms[#terms+1] = term end
        if #terms > 8 then return Admin.output(player,raw,false,"Search accepts at most 8 words") end
        CreateThread(function()
            local function current()
                return searches[player] == ticket and Open77.players.name(player) ~= nil
                    and Admin.allowed(player, "admin.self.morph.search")
            end
            while not ready do if not current() then return end; Wait(0) end
            if not categories[category] then Admin.output(player,raw,false,"Invalid catalogue category"); return end
            for index, entry in ipairs(catalogue) do
                local match = category == "all" or category == entry.category
                if match then
                    local text = (entry.record .. " " .. entry.category .. " " .. entry.risk):lower()
                    for _, term in ipairs(terms) do if not text:find(term, 1, true) then match=false; break end end
                    if match then matches[#matches+1] = entry end
                end
                if index % 64 == 0 then if not current() then return end; Wait(0) end
            end
            if not current() then return end
            local pages = math.max(1, math.ceil(#matches/pageSize))
            local selected, rows = math.min(page, pages), {}
            for i=(selected-1)*pageSize+1, math.min(selected*pageSize,#matches) do rows[#rows+1]=matches[i] end
            Admin.push(player, "morphCatalogue", {category=category,query=query,requestedPage=page,
                page=selected,pages=pages,total=#matches,records=rows})
        end)
        return true, "catalogue search queued"
    end,
})

AddEventHandler("onPlayerModelReady", function(player, revision)
    if leases[player] == revision then feedback(player, true, "Morph active — /admin.self.unmorph to restore") end
end)
AddEventHandler("onPlayerModelFailed", function(player, revision, reason)
    if leases[player] == revision then feedback(player, false, "Morph failed: " .. tostring(reason)); leases[player]=nil end
end)
AddEventHandler("onPlayerDisconnected", function(player)
    player=tonumber(player); searches[player],leases[player]=nil,nil
end)
CreateThread(function()
    while true do
        for player, revision in pairs(leases) do
            local current = GetPlayerModel(player)
            if not current or current.revision ~= revision then leases[player]=nil
            elseif not Admin.allowed(player, "admin.self.morph") then
                local ok = ResetPlayerModel(player)
                if ok then leases[player]=nil; feedback(player, false, "Morph released: permission revoked") end
            end
        end
        Wait(1000)
    end
end)

