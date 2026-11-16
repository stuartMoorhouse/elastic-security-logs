#!/usr/bin/env bash
# Prints access details from terraform outputs. Passwords are shown only with --show-secrets.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need terraform

SHOW=0
[ "${1:-}" = "--show-secrets" ] && SHOW=1

kb_url="$(tf_out kibana_url)"
[ -n "$kb_url" ] || die "no terraform outputs found - deploy first"
secret() { if [ "$SHOW" -eq 1 ]; then tf_out "$1"; else echo "(hidden; use --show-secrets)"; fi; }

echo "Kibana:         $kb_url"
echo "Discover:       ${kb_url%/}/app/discover"
echo "Elasticsearch:  $(tf_out elasticsearch_url)"
echo "Fleet URL:      $(tf_out fleet_url)"
echo "Elastic user:   $(tf_out elastic_username)"
echo "Elastic pass:   $(secret elastic_password)"
echo
echo "Linux VM:       $(tf_out linux_vm_public_ip)"
echo "  SSH:          $(tf_out linux_ssh_command)"
echo "  key:          $(tf_out linux_ssh_private_key_path)"
echo "Windows VM:     $(tf_out windows_vm_public_ip)"
echo "  user:         $(tf_out vm_admin_username)"
echo "  password:     $(secret windows_admin_password)"
