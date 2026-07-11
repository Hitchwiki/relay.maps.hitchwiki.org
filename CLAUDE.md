# relay.maps.hitchwiki.org — Claude Code Guide

This is a **Nostr relay** (`scsibug/nostr-rs-relay`) serving as the central data store for hitchhiking ride notes at maps.hitchwiki.org.

Directory: `/var/www/relay.maps.hitchwiki.org` · Container: `relaymapshitchwikiorg-relay-1` (project `relaymapshitchwikiorg`, pinned in `docker-compose.yml`).

> Note: the public hostname **`relay.nomadwiki.org`** is a *separate, empty* strfry relay
> (`nostr-relay:7777`), not this one. This relay is exposed publicly at
> **`wss://relay.maps.hitchwiki.org`** and reachable inside the docker network at
> **`ws://relay.maps.hitchwiki.org:8080`** on the shared `hitchwiki-relay` network (the
> docker service name `relay` also resolves).

## Database

- **Engine:** SQLite 3.x
- **File on host:** `/var/www/relay.maps.hitchwiki.org/data/nostr.db` (~907 MB)
- **File inside container:** `/usr/src/app/db/nostr.db`

### Accessing the database

SQLite is not installed on the host. Use `docker exec` to run queries:

```bash
# Non-interactive query
docker exec relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db "SELECT count(*) FROM event;"

# Interactive shell
docker exec -it relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db
```

Built-in helper scripts:

```bash
# Database statistics (event counts by kind, unique authors, date range)
./stats.sh

# Delete all kind-36820 events (prompts for confirmation)
./delete-kind-36820.sh
```

### Schema

#### `event` (~122k rows)
Primary table. One row per Nostr event.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | Internal row ID |
| `event_hash` | BLOB | 4-byte hash of the event |
| `first_seen` | INTEGER | Unix timestamp when relay received it |
| `created_at` | INTEGER | Unix timestamp set by the author |
| `expires_at` | INTEGER | Optional expiry (NIP-40) |
| `author` | BLOB | Author pubkey |
| `delegated_by` | BLOB | Delegator pubkey (NIP-26), nullable |
| `kind` | INTEGER | Nostr event kind |
| `hidden` | INTEGER | Soft-hide flag used in queries |
| `content` | TEXT | Full serialized JSON of the event object |

Key indexes: `event_hash` (unique), `author`, `kind`, `created_at`, composite indexes on `(kind, created_at)`, `(author, kind)`, etc.

#### `tag` (~4.7M rows)
Tags associated with events (one row per tag entry).

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `event_id` | INTEGER FK | References `event(id)`, cascades on delete |
| `name` | TEXT | Tag name: `p`, `e`, `L`, `d`, `g`, `l`, `r`, `t`, `published_at` |
| `value` | TEXT | Tag value when not hex |
| `value_hex` | BLOB | Tag value when lowercase hex |
| `created_at` | INTEGER | Copied from the parent event |
| `kind` | INTEGER | Copied from the parent event |

Key indexes: `tag_val_index` (value), `tag_composite_index` (event_id, name, value), `tag_covering_index` (name, kind, value, created_at, event_id).

#### `user_verification` (empty)
NIP-05 verification records. Currently unused (verification disabled in config).

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `metadata_event` | INTEGER FK | References `event(id)` |
| `name` | TEXT | NIP-05 identifier (`user@domain`) |
| `verified_at` | INTEGER | Timestamp of last successful verification |
| `failed_at` | INTEGER | Timestamp of last failure |
| `failure_count` | INTEGER | Consecutive failure count |

#### `account` (empty)
Pay-to-relay accounts. Currently unused (pay-to-relay disabled in config).

| Column | Type | Notes |
|---|---|---|
| `pubkey` | TEXT PK | |
| `is_admitted` | INTEGER | Boolean admission flag |
| `balance` | INTEGER | Balance in millisats |
| `tos_accepted_at` | INTEGER | Timestamp of ToS acceptance |

#### `invoice` (empty)
Payment invoices. Currently unused.

| Column | Type | Notes |
|---|---|---|
| `payment_hash` | TEXT PK | |
| `pubkey` | TEXT FK | References `account(pubkey)` |
| `invoice` | TEXT | BOLT-11 invoice string |
| `amount` | INTEGER | Amount in millisats |
| `status` | TEXT | `'Paid'`, `'Unpaid'`, or `'Expired'` |
| `description` | TEXT | |
| `created_at` | INTEGER | |
| `confirmed_at` | INTEGER | |

### Event kinds in use

| Kind | Count | Meaning |
|---|---|---|
| 36820 | ~72,600 | Hitchhiking ride notes (custom — primary data) |
| 1 | ~26,800 | Short text notes |
| 34242 | ~21,900 | Label events |
| 30399 | ~800 | User profile sets |
| 4 | ~220 | Encrypted direct messages |
| 5 | ~150 | Event deletion notices |
| 0 | ~19 | Metadata (user profiles) |

Kind **36820** is the core dataset — hitchhiking spots/rides from maps.hitchwiki.org.

### Useful query patterns

```sql
-- Count events by kind
SELECT kind, count(*) AS n FROM event GROUP BY kind ORDER BY n DESC;

-- Recent kind-36820 events
SELECT id, created_at, content FROM event WHERE kind=36820 ORDER BY created_at DESC LIMIT 10;

-- Tags for a specific event
SELECT name, value FROM tag WHERE event_id = <id>;

-- Events by a specific author (pubkey as hex)
SELECT id, kind, created_at FROM event WHERE author = X'<hex_pubkey>';

-- Events expiring soon
SELECT id, kind, expires_at FROM event WHERE expires_at IS NOT NULL ORDER BY expires_at ASC LIMIT 20;
```

## Configuration

- **File:** `config.toml`
- **Public URL:** `wss://relay.maps.hitchwiki.org/` (via Caddy, grey-cloud DNS + own Let's Encrypt cert)
- **Internal URL:** `ws://relay.maps.hitchwiki.org:8080` (docker network alias on `hitchwiki-relay`; service name `relay:8080` also works)
- **Port:** 7000 on host → 8080 in container
- **Future event rejection:** events >1800 s in the future are rejected
- **Authorization/pay-to-relay/NIP-05 verification:** all disabled

## Docker

```bash
# Check status
docker compose ps

# View logs
docker compose logs -f

# Restart relay
docker compose restart

# Bring down / up
docker compose down
docker compose up -d
```

Container name: `relaymapshitchwikiorg-relay-1`

### Content field structure (kind-36820)

The `content` column holds the **full Nostr event JSON**. For kind-36820, the Nostr event's own `content` field is a **nested JSON string** (with backslash-escaped quotes), e.g.:

```
{"id":"...","kind":36820,...,"content":"{\"version\":\"0.0.0\",\"stops\":[...],\"rating\":4,\"comment\":\"...\",\"source\":\"maps.hitchwiki.org\",\"license\":\"xxx\"}","sig":"..."}
```

Key fields inside the inner JSON:
- `source` — origin app (e.g. `maps.hitchwiki.org`, `liftershalte.info`)
- `comment` — user-supplied ride note
- `rating` — integer 1–5
- `hitchhikers` — array with `nickname`, `gender`, etc.
- `stops` — array of locations with lat/lon

The `d` tag value also encodes the source, e.g. `maps.hitchwiki.org-<uuid>`, making plain LIKE searches for the source reliable.

### Useful DELETE patterns

```sql
-- Delete kind-36820 events from a specific source with a specific comment value
-- (inner JSON fields are searchable with plain LIKE — no need to escape backslashes)
DELETE FROM event
WHERE kind=36820
  AND content LIKE '%maps.hitchwiki.org%'
  AND content LIKE '%comment%'
  AND lower(content) LIKE '%test%';
```
