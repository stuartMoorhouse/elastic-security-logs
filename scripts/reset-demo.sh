#!/usr/bin/env bash
# Resets demo data: deletes the demo data streams (live Agent data and backfill) so the backfill can be loaded again. Package policies,
# lifecycle, templates and Kibana objects are kept. Agents recreate their data streams automatically.
# Usage: scripts/reset-demo.sh [--yes] [--rebackfill]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

YES=0; REBACKFILL=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;; --rebackfill) REBACKFILL=1 ;;
    *) die "unknown argument: $a (use --yes, --rebackfill)" ;;
  esac
done
load_endpoints

if [ "$YES" -ne 1 ]; then
  echo "This deletes all data in the logs-*-default data streams for: $ALL_DATASETS"
  read -r -p "Continue? [y/N] " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || die "aborted"
fi

for ds in $ALL_DATASETS; do
  stream="logs-${ds}-default"
  if es GET "/_data_stream/$stream" >/dev/null 2>&1; then
    es DELETE "/_data_stream/$stream" >/dev/null && echo "deleted: $stream"
  else
    echo "skip (absent): $stream"
  fi
done
env_set demo_executed false bool

if [ "$REBACKFILL" -eq 1 ]; then
  "$ROOT_DIR/scripts/backfill.sh"
fi
echo "Reset complete."
