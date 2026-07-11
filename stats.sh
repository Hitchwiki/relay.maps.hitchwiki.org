#!/bin/bash
docker exec relaymapshitchwikiorg-relay-1 sqlite3 /usr/src/app/db/nostr.db "
SELECT 'Total events', COUNT(*) FROM event;
SELECT 'Unique authors', COUNT(DISTINCT author) FROM event;
SELECT 'Oldest event', datetime(MIN(created_at), 'unixepoch') FROM event;
SELECT 'Newest event', datetime(MAX(created_at), 'unixepoch') FROM event;
SELECT '--- by kind ---', '';
SELECT kind, COUNT(*) as count FROM event GROUP BY kind ORDER BY count DESC LIMIT 15;
SELECT '--- kind 36820 by source ---', '';
SELECT
  json_extract(json_extract(content, '$.content'), '$.source') as source,
  COUNT(*) as total,
  COUNT(DISTINCT json_extract(content, '$.content')) as unique_rides,
  COUNT(*) - COUNT(DISTINCT json_extract(content, '$.content')) as duplicates
FROM event WHERE kind = 36820
GROUP BY source
ORDER BY total DESC;
"
