#!/usr/bin/env bash
# Linux activity generator (run ON the Linux VM as a sudo-capable user).
# Produces benign auth, sudo, process-exec and account-management events for auth.log,
# syslog and auditd. Idempotent: the temp user is removed at the end of every run.
# Usage: ./generate-activity.sh [rounds]   (default 5)
set -uo pipefail

ROUNDS="${1:-5}"
TMPUSER="demo_tmp_user"
[ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null || { echo "ERROR: need root or sudo"; exit 1; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

cleanup() { $SUDO userdel -r "$TMPUSER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

for round in $(seq 1 "$ROUNDS"); do
  echo "round $round/$ROUNDS"

  # Failed SSH logins (invalid users and bad passwords); BatchMode prevents prompts.
  for u in admin test oracle backup "$TMPUSER"; do
    ssh -o BatchMode=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
        "$u@127.0.0.1" true >/dev/null 2>&1 || true
  done

  # sudo: successful use and a failed password attempt
  $SUDO -n true >/dev/null 2>&1 || true
  $SUDO -n ls /root >/dev/null 2>&1 || true
  if [ "$(id -u)" -ne 0 ]; then
    sudo -k
    echo "wrong-password" | sudo -S -p '' true >/dev/null 2>&1 || true
  fi

  # Ordinary process execution
  ls -la /home >/dev/null; id >/dev/null; whoami >/dev/null; ps aux >/dev/null
  uname -a >/dev/null; cat /etc/passwd >/dev/null; systemctl status ssh >/dev/null 2>&1 || true
  curl -s -m 3 -o /dev/null http://127.0.0.1/ || true
  python3 -c 'print("activity")' >/dev/null

  # Account management
  $SUDO useradd -m "$TMPUSER" >/dev/null 2>&1 || true
  $SUDO usermod -aG users "$TMPUSER" >/dev/null 2>&1 || true
  $SUDO userdel -r "$TMPUSER" >/dev/null 2>&1 || true

  sleep 2
done
echo "done"
