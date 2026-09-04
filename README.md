# Entra Intune Configuration Collector

This repository contains the architecture and initialization contract for a staged PowerShell automation that collects Microsoft Entra ID, Intune, and on-premises Active Directory or GPO configuration metadata for downstream AI analysis.

Current status: architecture discovery accepted, first development cycle contract pending implementation.

## Repository Navigation

- Solution architecture: [docs/architecture/solution-architecture.md](docs/architecture/solution-architecture.md)
- Repository engineering guardrails: [AGENTS.md](AGENTS.md)

## Scope Summary

- In scope: configuration and authorization metadata collection across Entra, Intune, and on-prem AD or GPO.
- ACLs, memberships, and assignments are treated as metadata.
- Out of scope: mailbox or collaboration workloads, Defender telemetry, secrets extraction, and audit or sign-in event streams.

## Implementation Note

No product collector code is committed yet. This repository is currently in architecture and planning state.
Planned execution is inventory-first JSON snapshot collection followed by staged metadata enrichment.
