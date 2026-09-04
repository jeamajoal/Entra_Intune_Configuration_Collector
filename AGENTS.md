# Repository Agent Guidance

## Current Repository State

- This repository is in initialization state.
- Product implementation code is not yet committed.
- Durable architecture owner: docs/architecture/solution-architecture.md.

## Engineering Intent for First Development Cycle

- Build a staged PowerShell metadata collector for Entra, Intune, and on-prem AD or GPO.
- Use inventory-first JSON snapshot collection, then metadata enrichment stages.
- Support stage or section resume using checkpoint artifacts.

## Scope Boundaries

- Treat ACLs, memberships, and assignments as metadata.
- Include Entra enterprise applications and app registrations, Intune applications and scripts, and on-prem AD or GPO metadata.
- Exclude mailbox or collaboration workloads, Defender telemetry domains, and audit or sign-in stream ingestion.

## Source of Live Work State

- GitHub Issues are the canonical owner for roadmap and first-cycle execution state.
- Do not maintain a parallel checked-in status tracker.
