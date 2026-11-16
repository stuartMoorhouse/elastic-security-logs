#!/usr/bin/env bash
# Post-deploy configuration (Serverless): data stream lifecycle component template, Fleet package
# policies, data views and saved Discover searches. Idempotent; nothing destructive.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_endpoints
wait_for_kibana

[ -d "$CONFIG_DIR" ] || die "$CONFIG_DIR not found (run /create-demo to generate config files)"

echo "== Lifecycle component template"
f="$CONFIG_DIR/component-template-security-logs-lifecycle.json"
[ -f "$f" ] || die "missing $f"
es PUT "/_component_template/security-logs-lifecycle" "$f" >/dev/null && echo "ok: security-logs-lifecycle"

# The same template body is also attached to each dataset's @custom component template
# (the hook Fleet-installed index templates compose), so the 90d retention applies to the
# integration data streams.
CUSTOM_BODY="$(mktemp)"
python3 - "$f" "$CUSTOM_BODY" <<'PY'
import json, sys
src = json.load(open(sys.argv[1]))
json.dump({"template": src.get("template", {})}, open(sys.argv[2], "w"))
PY

echo "== Attach lifecycle to dataset @custom templates"
for ds in $ALL_DATASETS; do
  es PUT "/_component_template/logs-${ds}@custom" "$CUSTOM_BODY" >/dev/null && echo "ok: logs-${ds}@custom"
done
es PUT "/_component_template/logs@custom" "$CUSTOM_BODY" >/dev/null && echo "ok: logs@custom"
rm -f "$CUSTOM_BODY"

echo "== Fleet package policies"
declare -A PKG_VER=()
pkg_version() {
  local pkg="$1"
  if [ -z "${PKG_VER[$pkg]:-}" ]; then
    PKG_VER[$pkg]="$(kb GET "/api/fleet/epm/packages/$pkg" | pyj "d.get('item',d.get('response',{})).get('version','')")"
    [ -n "${PKG_VER[$pkg]}" ] || die "could not resolve version of package $pkg"
  fi
  echo "${PKG_VER[$pkg]}"
}

EXISTING="$(kb GET "/api/fleet/package_policies?perPage=1000")"
add_pkg_policy() { # add_pkg_policy <file> <package> <policy_id>
  local file="$CONFIG_DIR/$1" pkg="$2" pid="$3"
  [ -f "$file" ] || die "missing $file"
  [ -n "$pid" ] || die "agent policy id for $1 is empty (terraform outputs linux_policy_id/windows_policy_id)"
  local name
  name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$file")"
  if printf '%s' "$EXISTING" | python3 -c '
import sys, json
n, p = sys.argv[1:3]
sys.exit(0 if any(i.get("name")==n and (i.get("policy_id")==p or p in i.get("policy_ids",[])) for i in json.load(sys.stdin).get("items",[])) else 1)' "$name" "$pid"; then
    echo "skip (exists): $name"; return
  fi
  local ver body
  ver="$(pkg_version "$pkg")"
  body="$(mktemp)"
  sed -e "s/__POLICY_ID__/$pid/g" -e "s/__PKG_VERSION__/$ver/g" "$file" > "$body"
  kb POST /api/fleet/package_policies "$body" >/dev/null && echo "created: $name ($pkg $ver)"
  rm -f "$body"
}

LINUX_POLICY_ID="$(tf_out linux_policy_id)"
WINDOWS_POLICY_ID="$(tf_out windows_policy_id)"
add_pkg_policy package-policy-linux-system.json system "$LINUX_POLICY_ID"
add_pkg_policy package-policy-linux-auditd.json auditd_manager "$LINUX_POLICY_ID"
add_pkg_policy package-policy-windows.json windows "$WINDOWS_POLICY_ID"
add_pkg_policy package-policy-windows-system.json system "$WINDOWS_POLICY_ID"

echo "== Data views"
f="$CONFIG_DIR/kibana-data-views.ndjson"
[ -f "$f" ] || die "missing $f"
curl -sS -K "$CURL_CFG" -X POST -H 'kbn-xsrf: true' -F "file=@$f" \
  "$KB_URL/api/saved_objects/_import?overwrite=true" | pyj "'imported:', d.get('successCount'), 'success=', d.get('success')"

echo "== Saved Discover searches"
f="$CONFIG_DIR/saved-searches.ndjson"
if [ -f "$f" ]; then
  curl -sS -K "$CURL_CFG" -X POST -H 'kbn-xsrf: true' -F "file=@$f" \
    "$KB_URL/api/saved_objects/_import?overwrite=true" | pyj "'imported:', d.get('successCount'), 'success=', d.get('success')"
else
  echo "WARN: $f not found"
fi

env_set elasticsearch_url "$ES_URL"
env_set kibana_url "$KB_URL"
env_set infra_ready true bool
env_set config_ready true bool
echo "Configuration complete."
