#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.
# Credentials come from `terraform output` at runtime and are never written to disk
# (apart from a mode-600 curl config in a temp file that is removed on exit).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
ENV_JSON="$ROOT_DIR/shared/env.json"
CONFIG_DIR="$ROOT_DIR/config"

# Datasets used by this demo (data stream = logs-<dataset>-default)
LINUX_DATASETS="system.auth system.syslog auditd_manager.auditd"
WINDOWS_DATASETS="system.security system.application system.system windows.sysmon_operational windows.powershell_operational"
ALL_DATASETS="$LINUX_DATASETS $WINDOWS_DATASETS"

die() { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

tf_out() { # tf_out <name> -> raw value, empty if missing
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

pyj() { # pyj '<python expr on d>' < json
  python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}

env_set() { # env_set key value [bool]
  python3 - "$ENV_JSON" "$1" "$2" "${3:-str}" <<'PY'
import json, sys, os
path, key, val, kind = sys.argv[1:5]
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, ValueError):
    data = {}
data[key] = (val == "true") if kind == "bool" else val
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

load_endpoints() {
  need terraform; need curl; need python3
  ES_URL="$(tf_out elasticsearch_url)"
  KB_URL="$(tf_out kibana_url)"
  ES_USER="$(tf_out elastic_username)"
  ES_PASS="$(tf_out elastic_password)"
  if [ -z "$ES_URL" ] || [ -z "$KB_URL" ] || [ -z "$ES_USER" ] || [ -z "$ES_PASS" ]; then
    die "terraform outputs missing (elasticsearch_url/kibana_url/elastic_username/elastic_password). Deploy first."
  fi
  ES_URL="${ES_URL%/}"; KB_URL="${KB_URL%/}"
  CURL_CFG="$(mktemp)"; chmod 600 "$CURL_CFG"
  local esc; esc="$(printf '%s:%s' "$ES_USER" "$ES_PASS" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf 'user = "%s"\n' "$esc" > "$CURL_CFG"
  trap 'rm -f "$CURL_CFG"' EXIT
  export ES_URL KB_URL ES_USER ES_PASS
}

_req() { # _req <base> <method> <path> [json-file]
  local base="$1" method="$2" path="$3" data="${4:-}" out code
  out="$(mktemp)"
  local args=(-sS -K "$CURL_CFG" -o "$out" -w '%{http_code}' -X "$method"
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' "$base$path")
  [ -n "$data" ] && args+=(--data-binary "@$data")
  code="$(curl "${args[@]}")" || { echo "ERROR: cannot reach $base - is the deployment up and reachable?" >&2; rm -f "$out"; return 7; }
  case "$code" in
    2*) cat "$out"; rm -f "$out"; return 0 ;;
    *) echo "ERROR: $method $path -> HTTP $code" >&2; cat "$out" >&2; echo >&2; rm -f "$out"; return 22 ;;
  esac
}
es() { _req "$ES_URL" "$@"; }
kb() { _req "$KB_URL" "$@"; }

tmp_json() { # tmp_json '<json string>' -> path of temp file
  local f; f="$(mktemp)"; printf '%s' "$1" > "$f"; echo "$f"
}

wait_for_kibana() {
  local i
  for i in $(seq 1 60); do
    if kb GET /api/status 2>/dev/null | pyj "d['status']['overall']['level']" 2>/dev/null | grep -q available; then
      return 0
    fi
    echo "Waiting for Kibana ($i/60)..." >&2; sleep 10
  done
  die "Kibana not available at $KB_URL"
}
