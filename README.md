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
- A Microsoft Graph access token with permissions required by selected Graph endpoints.
- Optional on-prem cmdlets for onprem-ad-gpo section:
	- ActiveDirectory module cmdlets (Get-ADForest, Get-ADOrganizationalUnit, Get-ADGroup, Get-ADDomain, Get-ADGroupMember)
	- GroupPolicy cmdlets (Get-GPO, Get-GPPermission)

Run all stages and sections:

```powershell
pwsh ./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output
```

Run only Stage1 for Entra apps and Intune core:

```powershell
pwsh ./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output `
	-Stages Stage1 `
	-Sections entra-apps,intune-core
```

Resume previous run and reprocess failed or missing batches only:

```powershell
pwsh ./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output `
	-Stages Stage2,Stage3 `
	-Resume `
	-ReprocessFailedOnly
```

## CLI Parameters

- GraphToken (mandatory): bearer token used for Graph requests.
- OutputRoot (mandatory): root output folder containing per-run artifacts.
- Stages: All, Stage1, Stage2, Stage3. Default is All.
- Sections: entra-apps, entra-pim, intune-core, onprem-ad-gpo. Default is all sections.
- Resume: resume using the run marker or latest run folder under OutputRoot.
- ReprocessFailedOnly: during resume, skip succeeded batches only when snapshot file exists; rerun failed, in-progress, missing, or missing-artifact batches.
- Force: reserved execution switch included in run metadata for explicit operator intent.
- BatchSize: batch size for snapshot partitioning. Default 100.
- MaxRetries: retry count for transient Graph failures. Default 5.
- BaseBackoffSeconds: base exponential backoff delay. Default 2.
- MaxBackoffSeconds: backoff upper bound and Retry-After cap. Default 30.
- ThrottleMilliseconds: delay before each Graph request. Default 100.

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
- On-prem families are collected by object identity plus persisted domain context from Stage1 inventory.
- Stage2 hard-fails if required Stage1 family artifacts are missing.

Stage3 relationship families:

- ACL metadata: domainRootAcl, ouAcl, gpoPermissions
- Membership metadata: groupMembers, groupMembersOnPrem
- Assignment metadata: mobileAppAssignments, deviceManagementScriptAssignments, servicePrincipalAppRoleAssignedTo
- Delegated grants: delegatedGrants from /v1.0/oauth2PermissionGrants
- PIM relationship edges: pimScheduleEdges derived from Stage1 PIM schedule instances
- On-prem relationship families use persisted Stage1 domain context where cmdlets support domain targeting.
- Stage3 hard-fails if required Stage1 family artifacts are missing.

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

Run local parser and test scaffolding:

```powershell
pwsh ./tools/Invoke-LocalValidation.ps1
```

The validation script runs parser checks, optional PSScriptAnalyzer if installed, and Pester tests if installed.

## Scope Boundaries

In scope:

- Entra, Intune, and on-prem AD or GPO configuration metadata.
- ACLs, memberships, and assignments treated as metadata.

Out of scope:

- Mailbox or collaboration workloads.
- Defender telemetry domains.
- Audit and sign-in stream ingestion.
