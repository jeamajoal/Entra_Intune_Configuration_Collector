# Entra Intune Configuration Collector

This repository contains a staged PowerShell metadata collector for Microsoft Entra ID, Microsoft Intune, and on-premises Active Directory or GPO domains.

The implementation is inventory-first and resumable:

1. Stage1 collects inventory snapshots.
2. Stage2 collects object details from Stage1 inventory.
3. Stage3 collects relationship metadata from Stage1 inventory.

## Repository Navigation

- Collector entry point: [collector/Invoke-Collector.ps1](collector/Invoke-Collector.ps1)
- Collector modules: [collector/modules](collector/modules)
- Artifact schemas: [collector/schemas](collector/schemas)
- Unit tests: [tests/unit](tests/unit)
- Local validation script: [tools/Invoke-LocalValidation.ps1](tools/Invoke-LocalValidation.ps1)
- Architecture owner document: [docs/architecture/solution-architecture.md](docs/architecture/solution-architecture.md)
- Repository engineering guardrails: [AGENTS.md](AGENTS.md)

## Quick Start

Prerequisites:

- PowerShell 7+ or Windows PowerShell 5.1.
- A Microsoft Graph access token with permissions required by any selected Graph-backed sections (`entra-apps`, `entra-pim`, `intune-core`). No Graph token is required for an `onprem-ad-gpo`-only run.
- Optional on-prem cmdlets for onprem-ad-gpo section:
	- ActiveDirectory module cmdlets (Get-ADForest, Get-ADOrganizationalUnit, Get-ADGroup, Get-ADDomain, Get-ADGroupMember)
	- GroupPolicy cmdlets (Get-GPO, Get-GPPermission)

Run all stages and sections:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output
```

Run only Stage1 for Entra apps and Intune core:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output `
	-Stages Stage1 `
	-Sections entra-apps,intune-core
```

Run only the on-prem section without a Graph token:

```powershell
./collector/Invoke-Collector.ps1 `
	-OutputRoot ./output `
	-Sections onprem-ad-gpo
```

Resume previous run and reprocess failed or missing batches only:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output `
	-Stages Stage2,Stage3 `
	-Resume `
	-ReprocessFailedOnly
```

## CLI Parameters

- GraphToken: bearer token used for Graph requests. Required only when `entra-apps`, `entra-pim`, or `intune-core` is selected; optional for `onprem-ad-gpo`-only execution.
- OutputRoot (mandatory): root output folder containing per-run artifacts.
- Stages: All, Stage1, Stage2, Stage3. Default is All.
- Sections: entra-apps, entra-pim, intune-core, onprem-ad-gpo. Default is all sections.
- Resume: resume the valid run named by `current-run.json`; if that marker is unusable, fall back to the latest valid collector run under OutputRoot. If no valid prior run exists, fail without creating or initializing run state.
- ReprocessFailedOnly: during resume, skip a succeeded Stage1 batch only when the persisted family plan is compatible and its canonical snapshot still exists and matches the current run/stage/section/family/batch identity and planned/checkpoint/snapshot item cardinality; rerun failed, in-progress, missing, missing-artifact, or invalid-prior-success batches.
- Force: reserved execution switch included in run metadata for explicit operator intent.
- BatchSize: batch size for snapshot partitioning. Default 100. A different BatchSize is an incompatible resume plan and is rejected rather than reinterpreting existing batch IDs.
- MaxRetries: retry count for transient Graph failures. Default 5.
- BaseBackoffSeconds: base exponential backoff delay. Default 2.
- MaxBackoffSeconds: backoff upper bound and Retry-After cap. Default 30.
- ThrottleMilliseconds: delay before each Graph request attempt. Default 100. Entra application/service-principal credential reads that explicitly select `keyCredentials` enforce at least 400 ms per request attempt to stay at or below Microsoft's documented 150 requests/minute tenant boundary.

## Stage and Section Model

Stage1 inventory families:

- entra-apps:
	- applications from /v1.0/applications
	- servicePrincipals from /v1.0/servicePrincipals
	- groups from /v1.0/groups
- entra-pim:
	- roleAssignmentScheduleInstances from /v1.0/roleManagement/directory/roleAssignmentScheduleInstances
	- roleEligibilityScheduleInstances from /v1.0/roleManagement/directory/roleEligibilityScheduleInstances
- intune-core:
	- mobileApps from /v1.0/deviceAppManagement/mobileApps
	- deviceManagementScripts from /beta/deviceManagement/deviceManagementScripts
- onprem-ad-gpo:
	- domains from Get-ADForest
	- organizationalUnits from Get-ADOrganizationalUnit per domain in Get-ADForest.Domains
	- groups from Get-ADGroup per domain in Get-ADForest.Domains
	- gpos from Get-GPO -All per domain in Get-ADForest.Domains

Stage2 detail collection:

- Graph families are collected by id from Stage1 inventory.
- `entra-apps` also writes separate `applicationCredentials` and `servicePrincipalCredentials` families. These request `id,keyCredentials,passwordCredentials`, enforce the credential-specific throttle floor, and persist an allowlisted metadata shape that excludes raw key material and password secret text.
- On-prem families are collected by object identity plus persisted domain context from Stage1 inventory.
- Stage2 hard-fails unless the required Stage1 family has a completed persisted plan, every expected batch is Succeeded, and every expected succeeded batch still has its artifact.
- Stage2 persists its own plan before processing so resume cannot silently reuse numeric batch IDs after Stage1 input, order, membership, or BatchSize changes.

Stage3 relationship families:

- ACL metadata: domainRootAcl, ouAcl, gpoPermissions
- Membership metadata: groupMembers, groupMembersOnPrem
- Assignment metadata: mobileAppAssignments, deviceManagementScriptAssignments, servicePrincipalAppRoleAssignedTo
- Entra federated trust metadata: applicationFederatedIdentityCredentials from each Stage1 application, limited to id/name/issuer/subject/audiences/description
- Delegated grants: delegatedGrants from /v1.0/oauth2PermissionGrants
- PIM relationship edges: pimScheduleEdges derived from Stage1 PIM schedule instances
- On-prem relationship families use persisted Stage1 domain context where cmdlets support domain targeting.
- Stage3 applies the same completed Stage1 plan readiness rule to every required dependency and persists its own compatible resume plan before processing relationship batches.

A lone Stage1 `batch-*.json` file is not sufficient inventory-first evidence. Readiness requires a completed Stage1 family plan whose expected batch count matches the checkpoint, with every expected batch Succeeded and every referenced artifact present. Plans include BatchSize, ordered source identity, per-batch fingerprints, expected batch count, and completion state. Reorder, membership change, or BatchSize change is rejected during resume instead of silently associating prior numeric batch IDs with different work. A legitimate zero-item family is represented as one successful completed empty batch.

## Output Layout

Artifacts are written under output/<runId>:

```text
output/
	<runId>/
		stage1/
			<section>/
				<family>/
					batch-0001.json
		stage2/
			<section>/
				<family>/
					batch-0001.json
		stage3/
			<section>/
				<family>/
					batch-0001.json
		checkpoints/
			stage1/<section>/<family>.json
			stage2/<section>/<family>.json
			stage3/<section>/<family>.json
		manifest/
			run-manifest.json
```

`run-manifest.json` is cumulative for the lifetime of a runId. Its top-level `stageResults` and `failures` retain evidence from prior resumed invocations, while `checkpointSummary` reflects the current persisted checkpoint state. `parameters`, `status`, and `completedUtc` represent the latest invocation for compatibility. The `invocations` array records each invocation's parameters, start/completion timestamps, status, stage results, and failures. The original top-level `startedUtc` is never reset by `-Resume`.

Each snapshot file includes provenance envelope fields:

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

For on-prem snapshots, sourceName records concrete cmdlet names and requestContext includes cmdletNames for the executed family.

## Validation

Ordinary `pull_request` and `main` push CI executes the same parser, PSScriptAnalyzer, and Pester validation gate on GitHub-hosted `windows-latest` runners under both PowerShell 7 (`pwsh`) and Windows PowerShell 5.1 (`powershell`). Automatic public-PR validation does not execute repository code on the persistent self-hosted runner. Both jobs pin Pester 5.9.1 and PSScriptAnalyzer 1.25.0. The Windows PowerShell job uses `-SkipPublisherCheck` only for the side-by-side Pester installation because Windows includes an older Microsoft-signed Pester with a different publisher; this does not skip or weaken Pester execution.

Trusted PowerShell 7 acceptance on the persistent self-hosted runner is a separate manual `workflow_dispatch` path. Invoke `.github/workflows/self-hosted-acceptance.yml` from `main` only for same-repository PR code you trust to execute on that persistent machine, supplying the open PR number and its exact current head SHA. A GitHub-hosted binding job requires dispatch from `main`, an open PR targeting `main`, a same-repository head, and an exact head-SHA match before the self-hosted job can start. The self-hosted job checks out only that validated immutable SHA and disables persisted checkout credentials. This is a trusted-code acceptance path, not a general public-PR runner.

For normal local validation, install the same pinned validation modules used by CI and run the script from whichever supported PowerShell host you want to validate. On Windows PowerShell 5.1, Pester's publisher transition requires `-SkipPublisherCheck` for unattended side-by-side installation.

```powershell
$pesterInstall = @{
	Name = 'Pester'
	RequiredVersion = '5.9.1'
	Scope = 'CurrentUser'
	Force = $true
}
if ($PSVersionTable.PSEdition -eq 'Desktop') {
	$pesterInstall.SkipPublisherCheck = $true
}
Install-Module @pesterInstall
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
./tools/Invoke-LocalValidation.ps1
```

The validation script runs parser checks, PSScriptAnalyzer, and Pester tests when Pester is installed. If PSScriptAnalyzer is unavailable, normal validation fails closed instead of silently skipping static analysis. Use `-SkipScriptAnalyzer` only when intentionally bypassing the analyzer for a bounded diagnostic; CI does not use that bypass. A Pester pass is reported only when the returned result uses a supported Pester 4/5 result shape, proves that at least one test executed, and reports zero failures; null, unknown, or zero-test results fail closed. Explicitly skipped or unavailable Pester remains reported as skipped rather than passed.

## Scope Boundaries

In scope:

- Entra, Intune, and on-prem AD or GPO configuration metadata.
- ACLs, memberships, and assignments treated as metadata.

Out of scope:

- Mailbox or collaboration workloads.
- Defender telemetry domains.
- Audit and sign-in stream ingestion.