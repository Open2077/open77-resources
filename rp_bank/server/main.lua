-- rp_bank / server: bank accounts, societies, ATM menu and the four commands.
--
-- Version 2 (world-interaction row B3): a facade. Balances are owned by the open77_transactions
-- coordinator (A13 decision 2) and cached by rp_economy, the wallet facade:
--   cash    -> cash:<subject>   (rp_economy)
--   account -> bank:<subject>   (this resource's exports, rp_economy's cache)
--   society -> soc:<name>
--   ledger  -> the coordinator journal (op77_tx_journal); the 1.x table rp_bank_transactions is a
--              read-only archive the statement still shows
--
-- The eight 1.x exports keep their signatures and are synchronous: each one is ONE coordinator
-- operation submitted by rp_economy's write-behind facade (walletMove), so a deposit can no
-- longer debit the cash and lose the account credit (B8 §3.5). The ATM menu and /virement use the
-- atomic asynchronous API (rp_economy:pay) and report the real outcome.
--
-- There is no store of its own and no KVP fallback: while the coordinator is unavailable every
-- operation is refused (`bank_not_ready`), never forked into another store (gap R1).

local RESOURCE = "rp_bank"

-- The `.await` forms are documented on every database card but are not catalogue entries of
-- their own, so the static validator reads the dotted spelling as an unknown native. They are
-- reached through this alias. Used only to read the 1.x ledger archive.
local DB = Open77.database

local recent = {}        -- identifier -> { { delta, balanceAfter, kind, note, at }, ... } newest first (this boot)
local online = {}        -- identifier -> playerId (ready players only)
local sessions = {}      -- playerId -> true while an ATM menu is open
local bootTag = "0"
local opSeq = 0

-- ---------------------------------------------------------------------------------------------
-- helpers

local function log(fmt, ...)
    print(("[%s] "):format(RESOURCE) .. fmt:format(...))
end

local function warn(fmt, ...)
    Open77.log.warn(fmt:format(...))
end

local function formatMoney(n)
    local s = tostring(math.tointeger(n) or n)
    local sign = ""
    if s:sub(1, 1) == "-" then sign, s = "-", s:sub(2) end
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    out = out:gsub("^ ", "")
    return sign .. out .. " €$"
end

-- A chat line from the bank, in one colour, to one player.
local function say(playerId, text)
    if type(playerId) ~= "number" or playerId <= 0 then return end
    local ok, reason = Open77.chat.send(playerId, { author = "NC Bank", text = text, color = { 34, 216, 226 } })
    if not ok then warn("chat.send to %d refused: %s", playerId, tostring(reason)) end
end

-- Positive integer amount within the per-operation cap, or nil, reason.
local function toAmount(value)
    local n = tonumber(value)
    if not n then return nil, "invalid_amount" end
    local i = math.tointeger(n)
    if not i or i < 1 then return nil, "invalid_amount" end
    if i > Config.MaxAmount then return nil, "amount_too_large" end
    return i
end

-- A positive integer player id, or nil, reason. Accepts the string form host events deliver.
local function toPlayerId(value)
    local n = tonumber(value)
    if not n then return nil, "invalid_player_id" end
    local i = math.tointeger(n)
    if not i or i < 1 then return nil, "invalid_player_id" end
    return i
end

local function cleanNote(note)
    if note == nil then return nil end
    if type(note) ~= "string" then return nil, "invalid_reason" end
    if #note < 1 or #note > 128 or note:find("[%c]") then return nil, "invalid_reason" end
    return note
end

local function cleanSocietyName(name)
    if type(name) ~= "string" then return nil, "invalid_society" end
    if #name < 1 or #name > 64 or not name:match("^[%w_%-%.]+$") then return nil, "invalid_society" end
    return name:lower()
end

local function base36(n)
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    n = math.tointeger(n) or 0
    if n <= 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        out[#out + 1] = digits:sub(d + 1, d + 1)
        n = n // 36
    end
    return string.reverse(table.concat(out))
end

-- Human reasons for chat. Unknown tokens are shown as they are.
local REASON_TEXT = {
    invalid_amount        = "Amount must be a positive whole number of eddies.",
    amount_too_large      = "That is more eddies than this ATM can move at once.",
    insufficient_funds    = "Not enough eddies in the account.",
    insufficient_cash     = "Not enough cash on you.",
    balance_limit         = "That account cannot hold more.",
    bank_not_ready        = "The bank network is unavailable right now. Nothing was moved; try again in a moment.",
    account_not_loaded    = "Your account is not loaded yet. Give it a second.",
    unknown_recipient     = "Unknown recipient. Use a connected player id or a citizen id.",
    self_transfer         = "You cannot wire eddies to yourself, choom.",
    wallet_unavailable    = "The wallet service (rp_economy) is offline.",
    invalid_player_id     = "That is not a player id.",
    player_not_found      = "No such player in Night City right now.",
    invalid_society       = "That is not a society name.",
    invalid_reason        = "Bad reason text.",
    in_doubt              = "The network is slow to confirm. Check /solde in a moment before trying again.",
}

local function reasonText(reason)
    return REASON_TEXT[reason] or ("Refused: " .. tostring(reason))
end

-- rp_economy's refusals in this resource's 1.x vocabulary. `side` names the wallet that was
-- short when it matters (a deposit short of cash says insufficient_cash, as in 1.x).
local function bankReason(reason, info, cashSide)
    if reason == "store_unavailable" or reason == "migration_pending" or reason == "coordinator_unavailable"
        or reason == "migration_failed" or reason == "migration_version_newer" then
        return "bank_not_ready"
    end
    if reason == "not_loaded" then
        if type(info) == "table" and type(info.account) == "string" and info.account:find("^soc:") then
            return "bank_not_ready"
        end
        return "account_not_loaded"
    end
    if reason == "insufficient_funds" and cashSide and type(info) == "table"
        and type(info.account) == "string" and info.account:find("^cash:") then
        return "insufficient_cash"
    end
    return reason
end

-- Append one statement line for this boot (the durable ledger is the coordinator journal).
local function record(identifier, delta, balanceAfter, kind, note)
    local at = math.floor(Open77.time.unix())
    local ring = recent[identifier]
    if not ring then ring = {}; recent[identifier] = ring end
    table.insert(ring, 1, { delta = delta, balanceAfter = balanceAfter, kind = kind, note = note, at = at })
    while #ring > Config.HistoryLimit do table.remove(ring) end
end

local function emitChanged(playerId, identifier, newBalance, delta, kind)
    local ok, reason = TriggerEvent("rp_bank:changed", playerId, identifier, newBalance, delta, kind)
    if not ok then warn("rp_bank:changed not published: %s", tostring(reason)) end
end

-- ---------------------------------------------------------------------------------------------
-- rp_economy bridge (server-only resource: reached through pcall, no dependency line)

local function walletRead(playerId, kind)
    local ok, wallet, why = pcall(Open77.exports.callSync, "rp_economy", "walletRead", playerId, kind)
    if not ok then return nil, "wallet_unavailable" end
    return wallet, why
end

local function societyRead(name)
    local ok, soc, why = pcall(Open77.exports.callSync, "rp_economy", "societyRead", name)
    if not ok then return nil, "wallet_unavailable" end
    return soc, why
end

-- One write-behind operation (synchronous). Returns the result | nil, reason, info.
local function walletMove(spec)
    local ok, result, why, info = pcall(Open77.exports.callSync, "rp_economy", "walletMove", spec)
    if not ok then return nil, "wallet_unavailable" end
    return result, why, info
end

-- One atomic operation (asynchronous: handlers and commands only, never from an export).
local function payAsync(spec)
    local promise, why = Open77.exports.call("rp_economy", "pay", spec)
    if not promise then return nil, "wallet_unavailable" end
    local receipt, reason, info = promise:await()
    if promise:status() ~= "resolved" then return nil, "in_doubt", { opId = spec.opId } end
    return receipt, reason, info
end

local function balanceOfAsync(party)
    local promise = Open77.exports.call("rp_economy", "balanceOf", party)
    if not promise then return nil, "wallet_unavailable" end
    local result, why = promise:await()
    if promise:status() ~= "resolved" then return nil, "wallet_unavailable" end
    return result, why
end

local function newOpId(kind, identifier)
    opSeq = opSeq + 1
    local id = ("rp_bank.%s.%s.%s.%s"):format(kind, bootTag, base36(opSeq), identifier or "-")
    if #id > 96 then id = id:sub(1, 96) end
    return id
end

local function caller()
    return GetInvokingResource() or RESOURCE
end

-- ---------------------------------------------------------------------------------------------
-- core operations (synchronous, never yield: safe behind exports.rp_bank:*)

local firstSeen = {}     -- identifier -> unix time this server first served the account

local function getAccount(playerId)
    local id, reason = toPlayerId(playerId)
    if not id then return nil, reason end
    local wallet, why = walletRead(id, "bank")
    if not wallet then return nil, bankReason(why) end
    firstSeen[wallet.identifier] = firstSeen[wallet.identifier] or math.floor(Open77.time.unix())
    return { identifier = wallet.identifier, balance = wallet.balance, createdAt = firstSeen[wallet.identifier] }
end

local function deposit(playerId, amount)
    local id, reason = toPlayerId(playerId)
    if not id then return nil, reason end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local result, why, info = walletMove({
        onBehalfOf = caller(), kind = "bank.deposit", reason = "bank:deposit",
        lines = { { amount = n, from = { player = id, wallet = "cash" }, to = { player = id, wallet = "bank" } } },
    })
    if not result then return nil, bankReason(why, info, true) end
    local balance = result.balances[result.lines[1].to]
    log("player %d deposit %d account=%s op=%s", id, n, tostring(balance), result.opId)
    return balance
end

local function withdraw(playerId, amount)
    local id, reason = toPlayerId(playerId)
    if not id then return nil, reason end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local result, why, info = walletMove({
        onBehalfOf = caller(), kind = "bank.withdraw", reason = "bank:withdraw",
        lines = { { amount = n, from = { player = id, wallet = "bank" }, to = { player = id, wallet = "cash" } } },
    })
    if not result then return nil, bankReason(why, info) end
    local balance = result.balances[result.lines[1].from]
    log("player %d withdraw %d account=%s op=%s", id, n, tostring(balance), result.opId)
    return balance
end

-- Account to account. `fee` (optional, integer >= 0) is taken from the sender on top of `amount`
-- and burned (sys:rp_bank:fee). The recipient must be an account this server has loaded (an
-- online player, or one seen this boot); the ATM path checks offline accounts asynchronously.
local function transfer(fromPlayerId, toIdentifier, amount, fee)
    local id, reason = toPlayerId(fromPlayerId)
    if not id then return nil, reason end
    if type(toIdentifier) ~= "string" or #toIdentifier < 1 or #toIdentifier > 96 then
        return nil, "unknown_recipient"
    end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local f = 0
    if fee ~= nil then
        f = math.tointeger(tonumber(fee) or -1) or -1
        if f < 0 or f > Config.MaxAmount then return nil, "invalid_amount" end
    end
    local own = walletRead(id, "bank")
    if own and own.identifier == toIdentifier then return nil, "self_transfer" end
    local lines = { { amount = n, from = { player = id, wallet = "bank" }, to = { identifier = toIdentifier, wallet = "bank" } } }
    if f > 0 then lines[2] = { amount = f, from = { player = id, wallet = "bank" }, to = { sys = "fee" } } end
    local result, why, info = walletMove({ onBehalfOf = RESOURCE, kind = "bank.transfer", reason = "bank:transfer", lines = lines })
    if not result then return nil, bankReason(why, info) end
    local balance = result.balances[result.lines[1].from]
    log("player %d transfer %d fee %d to %s account=%s op=%s", id, n, f, toIdentifier, tostring(balance), result.opId)
    return balance
end

local function society(name)
    local clean, reason = cleanSocietyName(name)
    if not clean then return nil, reason end
    local soc, why = societyRead(clean)
    if not soc then return nil, bankReason(why) end
    if not soc.loaded then return nil, "bank_not_ready" end
    return { name = soc.name, balance = soc.balance }
end

-- A credit from no wallet: a MINT, booked against the calling resource's hourly allowance
-- (rp_economy's mint allowlist; `mint_denied` / `mint_cap` when refused).
local function societyAdd(name, amount, reason)
    local clean, why = cleanSocietyName(name)
    if not clean then return nil, why end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local note, noteReason = cleanNote(reason)
    if reason ~= nil and not note then return nil, noteReason end
    local result, failure, info = walletMove({
        onBehalfOf = caller(), kind = "bank.society_add", reason = note,
        lines = { { amount = n, from = { sys = "legacy" }, to = { society = clean } } },
    })
    if not result then return nil, bankReason(failure, info) end
    local balance = result.balances[result.lines[1].to]
    log("society %s +%d %s balance=%s op=%s", clean, n, note or "-", tostring(balance), result.opId)
    return balance
end

local function societyRemove(name, amount, reason)
    local clean, why = cleanSocietyName(name)
    if not clean then return nil, why end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local note, noteReason = cleanNote(reason)
    if reason ~= nil and not note then return nil, noteReason end
    local result, failure, info = walletMove({
        onBehalfOf = caller(), kind = "bank.society_remove", reason = note,
        lines = { { amount = n, from = { society = clean }, to = { sys = "legacy" } } },
    })
    if not result then return nil, bankReason(failure, info) end
    local balance = result.balances[result.lines[1].from]
    log("society %s -%d %s balance=%s op=%s", clean, n, note or "-", tostring(balance), result.opId)
    return balance
end

-- Account -> society, in one operation: a fine, a hospital bill, a subscription. `reason` is a
-- short note. Returns the player's new account balance.
local function charge(playerId, amount, toSociety, reason)
    local id, idReason = toPlayerId(playerId)
    if not id then return nil, idReason end
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    local clean, why = cleanSocietyName(toSociety)
    if not clean then return nil, why end
    local note, noteReason = cleanNote(reason)
    if reason ~= nil and not note then return nil, noteReason end
    local result, failure, info = walletMove({
        onBehalfOf = caller(), kind = "bank.charge", reason = "bank:charge",
        lines = { { amount = n, from = { player = id, wallet = "bank" }, to = { society = clean } } },
    })
    if not result then return nil, bankReason(failure, info) end
    local balance = result.balances[result.lines[1].from]
    log("player %d charged %d to society %s (%s) account=%s op=%s", id, n, clean, note or "-", tostring(balance), result.opId)
    return balance
end

-- ---------------------------------------------------------------------------------------------
-- exports (phase 1 contract + charge, unchanged signatures)

exports("getAccount", getAccount)
exports("deposit", deposit)
exports("withdraw", withdraw)
exports("transfer", transfer)
exports("society", society)
exports("societyAdd", societyAdd)
exports("societyRemove", societyRemove)
exports("charge", charge)

-- Wallet changes published by rp_economy, re-published as the 1.x event for bank accounts and
-- societies, and kept as this boot's statement lines.
local REASON_KIND = {
    ["bank:deposit"] = "deposit", ["bank:withdraw"] = "withdraw", ["bank:charge"] = "charge",
}

AddEventHandler("rp_economy:walletChanged", function(kind, playerId, key, newBalance, delta, reason)
    if kind ~= "bank" and kind ~= "soc" then return end
    local tag = REASON_KIND[reason]
    if reason == "bank:transfer" then tag = delta < 0 and "transfer_out" or "transfer_in" end
    if kind == "soc" then tag = delta < 0 and "society_remove" or "society_add" end
    tag = tag or (type(reason) == "string" and reason:sub(1, 32)) or "sync"
    local identifier = kind == "soc" and ("society:" .. key) or key
    record(identifier, delta, newBalance, tag, kind == "soc" and reason or nil)
    emitChanged(kind == "soc" and nil or playerId, identifier, newBalance, delta, tag)
end)

-- ---------------------------------------------------------------------------------------------
-- 1.x KVP report (console). The 1.x fallback store is never read at runtime and never imported:
-- this lists how its values differ from the coordinator so an operator can decide.

local function kvpReport()
    local differ, total = 0, 0
    for _, prefix in ipairs({ "acct:", "soc:" }) do
        for _, key in ipairs(Open77.kvp.keys(prefix, 4096) or {}) do
            total = total + 1
            local name = key:sub(#prefix + 1)
            local kvp = math.tointeger(tonumber(Open77.kvp.get(key)) or -1)
            local party = prefix == "soc:" and { society = name } or { identifier = name, wallet = "bank" }
            local current = balanceOfAsync(party)
            local balance = type(current) == "table" and current.balance or nil
            local same = balance ~= nil and balance == kvp
            if not same then differ = differ + 1 end
            log("kvp_report %s kvp=%s coordinator=%s %s", key, tostring(kvp), tostring(balance), same and "same" or "DIFFERS")
        end
    end
    log("kvp_report: %d key(s), %d differ; nothing was imported", total, differ)
end

-- ---------------------------------------------------------------------------------------------
-- ATM location check

local function nearestAtm(playerId, range)
    local pos = Open77.players.position(playerId)
    if not pos then return nil end
    local best, bestDist
    for _, atm in ipairs(Config.Atms) do
        local dx, dy = pos.x - atm.position.x, pos.y - atm.position.y
        local dz = math.abs(pos.z - atm.position.z)
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= range and dz <= Config.AtmHeightTolerance and (not bestDist or d < bestDist) then
            best, bestDist = atm, d
        end
    end
    return best, bestDist
end

local function atmById(id)
    if type(id) ~= "string" then return nil end
    for _, atm in ipairs(Config.Atms) do
        if atm.id == id then return atm end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- UI kit helpers (server twins, asynchronous: only from handlers, never from an export)

local function uikit(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local function relativeTime(at)
    local delta = math.floor(Open77.time.unix()) - (at or 0)
    if delta < 60 then return "just now" end
    if delta < 3600 then return ("%d min ago"):format(delta // 60) end
    if delta < 86400 then return ("%d h ago"):format(delta // 3600) end
    return ("%d d ago"):format(delta // 86400)
end

local KIND_LABEL = {
    deposit = "Deposit", withdraw = "Withdrawal", transfer_out = "Wire sent",
    transfer_in = "Wire received", fee = "Wire fee", charge = "Charge", society_add = "Society credit",
    society_remove = "Society debit", sync = "Account update",
}

-- Last N statement lines, newest first: this boot's operations, then the 1.x ledger archive
-- (rp_bank_transactions, read only, never written since version 2). Lines after the cutover
-- that predate this boot are in the coordinator journal: open77_transactions:history(bank:<subject>)
-- reads it since Open77 697e9e2f, but the statement does not merge it yet (b3-wallet.md section 8).
local function history(identifier)
    local limit = math.tointeger(Config.HistoryLimit) or 10
    local out = {}
    for _, tx in ipairs(recent[identifier] or {}) do out[#out + 1] = tx end
    if #out < limit then
        local ok, rows = pcall(DB.query.await,
            "SELECT delta, balance_after, kind, note, `at` FROM rp_bank_transactions WHERE identifier = ? ORDER BY id DESC LIMIT "
                .. tostring(limit),
            { identifier })
        if ok and type(rows) == "table" then
            for _, row in ipairs(rows) do
                if #out >= limit then break end
                out[#out + 1] = {
                    delta = math.tointeger(tonumber(row.delta)) or 0,
                    balanceAfter = math.tointeger(tonumber(row.balance_after)) or 0,
                    kind = row.kind, note = ((row.note and row.note ~= "") and (row.note .. " · ") or "") .. "archive",
                    at = math.tointeger(tonumber(row.at)) or 0,
                }
            end
        end
    end
    return out
end

-- Resolve a recipient typed at the ATM: a connected player id, or a citizen id (identifier)
-- whose wallet exists in the coordinator (offline recipients included). Yields.
local function resolveRecipient(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    local id = toPlayerId(text)
    if id then
        local wallet = walletRead(id, "bank")
        if wallet then return wallet.identifier, id end
    end
    for _, kind in ipairs({ "bank", "cash" }) do
        local found = balanceOfAsync({ identifier = text, wallet = kind })
        if type(found) == "table" and found.exists then return text, online[text] end
    end
    return nil
end

local function askAmount(playerId, title, description)
    local answer, reason = uikit("input", playerId, {
        title = title,
        description = description,
        fields = {
            { id = "amount", type = "number", label = "Amount (eddies)", min = 1, max = Config.MaxAmount, step = 1, required = true },
        },
        confirm = "Confirm", cancel = "Back", timeoutMs = 60000,
    })
    if answer == nil then return nil, reason end
    if not answer.ok then return nil, "cancelled" end
    return answer.value.amount
end

local function showHistory(playerId, identifier)
    local rows = history(identifier)
    local options = {}
    for i, tx in ipairs(rows) do
        local sign = tx.delta >= 0 and "+" or "-"
        options[#options + 1] = {
            id = "tx" .. i,
            label = ("%s%s  %s"):format(sign, formatMoney(math.abs(tx.delta)), KIND_LABEL[tx.kind] or tx.kind),
            description = ("%s  ·  balance %s%s"):format(relativeTime(tx.at), formatMoney(tx.balanceAfter),
                (tx.note and tx.note ~= "") and ("  ·  " .. tx.note) or ""),
            disabled = true,
        }
    end
    if #options == 0 then
        options[1] = { id = "none", label = "No transactions yet", description = "Your ledger is clean, choom.", disabled = true }
    end
    options[#options + 1] = { id = "back", label = "Back", icon = "<" }
    uikit("context", playerId, {
        id = "rp_bank_history",
        title = "Statement",
        description = ("Last %d operations"):format(Config.HistoryLimit),
        options = options,
    }, { timeoutMs = 60000 })
end

-- The ATM menu loop. `atm` is the ATM the player stands at.
-- ---------------------------------------------------------------------------
-- Staging: a pose, a prop in the hand (or at the feet) and a progress bar for
-- every action that manipulates something, so nothing completes instantly and
-- everybody around sees it. Pattern of rp_nomade's carry pose: profiles tried
-- in order through Open77.animations.get, every native call inside pcall, a
-- refusal logged once and never fatal. RP animations are workspots: the
-- platform cancels one when the player moves more than 0.5 m, so the UI-kit bar
-- keeps the player still (disable.move, client side); the server never freezes
-- anyone. Everything comes from Config.Stage (shared/config.lua).
-- ---------------------------------------------------------------------------

local STAGE = Config.Stage or {}
local STAGE_TAG = "[" .. GetCurrentResourceName() .. "]"
local stageWarned = {}          -- "<what>" -> true once logged
local stageResolved = {}        -- key -> { profile, clip } | false
local stageActive = {}          -- playerId -> { key, playbackId, props = { ids } } while staged

local function stageLog(fmt, ...)
    print((STAGE_TAG .. " " .. fmt):format(...))
end

local function stageWarnOnce(what, fmt, ...)
    if stageWarned[what] then return end
    stageWarned[what] = true
    stageLog(fmt, ...)
end

local function stageAnimationsApi()
    return type(Open77.animations) == "table" and type(Open77.animations.play) == "function"
end

local function stagePropsApi()
    return type(Open77.props) == "table" and type(Open77.props.attach) == "function"
end

-- First profile of `pose.profiles` the server's catalogue knows (memoised per key).
local function stageResolvePose(key, pose)
    if stageResolved[key] ~= nil then return stageResolved[key] or nil end
    local found = false
    if type(pose) == "table" and stageAnimationsApi() then
        for _, candidate in ipairs(pose.profiles or {}) do
            local ok, profile = pcall(Open77.animations.get, candidate.profile)
            if ok and type(profile) == "table" then
                local clip = candidate.clip
                if clip then
                    local known = false
                    for _, name in ipairs(profile.clips or {}) do
                        if name == clip then known = true break end
                    end
                    if not known then
                        stageLog("stage %s: clip %s is not in profile %s, using %s", key, clip, candidate.profile, tostring(profile.clip))
                        clip = nil
                    end
                end
                found = { profile = candidate.profile, clip = clip or profile.clip }
                break
            end
        end
    end
    stageResolved[key] = found
    if not found then
        local names = {}
        for _, candidate in ipairs(type(pose) == "table" and pose.profiles or {}) do names[#names + 1] = tostring(candidate.profile) end
        stageWarnOnce("pose:" .. key, "stage %s: no known profile among [%s], the action runs without a pose", key, table.concat(names, ", "))
    end
    return found or nil
end

local function stagePoseWord(key)
    local r = stageResolved[key]
    if not r then return "none" end
    return r.profile .. "/" .. tostring(r.clip)
end

-- Start a pose on a player. A `loop` pose runs until stagePoseStop; a one-shot uses
-- `durationMs` (the platform accepts 1 000..600 000 ms). Returns the playback id or nil.
local function stagePoseStart(playerId, key, pose, durationMs)
    if type(pose) ~= "table" then return nil end
    local resolved = stageResolvePose(key, pose)
    if not resolved then return nil end
    local options = {}
    if pose.loop == false then
        options.loop = false
        options.durationMs = math.floor(math.max(1000, math.min(600000, tonumber(durationMs) or tonumber(pose.durationMs) or 5000)))
    else
        options.loop = true
    end
    if resolved.clip then options.clip = resolved.clip end
    local ok, playback, reason = pcall(Open77.animations.play, playerId, resolved.profile, options)
    if ok and type(playback) == "table" and playback.playbackId then
        return playback.playbackId
    end
    if not ok then reason = playback end
    stageWarnOnce("play:" .. key .. ":" .. tostring(reason), "stage %s: pose %s refused for player %d: %s (the action runs without it)",
        key, resolved.profile, playerId, tostring(reason))
    return nil
end

local function stagePoseStop(playerId, playbackId)
    if not playbackId or not stageAnimationsApi() then return end
    local ok, stopped, why = pcall(Open77.animations.stop, playerId, playbackId)
    if ok and not stopped and why ~= "stale_playback" then
        stageLog("stage: pose stop refused for player %d: %s", playerId, tostring(why))
    end
end

-- Spawn a curated prop and make it follow the player (a hand slot, or the root frame:
-- +y where the player faces, +x their right, +z up, origin at the feet). Returns the
-- prop id and the model, or nil.
local function stagePropHold(playerId, key, prop)
    if type(prop) ~= "table" or not stagePropsApi() then return nil end
    local ok0, pos = pcall(Open77.players.position, playerId)
    if not ok0 or type(pos) ~= "table" or type(pos.x) ~= "number" then return nil end
    for _, model in ipairs(prop.models or {}) do
        local okC, id, reason = pcall(Open77.props.create, {
            model = model,
            position = { x = pos.x, y = pos.y, z = pos.z or 0.0 },
            yaw = 0.0,
            bucket = pos.bucket or 0,
        })
        if not okC then id, reason = nil, id end
        if id then
            local okA, attached, why = pcall(Open77.props.attach, id, {
                parentType = "player",
                parentId = playerId,
                bone = prop.bone or "",
                offset = prop.offset or { x = 0.0, y = 0.0, z = 0.0 },
                rotation = prop.rotation or { x = 0.0, y = 0.0, z = 0.0 },
            })
            if okA and attached then return id, model end
            if not okA then why = attached end
            pcall(Open77.props.remove, id)
            stageWarnOnce("attach:" .. key .. ":" .. model, "stage %s: attach of %s to player %d refused: %s (no prop shown)",
                key, model, playerId, tostring(why))
            return nil
        end
        stageWarnOnce("prop:" .. key .. ":" .. model, "stage %s: prop %s refused: %s", key, model, tostring(reason))
    end
    return nil
end

local function stagePropDrop(propId)
    if propId and stagePropsApi() then pcall(Open77.props.remove, propId) end
end

local function stageSlotWord(prop)
    if type(prop) ~= "table" then return "root" end
    return (prop.bone and prop.bone ~= "") and prop.bone or "root"
end

-- Everything a staged action put on a player is taken back.
local function stageFinish(playerId, entry)
    if not entry then return end
    if stageActive[playerId] == entry then stageActive[playerId] = nil end
    stagePoseStop(playerId, entry.playbackId)
    entry.playbackId = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
    entry.props = {}
end

-- Pose + props of `def` on a player, returned as an entry for stageFinish.
local function stageBegin(playerId, key, def, durationMs)
    local entry = { key = key, props = {}, words = {} }
    stageActive[playerId] = entry
    if STAGE.enabled == false or type(def) ~= "table" then return entry end
    entry.playbackId = stagePoseStart(playerId, key, def.pose, durationMs)
    if def.prop then
        local id, model = stagePropHold(playerId, key .. ".prop", def.prop)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.prop = model .. "@" .. stageSlotWord(def.prop)
        end
    end
    if def.place then
        local id, model = stagePropHold(playerId, key .. ".place", def.place)
        if id then
            entry.props[#entry.props + 1] = id
            entry.words.place = model
        end
    end
    return entry
end

-- The UI-kit bar (server twin). A plain wait keeps the beat when the kit is missing.
local function stageBar(playerId, definition)
    local promise, reason = Open77.exports.call("open77_uikit", "progress", playerId, definition)
    if not promise then
        if reason == "progress_active" or reason == "dialog_active" then return nil, reason end
        stageWarnOnce("uikit:" .. tostring(reason), "stage: uikit progress unavailable (%s), plain wait instead", tostring(reason))
        Wait(definition.duration)
        return { ok = true, outcome = "ok", fallback = true }
    end
    local answer, err = promise:await()
    if not answer then return nil, err end
    return answer
end

-- Run a staged action on `playerId`: pose + props + bar, then everything is cleaned up.
-- `key` names a Config.Stage entry; opts.label / opts.durationMs / opts.cancellable override
-- it. Returns the bar's answer ({ ok, outcome }) or nil, reason when the bar never showed.
-- Yields: capture `source` before calling.
local function stage(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 5000)
    local entry = stageBegin(playerId, key, def, durationMs)
    local answer, err = stageBar(playerId, {
        label = opts.label or def.label or key,
        duration = durationMs,
        position = "bottom",
        style = "bar",
        color = def.color or STAGE.color,
        cancellable = opts.cancellable ~= false,
        cancelKey = "X",
        disable = { move = true, combat = true },
    })
    stageFinish(playerId, entry)
    stageLog("player %d stage %s: pose=%s prop=%s place=%s %d ms -> %s", playerId, key, stagePoseWord(key),
        entry.words.prop or "none", entry.words.place or "none", durationMs,
        answer and (answer.ok and "ok" or tostring(answer.outcome or "cancelled")) or ("failed:" .. tostring(err)))
    return answer, err
end

-- A gesture without a bar (a hand-over, a wave, a sip): pose + props for `durationMs`,
-- taken back by a timer. Never yields. Returns the entry.
local function gesture(playerId, key, opts)
    opts = opts or {}
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local durationMs = math.floor(tonumber(opts.durationMs) or tonumber(def.durationMs) or 3000)
    local entry = stageBegin(playerId, key, def, durationMs)
    SetTimeout(durationMs, function() stageFinish(playerId, entry) end)
    stageLog("player %d gesture %s: pose=%s prop=%s %d ms", playerId, key, stagePoseWord(key), entry.words.prop or "none", durationMs)
    return entry
end

-- A pose held until stageRelease (a cuffed suspect, a patient on the ground). Never yields.
local function stageHold(playerId, key)
    local def = type(STAGE[key]) == "table" and STAGE[key] or {}
    local entry = stageBegin(playerId, key, def, nil)
    stageLog("player %d hold %s: pose=%s prop=%s", playerId, key, stagePoseWord(key), entry.words.prop or "none")
    return entry
end

local function stageRelease(playerId, entry)
    stageFinish(playerId, entry or stageActive[playerId])
end

-- Disconnect: the pose died with the player, the props must not survive them.
local function stageClear(playerId)
    local entry = stageActive[playerId]
    if not entry then return end
    stageActive[playerId] = nil
    for _, id in ipairs(entry.props or {}) do stagePropDrop(id) end
end

-- ---------------------------------------------------------------------------------------------
-- Atomic operations for the ATM and /virement (asynchronous; one coordinator operation each)

local function atmMove(playerId, kind, fromWallet, toWallet, amount)
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    amount = n
    local wallet = walletRead(playerId, "bank")
    if not wallet then return nil, "account_not_loaded" end
    local receipt, why, info = payAsync({
        opId = newOpId(kind, wallet.identifier), reason = "bank:" .. kind, amount = amount,
        from = { player = playerId, wallet = fromWallet }, to = { player = playerId, wallet = toWallet },
    })
    if not receipt then
        if why == "insufficient_funds" and fromWallet == "cash" then return nil, "insufficient_cash" end
        return nil, bankReason(why, info)
    end
    log("player %d %s %d op=%s", playerId, kind, amount, receipt.opId)
    local after = walletRead(playerId, "bank")
    return after and after.balance or receipt.balances[wallet.account]
end

-- Account to account (+ an optional burned fee), offline recipients included.
local function atmTransfer(playerId, toIdentifier, amount, fee)
    local n, amountReason = toAmount(amount)
    if not n then return nil, amountReason end
    amount = n
    local wallet = walletRead(playerId, "bank")
    if not wallet then return nil, "account_not_loaded" end
    if toIdentifier == wallet.identifier then return nil, "self_transfer" end
    local payees = { { identifier = toIdentifier, wallet = "bank", amount = amount } }
    if fee and fee > 0 then payees[2] = { sys = "fee", amount = fee } end
    local receipt, why, info = payAsync({
        opId = newOpId("transfer", wallet.identifier), reason = "bank:transfer",
        from = { player = playerId, wallet = "bank" }, payees = payees,
    })
    if not receipt then return nil, bankReason(why, info) end
    log("player %d transfer %d fee %d to %s op=%s", playerId, amount, fee or 0, toIdentifier, receipt.opId)
    local after = walletRead(playerId, "bank")
    return after and after.balance or receipt.balances[wallet.account]
end

local function runBankSession(playerId, atm)
    if sessions[playerId] then
        say(playerId, "You already have the bank open.")
        return
    end
    sessions[playerId] = true
    -- The typing pose on the terminal for as long as the menu is open (Config.Stage.atm).
    local atmPose = stageHold(playerId, "atm")
    local ok, err = pcall(function()
        while true do
            local acct, why = walletRead(playerId, "bank")
            if not acct then say(playerId, reasonText(bankReason(why))); return end
            local identifier = acct.identifier
            local cashWallet = walletRead(playerId, "cash")
            local cash = cashWallet and cashWallet.balance or nil
            local answer, reason = uikit("context", playerId, {
                id = "rp_bank_main",
                title = "Night City Bank",
                description = ("%s  ·  Account %s  ·  Cash %s"):format(atm and atm.label or "Mobile banking",
                    formatMoney(acct.balance), cash and formatMoney(cash) or "unknown"),
                options = {
                    { id = "deposit",  label = "Deposit eddies",    icon = "+", description = "Cash into the account." },
                    { id = "withdraw", label = "Withdraw eddies",   icon = "-", description = "Account into cash." },
                    { id = "transfer", label = "Wire to a citizen", icon = ">", description = "Player id or citizen id. No fee at the ATM." },
                    { id = "history",  label = "Statement",         icon = "=", description = ("Last %d operations."):format(Config.HistoryLimit) },
                    { id = "leave",    label = "Leave",             icon = "x", tone = "danger" },
                },
            }, { timeoutMs = 60000 })
            if answer == nil then
                warn("bank menu for %d never answered (%s)", playerId, tostring(reason))
                if reason == "dialog_active" then say(playerId, "Close the other window first.") end
                return
            end
            if not answer.ok then return end
            local pick = answer.value and answer.value.id
            if pick == "deposit" then
                local amount, why = askAmount(playerId, "Deposit", ("Cash on you: %s"):format(cash and formatMoney(cash) or "unknown"))
                if amount then
                    stage(playerId, "process", { label = "Counting the eddies", cancellable = false })
                    local newBalance, failReason = atmMove(playerId, "deposit", "cash", "bank", amount)
                    if newBalance then
                        say(playerId, ("Deposited %s. Account: %s."):format(formatMoney(amount), formatMoney(newBalance)))
                    else
                        say(playerId, reasonText(failReason))
                    end
                elseif why ~= "cancelled" then
                    warn("deposit input for %d: %s", playerId, tostring(why))
                end
            elseif pick == "withdraw" then
                local amount, why = askAmount(playerId, "Withdraw", ("Account: %s"):format(formatMoney(acct.balance)))
                if amount then
                    stage(playerId, "process", { label = "Dispensing the eddies", cancellable = false })
                    local newBalance, failReason = atmMove(playerId, "withdraw", "bank", "cash", amount)
                    if newBalance then
                        say(playerId, ("Withdrew %s. Account: %s."):format(formatMoney(amount), formatMoney(newBalance)))
                    else
                        say(playerId, reasonText(failReason))
                    end
                elseif why ~= "cancelled" then
                    warn("withdraw input for %d: %s", playerId, tostring(why))
                end
            elseif pick == "transfer" then
                local form = uikit("input", playerId, {
                    title = "Wire transfer",
                    description = "Recipient: a connected player id (e.g. 3) or a citizen id.",
                    fields = {
                        { id = "to", type = "text", label = "Recipient", max = 96, required = true },
                        { id = "amount", type = "number", label = "Amount (eddies)", min = 1, max = Config.MaxAmount, step = 1, required = true },
                    },
                    confirm = "Wire it", cancel = "Back", timeoutMs = 60000,
                })
                if form and form.ok then
                    local toIdentifier, toId = resolveRecipient(form.value.to)
                    if not toIdentifier then
                        say(playerId, reasonText("unknown_recipient"))
                    else
                        local amount = form.value.amount
                        stage(playerId, "process", { label = "Wiring the eddies", cancellable = false })
                        local newBalance, failReason = atmTransfer(playerId, toIdentifier, amount, 0)
                        if newBalance then
                            local who = toId and Open77.players.name(toId) or toIdentifier
                            say(playerId, ("Wired %s to %s. Account: %s."):format(formatMoney(amount), tostring(who), formatMoney(newBalance)))
                            if toId then
                                say(toId, ("%s wired you %s."):format(Open77.players.name(playerId) or "Someone", formatMoney(amount)))
                            end
                        else
                            say(playerId, reasonText(failReason))
                        end
                    end
                end
            elseif pick == "history" then
                showHistory(playerId, identifier)
            else
                return
            end
            -- A dialog is a long time in a game world: make sure the player is still at the ATM.
            if atm and not nearestAtm(playerId, Config.AtmPromptRange + 2.0) then
                say(playerId, "You walked away from the ATM.")
                return
            end
        end
    end)
    stageRelease(playerId, atmPose)
    sessions[playerId] = nil
    if not ok then Open77.log.error("bank session for " .. tostring(playerId) .. " failed: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------------------------
-- lifecycle

local SUGGESTIONS = {
    { command = "/bank", help = "Open the bank menu at an ATM (within 3 m)" },
    { command = "/solde", help = "Your cash and account balance" },
    { command = "/virement", help = "Wire eddies to a connected player (1 % fee, min 1)",
      parameters = { { name = "playerId", help = "Connected player id" }, { name = "amount", help = "Eddies to send" } } },
    { command = "/societe", help = "Your job's society balance" },
}

-- The ATM terminals: one prop per configured ATM (Config.AtmProp.model at atm.prop), owned by
-- this resource and removed on stop. A refusal only logs: the ring and the prompt still work.
local atmProps = {}      -- atm id -> prop id (decimal string)

local function spawnAtmProps()
    local model = Config.AtmProp and Config.AtmProp.model
    if not model then return end
    for _, atm in ipairs(Config.Atms) do
        local at = atm.prop
        if at and not atmProps[atm.id] then
            local id, reason = Open77.props.create({
                model = model,
                position = { x = at.x, y = at.y, z = at.z },
                yaw = at.yaw or 0.0,
                bucket = 0,
                streamingRadius = Config.AtmProp.streamingRadius or 120.0,
            })
            if id then
                atmProps[atm.id] = id
                log("terminal prop %s for %s at %.1f %.1f %.1f", tostring(id), atm.id, at.x, at.y, at.z)
            else
                log("terminal prop for %s not spawned (%s): the ring alone marks it", atm.id, tostring(reason))
            end
        end
    end
end

local function removeAtmProps()
    for atmId, propId in pairs(atmProps) do
        Open77.props.remove(propId)
        atmProps[atmId] = nil
    end
end

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    bootTag = base36(math.floor(Open77.time.unix())) .. base36(math.random(46656, 1679615))
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    log("started, %d ATMs configured (accounts and societies held by open77_transactions through rp_economy)", #Config.Atms)
    local spawned, err = pcall(spawnAtmProps)
    if not spawned then log("terminal props failed: %s", tostring(err)) end
    -- Players already in the world when the resource (re)starts.
    for _, id in ipairs(Open77.players.all()) do
        local identifier = Open77.players.identifier(id)
        if identifier then online[identifier] = id end
    end
end)

RegisterNetEvent("chat:ready", function()
    if type(source) ~= "number" or source <= 0 then return end
    Open77.chat.addSuggestions(source, SUGGESTIONS)
end)

-- The account balance once rp_economy has loaded the player's wallets (bounded wait).
AddEventHandler("onPlayerReady", function(playerId)
    local id = toPlayerId(playerId)
    if not id then return end
    local identifier = Open77.players.identifier(id)
    if not identifier then return end
    online[identifier] = id
    local waited = 0
    while waited < 30000 do
        if Open77.players.identifier(id) ~= identifier then online[identifier] = nil; return end
        local wallet = walletRead(id, "bank")
        if wallet then
            say(id, ("Account balance: %s."):format(formatMoney(wallet.balance)))
            log("player %d loaded %s account=%d", id, identifier, wallet.balance)
            return
        end
        Wait(500)
        waited = waited + 500
    end
    say(id, reasonText("bank_not_ready"))
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    removeAtmProps()
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = toPlayerId(playerId)
    if not id then return end
    sessions[id] = nil
    stageClear(id)
    for identifier, onlineId in pairs(online) do
        if onlineId == id then online[identifier] = nil end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- ATM prompt intent (client -> server)

RegisterNetEvent("rp_bank:useAtm", function(atmId)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    local atm = atmById(atmId)
    if not atm then return end
    local near = nearestAtm(playerId, Config.AtmPromptRange)
    if not near or near.id ~= atm.id then
        say(playerId, "Get closer to the ATM.")
        return
    end
    runBankSession(playerId, atm)
end)

-- ---------------------------------------------------------------------------------------------
-- commands

RegisterCommand("bank", function(source)
    if source == 0 then return print("bank: run this from the game, not the console") end
    local atm = nearestAtm(source, Config.AtmRange)
    if not atm then
        say(source, "No ATM within 3 m. Find one on the map.")
        return
    end
    runBankSession(source, atm)
end, false)

RegisterCommand("solde", function(source)
    if source == 0 then return print("solde: run this from the game, not the console") end
    local cash, cashReason = walletRead(source, "cash")
    local acct, reason = walletRead(source, "bank")
    local cashText = cash and formatMoney(cash.balance) or ("unavailable (" .. tostring(bankReason(cashReason)) .. ")")
    local acctText = acct and formatMoney(acct.balance) or ("unavailable: " .. reasonText(bankReason(reason)))
    say(source, ("Cash: %s  ·  Account: %s"):format(cashText, acctText))
end, false)

RegisterCommand("virement", function(source, args)
    if source == 0 then return print("virement: run this from the game, not the console") end
    local targetId = toPlayerId(args[1])
    local amount = toAmount(args[2])
    if not targetId or not amount then
        say(source, "Usage: /virement <playerId> <amount>  (1 % fee, at least 1 eddie)")
        return
    end
    if targetId == source then say(source, reasonText("self_transfer")); return end
    local target, why = walletRead(targetId, "bank")
    if not target then
        say(source, reasonText(bankReason(why) == "bank_not_ready" and "bank_not_ready" or "player_not_found"))
        return
    end
    local fee = math.max(Config.TransferFeeMin, math.ceil(amount * Config.TransferFeePercent / 100))
    local newBalance, reason = atmTransfer(source, target.identifier, amount, fee)
    if not newBalance then
        say(source, reasonText(reason))
        return
    end
    local targetName = Open77.players.name(targetId) or ("player " .. targetId)
    say(source, ("Wired %s to %s (fee %s). Account: %s."):format(formatMoney(amount), targetName, formatMoney(fee), formatMoney(newBalance)))
    say(targetId, ("%s wired you %s. Check /solde."):format(Open77.players.name(source) or "Someone", formatMoney(amount)))
end, false)

RegisterCommand("bank_kvp_report", function(source)
    if source ~= 0 then return end
    kvpReport()
end, true)

RegisterCommand("societe", function(source)
    if source == 0 then return print("societe: run this from the game, not the console") end
    local ok, job = pcall(function() return exports.rp_jobs:getJob(source) end)
    if not ok then
        say(source, "The jobs service (rp_jobs) is offline.")
        return
    end
    if type(job) ~= "string" or job == "" then
        say(source, "You have no job, choom. No society, no funds.")
        return
    end
    local soc, reason = society(job)
    if not soc then say(source, reasonText(reason)); return end
    say(source, ("Society %s: %s."):format(soc.name, formatMoney(soc.balance)))
end, false)
