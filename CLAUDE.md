# relay.maps.hitchwiki.org — Claude Code Guide

This is a **Nostr relay** (`scsibug/nostr-rs-relay`) serving as the central data store for hitchhiking ride notes at maps.hitchwiki.org.

Directory: `/var/www/relay.maps.hitchwiki.org` · Container: `relaymapshitchwikiorg-relay-1` (project `relaymapshitchwikiorg`, pinned in `docker-compose.yml`).

This relay is exposed publicly at **`wss://relay.maps.hitchwiki.org`** and reachable inside the
docker network at **`ws://relay.maps.hitchwiki.org:8080`** on the shared `hitchwiki-relay` network
(the docker service name `relay` also resolves).

## Single-kind relay

As of **2026-07-25** this relay stores **only kind 36820** (hitchhiking ride notes).

- All 52,888 events of other kinds were deleted (kinds 1, 34242, 30399, 4, 5, 0, and ~15 minor kinds), along with 663,188 of their tags.
- An `event_kind_allowlist` in `config.toml` now makes the relay **discard any incoming event that is not kind 36820**.
- A pre-purge backup exists at `data/nostr.db.bak-20260725` (907 MB). Delete it once you are confident the purge was correct — the host disk runs at ~95% capacity.

**Consequences of the allowlist worth remembering:**

- Kind **0** (profile metadata) is rejected — clients cannot publish or update profiles here.
- Kind **5** (deletion requests) is rejected — clients can no longer delete their own events over the wire. Removing events now requires direct SQL (see below).
- Kind **4 / 1059** (DMs) are rejected.

To relax this, edit `event_kind_allowlist` in `config.toml` and restart. A sensible looser set would be `[0, 5, 36820]`.

## Database

- **Engine:** SQLite 3.x
- **File on host:** `/var/www/relay.maps.hitchwiki.org/data/nostr.db` (~255 MB)
- **File inside container:** `/usr/src/app/db/nostr.db`

### Accessing the database

SQLite is not installed on the host. Use `docker exec` to run queries:

```bash
# Non-interactive query
docker exec relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db "SELECT count(*) FROM event;"

# Interactive shell
docker exec -it relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db

# Multi-statement scripts: pipe a file in (avoids shell quoting problems, see below)
docker exec -i relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db < query.sql
```

Built-in helper scripts:

```bash
# Database statistics (event counts by kind, unique authors, date range, per-source breakdown)
./stats.sh

# Delete all kind-36820 events (prompts for confirmation)
# WARNING: with the relay now single-kind, this wipes the ENTIRE dataset.
# It also does not clean up the tag table — see the foreign-key gotcha below.
./delete-kind-36820.sh
```

### ⚠️ Foreign keys are OFF in the sqlite3 CLI

`tag.event_id` has `ON DELETE CASCADE`, but **the `sqlite3` CLI does not enforce foreign keys by default** (`PRAGMA foreign_keys` defaults to off). Deleting from `event` via `docker exec … sqlite3` therefore leaves orphaned `tag` rows behind.

This already happened historically: a cleanup on 2026-07-25 removed **163,764 orphaned tag rows** accumulated by earlier CLI deletions. Those orphans also skewed tag-based statistics — a `d`-tag survey run before the cleanup over-reported `hitchmap.com-*` by roughly 13,600.

**Always start a deletion script with:**

```sql
PRAGMA foreign_keys=ON;
```

…or delete the tags explicitly first:

```sql
DELETE FROM tag WHERE event_id IN (SELECT id FROM event WHERE <predicate>);
DELETE FROM event WHERE <predicate>;
```

Verify afterwards:

```sql
SELECT count(*) FROM tag t LEFT JOIN event e ON e.id = t.event_id WHERE e.id IS NULL;
```

Reclaim disk space after a large delete with `VACUUM;` (needs temporary free space roughly equal to the database size).

### Schema

#### `event` (~75.5k rows)
Primary table. One row per Nostr event.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | Internal row ID |
| `event_hash` | BLOB | 4-byte hash of the event |
| `first_seen` | INTEGER | Unix timestamp when relay received it |
| `created_at` | INTEGER | Unix timestamp set by the author |
| `expires_at` | INTEGER | Optional expiry (NIP-40) — currently unused, all NULL |
| `author` | BLOB | Author pubkey |
| `delegated_by` | BLOB | Delegator pubkey (NIP-26), nullable |
| `kind` | INTEGER | Nostr event kind — always 36820 now |
| `hidden` | INTEGER | Soft-hide flag used in queries (1 row currently set) |
| `content` | TEXT | Full serialized JSON of the event object |

Key indexes: `event_hash` (unique), `author`, `kind`, `created_at`, composite indexes on `(kind, created_at)`, `(author, kind)`, `(author, created_at)`, `expires_at`.

#### `tag` (~922k rows)
Tags associated with events (one row per tag entry). No orphans as of 2026-07-25.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `event_id` | INTEGER FK | References `event(id)`, cascades on delete (**but see the FK warning above**) |
| `name` | TEXT | Only `g`, `d`, `published_at` remain after the purge |
| `value` | TEXT | Tag value when not hex |
| `value_hex` | BLOB | Tag value when lowercase hex |
| `created_at` | INTEGER | Copied from the parent event |
| `kind` | INTEGER | Copied from the parent event |

Tag distribution:

| Name | Rows | Notes |
|---|---:|---|
| `g` | 770,380 | Geohash, 10 rows per event (nested precision levels) |
| `d` | 77,038 | Replaceable-event identifier; 1,247 events carry more than one |
| `published_at` | 74,549 | Not present on every event |

Key indexes: `tag_val_index` (value), `tag_composite_index` (event_id, name, value), `tag_name_eid_index` (name, event_id, value), `tag_covering_index` (name, kind, value, created_at, event_id).

#### `user_verification`, `account`, `invoice` (all empty)
NIP-05 verification, pay-to-relay accounts, and payment invoices. All three features are disabled in `config.toml`, so these tables stay empty. Schema retained by `nostr-rs-relay` migrations (DB version 18).

### Current contents

| Metric | Value |
|---|---|
| Events | 80,097 (all kind 36820) |
| Tags | 976,295 |
| Distinct authors | 3 |
| Date range | 2026-03-26 → 2026-08-12 |

Authors are bulk importers, not individual users:

| Pubkey (hex, truncated) | Events |
|---|---:|
| `6623bb9cbae2220e…8d4d142e` | 80,094 |
| `5dad78398a36eceb…f4b65a9f` | 2 |
| `2ab69bdb1b54a7c9…bec7e22bb` | 1 |

### Data sources

Both the `d` tag and the inner JSON `source` field encode the origin app. Counts by `d`-tag prefix:

| `d` tag prefix | Count |
|---|---:|
| `hitchwiki.org-<uuid>` | 42,466 |
| `hitchmap.com-<uuid>` | 29,404 |
| `liftershalte.info-<uuid>` | 8,251 |
| `maps.hitchwiki.org-<uuid>` | 1,496 |

### Content field structure (kind-36820)

The `content` column holds the **full Nostr event JSON**. For kind-36820, the Nostr event's own `content` field is a **nested JSON string** (with backslash-escaped quotes), e.g.:

```
{"id":"...","kind":36820,...,"content":"{\"version\":\"0.0.0\",\"stops\":[...],\"rating\":4,\"comment\":\"...\",\"source\":\"maps.hitchwiki.org\",\"license\":\"xxx\"}","sig":"..."}
```

Key fields inside the inner JSON:
- `source` — origin app (e.g. `hitchwiki.org`, `hitchmap.com`, `liftershalte.info`, `maps.hitchwiki.org`)
- `comment` — user-supplied ride note
- `rating` — integer 1–5
- `hitchhikers` — array with `nickname`, `gender`, etc.
- `stops` — array of locations with lat/lon

Because the inner JSON is escaped inside the outer string, the literal stored text is `comment\":\"…\",`. Two consequences:

1. **Plain `LIKE '%comment%'` works**, but matching a *value* needs the escaped form: `LIKE '%comment\":\"test\"%'`.
2. **Use single-quoted SQL strings.** SQLite treats `"…"` as an identifier and does not honour `\` escapes inside it, so a double-quoted pattern containing `\"` fails to parse. Piping a `.sql` file via `docker exec -i` avoids shell-quoting problems entirely.

Extracting the comment value:

```sql
SELECT substr(substr(content, instr(content,'comment\":\"')+12), 1,
              instr(substr(content, instr(content,'comment\":\"')+12), '\",') - 1) AS comment
FROM event
WHERE instr(content,'comment\":\"') > 0;
```

Note the offset `+12` — the marker `comment\":\"` is 12 characters, not 9.

`json_extract` also works for the outer layer, and nests for the inner one (this is what `stats.sh` uses):

```sql
SELECT json_extract(json_extract(content, '$.content'), '$.source') FROM event LIMIT 5;
```

### Useful query patterns

```sql
-- Count events by kind
SELECT kind, count(*) AS n FROM event GROUP BY kind ORDER BY n DESC;

-- Recent events
SELECT id, created_at, content FROM event ORDER BY created_at DESC LIMIT 10;

-- Tags for a specific event
SELECT name, value FROM tag WHERE event_id = <id>;

-- Events by a specific author (pubkey as hex)
SELECT id, kind, created_at FROM event WHERE author = X'<hex_pubkey>';

-- Breakdown by source
SELECT CASE
         WHEN value LIKE 'hitchwiki.org-%'        THEN 'hitchwiki.org'
         WHEN value LIKE 'hitchmap.com-%'         THEN 'hitchmap.com'
         WHEN value LIKE 'liftershalte.info-%'    THEN 'liftershalte.info'
         WHEN value LIKE 'maps.hitchwiki.org-%'   THEN 'maps.hitchwiki.org'
         ELSE 'other' END AS source,
       count(*)
FROM tag WHERE name='d' GROUP BY 1 ORDER BY 2 DESC;
```

### Useful DELETE patterns

```sql
-- Delete ride notes whose comment is exactly "test" (any capitalisation)
PRAGMA foreign_keys=ON;
BEGIN;
DELETE FROM event
WHERE kind=36820
  AND lower(content) LIKE '%comment\":\"test\"%';
COMMIT;
```

Beware over-broad patterns: `LIKE '%test%'` matches legitimate notes ("Tested in the evening…"), and a bare `%bar%` matches Barcelona, Bardejov, and barfleur. Always `SELECT` the matches first.

## Configuration

- **File:** `config.toml`
- **Public URL:** `wss://relay.maps.hitchwiki.org/` (via Caddy, grey-cloud DNS + own Let's Encrypt cert)
- **Internal URL:** `ws://relay.maps.hitchwiki.org:8080` (docker network alias on `hitchwiki-relay`; service name `relay:8080` also works)
- **Port:** 7000 on host → 8080 in container
- **Event kind allowlist:** `[36820]` — everything else is discarded
- **Future event rejection:** events >1800 s in the future are rejected
- **Authorization / pay-to-relay / NIP-05 verification:** all disabled

Everything else in `config.toml` is commented out and runs on `nostr-rs-relay` defaults.

## Daily hitchmap.com import

New hitchmap.com rides are pulled in every night by `./import-hitchmap-daily.sh`, a wrapper around
`hitchhiking-data-standard/nostr/publish_hitchmap_with_nicknames.py`. That script
downloads `https://hitchmap.com/dump.sqlite`, reads the newest hitchmap.com `submission_time`
already in `data/nostr.db` as its cutoff, and writes only the rides submitted after it — so
re-running never duplicates. It writes to the SQLite file directly (not over the websocket), which
is why it has to run on this host, as root (`data/` is owned by uid `100`).

```bash
# Manual run
sudo ./import-hitchmap-daily.sh

# See what would be imported without writing
cd hitchhiking-data-standard/nostr && .venv/bin/python3 publish_hitchmap_with_nicknames.py --dry-run

# Log
sudo tail -30 /var/log/hitchmap-import.log
```

Cron (in the `hitchwiki` crontab, `CRON_TZ=Europe/Berlin`):

```
15 6 * * * /usr/bin/sudo -n /var/www/relay.maps.hitchwiki.org/import-hitchmap-daily.sh
```

Notes:

- `flock` on `/var/lock/hitchmap-import.lock` keeps runs from overlapping; the log is trimmed to
  the last 2000 lines once it passes 5 MB.
- The 60 MB `dump.sqlite` is re-downloaded into `hitchhiking-data-standard/nostr/` on every run
  (replaced, not accumulated) and chowned back to `hitchwiki:hitchwiki` afterwards.

### Exit codes

The Python script's exit code says what happened, and the wrapper passes anything unhealthy on to
cron instead of swallowing it:

| Code | Meaning | Wrapper |
|---:|---|---|
| 0 | rides published, relay database verified afterwards | exits 0 |
| 1 | nothing to publish, the relay is up to date — the normal no-op | exits 0, cron stays quiet |
| 2 | no usable `dump.sqlite` could be downloaded, nothing was published | exits 2 + message on stderr |
| 3 | relay database not writable, or the batch did not land intact | exits 3 + message on stderr |
- Rides without a `submission_time` in the dump are never imported — they cannot be placed
  relative to the cutoff.
- The import bypasses the relay process, so the `event_kind_allowlist` does not apply to it.

### Duplicate filtering

hitchmap.com stores some submissions several times over: a double-clicked or retried submit writes
two or more `points` rows that are identical apart from their `id` and a sub-second difference in
`datetime`. The dump currently holds ~120 such clusters. Publishing them unchanged had put **119
redundant ride notes** in the relay; they were deleted on **2026-08-12** (backup:
`data/nostr.db.bak-20260812-predupclean`).

`publish_hitchmap_with_nicknames.py` now filters them out before publishing. Two rides are the same
ride when

- position (rounded to 7 decimals, ~1 cm), comment, ride time, rating and nickname all match, **and**
- their submission times are within `DUP_WINDOW_S` (300 s) of each other.

The check runs twice: against the rides already in the relay (so an overlapping `--since`, or a
cutoff that moved backwards, cannot re-import anything) and within the batch itself. The earliest
submission of a cluster is the one kept. Both counts are printed on every run:

```
Dropped 12 rides duplicated inside the dump and 3932 already published; 525 left to publish
```

Two caveats:

- The filter lives in the import path only. Events pushed **over the websocket** by clients are not
  deduplicated, so live submissions can still land twice.
- Rides that appear in the dump with a `submission_time` older than the relay's current maximum are
  skipped by the cutoff and never picked up again. As of 2026-08-12 that gap is ~540 rides submitted
  in late July / August. Now that the importer dedupes against the relay, the cutoff could safely be
  backdated a few days to catch them.

### Integrity checks

On **2026-08-12** the download produced a 19 MB `dump.sqlite` holding nothing but the `points`
table, and the run died on `select … from user` — after it had already replaced the previous dump.
Both ends of the import are now checked.

**The dump, before it is used.** It is fetched to `dump.sqlite.part` and only moved into place once
it passes: at least 40 MB, `PRAGMA quick_check` = `ok`, `points` and `user` both present, `points`
carrying every column the import reads, at least 60,000 points, and at least one submission time. A
failed download is retried up to three times; if none succeeds the script exits **2** without
publishing and **leaves the previous dump untouched**. A dump that shrank more than 5 % since the
last run is logged as a warning, not an error — bans and deletions legitimately shrink it.

**The relay database, around the write.** The import writes `event` and `tag` rows itself rather
than going through the relay process, so a half-written batch would otherwise pass unnoticed:

- Before building anything, a write is attempted and rolled back. `mode=rw` alone is not enough —
  SQLite opens an unwritable file read-only and only complains on the first real write. Running the
  import as a non-root user now fails immediately with exit **3** instead of printing one error per
  record.
- Afterwards, `event` must have grown by exactly the number of records published, `tag` by exactly
  12 per event (one `d`, ten `g`, one `published_at`), and no new orphaned tags may have appeared.
  Any mismatch is printed and exits **3**.

All of this was exercised against deliberately broken dumps (truncated at 19 MB and 45 MB, random
bytes, valid SQLite with no dump tables, `user` dropped, only 11k points, and a URL that 404s), a
read-only relay database, and a real 57-ride publish into a copy of the live database.

## Docker

```bash
# Check status
docker compose ps

# View logs
docker compose logs -f

# Restart relay (required after editing config.toml)
docker compose restart

# Bring down / up
docker compose down
docker compose up -d
```

Container name: `relaymapshitchwikiorg-relay-1`. The container runs as uid/gid `100:100`, so `data/` is **not writable by the host user** — create backups from inside the container:

```bash
docker exec relaymapshitchwikiorg-relay-1 \
  sh -c 'sqlite3 /usr/src/app/db/nostr.db ".backup /usr/src/app/db/nostr.db.bak-$(date +%Y%m%d)"'
```

A bad `config.toml` makes the container fail to start, so always check `docker compose logs` after a restart and confirm `listening on: 0.0.0.0:8080`.

## Git

Versioned at `github.com/Hitchwiki/relay.maps.hitchwiki.org` (private), branch `main`.

Pushes use a dedicated deploy key with an SSH alias in `~/.ssh/config`:

```
Host github.com-relay-maps-hitchwiki
	HostName github.com
	User git
	IdentityFile ~/.ssh/relay-maps-hitchwiki-deploy-key
	IdentitiesOnly yes
```

Remote: `git@github.com-relay-maps-hitchwiki:Hitchwiki/relay.maps.hitchwiki.org.git`

`data/` (live database and backups) and `hitchhiking-data-standard/` (a separate checkout of `github.com/Hitchwiki/hitchhiking-data-standard`) are excluded via `.gitignore`.

> The shell environment sets `GIT_ASKPASS` to a VS Code helper whose socket is usually dead,
> which breaks HTTPS git operations with a confusing `ECONNREFUSED` error. SSH is unaffected.
