# Industrial switches and gateways via Automatic Import

Demonstrates AI-assisted normalization of vendor-specific syslog (Hirschmann switches, Moxa switches and
gateways) into ECS using Kibana Automatic Import. The wizard is a manual, live step: Automatic Import has no
documented public API.

## Files

| File | Purpose |
|---|---|
| `hirschmann-sample.log` | 200 synthetic lines, BSD-style syslog (RFC 3164) with `HM2-<MODULE>` tags and free-text messages. The first lines cover each event type once. |
| `moxa-sample.log` | 200 synthetic lines, RFC 5424 syslog with structured data (`[meta sn=... fw=...]`), event ids and key=value text. |
| `../../scripts/industrial_syslog.py` | Generates the samples and sends live syslog (UDP or TCP). |
| `../../scripts/send-industrial-syslog.sh` | Runs the sender on the Linux VM. |
| `../../scripts/configure-industrial.sh` | Post-wizard: data stream lifecycle, data view, saved searches, ES|QL examples. |

The two formats are plausible approximations of each vendor's style, not authentic device captures. Say so if asked.
Regenerate the samples with `scripts/send-industrial-syslog.sh samples`.

## Prerequisites (checked on this deployment)

- Enterprise license: active (required by Automatic Import).
- LLM connector: Elastic-managed connectors are preconfigured, for example "Anthropic Claude Sonnet 5.5".
- Kibana Serverless uses the 9.4+ flow: several data streams per integration, then Review and approve.

## Walkthrough

1. Kibana > Integrations > **Create integration** (under "Can't find an integration?").
2. Select an LLM connector (top right). Title: `Industrial Network Devices`. Add a description.
3. **Add Data Stream** twice:
   - `Hirschmann switches`, data collection method **UDP**, upload `hirschmann-sample.log`.
   - `Moxa switches and gateways`, data collection method **UDP**, upload `moxa-sample.log`.
4. **Analyze logs**. This takes several minutes. Both data streams must reach Success.
5. In **Manage my integrations**, open the integration's Actions menu > **Review and approve**. Pick a category and
   review the field mappings and ingest pipeline. Point out how the same ECS fields (`source.ip`, `user.name`,
   `event.action`, `host.name`, ...) come out of two different formats. Approving also installs it by default.
6. Note the generated package name (Integrations > the integration > URL, or run
   `scripts/configure-industrial.sh` with no arguments to list installed packages), then:
   `scripts/configure-industrial.sh --package <name>`
7. Add the integration to the **linux-workstations** policy. Set the UDP listen host `localhost`, port **5514** for
   the Hirschmann input and **5515** for the Moxa input.
8. `scripts/send-industrial-syslog.sh start` (UDP) to start the live feed from the Linux VM.
9. In Discover, open the data view "Industrial switches and gateways" or the saved searches "Industrial devices - ...".
   Queries are in `results/industrial-esql-queries.md` (written by step 6).
10. `scripts/verify.sh` criteria 10 and 11 now report PASS.

Stop the feed with `scripts/send-industrial-syslog.sh stop`.

## Demo talking points

- Before: the raw line is one string in `event.original`. After: ECS fields, searchable across vendors.
- The LLM only saw the first samples of each file (limits: 1,000 samples, 10 MB on 9.4+), which is why each file
  starts with one line of every event type.
- The generated pipeline is editable (Review and approve > pipeline) when a mapping needs a human decision.
- The integration is a normal Fleet package: versioned, installable on other policies, and its data streams use the
  same 90d data stream lifecycle as everything else.

## Streams versus Automatic Import

Both parse unstructured logs, but they solve different problems.

| | Automatic Import | Streams |
|---|---|---|
| Output | A reusable integration package (pipeline, ECS mappings, data streams, Agent input) | Processing rules on an existing stream |
| Ingest path | Creates the Agent input (UDP/TCP/file) | You supply the input separately |
| Fit for "new vendor format" | Strong: onboarding a device family end to end | Good for tuning or re-parsing data already flowing |

Streams is not part of this demo. I did not find documentation of its AI-assisted parsing for 9.5.6, so this table
is about the documented scope of each feature, not a tested comparison.

## Assumptions to check on first run

- Fleet-installed custom packages are expected to compose `logs-<package>.<dataset>@custom`, which is how the lifecycle
  policy gets attached. `configure-industrial.sh` creates those and rolls over; criterion 11 confirms it worked.
- Field names in the saved searches and ES|QL examples beyond `@timestamp`, `data_stream.dataset` and
  `event.original` depend on what the LLM mapped. Adjust after the review screen.
