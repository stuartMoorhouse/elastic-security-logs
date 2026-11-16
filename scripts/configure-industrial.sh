#!/usr/bin/env bash
# Post-wizard configuration for the Automatic Import integration (industrial switches and gateways).
# Run this AFTER you have approved and installed the integration in Kibana, ideally before adding
# it to the agent policy (so the first backing index already has the lifecycle).
#
# Usage: scripts/configure-industrial.sh --package <package-name>
#   Without --package it lists installed packages so you can find the generated name.
#
# Does: data stream lifecycle @custom component templates for each of the integration's data streams (+ lifecycle update if
# data already exists), a data view, two saved Discover searches, and an ES|QL query file in results/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_endpoints

PKG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --package) PKG="${2:-}"; shift 2 ;;
    *) die "usage: $0 --package <package-name>" ;;
  esac
done

if [ -z "$PKG" ]; then
  echo "Installed packages (pick the one Automatic Import generated):"
  kb GET "/api/fleet/epm/packages/installed?perPage=200" \
    | pyj "'\n'.join('  %s %s' % (i['name'], i.get('version','')) for i in d.get('items', []))" | sort
  die "re-run with --package <name>"
fi

echo "== Package $PKG"
kb GET "/api/fleet/epm/packages/$PKG" | pyj "d.get('item',d.get('response',{})).get('status','unknown')" | grep -q installed \
  || die "package '$PKG' is not installed. Approve and install it in Integrations > Manage my integrations first."

echo "== Data streams (from index templates logs-$PKG.*)"
TEMPLATES="$(es GET "/_index_template/logs-${PKG}.*?filter_path=index_templates.name" | pyj "' '.join(t['name'] for t in d.get('index_templates', []))")"
[ -n "$TEMPLATES" ] || die "no index templates found for logs-$PKG.* (is the package installed with data streams?)"
echo "  $TEMPLATES"

echo "== Attach lifecycle to each data stream's @custom component template"
BODY="$(mktemp)"
python3 - "$CONFIG_DIR/component-template-security-logs-lifecycle.json" "$BODY" <<'PY'
import json, sys
json.dump({"template": json.load(open(sys.argv[1])).get("template", {})}, open(sys.argv[2], "w"))
PY
for t in $TEMPLATES; do
  es PUT "/_component_template/${t}@custom" "$BODY" >/dev/null && echo "ok: ${t}@custom"
  ds="${t}-default"
  if es GET "/_data_stream/$ds?filter_path=data_streams.name" 2>/dev/null | grep -q "$ds"; then
    # Data already flowing: apply the retention to the existing data stream directly
    LB="$(tmp_json '{"data_retention":"90d"}')"
    es PUT "/_data_stream/$ds/_lifecycle" "$LB" >/dev/null && echo "lifecycle set: $ds"
    rm -f "$LB"
  fi
done
rm -f "$BODY"

echo "== Data view and saved searches"
DV="dv-industrial"
DVB="$(tmp_json "{\"data_view\":{\"id\":\"$DV\",\"title\":\"logs-${PKG}.*\",\"name\":\"Industrial switches and gateways\",\"timeFieldName\":\"@timestamp\"},\"override\":true}")"
kb POST "/api/data_views/data_view" "$DVB" >/dev/null && echo "ok: data view $DV (logs-${PKG}.*)"
rm -f "$DVB"
# DISABLED: the saved searches below are created with a direct POST to /api/saved_objects/...,
# which Elastic Cloud Serverless rejects (HTTP 400, "not available with the current configuration").
# If Automatic Import is used, rewrite this to build an ndjson file and use
# POST /api/saved_objects/_import?overwrite=true (see configure.sh and config/saved-searches.ndjson).
# TAGB="$(tmp_json '{"attributes":{"name":"security-logs-demo","description":"Objects created by the security logs demo","color":"#E7664C"}}')"
# kb POST "/api/saved_objects/tag/tag-security-logs-demo?overwrite=true" "$TAGB" >/dev/null && echo "ok: tag security-logs-demo"
# rm -f "$TAGB"
# save_search() { # save_search <id> <title> <esql>
#   local b; b="$(tmp_json "$(python3 - "$2" "$3" <<'PY'
# import json, sys
# title, esql = sys.argv[1:3]
# print(json.dumps({"attributes": {"title": title, "columns": [], "sort": [["@timestamp", "desc"]], "isTextBasedQuery": True,
#   "kibanaSavedObjectMeta": {"searchSourceJSON": json.dumps({"query": {"esql": esql}, "filter": []})}},
#   "references": [{"name": "tag-ref-1", "type": "tag", "id": "tag-security-logs-demo"}]}))
# PY
# )")"
#   kb POST "/api/saved_objects/search/$1?overwrite=true" "$b" >/dev/null && echo "ok: saved search $1"
#   rm -f "$b"
# }
# save_search "search-industrial-all" "Industrial devices - all events" "FROM logs-${PKG}.* | SORT @timestamp DESC | KEEP @timestamp, host.name, event.original | LIMIT 500"
# save_search "search-industrial-auth" "Industrial devices - login failures" "FROM logs-${PKG}.* | WHERE event.original LIKE \"*ailed*\" | SORT @timestamp DESC | KEEP @timestamp, host.name, event.original | LIMIT 500"

echo "== ES|QL examples"
OUT="$ROOT_DIR/results/industrial-esql-queries.md"
mkdir -p "$ROOT_DIR/results"
cat > "$OUT" <<EOF
# Industrial devices - ES|QL examples (package: ${PKG})

Field names below beyond @timestamp, data_stream.dataset and event.original depend on what the LLM mapped.
Check the Review and approve screen, or run the first query and look at the columns, then adjust.

## Events per data stream per 5 minutes
\`\`\`esql
FROM logs-${PKG}.*
| STATS events = COUNT(*) BY data_stream.dataset, bucket = BUCKET(@timestamp, 5 minutes)
| SORT bucket DESC
\`\`\`

## Login failures per source (both vendors)
\`\`\`esql
FROM logs-${PKG}.*
| WHERE event.original LIKE "*ailed*"
| STATS failures = COUNT(*) BY source.ip
| SORT failures DESC
\`\`\`

## Ring redundancy events
\`\`\`esql
FROM logs-${PKG}.*
| WHERE event.original LIKE "*redundancy*" OR event.original LIKE "*ring break*"
| KEEP @timestamp, host.name, event.original
| SORT @timestamp DESC
| LIMIT 50
\`\`\`
EOF
echo "wrote $OUT"
env_set industrial_package "$PKG"
echo "Done. Next: add the integration to the linux-workstations policy (UDP/TCP ports 5514 Hirschmann, 5515 Moxa), then scripts/send-industrial-syslog.sh start"
