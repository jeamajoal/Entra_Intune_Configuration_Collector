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

The previously deferred collector layout and naming are now concretized:

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

Stage2 detail and Stage3 relationship execution can be run independently by stage and section, but both are gated by Stage1 evidence for required section and family dependencies.
On-prem inventory records persist domain identity so Stage2 and Stage3 reuse the same domain context for domain-targeted cmdlets.

## Inventory-First Gating and Resume Semantics

- Stage2 and Stage3 reject a required Stage1 family when its Stage1 checkpoint is missing or has no recorded batches.
- Every recorded Stage1 checkpoint batch must be `Succeeded` before downstream enrichment can use that family.
- Every recorded succeeded Stage1 batch must still reference an artifact that exists.
- A lone `batch-*.json` file is not sufficient readiness evidence when the checkpoint proves another recorded batch failed, is in progress, is missing, or lost its artifact.
- A legitimate zero-item Stage1 inventory remains representable as the normal succeeded empty batch and may satisfy the recorded-checkpoint readiness rule.
- Checkpoints are written per stage/section/family.
- Batch statuses: Succeeded, Failed, InProgress, Missing.
- Checkpoint batch fields include attempts, counts, artifact path, and error.
- Resume with ReprocessFailedOnly:
  - skips Succeeded batches only when artifact file exists,
  - reruns Failed, InProgress, Missing, and missing-artifact batches.

Current limitation: Stage1 does not yet persist the expected total batch count or a family-completion marker before batch processing begins. Therefore a process interruption before a later expected batch is ever recorded cannot yet be distinguished from a genuinely complete one-batch family using checkpoint state alone. That is a separate follow-up boundary under Issue #1 and must not be misrepresented as solved by the recorded-batch gate.

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
- Failures are localized to section/family batches where possible and do not force a full process crash unless inventory-first gating fails.

## Deferred Decisions

Remaining deferred decisions after implementation candidate:

- Stage1 family completion/batch-plan metadata sufficient to prove no expected batch was never recorded after interruption.
- Stable Stage1 resume identity when the live source inventory changes ordering or membership between attempts.
- Long-term retention and archival strategy for output snapshots.
- Optional future parallelism model beyond current sequential batch orchestration.
- Optional policy for explicit collector-side privacy transformations.
