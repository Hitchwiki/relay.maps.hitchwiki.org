Lives in Hitchwiki server /var/www/relay.maps.hitchwiki.org

# relay.maps.hitchwiki.org

This is the central Nostr relay for [maps.hitchwiki.org](https://maps.hitchwiki.org).

It is the primary data store for hitchhiking ride notes submitted through the Hitchwiki Maps application. The maps application depends on this relay — if the relay is down or data is lost, ride notes will be unavailable.

Public URL: `wss://relay.maps.hitchwiki.org/` (via Caddy). Inside the shared `hitchwiki-relay` docker network it is reachable at `ws://relay.maps.hitchwiki.org:8080`.

> Not to be confused with **relay.nomadwiki.org**, which is a separate, empty strfry relay.

## Contents

The relay stores **only kind 36820** (hitchhiking ride notes). Since 2026-07-25 an `event_kind_allowlist` in `config.toml` discards every other kind — including kind 0 (profiles) and kind 5 (deletion requests), so events can no longer be deleted over the wire.

## Scripts

- `./stats.sh` — show statistics about events currently held on the relay
- `./delete-kind-36820.sh` — delete all events of kind 36820, with a confirmation prompt. **This now wipes the entire dataset**, since kind 36820 is all that remains. It also leaves orphaned `tag` rows behind (see CLAUDE.md on `PRAGMA foreign_keys`).

## Running

```sh
docker compose up -d  # project name pinned in docker-compose.yml (name: relaymapshitchwikiorg)
```

This names the container `relaymapshitchwikiorg-relay-1` (project relaymapshitchwikiorg).

Restart after editing `config.toml`, then confirm `listening on: 0.0.0.0:8080` in `docker compose logs` — a malformed config stops the container from starting.

## Stack

- Software: [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay)
- Database: SQLite (`./data/nostr.db`)
- Deployed via Docker Compose (`docker-compose.yml`)

See `CLAUDE.md` for database schema, query patterns, and operational gotchas.
