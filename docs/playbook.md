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
4. **Asset inventory**: distinct hosts and data streams seen in the last 30 days, with event counts and first and last
   seen. Use it to show an asset inventory built from log data (ISO/IEC 27001 5.9, IEC 62443-2-1 CM 1.1).

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

## 6. Standards mapping (reference, not a demo step)

Use this when a prospect asks how the demo relates to ISO/IEC 27001 or IEC 62443. Elastic provides logging, monitoring
and event-analysis evidence for these controls. It does not make an organization compliant.

IEC 62443-3-3 system requirements (SRs) describe capabilities of the control system itself. In this demo Elastic sits
outside the control system, so it supports the asset-owner requirements in IEC 62443-2-1 (EVENT, DATA, CM) and gives
evidence in the 3-3 areas for auditable events (SR 2.x) and timely response to events (SR 6.x).

| What the demo shows | ISO/IEC 27001:2022 Annex A | IEC 62443 |
|---|---|---|
| Windows, Linux and auditd logs collected in one place, with ECS fields | 8.15 Logging | 3-3 SR 2.8 Auditable events; 2-1 EVENT 1.4 Logging |
| Failed logons, brute force and spray-then-success tabs | 8.16 Monitoring activities; 5.25 Assessment of security events | 3-3 SR 6.2 Continuous monitoring; 2-1 EVENT 1.7 Event analysis |
| Sudo, PowerShell and new-process tabs | 8.15, 8.16 | 3-3 SR 2.8; 2-1 EVENT 1.1 Event detection |
| 90-day retention on the data streams | 8.15 (logs stored and protected) | 3-3 SR 2.9 Audit storage capacity; 2-1 DATA 1.4 Data retention policy |
| Searching and pivoting on logs in Discover | 5.28 Collection of evidence | 3-3 SR 6.1 Audit log accessibility |
| Industrial syslog from Hirschmann and Moxa devices (optional step 5) | 8.16 Monitoring activities | 3-3 SR 6.2; 2-1 NET 3.2 Remote access connections (if remote sessions are logged) |
| Asset inventory tab | 5.9 Inventory of information and other associated assets | 2-1 CM 1.1 Asset inventory baseline |

Not covered by this demo:

- Zone boundary protection (3-3 SR 5.2) and the zones and conduits model (IEC 62443-3-2). These would need network or
  firewall logs tagged by security zone.
- Timestamps and clock synchronization (3-3 SR 2.11, ISO/IEC 27001 8.17). The data has `@timestamp`, but the demo does
  not show time synchronization of the sources.

Source for the framing: ISAGCA, "Securing Operational Technology: Understanding the ISA/IEC 62443 Series of Standards
from an ISO/IEC 27001 and ISO/IEC 27002 Perspective" (June 2025). Check requirement numbers and wording against the
standards before quoting them to a customer.

## Reset and clean up

- Reload data: `scripts/reset-demo.sh --rebackfill`.
- Stop the industrial feed: `scripts/send-industrial-syslog.sh stop`.
- Tear down everything (stops all billing): `scripts/destroy.sh`.
