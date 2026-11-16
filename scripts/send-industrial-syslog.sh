#!/usr/bin/env bash
# Run the industrial syslog sender (scripts/industrial_syslog.py) on the Linux VM.
# The sender talks to the Elastic Agent's syslog input on the same VM via localhost,
# so no network security group changes are needed.
#
# Usage: scripts/send-industrial-syslog.sh start [udp|tcp] | stop | status | samples
#   start    copy the sender to the VM and run it in the background (default protocol: udp)
#   stop     stop the sender
#   status   show whether the sender is running and its recent output
#   samples  regenerate the sample files in config/industrial-syslog/ locally (for the wizard)
# Ports: Hirschmann 5514, Moxa 5515 (set the same ports on the integration's UDP/TCP inputs).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need ssh; need scp; need python3

ACTION="${1:-}"; PROTO="${2:-udp}"
REMOTE_DIR="/home/azureuser/industrial"

if [ "$ACTION" = "samples" ]; then
  python3 "$ROOT_DIR/scripts/industrial_syslog.py" samples --out-dir "$CONFIG_DIR/industrial-syslog"
  exit 0
fi

IP="$(tf_out linux_vm_public_ip)"; KEY="$(tf_out linux_ssh_private_key_path)"; USER_NAME="$(tf_out vm_admin_username)"
[ -n "$IP" ] && [ -n "$KEY" ] && [ -n "$USER_NAME" ] || die "terraform outputs missing (linux_vm_public_ip, linux_ssh_private_key_path, vm_admin_username). Deploy first."
[ -f "$KEY" ] || die "SSH key not found: $KEY"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
rssh() { ssh "${SSH_OPTS[@]}" "$USER_NAME@$IP" "$@"; }

case "$ACTION" in
  start)
    [ "$PROTO" = "udp" ] || [ "$PROTO" = "tcp" ] || die "protocol must be udp or tcp"
    rssh "mkdir -p $REMOTE_DIR" || die "cannot SSH to $IP (is your IP still allowed by the NSG?)"
    scp "${SSH_OPTS[@]}" "$ROOT_DIR/scripts/industrial_syslog.py" "$USER_NAME@$IP:$REMOTE_DIR/" >/dev/null
    rssh "pkill -f industrial_syslog.py || true; cd $REMOTE_DIR && nohup python3 industrial_syslog.py send --proto $PROTO > sender.log 2>&1 &"
    sleep 2
    rssh "pgrep -f 'industrial_syslog.py send' >/dev/null" && echo "sender running on $IP ($PROTO, ports 5514/5515)" || die "sender did not start; see $REMOTE_DIR/sender.log on the VM"
    echo "Note: messages are dropped until the integration's syslog inputs are listening (add it to the linux-workstations policy)."
    ;;
  stop)
    rssh "pkill -f industrial_syslog.py || true"; echo "sender stopped"
    ;;
  status)
    if rssh "pgrep -f 'industrial_syslog.py send' >/dev/null"; then echo "running"; else echo "not running"; fi
    rssh "tail -5 $REMOTE_DIR/sender.log 2>/dev/null || true"
    ;;
  *) die "usage: $0 start [udp|tcp] | stop | status | samples" ;;
esac
