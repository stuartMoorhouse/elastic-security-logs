# ES|QL Queries for Discover

Switch Discover to ES|QL mode and paste a query. Set the time picker to the last 30 days.
Field names assume the datasets listed in `backfill-schema.md`; validate against the live 9.5 cluster
(`scripts/verify.sh` should POST each query to `/_query`).

## 1. Event volume per day by OS

```esql
FROM logs-*
| STATS events = COUNT(*) BY day = BUCKET(@timestamp, 1 day), host.os.type
| SORT day
```

## 2. Events per dataset

```esql
FROM logs-*
| STATS events = COUNT(*) BY data_stream.dataset
| SORT events DESC
```

## 3. Failed logons by user and host (Windows and Linux)

```esql
FROM logs-*
| WHERE event.code == "4625" OR (event.dataset == "system.auth" AND event.outcome == "failure")
| STATS failures = COUNT(*) BY user.name, host.name
| SORT failures DESC
| LIMIT 20
```

## 4. Brute-force pattern: more than 10 failures from one source in 5 minutes

```esql
FROM logs-*
| WHERE event.code == "4625" OR (event.dataset == "system.auth" AND event.outcome == "failure")
| STATS failures = COUNT(*) BY source.ip, window = BUCKET(@timestamp, 5 minutes)
| WHERE failures > 10
| SORT failures DESC
| LIMIT 50
```

## 5. Logon success versus failure per hour

```esql
FROM logs-*
| WHERE event.category == "authentication"
| STATS events = COUNT(*) BY hour = BUCKET(@timestamp, 1 hour), event.outcome
| SORT hour
```

## 6. Sudo usage by user

```esql
FROM logs-system.auth-*
| WHERE process.name == "sudo"
| STATS commands = COUNT(*) BY user.name, host.name
| SORT commands DESC
| LIMIT 20
```

## 7. Top processes created on Windows (Sysmon event 1)

```esql
FROM logs-windows.sysmon_operational-*
| WHERE event.code == "1"
| STATS launches = COUNT(*) BY process.name
| SORT launches DESC
| LIMIT 20
```

## 8. Suspicious PowerShell script blocks

```esql
FROM logs-windows.powershell_operational-*
| WHERE event.code == "4104" AND powershell.file.script_block_text RLIKE ".*(DownloadString|EncodedCommand|Invoke-Expression|FromBase64String).*"
| KEEP @timestamp, host.name, user.name, powershell.file.script_block_text
| SORT @timestamp DESC
| LIMIT 50
```

## 9. Linux process execution (auditd execve)

```esql
FROM logs-auditd_manager.auditd-*
| WHERE auditd.data.syscall == "execve"
| STATS executions = COUNT(*) BY host.name, process.name
| SORT executions DESC
| LIMIT 20
```

## 10. Account management events on Windows

```esql
FROM logs-system.security-*
| WHERE event.code IN ("4720", "4722", "4724", "4732", "4738")
| STATS changes = COUNT(*) BY event.code, event.action, user.name
| SORT changes DESC
| LIMIT 50
```

## 11. Password spraying or brute force followed by a successful logon

Sources with many failures and at least one success. A high `users_tried` points to spraying; one user with many failures points to brute force. Pivot to the `source.ip` in Discover to see what the account did next.

```esql
FROM logs-*
| WHERE source.ip IS NOT NULL
    AND (event.code IN ("4624", "4625")
         OR (event.dataset == "system.auth" AND event.outcome IN ("success", "failure")))
| EVAL failed = CASE(event.outcome == "failure", 1, 0),
       ok     = CASE(event.outcome == "success", 1, 0)
| STATS failures = SUM(failed),
        successes = SUM(ok),
        users_tried = COUNT_DISTINCT(user.name),
        first_seen = MIN(@timestamp),
        last_seen = MAX(@timestamp)
  BY source.ip
| WHERE failures > 20 AND successes > 0
| SORT failures DESC
```
