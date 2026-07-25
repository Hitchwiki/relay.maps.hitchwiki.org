# relay.maps.hitchwiki.org — Claude Code Guide

This is a **Nostr relay** (`scsibug/nostr-rs-relay`) serving as the central data store for hitchhiking ride notes at maps.hitchwiki.org.

Directory: `/var/www/relay.maps.hitchwiki.org` · Container: `relaymapshitchwikiorg-relay-1` (project `relaymapshitchwikiorg`, pinned in `docker-compose.yml`).

> Note: the public hostname **`relay.nomadwiki.org`** is a *separate, empty* strfry relay
> (`nostr-relay:7777`), not this one. This relay is exposed publicly at
> **`wss://relay.maps.hitchwiki.org`** and reachable inside the docker network at
> **`ws://relay.maps.hitchwiki.org:8080`** on the shared `hitchwiki-relay` network (the
> docker service name `relay` also resolves).

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
| Events | 75,514 (all kind 36820) |
| Tags | 921,967 |
| Distinct authors | 4 |
| Date range | 2026-03-26 → 2026-07-25 |

Authors are bulk importers, not individual users:

| Pubkey (hex, truncated) | Events |
|---|---:|
| `d17ff51bfc32d492…c5c5dbd5` | 59,089 |
| `6623bb9cbae2220e…8d4d142e` | 16,422 |
| `5dad78398a36eceb…f4b65a9f` | 2 |
| `2ab69bdb1b54a7c9…bec7e22bb` | 1 |

### Data sources

Both the `d` tag and the inner JSON `source` field encode the origin app. Counts by `d`-tag prefix:

| `d` tag prefix | Count |
|---|---:|
| `hitchwiki.org-<uuid>` | 42,469 |
| `hitchmap.com-<uuid>` | 25,356 |
| `liftershalte.info-<uuid>` | 8,251 |
| `maps.hitchwiki.org-<uuid>` | 962 |

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

> **Known inconsistency:** `config.toml` still advertises `relay_url = "wss://relay.nomadwiki.org/"`
> and a matching `description`, so the relay reports the wrong identity over NIP-11 despite being
> served at `relay.maps.hitchwiki.org`. `README.md` is titled `relay.nomadwiki.org` for the same
> reason. Neither has been corrected yet.

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
