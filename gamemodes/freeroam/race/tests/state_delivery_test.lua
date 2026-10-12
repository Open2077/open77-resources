-- Run after server/state_delivery.lua; no Open77 host or live server required.
local calls, statuses, nextStream, refuse, refuseLatent = {}, {}, 0, false, false
local function cache(extra)
    local options = {
        ordinaryLimit = 20,
        send = function(player, payload)
            calls[#calls + 1] = { player = player, payload = payload, latent = false }
            if refuse then return false, "backpressure" end
            return true
        end,
        sendLatent = function(player, payload)
            calls[#calls + 1] = { player = player, payload = payload, latent = true }
            if refuseLatent then return nil, "stream_limit" end
            nextStream = nextStream + 1
            statuses[nextStream] = { state = "sending" }
            return nextStream
        end,
        latentStatus = function(stream) return statuses[stream] end,
    }
    for key, value in pairs(extra or {}) do options[key] = value end
    return RaceStateDelivery.new(options)
end

local delivery = cache()
local function send(player, encoded, force)
    return delivery.send(player, { encoded = encoded }, encoded, force)
end
assert(send(1, "idle"))
assert(#calls == 1 and calls[1].player == 1)
for _ = 1, 40 do assert(send(1, "idle")) end
assert(#calls == 1, "ten seconds of identical 4Hz state must not send duplicates")
local accepted, why = send(1, "idle")
assert(accepted and why == "unchanged")
for _ = 1, 3 do assert(send(1, "idle", true)) end
assert(#calls == 4, "ready/request/open must force a baseline")
assert(send(2, "idle") and #calls == 5, "each recipient needs its own baseline")
assert(send(1, "not_ready") and #calls == 6, "polled eligibility changes must send")
refuse = true
accepted, why = send(1, "ready_again")
assert(not accepted and why == "backpressure")
local before = #calls
refuse = false
assert(send(1, "ready_again") and #calls == before + 1, "refusal cannot update the cache")
assert(send(1, "ready_again") and #calls == before + 1)
delivery.forget(1)
assert(send(1, "ready_again") and #calls == before + 2, "rejoin needs a baseline")
assert(send(2, "idle") and #calls == before + 2, "disconnect must not reset other peers")
delivery.clear()
assert(delivery.inspect().entries == 0 and delivery.inspect().bytes == 0)
assert(send(2, "idle") and #calls == before + 3, "resource reset needs a baseline")

-- Large states are not suppressed or acknowledged merely because a stream ID
-- was admitted. Older streams can complete after newer ordinary states.
local large = string.rep("x", 21)
assert(send(2, large)); local first = nextStream
assert(send(2, large)); local second = nextStream
assert(delivery.hasPending(2) and not delivery.hasPending(1))
before = #calls
assert(send(2, "idle") and send(2, "idle"))
assert(#calls == before + 2 and delivery.inspect().entries == 0)
statuses[first].state = "completed"
assert(delivery.hasPending(2), "the other old stream still needs repair")
assert(send(2, "idle") and delivery.inspect().entries == 0)
statuses[second].state = "completed"
assert(not delivery.hasPending(2), "a current baseline may now be retained")
before = #calls
assert(send(2, "idle") and #calls == before + 1, "refresh after all old streams finish")
assert(send(2, "idle") and #calls == before + 1)
refuseLatent = true
accepted, why = send(2, large)
assert(not accepted and why == "stream_limit")
refuseLatent = false
before = #calls
assert(send(2, large) and #calls == before + 1, "latent refusal remains retryable")
statuses[nextStream] = nil -- runtime prunes only finished history
assert(send(2, "idle") and delivery.inspect().entries == 1)
assert(delivery.inspect().streams == 0)

-- Both entry count and retained JSON bytes are bounded; saturation only
-- disables deduplication for uncached states, never their delivery.
delivery = cache({ maxEntries = 2, maxBytes = 10, ordinaryLimit = 100 })
assert(send(1, "1234") and send(2, "123456"))
assert(delivery.inspect().entries == 2 and delivery.inspect().bytes == 10)
before = #calls
assert(send(3, "1") and send(3, "1"))
assert(#calls == before + 2 and delivery.inspect().bytes == 10)
assert(send(1, "12345678901"))
assert(delivery.inspect().entries == 1 and delivery.inspect().bytes == 6)
assert(send(3, "1234") and delivery.inspect().bytes == 10)
delivery.forget(2)
assert(delivery.inspect().bytes == 4 and delivery.inspect().entries == 1)

delivery = cache({ maxStreams = 2 })
assert(send(1, large)); first = nextStream
assert(send(2, large)); second = nextStream
before = #calls
accepted, why = send(3, large)
assert(not accepted and why == "stream_limit" and #calls == before)
statuses[first].state = "cancelled"
assert(send(3, large) and delivery.inspect().streams == 2)
delivery.forget(2)
assert(delivery.inspect().streams == 1)
delivery.clear()
assert(delivery.inspect().streams == 0)
print("Race state delivery: duplicate/forced/retry/recipient/lifecycle/bounds/latent cases passed")
