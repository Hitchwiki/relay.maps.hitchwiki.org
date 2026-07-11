Lives in Hitchwiki server /var/www/relay.maps.hitchwiki.org

# relay.nomadwiki.org

This is the central Nostr relay for [maps.hitchwiki.org](https://maps.hitchwiki.org).

It is the primary data store for hitchhiking ride notes submitted through the Hitchwiki Maps application. The maps application depends on this relay — if the relay is down or data is lost, ride notes will be unavailable.

## Scripts

- `./stats.sh` — show statistics about events currently held on the relay
- `./delete-kind-36820.sh` — delete all events of kind 36820 (with confirmation prompt)

## Running

```sh
docker compose up -d  # project name pinned in docker-compose.yml (name: relaymapshitchwikiorg)
```

This names the container `relaymapshitchwikiorg-relay-1` (project relaymapshitchwikiorg).

## Stack

- Software: [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay)
- Database: SQLite (`./data/nostr.db`)
- Deployed via Docker Compose (`docker-compose.yml`)
