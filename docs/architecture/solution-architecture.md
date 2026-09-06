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

Bearer-authenticated absolute Graph request and pagination URIs are restricted to the collector's public Microsoft Graph HTTPS origin (`https://graph.microsoft.com:443`); insecure, cross-origin, alternate-port, and user-info-bearing absolute URIs fail before HTTP execution.

### Out of Scope

- Mailbox or collaboration workloads.
- Defender telemetry domains.
- Audit and sign-in stream ingestion.
- Configuration mutation through the collector; the normal Graph provider request boundary is GET-only and exposes no mutation/body request surface.

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

### Entra Stage2 detail property contract

The ordinary `entra-apps` Stage2 detail families use explicit Microsoft Graph v1.0 `$select` lists owned by `Collector.Stage2.Details.psm1` rather than relying on Graph default-property subsets.

- `applications` owns identity/profile plus authentication, token, client, API, SAML, redirect, and lock configuration fields defined by Issue #16.
- `servicePrincipals` owns identity/profile plus assignment, SSO, exposed API, redirect, notification, and token-signing configuration fields defined by Issue #16.
- `groups` owns identity/security/membership plus lifecycle, provisioning, licensing, synchronization, label, management-restriction, and on-premises extension-attribute configuration fields defined by Issue #16.
- Each Stage2 snapshot records the exact selected property names in `requestContext.selectedProperties`.
- The contract is intentionally not `$select=*` and does not claim complete Microsoft Graph object coverage.
- `keyCredentials`, `passwordCredentials`, and application federated identity credentials are outside this ordinary detail contract and are owned by the dedicated credential/FIC work item.
- `group.onPremisesExtensionAttributes` is included explicitly because the current Microsoft Graph v1.0 group contract exposes it only when requested with `$select`.
- PIM and Intune Stage2 families retain their existing request behavior until separately reviewed property contracts exist for those surfaces.

### Entra credential and federated identity boundary

Credential metadata is collected in separate families so its security and throttling behavior is not hidden inside the ordinary Stage2 detail contract.

- Stage2 `applicationCredentials` depends on Stage1 `applications`; `servicePrincipalCredentials` depends on Stage1 `servicePrincipals`.
- Both credential families request only `id,keyCredentials,passwordCredentials` from the corresponding v1.0 object endpoint.
- Because Microsoft Graph applies a 150 requests/minute tenant ceiling when `keyCredentials` is explicitly selected, those calls use an effective pre-request throttle of `max(ThrottleMilliseconds, 400)` and record the minimum/effective throttle in provenance.
- Credential snapshots use an allowlist. Key credentials retain `customKeyIdentifier`, `displayName`, `endDateTime`, `keyId`, `startDateTime`, `type`, and `usage`. Password credentials retain `displayName`, `endDateTime`, `keyId`, and `startDateTime`.
- Raw key material (`key`), password `secretText`, password `hint`, password `customKeyIdentifier`, and unrecognized response fields are never persisted by the credential transform.
- Stage3 `applicationFederatedIdentityCredentials` depends on Stage1 `applications` and requests `/v1.0/applications/{id}/federatedIdentityCredentials?$select=id,name,issuer,subject,audiences,description` through the existing per-object relationship seam.
- Federated identity snapshots preserve the application parent id/count plus only the six explicitly selected trust fields.
- These paths preserve the normal GET-only Graph provider boundary; secret retrieval, credential export, rotation, and mutation remain out of scope.

## Inventory-First Gating and Resume Semantics

- Checkpoints are written per stage/section/family.
- Batch statuses are Succeeded, Failed, InProgress, and Missing.
- A family checkpoint persists plan version, BatchSize, expected batch count, ordered source fingerprint, per-batch fingerprints, and completion state before batch execution begins.
- Stage2 and Stage3 reject a required Stage1 family unless its plan is complete, its expected/recorded batch counts agree, every expected batch is Succeeded, and every expected artifact exists.
- A lone `batch-*.json` file is never sufficient readiness evidence.
- Stage2 and Stage3 persist their own plans before downstream batch decisions, so refreshed Stage1 source identity cannot silently reuse stale successful downstream numeric batch IDs.
- Reorder, membership change, BatchSize change, or other persisted plan incompatibility is rejected during resume rather than interpreted as the prior work.
- A legitimate zero-item family is one expected successful empty batch and may complete normally.
- Resume requires an existing OutputRoot; it does not create a new root when there is nothing to resume.
- A valid `current-run.json` target is preferred. If the marker is missing or unusable, fallback selects the newest directory that contains a readable run manifest whose `runId` matches that directory; unrelated or malformed directories are skipped.
- If no valid prior collector run can be identified, resume fails before writing `current-run.json` or initializing collector child directories.
- Resume with ReprocessFailedOnly:
  - reruns Failed, InProgress, Missing, and missing-artifact batches;
  - Stage1 and Stage2 reuse a Succeeded batch only after current-input plan compatibility is established and the canonical snapshot is readable/non-null, matches current run/stage/section/family/batch identity, and agrees with current planned/checkpoint/snapshot item cardinality;
  - a Stage1 or Stage2 prior success that fails that validation is recorded as non-success and reprocessed through that stage's normal write/checkpoint path in the same resume invocation without deleting the artifact first;
  - Stage3 currently retains compatible-plan plus artifact-existence prior-success reuse semantics and remains a separate correctness-audit target.
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
- Key-credential Stage2 reads have a 400 ms minimum pre-request throttle to stay at or below the documented 150 requests/minute tenant boundary.

## Failure Behavior

- On-prem command absence or runtime failures are recorded as failed batches in checkpoints and manifest entries.
- Failures are localized to section/family batches where possible and do not force a full process crash unless inventory-first gating or orchestration integrity fails.
- Historical failures remain visible in cumulative manifest state after a later successful resume invocation.

## Deferred Decisions

Remaining deferred decisions after the current implementation:

- Long-term retention and archival strategy for output snapshots.
- Optional future parallelism model beyond current sequential batch orchestration.
- Optional policy for explicit collector-side privacy transformations.
