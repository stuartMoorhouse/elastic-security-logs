#!/usr/bin/env bash
# Terraform `data "external"` helper. Reads JSON on stdin:
#   {kibana_url, username, password, policy_name}
# Prints exactly one JSON object on stdout: {fleet_url, enrollment_token, policy_id}
# All logging goes to stderr. Idempotent: finds the policy by name or creates it.
# Note: the policy is created WITHOUT sys_monitoring; System/Windows/Auditd integrations are
# added explicitly by scripts/configure.sh to avoid duplicate collection.
set -euo pipefail

log() { echo "[setup-fleet-policy] $*" >&2; }
INPUT="$(cat)"
getf() { printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
KB_URL="$(getf kibana_url)"; KB_URL="${KB_URL%/}"
USERNAME="$(getf username)"; PASSWORD="$(getf password)"; POLICY_NAME="$(getf policy_name)"

CFG="$(mktemp)"; chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
esc="$(printf '%s:%s' "$USERNAME" "$PASSWORD" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
printf 'user = "%s"\n' "$esc" > "$CFG"

api() { # api METHOD PATH [body]
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  local args=(-sS -K "$CFG" -o "$out" -w '%{http_code}' -X "$method" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' "$KB_URL$path")
  [ -n "$body" ] && args+=(-d "$body")
  code="$(curl "${args[@]}" 2>/dev/null)" || code=000
  if [[ "$code" == 2* ]]; then cat "$out"; rm -f "$out"; return 0; fi
  log "$method $path -> HTTP $code: $(head -c 300 "$out")"; rm -f "$out"; return 1
}

log "waiting for Kibana at $KB_URL"
for i in $(seq 1 90); do
  lvl="$(api GET /api/status 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"]["overall"]["level"])' 2>/dev/null || true)"
  [ "$lvl" = "available" ] && break
  if [ "$i" = 90 ]; then log "Kibana not available"; exit 1; fi
  sleep 10
done

# Fleet setup (idempotent)
api POST /api/fleet/setup >/dev/null || true

find_policy() {
  api GET "/api/fleet/agent_policies?perPage=200" | python3 -c '
import sys, json
name = sys.argv[1]
for p in json.load(sys.stdin).get("items", []):
    if p.get("name") == name:
        print(p["id"]); break' "$POLICY_NAME"
}

POLICY_ID="$(find_policy || true)"
if [ -z "$POLICY_ID" ]; then
  log "creating agent policy $POLICY_NAME"
  body="$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"namespace":"default","description":"Managed by Terraform (elastic-security-logs)","monitoring_enabled":["logs","metrics"]}))' "$POLICY_NAME")"
  api POST "/api/fleet/agent_policies" "$body" >/dev/null || { log "create failed"; exit 1; }
  POLICY_ID="$(find_policy)"
fi
[ -n "$POLICY_ID" ] || { log "could not resolve policy id"; exit 1; }

TOKEN=""
for i in $(seq 1 30); do
  TOKEN="$(api GET "/api/fleet/enrollment_api_keys?perPage=200" | python3 -c '
import sys, json
pid = sys.argv[1]
for k in json.load(sys.stdin).get("items", []):
    if k.get("policy_id") == pid and k.get("active", True):
        print(k["api_key"]); break' "$POLICY_ID" || true)"
  [ -n "$TOKEN" ] && break
  sleep 4
done
[ -n "$TOKEN" ] || { log "no active enrollment key for policy $POLICY_ID"; exit 1; }

FLEET_URL="$(api GET /api/fleet/fleet_server_hosts | python3 -c '
import sys, json
items = json.load(sys.stdin).get("items", [])
pick = next((i for i in items if i.get("is_default")), items[0] if items else None)
print(pick["host_urls"][0] if pick else "")')"
[ -n "$FLEET_URL" ] || { log "no Fleet server host registered"; exit 1; }

python3 -c 'import json,sys; print(json.dumps({"fleet_url":sys.argv[1],"enrollment_token":sys.argv[2],"policy_id":sys.argv[3]}))' "$FLEET_URL" "$TOKEN" "$POLICY_ID"
