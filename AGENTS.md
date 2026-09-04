# Repository Agent Guidance

## Current Repository State

- First implementation candidate for the staged PowerShell collector is committed under collector/.
- Durable architecture owner remains docs/architecture/solution-architecture.md.
- Canonical live execution and roadmap state remains GitHub Issue #1 and related issue threads.

## Engineering Intent for First Development Cycle

- Preserve staged execution with Stage1 inventory, Stage2 detail, and Stage3 relationship collection.
- Preserve inventory-first gating for Stage2 and Stage3.
- Preserve stage-only and section-only execution with checkpoint-based resume and failed-only reprocessing.

## Scope Boundaries

- Treat ACLs, memberships, and assignments as metadata.
- Include Entra enterprise applications and app registrations, Intune applications and scripts, and on-prem AD or GPO metadata.
- Exclude mailbox or collaboration workloads, Defender telemetry domains, and audit or sign-in stream ingestion.

## Source of Live Work State

- GitHub Issues are the canonical owner for roadmap and first-cycle execution state.
- Do not maintain a parallel checked-in status tracker.
