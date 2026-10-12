-- =============================================================================
-- open77_media -- server/config.lua
-- =============================================================================
-- The operator-editable half of the television feature: what the ad blocklist
-- starts as, and where an operator's changes are kept.
--
-- -----------------------------------------------------------------------------
-- THE SEED, NOT A LAYER
-- -----------------------------------------------------------------------------
-- The live list has exactly one owner at a time:
--
--   * `data/adblock.json` once anything has been changed -- by `media.adblock.*`
--     or by hand -- because that is where a server that has been told something
--     keeps it;
--   * the `hosts` / `tokens` keys below until then, which is what a fresh
--     install reads so a network can ship a default list to a whole fleet by
--     editing this file in the resource.
--
-- It is deliberately NOT a second layer added on top of the stored list. Two
-- lists that both apply is a state where removing a rule appears to do nothing
-- because the rule is still in the file you forgot about, and an operator
-- debugging that has no way to see which of the two is winning without reading
-- the resource's own source.
--
-- So: to change a live server, use the commands, or edit `data/adblock.json` and
-- run `media.adblock.reload`. To change what a NEW server starts with, edit this
-- file. `media.adblock.reload` re-reads the store, never this file, which is why
-- the two never argue.
--
-- -----------------------------------------------------------------------------
-- WHAT THE RULES MAY BE
-- -----------------------------------------------------------------------------
--   * a HOST rule covers that host and its subdomains: `ads.example.com` refuses
--     `ads.example.com` and `cdn.ads.example.com`, and nothing that merely ends
--     with those characters (`notads.example.com` and
--     `ads.example.com.evil.test` both still load).
--   * a TOKEN rule matches anywhere inside a host, which is how a campaign that
--     rotates through fresh domains faster than a list can be written is caught:
--     the token `popads` refuses `popads-delivery-7.anything.test`.
--
-- A rule is refused -- with a reason, at the console, when you type it -- if it
-- is a registry rather than a company (`com`, `co.uk`), if it contains anything
-- other than letters, digits, dots and inner hyphens, or if a token would match
-- the whole internet. `server/adblock.lua` is the grammar and the refusals; it is
-- the file to read before arguing with one.
--
-- -----------------------------------------------------------------------------
-- AND WHAT A CLIENT DOES WITH THEM
-- -----------------------------------------------------------------------------
-- The rules are pushed to each client, which hands them to the process that
-- enforces them. That layer only ever ADDS to the blocklist compiled into the
-- client -- nothing here can unblock something the build refuses, which is the
-- whole reason a server is allowed to push a list at all. A rule this file
-- accepts and that host refuses comes back on the receipt, named, with the
-- host's reason: `media.adblock.status` shows it.
-- =============================================================================

MediaServerConfig = {
    -- The layer as a whole. Off means nothing is read or pushed from here; the
    -- compiled list still protects every client, because that half is not this
    -- server's to turn off.
    enabled = true,

    -- Relative to the resource's own `data/` directory.
    dataFile = "adblock.json",

    -- The seed. One entry per line, quoted, exactly as an operator would type it
    -- at `media.adblock.add`. Empty by default: a server that has not been told
    -- anything should not be blocking anything, and every entry here is one an
    -- operator has to be able to explain.
    hosts = {
        -- "ads.example.com",
        -- "tracker.example.net",
    },

    -- The seed's token half. A token is matched anywhere inside a host, so these
    -- are the ones worth writing down: a network's own name, not a domain it
    -- happens to be using this month.
    tokens = {
        -- "popads",
    },
}
