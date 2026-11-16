#!/usr/bin/env python3
"""Synthetic industrial network syslog (Hirschmann switches, Moxa switches and gateways).

The formats are plausible approximations of each vendor's style, NOT authentic captures:
  - Hirschmann: BSD-style (RFC 3164) syslog with HM2-<MODULE> tags and free-text messages.
  - Moxa:       RFC 5424 syslog with structured data ([meta ...]), event ids and key=value text.
Two different, vendor-specific formats are what Automatic Import has to learn.

Subcommands:
  samples  write sample files for the Automatic Import wizard (no network)
  send     send live syslog over UDP or TCP (run on the Linux VM, to the Agent's syslog input)
"""
import argparse
import datetime as dt
import random
import socket
import sys
import time

HM_HOSTS = ["RSP35-plant1-sw01", "RSP20-plant1-sw02", "GRS1042-cell3-gw", "BRS30-line2-sw", "MSP30-core-sw"]
MX_HOSTS = [("EDS-G512E-cell3", "MOXA0012345", "v3.9"), ("EDS-408A-line1", "MOXA0023456", "v3.11"),
            ("MGate-5105-line1", "MOXA0034567", "v4.2"), ("MGate-5109-line2", "MOXA0045678", "v4.3"),
            ("TN-4516A-core", "MOXA0056789", "v3.6")]
ENG_IPS = ["10.40.5.20", "10.40.5.21", "10.40.5.22"]
ATTACK_IPS = ["203.0.113.45", "198.51.100.77"]
PLC_IPS = ["10.40.8.%d" % i for i in range(10, 20)]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def mac(r):
    return ":".join("%02x" % r.randint(0, 255) for _ in range(6))


# ---- Hirschmann (RFC 3164 style) -------------------------------------------------------------
# (severity, module, template)
HM_EVENTS = [
    (4, "IFMGR", "Port {port} link down"),
    (6, "IFMGR", "Port {port} link up ({speed} Mbit/s full duplex)"),
    (3, "MRP", "Ring 1: redundancy lost, ring port {port} down"),
    (5, "MRP", "Ring 1: ring closed, redundancy restored, role manager"),
    (4, "USER", "Login failed for user '{user}' from {ip} ({proto})"),
    (6, "USER", "User '{user}' logged in from {ip} ({proto})"),
    (5, "CFG", "Configuration saved to NVM by user '{user}'"),
    (5, "CFG", "Firmware update to {fw} initiated by user '{user}'"),
    (4, "PORTSEC", "Port {port} violation, unauthorized MAC {mac} dropped"),
    (5, "STP", "Topology change on instance 0, root bridge 8000.{rootmac}"),
    (2, "PWR", "Power supply {psu} failed"),
    (5, "PWR", "Power supply {psu} restored"),
    (5, "SYS", "Cold start, firmware {fw}"),
]
HM_WEIGHTS = [20, 18, 4, 4, 8, 8, 4, 1, 6, 6, 1, 1, 1]


def hm_line(r, t, idx=None):
    i = idx if idx is not None else r.choices(range(len(HM_EVENTS)), weights=HM_WEIGHTS)[0]
    sev, module, tmpl = HM_EVENTS[i]
    attack = module == "USER" and "failed" in tmpl
    msg = tmpl.format(port="1/%d" % r.randint(1, 8), speed=r.choice([100, 1000]),
                      user=r.choice(["admin", "operator", "service"]) if not attack else r.choice(["admin", "root", "guest"]),
                      ip=r.choice(ATTACK_IPS) if attack and r.random() < 0.5 else r.choice(ENG_IPS),
                      proto=r.choice(["ssh", "web", "snmp"]), fw="HiOS-2A-09.4.0%d" % r.randint(1, 3),
                      mac=mac(r), rootmac=mac(r).replace(":", ""), psu=r.choice([1, 2]))
    pri = 16 * 8 + sev  # local0
    host = r.choice(HM_HOSTS)
    ts = "%s %2d %s" % (MONTHS[t.month - 1], t.day, t.strftime("%H:%M:%S"))
    return "<%d>%s %s HM2-%s: %s" % (pri, ts, host, module, msg)


# ---- Moxa (RFC 5424 with structured data) ----------------------------------------------------
# (severity, event id, template)
MX_EVENTS = [
    (4, "EVT2005", "Port {port} link down"),
    (6, "EVT2006", "Port {port} link up speed={speed}M duplex=full"),
    (4, "EVT3010", "Turbo Ring: ring break detected on port {port} ring_id=1"),
    (5, "EVT3011", "Turbo Ring: ring recovered ring_id=1 role=master"),
    (4, "EVT4001", "Modbus timeout serial_port={sport} slave_id={slave} count={count}"),
    (6, "EVT4002", "Modbus TCP connection {state} client={plc} port=502"),
    (4, "EVT5001", "Login failed user={user} src={ip} method={proto}"),
    (5, "EVT5002", "Configuration changed by user={user} via {proto}"),
    (4, "EVT6001", "Digital input DI{di} changed to {dival}"),
    (5, "EVT1001", "Cold start firmware={fw}"),
]
MX_WEIGHTS = [18, 16, 4, 4, 12, 18, 6, 4, 8, 1]


def mx_line(r, t, idx=None):
    i = idx if idx is not None else r.choices(range(len(MX_EVENTS)), weights=MX_WEIGHTS)[0]
    sev, evt, tmpl = MX_EVENTS[i]
    host, sn, fw = r.choice(MX_HOSTS)
    attack = evt == "EVT5001"
    msg = tmpl.format(port=r.randint(1, 8), speed=r.choice([100, 1000]), sport=r.randint(1, 4),
                      slave=r.randint(1, 30), count=r.randint(1, 5), state=r.choice(["accepted", "closed"]),
                      plc=r.choice(PLC_IPS), user=r.choice(["admin", "operator", "root"]),
                      ip=r.choice(ATTACK_IPS) if attack and r.random() < 0.5 else r.choice(ENG_IPS),
                      proto=r.choice(["https", "ssh", "telnet"]), di=r.randint(1, 4),
                      dival=r.choice(["ON", "OFF"]), fw=fw)
    pri = 3 * 8 + sev  # daemon facility
    return '<%d>1 %s %s moxa-evt %d %s [meta sn="%s" fw="%s"] %s' % (
        pri, t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000),
        host, r.randint(100, 4000), evt, sn, fw, msg)


def build(vendor, n, seed, now=None):
    """First len(EVENTS) lines cover every event type once (the wizard reads from the top)."""
    r = random.Random(seed)
    now = now or dt.datetime.now(dt.timezone.utc)
    events, fn = (HM_EVENTS, hm_line) if vendor == "hirschmann" else (MX_EVENTS, mx_line)
    lines = []
    t = now - dt.timedelta(seconds=n * 60)
    for k in range(n):
        t += dt.timedelta(seconds=r.randint(20, 90), milliseconds=r.randint(0, 999))
        lines.append(fn(r, t, idx=k if k < len(events) else None))
    return lines


def cmd_samples(a):
    for vendor in ("hirschmann", "moxa"):
        path = "%s/%s-sample.log" % (a.out_dir.rstrip("/"), vendor)
        with open(path, "w") as f:
            f.write("\n".join(build(vendor, a.lines, a.seed)) + "\n")
        print("wrote %s (%d lines)" % (path, a.lines))


def cmd_send(a):
    r = random.Random()
    targets = [("hirschmann", a.hirschmann_port, hm_line), ("moxa", a.moxa_port, mx_line)]
    socks = {}
    for vendor, port, _ in targets:
        if a.proto == "udp":
            socks[vendor] = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        else:
            socks[vendor] = None  # opened lazily; TCP syslog is newline framed
    sent = 0
    while True:
        for vendor, port, fn in targets:
            line = fn(r, dt.datetime.now(dt.timezone.utc))
            try:
                if a.proto == "udp":
                    socks[vendor].sendto(line.encode(), (a.host, port))
                else:
                    if socks[vendor] is None:
                        socks[vendor] = socket.create_connection((a.host, port), timeout=5)
                    socks[vendor].sendall((line + "\n").encode())
            except OSError as e:
                if a.proto == "tcp":
                    socks[vendor] = None
                print("WARN %s:%d %s" % (a.host, port, e), file=sys.stderr)
            sent += 1
        if a.count and sent >= a.count:
            break
        time.sleep(1.0 / a.rate)
    print("sent %d messages" % sent)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("samples")
    s.add_argument("--out-dir", default="config/industrial-syslog")
    s.add_argument("--lines", type=int, default=200)
    s.add_argument("--seed", type=int, default=7)
    s.set_defaults(fn=cmd_samples)
    d = sub.add_parser("send")
    d.add_argument("--host", default="127.0.0.1")
    d.add_argument("--proto", choices=["udp", "tcp"], default="udp")
    d.add_argument("--hirschmann-port", type=int, default=5514)
    d.add_argument("--moxa-port", type=int, default=5515)
    d.add_argument("--rate", type=float, default=2.0, help="iterations per second (one message per vendor each)")
    d.add_argument("--count", type=int, default=0, help="stop after N messages (0 = run until killed)")
    d.set_defaults(fn=cmd_send)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
