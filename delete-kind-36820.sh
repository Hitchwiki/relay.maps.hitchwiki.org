#!/bin/bash
echo "Events to delete:"
docker exec relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db \
  "SELECT COUNT(*) FROM event WHERE kind = 36820;"

read -p "Proceed? [y/N] " confirm
if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
  docker exec relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db \
    "DELETE FROM event WHERE kind = 36820;"
  echo "Done."
else
  echo "Aborted."
fi
