# Repository Agent Guidance

## Current Repository State

- First implementation candidate for the staged PowerShell collector is committed under collector/.
- Durable architecture owner remains docs/architecture/solution-architecture.md.
- Canonical live execution and roadmap state remains GitHub Issue #1 and related issue threads.
- Canonical collector authorization/dependency inventory is docs/permissions/permission-matrix.json, with operator guidance in docs/permissions.md.

## Engineering Intent for First Development Cycle

- Preserve staged execution with Stage1 inventory, Stage2 detail, and Stage3 relationship collection.
- Preserve inventory-first gating for Stage2 and Stage3.
- Preserve stage-only and section-only execution with checkpoint-based resume and failed-only reprocessing.

## Scope Boundaries

- Treat ACLs, memberships, and assignments as metadata.
- Include Entra enterprise applications and app registrations, Intune applications and scripts, and on-prem AD or GPO metadata.
- Exclude mailbox or collaboration workloads, Defender telemetry domains, and audit or sign-in stream ingestion.

## Permission Lifecycle Gate

- Any PR that adds, removes, or changes a collector section, family, Microsoft Graph endpoint/API version, or on-prem external cmdlet/provider dependency must review and update `docs/permissions/permission-matrix.json` in the same PR.
- Verify Graph permission claims against current Microsoft Learn documentation and prefer read-only application permissions for unattended collection. Do not add a ReadWrite permission solely to make a GET/read-only collector call work.
- Record delegated permission and signed-in-user role caveats separately; a delegated OAuth scope does not by itself prove the user is authorized for every Entra read surface.
- Keep `docs/permissions.md` and README prerequisite guidance aligned when the practical permission or module contract changes.
- `tests/unit/PermissionMatrixConformance.Tests.ps1` must continue to prove production Graph endpoint and on-prem external command coverage.

## Source of Live Work State

- GitHub Issues are the canonical owner for roadmap and first-cycle execution state.
- Do not maintain a parallel checked-in status tracker.
