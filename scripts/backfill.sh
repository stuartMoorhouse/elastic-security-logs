#!/usr/bin/env bash
# Wrapper for backfill.py: loads endpoints/credentials from terraform outputs.
# Usage: scripts/backfill.sh [--docs N] [--days N] [--batch-size N] [--seed N] [--dry-run]
# Not idempotent by design (each run adds documents); use scripts/reset-demo.sh first to start clean.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for a in "$@"; do
  if [ "$a" = "--dry-run" ]; then
    exec python3 -I "$ROOT_DIR/scripts/backfill.py" "$@"
  fi
done

load_endpoints
es GET / >/dev/null || die "Elasticsearch not reachable"
env_set elasticsearch_url "$ES_URL"
python3 -I "$ROOT_DIR/scripts/backfill.py" "$@"
env_set demo_executed true bool
echo "Backfill done. Open Discover and set the time range to the last 30 days."
