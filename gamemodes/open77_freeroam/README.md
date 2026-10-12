# open77_freeroam

This resource saves players to your own MySQL database and adds `kick`, `ban` and `makeadmin` commands for the Freeroam template. It is also the reference for how a gamemode's persistence layer talks to the owner's database.

- **Docs:** [Configure a SQL database](https://open2077.net/docs/database)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server

## Use it

The Night City Freeroam template installs it next to [freeroam](../freeroam/). To load it by hand, add `open77_freeroam` to `resources.load`. Turn persistence on by setting `database.enabled` and `database.connectionString` in `server.jsonc`; without them the resource still runs and `kick` still works.

From the server console, run `makeadmin <playerId>` to add an online player to the `admin_groups` table. `kick <playerId> [reason]` and `ban <playerId> [reason]` work from the console, and in game for an admin who also holds the `command.kick` or `command.ban` ACL entry, because the commands are registered as restricted.

## About this resource

It is the reference **server-owner database** resource: MySQL-backed player
persistence and admin moderation for the freeroam template. It shows the
intended shape of an Open77 gamemode's persistence layer against the
owner's *own* MySQL (the oxmysql-style `MySQL` bridge, gated by the
`database.access` permission), separate from the platform master DB.

## What it does

- **Player rows keyed by `GetPlayerIdentifier()`**: the master-backed
  GUID, cryptographically bound to the client's identity certificate, so
  persistence follows the real identity, not a name.
- On `onPlayerConnected`: upsert the player row (identifier, name,
  first/last seen), and drop identities on the server's local ban list.
- On `onPlayerDisconnected`: accumulate playtime and save last position.
- **Admin moderation**: an `admin_groups` table drives console/admin-only
  `kick`, `ban` (adds to the local `bans` table + drops), and
  console-only `makeadmin` commands.

## Tables (created on first start)

`players` (identifier, name, money, playtime_ms, last_x/y/z, first/last
seen), `admin_groups` (identifier, role), `bans` (identifier, reason).

## Degrades gracefully

With no database configured, the resource still loads and runs. It logs
that persistence is disabled; `kick` still works. Enable persistence by
setting `database.enabled` + `database.connectionString` in
`server.jsonc`.

## Scope note

The `ban` command bans on **this owner's server**. A platform-wide ban
that blocks an identity from *every* server is issued through the master
and enforced at connect-ticket time; a future `Open77.players.ban()`
binding will forward a local ban there automatically.
