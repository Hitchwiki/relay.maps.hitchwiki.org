#!/bin/bash
# Daily incremental import of new hitchmap.com rides into the relay database.
#
# Wraps hitchhiking-data-standard/nostr/publish_hitchmap_with_nicknames.py,
# which downloads https://hitchmap.com/dump.sqlite and writes every ride submitted after
# the newest hitchmap.com ride already in the relay straight into data/nostr.db.
# Re-running is safe: the cutoff is read back from the relay, so nothing is duplicated.
#
# Must run as root - data/ is owned by the container uid (100:100).
#   Manual run:  sudo /var/www/relay.maps.hitchwiki.org/import-hitchmap-daily.sh
#   Log:         /var/www/relay.maps.hitchwiki.org/import-hitchmap-daily.log  (gitignored)
#   Cron:        see the hitchwiki crontab (crontab -l)

set -uo pipefail

NOSTR_DIR=/var/www/relay.maps.hitchwiki.org/hitchhiking-data-standard/nostr
SCRIPT=publish_hitchmap_with_nicknames.py
PYTHON="$NOSTR_DIR/.venv/bin/python3"
LOG=/var/www/relay.maps.hitchwiki.org/import-hitchmap-daily.log
LOCK=/var/lock/hitchmap-import.lock
OWNER=hitchwiki:hitchwiki   # keep the downloaded dump usable for manual runs

# Only one import at a time; a slow download must not overlap the next day's run.
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "$(date -Is) previous import still running, skipping this run" >>"$LOG"
    exit 0
fi

# Keep the log from growing without bound (the host disk runs above 90%).
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 5242880 ]; then
    tail -n 2000 "$LOG" >"$LOG.tmp" && cat "$LOG.tmp" >"$LOG" && rm -f "$LOG.tmp"
fi

cd "$NOSTR_DIR" || exit 1

{
    echo "=== $(date -Is) hitchmap import starting ==="
    # The wget progress bar is carriage-return animated; unroll it and drop the partial frames.
    "$PYTHON" "$SCRIPT" "$@" 2>&1 | tr '\r' '\n' | grep -v '^ *[0-9]\+% \['
    status=${PIPESTATUS[0]}
    # The script exits 1 with "Nothing to publish" when the relay is already up to date.
    echo "=== $(date -Is) hitchmap import finished (exit $status) ==="
} >>"$LOG" 2>&1

chown "$OWNER" "$NOSTR_DIR/dump.sqlite" 2>/dev/null

exit 0
