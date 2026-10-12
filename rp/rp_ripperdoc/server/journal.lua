-- rp_ripperdoc / server/journal.lua: the clinic's durable notebook (Open77.kvp, one JSON file under
-- this resource's data folder; no permission, no database).
--
-- It holds no value: money and implants live in the coordinator, implants in the patient's
-- cyberware record. It remembers which procedures were in flight, so a restart can reconcile the
-- two systems:
--
--   surgery:<id>   one row per accepted quote, written when the hold is placed, rewritten just
--                  BEFORE the implant is submitted (state `installing`), deleted when it ends
--   log            the last `logKept` finished procedures, newest first (/ripper reads it)
--
-- Every finished procedure is also a row of the 1.x SQL table `rp_ripperdoc_operations` when the
-- server has a database (the history operators already query; written fire-and-forget).
--
-- Global: RipperJournal.

RipperJournal = {}
local J = {}
J.__index = J

local PREFIX = "surgery:"

function RipperJournal.new(ports, config)
    return setmetatable({ P = ports, cfg = config, sql = "pending" }, J)
end

-- The SQL history: created once the database answers; without a database the KVP ring is the log.
function J:setupHistory()
    local queued, why = self.P.db.ready(function()
        local ok, err = pcall(self.P.db.update, [[
            CREATE TABLE IF NOT EXISTS rp_ripperdoc_operations (
                id           INT AUTO_INCREMENT PRIMARY KEY,
                ripper       VARCHAR(64)  NOT NULL,
                ripper_name  VARCHAR(64)  NOT NULL DEFAULT '',
                patient      VARCHAR(64)  NOT NULL,
                patient_name VARCHAR(64)  NOT NULL DEFAULT '',
                implant      VARCHAR(96)  NOT NULL,
                grade        VARCHAR(32)  NOT NULL DEFAULT '',
                action       VARCHAR(16)  NOT NULL,
                price        INT          NOT NULL DEFAULT 0,
                paid_via     VARCHAR(16)  NOT NULL DEFAULT '',
                `at`         BIGINT       NOT NULL,
                INDEX idx_ripper_at (ripper, `at`)
            )
        ]])
        self.sql = ok and "ready" or "off"
        self.P.log(ok and "history=sql table=rp_ripperdoc_operations" or ("history=kvp (" .. tostring(err) .. ")"))
    end)
    if not queued then
        self.sql = "off"
        self.P.log("history=kvp (" .. tostring(why) .. ")")
    end
end

function J:historyRow(entry)
    if self.sql ~= "ready" then return end
    self.P.db.insert(
        "INSERT INTO rp_ripperdoc_operations (ripper, ripper_name, patient, patient_name, implant, grade, action, price, paid_via, `at`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        { tostring(entry.ripper or ""):sub(1, 64), tostring(entry.ripperName or ""):sub(1, 64),
          tostring(entry.patient or ""):sub(1, 64), tostring(entry.patientName or ""):sub(1, 64),
          tostring(entry.definition or entry.key or ""):sub(1, 96), tostring(entry.grade or ""):sub(1, 32),
          tostring(entry.action or ""):sub(1, 16), math.floor(tonumber(entry.price) or 0),
          tostring(entry.how or ""):sub(1, 16), math.floor((tonumber(entry.at) or 0) / 1000) },
        function(id, err)
            if not id then self.P.log("history row not written: " .. tostring(err)) end
        end)
end

-- The fields a restart needs to settle a surgery, and nothing else.
function J:row(s)
    return {
        v = 1, id = s.id, state = s.state, clinic = s.clinic,
        ripperSubject = s.ripperSubject, patientSubject = s.patientSubject,
        ripperName = s.ripperName, patientName = s.patientName,
        action = s.proc.action, key = s.proc.key, grade = s.proc.grade, item = s.item,
        price = s.price, instrument = s.instrument, wallets = s.wallets, society = s.society, stock = s.stock,
        txOpId = s.txOpId, cwOpId = s.cwOpId, actionOpId = s.actionOpId,
        createdAt = s.createdAt, updatedAt = self.P.now(),
    }
end

function J:put(s)
    local text = self.P.json.encode(self:row(s))
    if not text then return nil, "journal_unavailable" end
    local ok, why = self.P.kvp.set(PREFIX .. s.id, text)
    if not ok then return nil, why or "journal_unavailable" end
    return true
end

function J:drop(id)
    if id then self.P.kvp.delete(PREFIX .. id) end
end

-- Every surgery row still open (a previous boot did not finish it).
function J:open()
    local out = {}
    for _, entry in ipairs(self.P.kvp.find(PREFIX, 500)) do
        local row = self.P.json.decode(entry.value)
        if type(row) == "table" and row.id then out[#out + 1] = row end
    end
    table.sort(out, function(a, b) return (a.createdAt or 0) < (b.createdAt or 0) end)
    return out
end

-- A finished procedure for /ripper (newest first, capped).
function J:append(entry)
    self:historyRow(entry)
    local list = self.P.json.decode(self.P.kvp.get("log")) or {}
    table.insert(list, 1, entry)
    while #list > (self.cfg.logKept or 100) do table.remove(list) end
    local text = self.P.json.encode(list)
    if text then self.P.kvp.set("log", text) end
end

function J:recent(clinic, sinceMs, limit)
    local out = {}
    for _, entry in ipairs(self.P.json.decode(self.P.kvp.get("log")) or {}) do
        if (clinic == nil or entry.clinic == clinic) and (tonumber(entry.at) or 0) >= sinceMs then
            out[#out + 1] = entry
            if limit and #out >= limit then break end
        end
    end
    return out
end

return J
