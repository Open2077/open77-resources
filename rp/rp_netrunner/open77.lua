-- rp_netrunner: the netrunner job of a Night City RP server. Breach contracts posted by a fixer
-- (a player, the NPC board or another resource), taken on a board, run as a timed breach at a real
-- terminal, paid on delivery of the data shard; and the quickhacks (ping, Short Circuit, Overheat,
-- NCPD radio jammer). Built on the job libraries: open77_actions (prompts, claims, animation, the
-- breach bar, eligibility and epoch guards), open77_transactions (the board, the shard, the kit,
-- every quickhack), Open77.playerInteractions (the consented hand-over to a player fixer),
-- rp_jobs (netrunner and fixer duty, grade), rp_inventory (item definitions), rp_economy (the
-- delivery sale with the fixer's cut) and rp_ncpd (the trace).
resource "rp_netrunner"
version "2.0.0"
open77_version "*"

-- Opt-in: it needs open77_transactions and open77_actions, which an operator lists and starts.
auto_start false

-- This manifest ships a client script, so it may only depend on resources that ship a client half
-- too. open77_transactions, open77_actions, rp_jobs, rp_inventory, rp_economy and rp_ncpd are
-- server-only: they are reached through exports and waited for at boot (never declared here).
dependency "open77_uikit >=1.0.0"           -- the contract board (server twins context / alert / input)
dependency "open77_contextmenu"             -- ALT+click quickhacks and the hand-over (client)
-- open77_player_interactions (the hand-over to a player fixer) is optional: without it the
-- hand-over answers interactions_unavailable and the drop at the fixer point still pays.

-- Least privilege, native by native (wiki/data/api.json):
permissions {
    -- server
    "network.events",               -- RegisterNetEvent / TriggerClientEvent (ping pins, duty), Open77.notifications.send
    "players.hacking.define",       -- Open77.hacking.define (the deck's Short Circuit / Overheat grades)
    "players.hacking.read",         -- Open77.hacking.state (gates shown by /netrun)
    "players.hacking.activate",     -- Open77.hacking.start (the warned, interruptible upload)
    "players.cyberware.define",     -- Open77.cyberware.define (the operating_system implant)
    "players.cyberware.read",       -- Open77.cyberware.current (which grade the deck holds)
    "players.cyberware.manage",     -- Open77.cyberware.install / newOperationId (loading a grade)
    "players.life.read",            -- Open77.players.isDead (no netrunning from the floor)
    "players.interactions.control", -- Open77.playerInteractions.request / cancel (the hand-over)
    "players.interactions.read",    -- Open77.playerInteractions.get (a lost hand-over from a live one)
    "players.wanted",               -- Open77.players.setWanted (the native heat of a trace)
    "players.wanted.read",          -- Open77.players.getWanted (never lower someone else's heat)
    -- client
    "ui.vanilla.map",               -- Open77.blips.create / setPosition / remove (the ping pin)
}

shared_script "shared/config.lua"
server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/quickhacks.lua",
    "server/main.lua",
}
client_script "client/main.lua"
