# Solution Architecture

## Status

- Discovery completion date: 2026-09-04
- First implementation candidate date: 2026-09-04
- Canonical live execution and roadmap status remains tracked in GitHub Issue #1

## Accepted High-Level Solution

Implement a self-contained staged PowerShell collector that writes raw JSON metadata snapshots for Entra, Intune, and on-prem AD or GPO surfaces.

Execution is inventory-first and resumable:

1. Stage1 collects inventory lists by section and family.
2. Stage2 collects object details by id or object identity from Stage1 artifacts.
3. Stage3 collects relationship metadata (ACLs, memberships, assignments, delegated grants, and PIM edges) from Stage1 artifacts.

ACLs, memberships, and assignments are classified as metadata.

## Concretized Implementation Layout

- CLI entry: collector/Invoke-Collector.ps1
- Orchestration: collector/modules/Collector.Orchestrator.psm1
- Stage modules:
  - collector/modules/Collector.Stage1.Inventory.psm1
  - collector/modules/Collector.Stage2.Details.psm1
  - collector/modules/Collector.Stage3.Relationships.psm1
- Providers:
  - collector/modules/Collector.Provider.Graph.psm1
  - collector/modules/Collector.Provider.OnPrem.psm1
- Control and storage:
  - collector/modules/Collector.Storage.Artifacts.psm1
  - collector/modules/Collector.Storage.Checkpoints.psm1
  - collector/modules/Collector.Common.Retry.psm1
  - collector/modules/Collector.Common.Provenance.psm1
- Schemas:
  - collector/schemas/snapshot.schema.json
  - collector/schemas/checkpoint.schema.json
  - collector/schemas/manifest.schema.json

## Architecture Boundaries

### In Scope

- Entra application, service principal, group, and PIM schedule metadata.
- Intune core application and script metadata.
- On-prem forest/domain/OU/group/GPO metadata via AD and Group Policy cmdlets.
- Relationship metadata for ACLs, memberships, assignments, delegated grants, and PIM schedule edges.

### Out of Scope

- Mailbox or collaboration workloads.
- Defender telemetry domains.
- Audit and sign-in stream ingestion.

## Stage and Section Model

Sections are fixed to:

- entra-apps
- entra-pim
- intune-core
- onprem-ad-gpo

Representative Stage1 families and sources:

- entra-apps:
  - /v1.0/applications
  - /v1.0/servicePrincipals
  - /v1.0/groups
- entra-pim:
  - /v1.0/roleManagement/directory/roleAssignmentScheduleInstances
  - /v1.0/roleManagement/directory/roleEligibilityScheduleInstances
- intune-core:
  - /v1.0/deviceAppManagement/mobileApps
  - /beta/deviceManagement/deviceManagementScripts
- onprem-ad-gpo:
  - Get-ADForest
  - Get-ADOrganizationalUnit per domain in Get-ADForest.Domains
  - Get-ADGroup per domain in Get-ADForest.Domains
  - Get-GPO -All per domain in Get-ADForest.Domains

Stage2 detail and Stage3 relationship execution can be run independently by stage and section, but both are gated by completed Stage1 plan evidence for required section/family dependencies.
On-prem inventory records persist domain identity so Stage2 and Stage3 reuse the same domain context for domain-targeted cmdlets.

## Inventory-First Gating and Resume Semantics

- Checkpoints are written per stage/section/family.
- Batch statuses are Succeeded, Failed, InProgress, and Missing.
- A family checkpoint persists plan version, BatchSize, expected batch count, ordered source fingerprint, per-batch fingerprints, and completion state before batch execution begins.
- Stage2 and Stage3 reject a required Stage1 family unless its plan is complete, its expected/recorded batch counts agree, every expected batch is Succeeded, and every expected artifact exists.
- A lone `batch-*.json` file is never sufficient readiness evidence.
- Stage2 and Stage3 persist their own plans before downstream batch decisions, so refreshed Stage1 source identity cannot silently reuse stale successful downstream numeric batch IDs.
- Reorder, membership change, BatchSize change, or other persisted plan incompatibility is rejected during resume rather than interpreted as the prior work.
- A legitimate zero-item family is one expected successful empty batch and may complete normally.
- Resume with ReprocessFailedOnly:
  - skips Succeeded batches only when the persisted plan remains compatible and the artifact exists,
  - reruns Failed, InProgress, Missing, and missing-artifact batches.
- Checkpoint writes use same-directory validated temporary files and atomic replacement so a failed replacement does not destroy the last valid checkpoint.
- Persisted artifact paths are normalized from run/stage/section/family/batch identity rather than interpreted relative to process working directory.

## Manifest Lifetime and Resume History

`output/<runId>/manifest/run-manifest.json` is the cumulative run-level execution record.

- `runId` and top-level `startedUtc` identify the original run and are preserved across resume invocations.
- top-level `stageResults` and `failures` accumulate durable evidence across the lifetime of the runId.
- top-level `checkpointSummary` is refreshed from current persisted checkpoint state.
- top-level `parameters`, `status`, and `completedUtc` represent the latest invocation for compatibility with the original manifest shape.
- `invocations[]` records every invocation separately with its own started/completed timestamps, parameters, status, stage results, and failures.
- a legacy manifest without `invocations` is promoted to one historical invocation when first resumed; its existing evidence is retained before the new invocation is appended.
- resume fails rather than silently replacing a missing, unreadable, or wrong-run manifest for the selected runId.

This separates cumulative run truth from invocation-specific truth while keeping one durable manifest per runId.

## Artifact Contracts

Run artifacts are written under output/<runId>:

- snapshots:
  - output/<runId>/stageX/<section>/<family>/batch-####.json
- checkpoints:
  - output/<runId>/checkpoints/stageX/<section>/<family>.json
- manifest:
  - output/<runId>/manifest/run-manifest.json

Snapshot provenance envelope fields:

- schemaVersion
- runId
- stage
- section
- family
- batchId
- collectedUtc
- sourceType
- sourceName
- apiVersion
- isBeta
- requestContext
- itemCount
- items

For on-prem families, sourceName is cmdlet-specific and requestContext includes cmdletNames for concrete execution traceability.

## Retry and Throttle Model

- Graph requests use centralized retry logic.
- Transient retries include HTTP 429, 500, 502, 503, 504 and timeout-class failures.
- Retry-After is honored when present.
- Exponential backoff with jitter is applied within configured min/max bounds.
- Throttle delay is applied before Graph requests.

## Failure Behavior

- On-prem command absence or runtime failures are recorded as failed batches in checkpoints and manifest entries.
- Failures are localized to section/family batches where possible and do not force a full process crash unless inventory-first gating or orchestration integrity fails.
- Historical failures remain visible in cumulative manifest state after a later successful resume invocation.

## Deferred Decisions

Remaining deferred decisions after the current implementation:

- Long-term retention and archival strategy for output snapshots.
- Optional future parallelism model beyond current sequential batch orchestration.
- Optional policy for explicit collector-side privacy transformations.
