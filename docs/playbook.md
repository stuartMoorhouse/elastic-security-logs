# Demo Playbook

Objective: show Elastic Discover as a log search and management platform on Elastic Cloud Serverless Security,
using Windows and Linux workstation logs collected by Fleet and Elastic Agent. About 20 minutes.

Key messages:
- One place to search logs from Windows and Linux hosts, in seconds, across 30 days (about 2M events).
- Agents are managed centrally in Fleet; data arrives as ECS-normalised data streams.
- Serverless: no cluster, tiers or ILM to manage. Retention is a data stream lifecycle (90 days).
- Optional: AI-assisted onboarding of unusual log formats with Automatic Import.

## Before the demo

1. Deploy and load data (once): `terraform apply` in `terraform/`, then `scripts/configure.sh` and `scripts/backfill.sh`.
2. `scripts/verify.sh` should report PASS for criteria 1 to 9.
3. `scripts/get-credentials.sh --show-secrets` for the Kibana URL and login.
4. Optional, to produce fresh events during the demo: run `scripts/generate-activity.sh` on the Linux VM (SSH command
   from `terraform output linux_ssh_command`) and `scripts/generate-activity.ps1` on the Windows VM (RDP).
5. Optional industrial segment: run the Automatic Import wizard beforehand if you do not want to wait for the analysis
   (see `config/industrial-syslog/README.md`).

## 1. Fleet: where the data comes from (3 min)

1. Kibana > Fleet > Agents. Two agents are Healthy: a Linux and a Windows VM on Azure, on-demand (not Spot).
2. Open the `linux-workstations` and `windows-workstations` policies. Show the integrations: System, Auditd Manager
   (Linux); System, Windows with Sysmon and PowerShell (Windows).
3. Point out that adding a host is one install command with an enrollment token, and a policy change reaches all
   hosts without touching them.

## 2. Discover: search and explore (7 min)

1. Open Discover, ES|QL mode. Search for: 

´
FROM logs-*
| LIMIT 100
´

Set the time range to the last 30 days: the histogram shows the full range.

2. Add the `host.os.type` and `data_stream.dataset` fields from the sidebar to show the split by OS and source.
3. Open the saved session (Open in the top menu): **Security logs demo**. Each tab holds one ES|QL query:
   - **Failed logons**: one query across Windows 4625 and Linux auth failures.
   - **Sudo usage**
   - **PowerShell activity**
   - **New processes** (Sysmon 1 and auditd execve)
4. Narrow in live: in the Failed logons tab click a `user.name` or `source.ip` value to filter, then pin the filter.
5. Edit the ES|QL in a tab, for example add `| WHERE host.name == "winws01"`, then change `FROM logs-*` to
   `FROM logs-windows.*`, `logs-system.*` or `logs-auditd_manager.*` to show scoping.
6. Open a document: show ECS fields next to the original message.

## 3. ES|QL in Discover (4 min)

Stay in the **Security logs demo** session and move to the aggregation tabs. Each runs the matching query from
`config/esql-queries.md`; set the time range to the last 30 days.

1. **Event volume by OS** (query 1): a table plus the visualization. Use the chart toggle to switch between them.
2. **Brute force (5 min)** (query 4): more than 10 failures from one source in 5 minutes.
3. **Spray then success** (query 11): password spraying followed by a successful logon, the pipeline form of a
   correlation question.

To show that sessions are reusable, change a query in one tab and use Save to update the session, or Save as new.

## 4. Data management on Serverless (3 min)

1. Stack Management > Index Management > Data Streams: show the `logs-*` data streams.
2. Open one data stream and show the lifecycle: delete after 90 days.
3. Message: there is no hot/frozen tiering to size or tune on Serverless. Retention is one setting, and older data
   stays searchable in the same Discover view. The setting comes from `config/component-template-security-logs-lifecycle.json`.

## 5. Optional: Automatic Import for industrial devices (5 min)

Follow the walkthrough in `config/industrial-syslog/README.md`: upload Hirschmann and Moxa syslog samples, let the LLM
build the integration, then show the same ECS fields coming out of two different formats. Start the live feed with
`scripts/send-industrial-syslog.sh start` and show it arriving in Discover. The samples are synthetic approximations
of the vendor formats, not authentic device captures.

## Reset and clean up

- Reload data: `scripts/reset-demo.sh --rebackfill`.
- Stop the industrial feed: `scripts/send-industrial-syslog.sh stop`.
- Tear down everything (stops all billing): `scripts/destroy.sh`.
