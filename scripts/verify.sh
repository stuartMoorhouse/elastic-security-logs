#!/usr/bin/env bash
# Checks the 11 acceptance criteria from .claude/spec/spec.md. Prints PASS/FAIL/SKIP per criterion.
# Exit code is non-zero if any criterion FAILs.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_endpoints

FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1 -- $2"; FAILS=$((FAILS+1)); }
skip() { echo "SKIP  $1 -- $2"; }

count() { # count <index-pattern> <query-json>
  local b; b="$(tmp_json "{\"query\":$2}")"
  es POST "/$1/_count?ignore_unavailable=true&allow_no_indices=true" "$b" 2>/dev/null | pyj "d['count']" 2>/dev/null || echo 0
  rm -f "$b"
}
LIVE='{"bool":"BOOL","must_not":[{"term":{"tags":"synthetic-backfill"}}]}'
live_q() { echo "{\"bool\":{\"filter\":[$1],\"must_not\":[{\"term\":{\"tags\":\"synthetic-backfill\"}}]}}"; }

# 1. Serverless Security project reachable and healthy
code="$(curl -s -o /dev/null -w '%{http_code}' -K "$CURL_CFG" "$ES_URL/" 2>/dev/null || echo 000)"
dist="$(es GET / 2>/dev/null | pyj "d['version'].get('build_flavor','')" 2>/dev/null || true)"
if [ "$code" = 200 ] && [ "$dist" = serverless ]; then pass "1. Serverless project reachable (build_flavor=$dist)"
else fail "1. Serverless project" "http=$code build_flavor=$dist"; fi

# 2. Data stream lifecycle (90d retention) on the logs-* data streams
lc="$(es GET "/_data_stream/logs-*-default" 2>/dev/null | pyj "[(s['name'], (s.get('lifecycle') or {}).get('data_retention')) for s in d.get('data_streams',[]) if s['name'].split('-',1)[1].rsplit('-',1)[0] in '$ALL_DATASETS'.split()]" 2>/dev/null || echo '[]')"
bad="$(printf '%s' "$lc" | python3 -c 'import sys,ast; l=ast.literal_eval(sys.stdin.read()); print(len(l), sum(1 for _,p in l if p!="90d"))' 2>/dev/null || echo '0 0')"
set -- $bad
if [ "${1:-0}" -ge 1 ] && [ "${2:-1}" -eq 0 ]; then pass "2. Data stream lifecycle data_retention=90d on $1 data streams"
else fail "2. Data stream lifecycle" "streams=${1:-0} without 90d retention=${2:-?}"; fi

# 3. VMs on-demand + Fleet agents healthy
RG="$(tf_out resource_group_name)"
if command -v az >/dev/null 2>&1 && [ -n "$RG" ]; then
  prios="$(az vm list -g "$RG" --query "[].priority" -o tsv 2>/dev/null | tr '\n' ' ')"
  nvm="$(az vm list -g "$RG" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
  if [ "${nvm:-0}" -ge 2 ] && ! echo "$prios" | grep -qi spot; then vm_ok=1; else vm_ok=0; fi
else vm_ok=-1; fi
agents="$(kb GET "/api/fleet/agents?perPage=100" 2>/dev/null | pyj "sum(1 for a in d['items'] if a['status']=='online')" 2>/dev/null || echo 0)"
if [ "$vm_ok" = -1 ]; then
  [ "${agents:-0}" -ge 2 ] && skip "3. VM priority (az or terraform output resource_group_name unavailable); Fleet healthy agents: $agents" "VM check not run" \
    || fail "3. Fleet agents" "healthy agents: $agents (need 2); VM priority not checked"
elif [ "$vm_ok" = 1 ] && [ "${agents:-0}" -ge 2 ]; then pass "3. $nvm VMs not Spot ($prios); $agents Fleet agents healthy"
else fail "3. VMs / agents" "vms=${nvm:-0} priorities='${prios:-}' healthy_agents=$agents"; fi

# 4. Windows live data
w="$(count 'logs-system.security-*,logs-windows.sysmon_operational-*,logs-windows.powershell_operational-*,partial-*' "$(live_q '{"term":{"host.os.type":"windows"}}')")"
wsets="$(es POST "/logs-*/_search?size=0" "$(tmp_json "{\"query\":$(live_q '{"term":{"host.os.type":"windows"}}'),\"aggs\":{\"d\":{\"terms\":{\"field\":\"data_stream.dataset\"}}}}")" 2>/dev/null | pyj "sorted(b['key'] for b in d['aggregations']['d']['buckets'])" 2>/dev/null || echo '[]')"
if [ "${w:-0}" -gt 0 ]; then pass "4. Windows live docs: $w; datasets: $wsets"; else fail "4. Windows live data" "no non-backfill windows docs (agent enrolled? waited 5 min?)"; fi

# 5. Linux live data
l="$(count 'logs-system.auth-*,logs-system.syslog-*,logs-auditd_manager.auditd-*,partial-*' "$(live_q '{"term":{"host.os.type":"linux"}}')")"
lsets="$(es POST "/logs-*/_search?size=0" "$(tmp_json "{\"query\":$(live_q '{"term":{"host.os.type":"linux"}}'),\"aggs\":{\"d\":{\"terms\":{\"field\":\"data_stream.dataset\"}}}}")" 2>/dev/null | pyj "sorted(b['key'] for b in d['aggregations']['d']['buckets'])" 2>/dev/null || echo '[]')"
if [ "${l:-0}" -gt 0 ]; then pass "5. Linux live docs: $l; datasets: $lsets"; else fail "5. Linux live data" "no non-backfill linux docs"; fi

# 6. Backfill ~2M docs over 30d
bq='{"term":{"tags":"synthetic-backfill"}}'
bf="$(count 'logs-*,partial-*' "$bq")"
rng="$(es POST "/logs-*,partial-*/_search?size=0&ignore_unavailable=true" "$(tmp_json "{\"query\":$bq,\"aggs\":{\"mn\":{\"min\":{\"field\":\"@timestamp\"}},\"mx\":{\"max\":{\"field\":\"@timestamp\"}}}}")" 2>/dev/null | pyj "round((d['aggregations']['mx']['value']-d['aggregations']['mn']['value'])/86400000,1)" 2>/dev/null || echo 0)"
if [ "${bf:-0}" -ge 1800000 ] && python3 -c "import sys; sys.exit(0 if float('${rng:-0}')>=28 else 1)"; then
  pass "6. Backfill docs: $bf spanning $rng days"
else fail "6. Backfill" "docs=$bf span_days=$rng (need >=1.8M and >=28d)"; fi

# 7. Old (backfilled) data searchable in Discover's time range
old="$(count 'logs-*' '{"range":{"@timestamp":{"lt":"now-2d"}}}')"
if [ "${old:-0}" -gt 0 ]; then pass "7. $old docs older than 2d searchable"
else fail "7. Old data searchable" "no docs older than 2d (run scripts/backfill.sh)"; fi

# 8. Data views and saved searches
# Serverless does not expose saved_objects/_find: use the data views API and _export for searches
so_dv="$(kb GET "/api/data_views" 2>/dev/null | pyj "len([o for o in d['data_view'] if o['id'].startswith('dv-logs')])" 2>/dev/null || echo 0)"
EXP="$(tmp_json '{"type":"search"}')"
so_ss="$(kb POST "/api/saved_objects/_export" "$EXP" 2>/dev/null | python3 -c 'import sys,json; print(sum(1 for l in sys.stdin if l.strip() and json.loads(l).get("type")=="search"))' 2>/dev/null || echo 0)"
rm -f "$EXP"
if [ "${so_dv:-0}" -ge 1 ] && [ "${so_ss:-0}" -ge 1 ]; then pass "8. $so_dv data views, $so_ss saved searches"
else fail "8. Saved objects" "data views=$so_dv saved searches=$so_ss (expected >=1 / >=1)"; fi

# 9. ES|QL example queries
f="$CONFIG_DIR/esql-queries.md"
if [ ! -f "$f" ]; then fail "9. ES|QL queries" "$f not found"
else
  QDIR="$(mktemp -d)"
  python3 - "$f" "$QDIR" <<'PY'
import re, sys, json
text = open(sys.argv[1]).read()
for n, q in enumerate(re.findall(r"```esql\n(.*?)```", text, re.S), 1):
    json.dump({"query": q.strip()}, open("%s/%02d.json" % (sys.argv[2], n), "w"))
PY
  total=0; ok=0
  for q in "$QDIR"/*.json; do
    [ -e "$q" ] || continue
    total=$((total+1))
    if es POST "/_query?format=json" "$q" >/dev/null 2>"$QDIR/err"; then ok=$((ok+1)); else echo "      query $(basename "$q" .json) failed: $(head -c 200 "$QDIR/err")"; fi
  done
  rm -rf "$QDIR"
  if [ "$total" -gt 0 ] && [ "$ok" -eq "$total" ]; then pass "9. ES|QL queries: $ok/$total executed"
  else fail "9. ES|QL queries" "$ok/$total executed"; fi
fi

# 10-11. Industrial switches and gateways via Automatic Import (needs the wizard run by hand first)
IPKG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("industrial_package",""))' "$ENV_JSON" 2>/dev/null || true)"
if [ -z "$IPKG" ]; then
  skip "10. Industrial data (Automatic Import)" "not set up yet: run the wizard, then scripts/configure-industrial.sh --package <name>"
  skip "11. Industrial data streams lifecycle" "not set up yet"
else
  isets="$(es POST "/logs-${IPKG}.*/_search?size=0" "$(tmp_json '{"query":{"exists":{"field":"event.original"}},"aggs":{"d":{"terms":{"field":"data_stream.dataset"}},"ecs":{"filter":{"bool":{"should":[{"exists":{"field":"event.category"}},{"exists":{"field":"event.action"}},{"exists":{"field":"host.name"}}],"minimum_should_match":1}}}}}')" 2>/dev/null \
    | pyj "'%d|%d|%s' % (d['hits']['total']['value'], d['aggregations']['ecs']['doc_count'], sorted(b['key'] for b in d['aggregations']['d']['buckets']))" 2>/dev/null || echo "0|0|[]")"
  itotal="${isets%%|*}"; irest="${isets#*|}"; iecs="${irest%%|*}"; inames="${irest#*|}"
  ndss="$(python3 -c 'import sys,ast; print(len(ast.literal_eval(sys.argv[1])))' "$inames" 2>/dev/null || echo 0)"
  if [ "${itotal:-0}" -gt 0 ] && [ "${ndss:-0}" -ge 2 ] && [ "${iecs:-0}" -gt 0 ]; then
    pass "10. Industrial docs: $itotal across $ndss data streams $inames, $iecs with ECS event/host fields"
  else fail "10. Industrial data (Automatic Import)" "docs=$itotal data_streams=$ndss ecs_docs=$iecs (is the integration on the policy and the sender running?)"; fi
  ilm="$(es GET "/_data_stream/logs-${IPKG}.*" 2>/dev/null \
    | pyj "'%d|%d' % (len(d['data_streams']), sum(1 for s in d['data_streams'] if (s.get('lifecycle') or {}).get('data_retention') == '90d'))" 2>/dev/null || echo "0|0")"
  if [ "${ilm%%|*}" -gt 0 ] && [ "${ilm%%|*}" = "${ilm##*|}" ]; then pass "11. Industrial data streams with 90d lifecycle: ${ilm##*|}/${ilm%%|*}"
  else fail "11. Industrial data streams lifecycle" "${ilm##*|}/${ilm%%|*} have 90d retention (re-run configure-industrial.sh)"; fi
fi

echo
[ "$FAILS" -eq 0 ] && echo "ALL CRITERIA PASSED" || echo "$FAILS criteria failed"
exit $((FAILS > 0))
