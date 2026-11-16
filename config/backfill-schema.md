# Backfill Document Schema

Contract between the backfill generator (`scripts/`) and the saved searches and ES|QL queries in this directory.
Bulk-index with `create` actions into the data streams below. The Fleet integrations must be installed first
(configure.sh creates the package policies), so the data stream index templates and mappings exist.
Spread `@timestamp` over the last 30 days; ~2M docs total (suggested split: 40% sysmon, 20% windows security,
10% powershell, 15% auditd, 10% auth, 5% syslog).

## Common fields (every document)

| Field | Value |
|---|---|
| `@timestamp` | ISO 8601 UTC, back-dated |
| `data_stream.type` | `logs` |
| `data_stream.dataset` | see table |
| `data_stream.namespace` | `default` |
| `event.dataset` | same as `data_stream.dataset` |
| `event.ingested` | any time >= `@timestamp` |
| `ecs.version` | `8.11.0` |
| `host.name` | one of a small set per OS, e.g. `win-wks-01..05`, `lnx-wks-01..05` |
| `host.hostname` | same as `host.name` |
| `host.os.type` | `windows` or `linux` |
| `host.os.family` | `windows` or `debian` |
| `host.os.name` | `Windows Server 2022 Datacenter` or `Ubuntu` |
| `host.ip` | private IP per host |
| `user.name` | from a pool of ~15 names (e.g. alice, bob, svc_backup, administrator, root) |
| `message` | human-readable text consistent with the event |

## Datasets and data streams

| Data stream | OS | Required extra fields |
|---|---|---|
| `logs-system.security-default` | windows | `event.code` (string), `event.action`, `event.category`, `event.outcome`, `event.provider` = `Microsoft-Windows-Security-Auditing`, `winlog.channel` = `Security`, `winlog.event_id`, `source.ip` (failed logons), `winlog.logon.type` |
| `logs-windows.sysmon_operational-default` | windows | `event.code` = `"1"` for process create (also use `3`, `11`), `event.category` = `process`, `event.type` = `start`, `process.name`, `process.executable`, `process.command_line`, `process.pid`, `process.parent.name`, `process.parent.command_line`, `winlog.channel` = `Microsoft-Windows-Sysmon/Operational` |
| `logs-windows.powershell_operational-default` | windows | `event.code` = `"4104"` mostly (also `4103`), `powershell.file.script_block_text` (include some containing `DownloadString`, `EncodedCommand`, `Invoke-Expression`), `winlog.channel` = `Microsoft-Windows-PowerShell/Operational` |
| `logs-system.auth-default` | linux | `event.category` = `authentication`, `event.outcome` = `success` or `failure`, `event.action` (`ssh_login`, `ssh_login_failed`, `sudo`), `process.name` (`sshd` or `sudo`), `source.ip` for ssh, `system.auth.ssh.method` |
| `logs-system.syslog-default` | linux | `process.name`, `log.syslog.*` optional, `message` |
| `logs-auditd_manager.auditd-default` | linux | `auditd.data.syscall` = `execve` (majority), `event.category` = `process`, `event.action` = `executed`, `process.name`, `process.executable`, `process.args`, `process.pid`, `process.parent.pid` |

## Value rules

- Failed logons: Windows `event.code: "4625"`, `event.outcome: "failure"`, `event.category: "authentication"`.
  Successful logons: `event.code: "4624"`, `event.outcome: "success"`.
- Include a few `source.ip` values that fail more than 10 times in 5 minutes (supports ES|QL query 4).
- Account management on windows: `event.code` in `4720`, `4722`, `4724`, `4732`, `4738`.
- `event.code` must be a string for all datasets.
- Keep `process.name` lowercase for Windows (for example `powershell.exe`), and populate `process.command_line` for Sysmon.

## Validation

After loading, each saved search in `saved-searches.ndjson` and each query in `esql-queries.md` must return rows.
