-- rp_ripperdoc / server/model.lua: pure rules. No platform call lives here: catalogue lookups, the
-- procedures a patient may buy, the lines of a surgery / a restock / a buy-back, prices, ids, the
-- cyberware record helpers and the texts players read.
--
-- Global: RipperModel.

RipperModel = {}
local M = RipperModel

M.THEATRE = "sys:ripperdoc.theatre"     -- an installed implant is burned into it
M.SUPPLIER = "sys:ripperdoc.supplier"   -- restock boxes are minted from it, their price burned into it

-- Slots the cyberware guide names on this build, in display order.
M.SLOTS = { "arms", "legs", "operating_system", "self_ice", "purge" }

function M.playerId(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > 2147483647 then return nil end
    return math.tointeger(n)
end

function M.count(value, maximum)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > (maximum or 1) then return nil end
    return math.tointeger(n)
end

function M.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or not a.x or not b.x then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The stock stash of a clinic: a deterministic id, so a restart finds the same boxes again. The
-- part after the last colon lets an operator grant exactly it (`rp_ripperdoc:stash/stock`).
function M.stockAccount(clinicKey) return ("stash:rd.%s:stock"):format(clinicKey) end

function M.validKey(key)
    return type(key) == "string" and #key >= 1 and #key <= 24 and key:match("^[a-z0-9_]+$") ~= nil
end

-- ---------------------------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------------------------
function M.entry(cfg, key)
    for _, entry in ipairs(cfg.catalogue) do
        if entry.key == key then return entry end
    end
    return nil
end

function M.grade(entry, gradeId)
    if not entry then return nil end
    for _, grade in ipairs(entry.grades) do
        if grade.id == gradeId then return grade end
    end
    return nil
end

function M.entryBySlot(cfg, slot)
    for _, entry in ipairs(cfg.catalogue) do
        if entry.slot == slot then return entry end
    end
    return nil
end

function M.entryByDefinition(cfg, definitionId)
    for _, entry in ipairs(cfg.catalogue) do
        if entry.definitionId == definitionId then return entry end
    end
    return nil
end

-- The catalogue entry and grade a boxed item stands for.
function M.byItem(cfg, item)
    for _, entry in ipairs(cfg.catalogue) do
        for _, grade in ipairs(entry.grades) do
            if grade.item == item then return entry, grade end
        end
    end
    return nil
end

-- An entry and grade from player words: `arms`, `arms street`, or a box id.
function M.resolve(cfg, key, gradeId)
    local entry = M.entry(cfg, key)
    if not entry then
        local e, g = M.byItem(cfg, key)
        if e then return e, g end
        return nil
    end
    if gradeId == nil or gradeId == "" then return entry, entry.grades[1] end
    return entry, M.grade(entry, gradeId)
end

function M.label(entry, grade)
    if grade then return ("%s (%s)"):format(entry.label, grade.label) end
    return entry.label
end

-- Every boxed item, in catalogue order.
function M.stockItems(cfg)
    local out = {}
    for _, entry in ipairs(cfg.catalogue) do
        for _, grade in ipairs(entry.grades) do
            if grade.item then out[#out + 1] = { item = grade.item, entry = entry, grade = grade } end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Procedures: { action = "install" | "remove", key, grade }
-- ---------------------------------------------------------------------------------------------
function M.actionId(proc)
    if proc.action == "remove" then return "rm_" .. proc.key end
    return ("op_%s_%s"):format(proc.key, proc.grade)
end

-- Every operate action this catalogue needs: { id, proc, entry, grade, durationMs, label, progress }.
function M.operateActions(cfg)
    local out = {}
    for _, entry in ipairs(cfg.catalogue) do
        for _, grade in ipairs(entry.grades) do
            local proc = { action = "install", key = entry.key, grade = grade.id }
            out[#out + 1] = { id = M.actionId(proc), proc = proc, entry = entry, grade = grade,
                durationMs = grade.durationMs, label = "Install " .. M.label(entry, grade),
                progress = "Installing " .. entry.label }
        end
        local proc = { action = "remove", key = entry.key }
        out[#out + 1] = { id = M.actionId(proc), proc = proc, entry = entry,
            durationMs = entry.grades[1].durationMs, label = "Remove " .. entry.label,
            progress = "Removing " .. entry.label }
    end
    return out
end

-- Menu option ids: "install:<key>:<grade>" and "remove:<key>".
function M.optionId(proc)
    if proc.action == "remove" then return "remove:" .. proc.key end
    return ("install:%s:%s"):format(proc.key, proc.grade)
end

function M.parseOption(cfg, id)
    if type(id) ~= "string" then return nil end
    local action, key, gradeId = id:match("^(%a+):([%w_]+):?([%w_]*)$")
    if action == "remove" and M.entry(cfg, key) then return { action = "remove", key = key } end
    if action == "install" then
        local entry = M.entry(cfg, key)
        if entry and M.grade(entry, gradeId) then return { action = "install", key = key, grade = gradeId } end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- The cyberware record (Open77.cyberware.current): slots may be absent on this build for the
-- hacking implants, so any implant-shaped field is listed too.
-- ---------------------------------------------------------------------------------------------
function M.installedList(record)
    local list, seen = {}, {}
    if type(record) ~= "table" then return list end
    for _, slot in ipairs(M.SLOTS) do
        local implant = record[slot]
        if type(implant) == "table" and implant.definition then
            list[#list + 1] = { slot = slot, implant = implant }
            seen[slot] = true
        end
    end
    for key, value in pairs(record) do
        if not seen[key] and type(value) == "table" and value.definition and value.slot then
            list[#list + 1] = { slot = tostring(value.slot), implant = value }
        end
    end
    return list
end

function M.installedInSlot(record, slot)
    for _, item in ipairs(M.installedList(record)) do
        if item.slot == slot then return item.implant end
    end
    return nil
end

-- The grade snapshot of an installed implant may be a table ({ id = ... }) or an id.
function M.installedGradeId(implant)
    if type(implant) ~= "table" then return nil end
    if type(implant.grade) == "table" then return implant.grade.id end
    return implant.grade
end

function M.describeImplant(cfg, implant)
    if type(implant) ~= "table" then return nil end
    local entry = M.entryByDefinition(cfg, implant.definition)
    local gradeId = M.installedGradeId(implant)
    local grade = entry and M.grade(entry, gradeId)
    local label = entry and entry.label or tostring(implant.definition)
    return ("%s (%s)"):format(label, grade and grade.label or tostring(gradeId or "?")), entry, grade
end

-- ---------------------------------------------------------------------------------------------
-- Prices
-- ---------------------------------------------------------------------------------------------
function M.removalPrice(cfg, entry, implant)
    local _, _, grade = M.describeImplant(cfg, implant)
    local base = grade and grade.price or (entry.grades[1] and entry.grades[1].price) or 0
    return math.floor(base * (cfg.removalPriceFactor or 0.5))
end

function M.wholesale(cfg, grade, count)
    return math.floor((grade.price or 0) * (cfg.supplier.priceFactor or 0.6)) * (count or 1)
end

function M.buybackPrice(cfg, grade, count)
    return math.floor((grade.price or 0) * (cfg.buyback.ratio or 0.5)) * (count or 1)
end

-- ---------------------------------------------------------------------------------------------
-- Lines (coordinator operations)
-- ---------------------------------------------------------------------------------------------
-- One surgery: the price from the patient's wallet to the society, the implant out of the clinic's
-- stock into the theatre (it is in the patient now). A removal moves money only.
function M.surgeryLines(o)
    local lines = {}
    if (o.price or 0) > 0 then
        lines[#lines + 1] = { money = o.price, from = o.wallet, to = "soc:" .. o.society, reason = o.reason }
    end
    if o.item and o.withItem ~= false then
        lines[#lines + 1] = { item = o.item, count = 1, from = o.stock, to = M.THEATRE, reason = o.reason }
    end
    return lines
end

-- One restock order. Mint mode: the price out of the payer into the supplier, the boxes out of the
-- supplier into the stock. Components mode: the grade's components out of `componentsFrom`, no money.
function M.restockLines(o)
    local lines = {}
    if o.mode == "components" then
        for _, c in ipairs(o.components or {}) do
            lines[#lines + 1] = { item = c.item, count = c.count * o.count, from = o.componentsFrom, to = M.SUPPLIER,
                reason = "chrome components" }
        end
    elseif (o.cost or 0) > 0 then
        lines[#lines + 1] = { money = o.cost, from = o.payer, to = M.SUPPLIER, reason = "chrome order" }
    end
    lines[#lines + 1] = { item = o.item, count = o.count, from = M.SUPPLIER, to = o.stock, reason = "chrome order" }
    return lines
end

-- A box bought from a player: the box from their pockets into the stock, the price to them.
function M.buybackLines(o)
    local lines = {
        { item = o.item, count = o.count, from = o.sellerPockets, to = o.stock, reason = "chrome bought" },
    }
    if (o.price or 0) > 0 then
        lines[#lines + 1] = { money = o.price, from = o.payer, to = o.sellerWallet, reason = "chrome bought" }
    end
    return lines
end

-- ---------------------------------------------------------------------------------------------
-- Ids
-- ---------------------------------------------------------------------------------------------
-- The cyberware operation id of a surgery: its coordinator id in the cyberware alphabet
-- (1..96 of A-Z a-z 0-9 _ . : -), so a retry, a replay and the restart recovery all use one id.
function M.cwOpId(id)
    return (tostring(id):gsub("[^%w_%.:%-]", "-")):sub(1, 96)
end

-- ---------------------------------------------------------------------------------------------
-- Texts (ASCII only: prompt cards and chat show a non-ASCII glyph as "?")
-- ---------------------------------------------------------------------------------------------
function M.money(n) return ("%d eddies"):format(math.tointeger(math.floor(tonumber(n) or 0)) or 0) end
function M.seconds(ms) return math.floor((tonumber(ms) or 0) / 1000 + 0.5) end

M.TEXT = {
    not_owner = "That is not yours to do.",
    clinic_unavailable = "The clinic is closed for now (its ledger is not ready).",
    store_unavailable = "The clinic's ledger is unavailable: try again in a moment.",
    coordinator_unavailable = "The clinic's ledger is unavailable: try again in a moment.",
    in_doubt = "The clinic is still settling that: check again in a moment.",
    no_job = "You are no ripperdoc.",
    wrong_job = "You are no ripperdoc.",
    off_duty = "Clock in first: /service.",
    stale_job_epoch = "Your shift changed in the middle of that: nothing was done.",
    not_eligible = "Only a ripperdoc on duty can do that.",
    outside_clinic = "Work inside the clinic.",
    clinic_busy = "The clinic already has a procedure in progress: finish it first.",
    busy = "One of you is already in a procedure.",
    player_reserved = "One of you is already in another interaction.",
    self_surgery = "Operating on yourself? Not even in Night City.",
    no_patient = "No such player. /players for the ids.",
    too_far = "Get closer.",
    patient_too_far = "Get closer to them (within 4 m).",
    record_not_ready = "The patient's implant record is not ready yet: try again in a moment.",
    records_pending = "The clinic is still settling that patient's last procedure: try again in a moment.",
    provider_offline = "That implant is not available on this server right now.",
    slot_taken = "That slot is already taken: remove the implant first.",
    slot_empty = "Nothing to remove in that slot.",
    out_of_stock = "The clinic has no box of that implant left: restock at the chrome dealer.",
    unknown_implant = "Unknown implant. /ripper stock lists the catalogue.",
    insufficient_funds = "Not enough eddies (cash or bank).",
    no_quote = "No accepted quote here. ALT+click your patient > Quote, or /ripper quote <id>.",
    quote_pending = "The patient has not answered the quote yet.",
    surgery_busy = "That procedure is already running.",
    wrong_clinic = "That patient's quote is for another clinic.",
    patient_not_on_chair = "The patient must sit in the operating chair first (E on the chair).",
    hold_lost = "The hold on that quote is gone: send a new quote.",
    quote_expired = "The quote expired: send a new one.",
    patient_left = "The patient got off the chair.",
    patient_gone = "The patient left.",
    capacity_exceeded = "The clinic's stash is full.",
    insufficient_items = "Not enough boxes.",
    mint_denied = "The dealer cannot sell that (operator: mint rule missing).",
    mint_cap_exceeded = "The dealer is out of chrome for this hour.",
    namespace_denied = "The clinic's accounts are not writable (operator: writers policy).",
    no_components = "That implant has no components recipe: the dealer sells it for eddies only.",
    seller_short = "The seller does not carry that.",
    not_a_patient = "You are not on a ripperdoc's list right now.",
    nothing_to_cancel = "Nothing to cancel.",
    installing = "The chrome is going in: it cannot be stopped now.",
    interactions_unavailable = "Quotes are unavailable on this server (open77_player_interactions).",
    animation_busy = "The patient is busy with an animation: ask them to stand up first.",
    player_not_alive = "One of you is not alive enough for this.",
    player_in_vehicle = "Nobody operates inside a vehicle.",
    wrong_bucket = "You are not in the same world as the patient.",
    position_unavailable = "Your position is unknown right now: try again.",
    unknown_clinic = "There is no clinic here.",
    target_claimed = "Someone is already using that.",
    actor_busy = "Finish what you are doing first.",
    journal_unavailable = "The clinic's records are unavailable: nothing was done.",
}

function M.textFor(reason)
    return M.TEXT[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

-- What open77_actions shows when one of this resource's actions is refused or stops: the same words
-- as the toast (a reason token -> text, at most 32 entries of 160 characters), and nothing at all for
-- the patient's quote stand-up (the consent offer itself says what happens).
local ACTION_REASONS = {
    "not_eligible", "outside_clinic", "clinic_busy", "busy", "too_far", "no_quote", "quote_pending",
    "patient_not_on_chair", "patient_left", "surgery_lost", "out_of_stock", "stale_job_epoch",
}
function M.actionMessages()
    local messages = { quote_offered = false }
    for _, reason in ipairs(ACTION_REASONS) do
        local text = M.TEXT[reason]
        if type(text) == "string" and #text <= 160 then messages[reason] = text end
    end
    return messages
end

-- Why a quote, an offer or a surgery ended, as players read it.
function M.endText(reason)
    reason = tostring(reason or "")
    if reason == "declined" or reason:find("declin") or reason:find("reject") then return "the patient declined the quote." end
    if reason == "timeout" or reason:find("expired") and not reason:find("quote") then return "the quote was not answered in time." end
    if reason == "quote_expired" then return "the quote expired before the operation started." end
    if reason == "cancelled_by_player" then return "the ripperdoc stopped." end
    if reason == "patient_stopped" then return "the patient stopped it." end
    if reason == "patient_left" or reason:find("animation_interrupted") or reason == "superseded" then
        return "the patient got off the chair."
    end
    if reason == "patient_walked_away" or reason == "too_far" or reason == "moved" then return "somebody walked away." end
    if reason == "patient_gone" or reason == "ripper_gone" or reason:find("disconnect") then return "somebody left the server." end
    if reason == "patient_dead" or reason == "dead" or reason:find("alive") then return "somebody flatlined." end
    if reason == "ripper_off_duty" or reason == "stale_job_epoch" or reason == "off_duty" then return "the ripperdoc clocked out." end
    if reason == "vehicle" or reason:find("vehicle") then return "somebody got into a vehicle." end
    if reason == "combat" then return "somebody drew a weapon." end
    if reason == "restart" or reason == "owner_stopped" or reason == "resource_stopping" then return "the clinic restarted." end
    if reason == "withdrawn" then return "the ripperdoc withdrew it." end
    if reason == "native_projection_failed" then return "the chrome would not take (native_projection_failed)." end
    if reason == "install_timeout" then return "the chrome did not answer in time." end
    if M.TEXT[reason] then return M.TEXT[reason] end
    return ("%s."):format(reason ~= "" and reason or "unknown")
end

return M
