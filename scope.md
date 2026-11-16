Elastic Security Logs

A terraform project to create an Elastic Cloud Serverless Security project which contains synthetic logs from:

Windows workstations
Linux workstations

For the purpose of demoing Elastic (specificaly Discover) as a log-search and management platform.

Serverless has no tiers (no Frozen tier) and no ILM; retention is managed with a data stream lifecycle (90d).

Use Elastic Fleet and Agent to get the data from 2 VMs (one Linux and one Windows) on Azure. Do not use spot instances or the VMs.
