Lives in Hitchwiki server /var/www/relay.maps.hitchwiki.org

# relay.maps.hitchwiki.org

This is the central Nostr relay for [maps.hitchwiki.org](https://maps.hitchwiki.org).

It is the primary data store for hitchhiking ride notes submitted through the Hitchwiki Maps application. The maps application depends on this relay — if the relay is down or data is lost, ride notes will be unavailable.

Public URL: `wss://relay.maps.hitchwiki.org/` (via Caddy). Inside the shared `hitchwiki-relay` docker network it is reachable at `ws://relay.maps.hitchwiki.org:8080`.

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

## Daily hitchmap.com import

New hitchmap.com rides are imported every night at 06:15 (Europe/Berlin) by
`./import-hitchmap-daily.sh`, which logs to `./import-hitchmap-daily.log` (gitignored).

The importer is **not part of this repo** — it lives in
[Hitchwiki/hitchhiking-data-standard](https://github.com/Hitchwiki/hitchhiking-data-standard)
and must be cloned *into this directory* as `hitchhiking-data-standard/`. That path is
gitignored here, so a fresh checkout of this repo will not have it and the import will
fail until you set it up:

```sh
cd /var/www/relay.maps.hitchwiki.org
git clone https://github.com/Hitchwiki/hitchhiking-data-standard.git

cd hitchhiking-data-standard/nostr
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

cp example.env .env   # then fill in NSEC — the key the imported events are signed with
```

The wrapper expects exactly this layout (`hitchhiking-data-standard/nostr/.venv/bin/python3`
running `publish_hitchmap_with_nicknames.py`); the paths are hardcoded in
`import-hitchmap-daily.sh`.

```sh
sudo ./import-hitchmap-daily.sh                       # manual run
tail -30 import-hitchmap-daily.log                    # log

cd hitchhiking-data-standard/nostr && \
  .venv/bin/python3 publish_hitchmap_with_nicknames.py --dry-run   # preview only
```

Notes:

- Must run as **root** — `data/` is owned by the container uid (100:100). The script writes
  to `data/nostr.db` directly rather than over the websocket, so it must run on this host
  and the `event_kind_allowlist` does not apply to it.
- Incremental and safe to re-run: the cutoff is the newest hitchmap.com `submission_time`
  already in the relay, so nothing is duplicated.
- "Nothing to publish" (script exit 1) is the normal no-op when the relay is up to date;
  the wrapper still exits 0 so cron stays quiet.

## Stack

- Software: [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay)
- Database: SQLite (`./data/nostr.db`)
- Deployed via Docker Compose (`docker-compose.yml`)

See `CLAUDE.md` for database schema, query patterns, and operational gotchas.
