#!/usr/bin/env bash
# Safe destroy wrapper: verifies EC_API_KEY is valid (ec provider calls the Elastic Cloud API
# on every refresh, including destroy) and then runs the Terraform destroy.
# Never use -refresh=false or `state rm` to get around an invalid key; that orphans the
# billable deployment.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -n "${EC_API_KEY:-}" ] || { echo "EC_API_KEY is not set: export it (Elastic Cloud console > Organization > API keys)"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: ApiKey $EC_API_KEY" https://api.elastic-cloud.com/api/v1/deployments)
[ "$code" = 200 ] || { echo "EC_API_KEY invalid (HTTP $code): create a new key in Elastic Cloud console > Organization > API keys, export EC_API_KEY, retry"; exit 1; }

cd "$ROOT_DIR/terraform"
exec terraform destroy "$@"
