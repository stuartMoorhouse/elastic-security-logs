# config/

Static payloads for the Elastic solution layer. Consumed by `scripts/configure.sh`. Nothing here talks to a live service.

Placeholders replaced by the script: `__POLICY_ID__` (Fleet agent policy id), `__PKG_VERSION__` (latest package version from `GET /api/fleet/epm/packages/<name>`).

| File | Purpose | Target API |
|---|---|---|
| `component-template-security-logs-lifecycle.json` | Sets the data stream lifecycle (`data_retention: 90d`; Serverless has no ILM or tiers). PUT the same body to each `@custom` component template listed below | `PUT /_component_template/<name>` (Elasticsearch) |
| `package-policy-linux-system.json` | System integration: Linux auth and syslog | `POST /api/fleet/package_policies` (Kibana) |
| `package-policy-linux-auditd.json` | Auditd Manager integration with execve, identity and sudoers rules | `POST /api/fleet/package_policies` |
| `package-policy-windows-system.json` | System integration on Windows: Security, System, Application event logs | `POST /api/fleet/package_policies` |
| `package-policy-windows.json` | Windows integration: Sysmon Operational and PowerShell Operational | `POST /api/fleet/package_policies` |
| `kibana-data-views.ndjson` | Data views `dv-logs-all`, `dv-logs-system`, `dv-logs-windows`, `dv-logs-auditd` | `POST /api/saved_objects/_import?overwrite=true` (multipart, header `kbn-xsrf`) |
| `saved-searches.ndjson` | `security-logs-demo` tag plus one tagged Discover session (`Security logs demo`) with one ES|QL query per tab: tabs for failed logons, sudo usage, PowerShell activity, new processes, event volume by OS, brute force and spray-then-success (no data view needed) | `POST /api/saved_objects/_import?overwrite=true` |
| `esql-queries.md` | 10 ES|QL queries for Discover (documentation, not imported) | `POST /_query` for verification |
| `backfill-schema.md` | Field contract for the synthetic backfill generator | none |

## Lifecycle application: `@custom` component templates

Integration data streams are composed of `logs-<package>.<dataset>@package` and `logs-<package>.<dataset>@custom`;
`@custom` is applied last, so its `lifecycle` overrides the default retention. PUT the lifecycle body to:

- `logs-system.auth@custom`
- `logs-system.syslog@custom`
- `logs-system.security@custom`
- `logs-system.application@custom`
- `logs-system.system@custom`
- `logs-windows.sysmon_operational@custom`
- `logs-windows.powershell_operational@custom`
- `logs-auditd_manager.auditd@custom`
- `logs@custom` (covers any other logs-*-* data stream, for example the backfill if it creates streams outside integrations)

Do this before installing package policies or loading data so the first backing indices already carry the retention.

## Format notes

- Package policies use the simplified `inputs` object format (inputs keyed `<policy_template>-<input_type>`, streams keyed by `<package>.<dataset>`) and `policy_ids` (array) rather than the deprecated `policy_id`.
  Input and stream keys must be validated against `GET /api/fleet/epm/packages/<name>/<version>` on the live Serverless project; a mismatch returns HTTP 400 naming the key.
- The Fleet agent policy created with `sys_monitoring=true` already contains a default `system` package policy
  that would duplicate the System integration here (and collect metrics). Create the policies with `sys_monitoring=false`, or delete that default package policy first.
- Saved search ES|QL uses `auditd.data.syscall`, `powershell.file.script_block_text` and `event.dataset` values from the real integrations; confirm after the first live ingest.
