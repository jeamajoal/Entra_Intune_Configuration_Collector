# Entra Intune Configuration Collector

This repository contains a staged PowerShell metadata collector for Microsoft Entra ID, Microsoft Intune, and on-premises Active Directory or GPO domains.

The implementation is inventory-first and resumable:

1. Stage1 collects inventory snapshots.
2. Stage2 collects object details from Stage1 inventory.
3. Stage3 collects relationship metadata from Stage1 inventory.

## Repository Navigation

- Collector entry point: [collector/Invoke-Collector.ps1](collector/Invoke-Collector.ps1)
- Offline catalog command: [collector/Export-KnowledgeCatalog.ps1](collector/Export-KnowledgeCatalog.ps1)
- Offline package validation command: [collector/Test-KnowledgePackage.ps1](collector/Test-KnowledgePackage.ps1)
- Collector modules: [collector/modules](collector/modules)
- Artifact schemas: [collector/schemas](collector/schemas)
- Unit tests: [tests/unit](tests/unit)
- Local validation script: [tools/Invoke-LocalValidation.ps1](tools/Invoke-LocalValidation.ps1)
- Architecture owner document: [docs/architecture/solution-architecture.md](docs/architecture/solution-architecture.md)
- Provider/audience boundary: [docs/architecture/provider-boundaries.md](docs/architecture/provider-boundaries.md)
- Graph authentication lifecycle: [docs/graph-authentication.md](docs/graph-authentication.md)
- Graph authentication architecture: [docs/architecture/graph-authentication-lifecycle.md](docs/architecture/graph-authentication-lifecycle.md)
- Permission/dependency guide: [docs/permissions.md](docs/permissions.md)
- Canonical permission matrix: [docs/permissions/permission-matrix.json](docs/permissions/permission-matrix.json)
- Repository engineering guardrails: [AGENTS.md](AGENTS.md)

## Quick Start

Prerequisites:

- PowerShell 7+ or Windows PowerShell 5.1.
- Microsoft Graph authentication with the read permissions required by the selected Graph-backed sections (`entra-apps`, `entra-pim`, `entra-ca`, `entra-governance`, `intune-core`, `intune-enrollment`). Supply either an existing bearer with `-GraphToken`, a renewable callback with `-GraphTokenProvider`, or both. Application permissions are the recommended unattended-run contract; delegated access can additionally require a supported signed-in-user Entra role. Long-running unattended collection should prefer `GraphTokenProvider` so a run can renew an expired bearer instead of failing after the initial token lifetime. The callback contract and secret boundary are documented in [docs/graph-authentication.md](docs/graph-authentication.md). The exact section/stage/family permission mapping is maintained in [docs/permissions/permission-matrix.json](docs/permissions/permission-matrix.json) and explained in [docs/permissions.md](docs/permissions.md). No Graph authentication input is required for an `onprem-ad-gpo`-only run.
- Permission names are scoped to a provider/resource, not globally interchangeable. `GraphToken` and `GraphTokenProvider` belong only to provider `microsoft-graph` and resource `https://graph.microsoft.com/`; `onprem-ad-gpo` uses the local Windows/domain execution identity by default or an optional `ADCredential` for alternate outbound AD/GPO authentication. A future distinct provider such as Defender/MDE must add its own audience/origin/token boundary only when its first real consuming route is implemented.
- `entra-ca` is deliberately opt-in so existing default runs do not silently acquire new Conditional Access permission dependencies. Current policy/named-location reads use `Policy.Read.All`, authentication-strength reads use `Policy.Read.AuthenticationMethod`, and authentication-context reads use `AuthenticationContext.Read.All`.
- `entra-governance` is also opt-in. Administrative-unit reads use `AdministrativeUnit.Read.All`; directory-role, role-definition, role-assignment, and administrative-unit scoped-role reads use `RoleManagement.Read.Directory`. Hidden administrative-unit membership can additionally require `Member.Read.Hidden`.
- `intune-core` requires an active Intune tenant license. Current app reads use `DeviceManagementApps.Read.All`; script inventory/detail uses the dedicated `DeviceManagementScripts.Read.All`; script-assignment, compliance, assignment-filter, Settings Catalog/classic configuration, endpoint-security/security-baseline, settings, and assignment reads use `DeviceManagementConfiguration.Read.All`.
- `intune-enrollment` is deliberately opt-in because it requires the distinct Microsoft Graph application permission `DeviceManagementServiceConfig.Read.All`. It collects tenant enrollment configuration through v1.0 and Windows Autopilot deployment-profile configuration/assignments through beta; existing default `intune-core` runs therefore do not silently acquire the enrollment service-configuration permission.
- The `onprem-ad-gpo` section requires the ActiveDirectory and GroupPolicy RSAT modules plus read access to the targeted forest/domain/GPO/ACL data. Current commands are enumerated in the canonical permission matrix; no mutation rights are required. When the collector process identity does not have that read access, supply `-ADCredential` with an existing `PSCredential`; the credential is used only for the on-prem stage and is not serialized into run artifacts.
- For `403 Forbidden` or equivalent authorization errors, verify the token grants/admin consent, delegated user role, Intune licensing, and target visibility **and** confirm that the permission matrix is still current for the failing endpoint. Do not add broad `ReadWrite` scopes solely to make a read-only collector request work.

Run all stages for the legacy default sections with an existing bearer token:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output
```

For a long-running unattended collection, inject a renewable token source. The provider receives `$false` for initial acquisition and `$true` for the single forced replacement after a 401:

```powershell
$graphTokenProvider = {
	param([bool]$ForceRefresh)
	Get-OrganizationGraphAccessToken -ForceRefresh:$ForceRefresh
}

./collector/Invoke-Collector.ps1 `
	-GraphTokenProvider $graphTokenProvider `
	-OutputRoot ./output
```

If an initial token is already available, supply both; the static bearer is used first and the provider is called only if a request returns 401:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-GraphTokenProvider $graphTokenProvider `
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

Collect Conditional Access configuration explicitly:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output `
	-Sections entra-ca
```

Collect Entra administrative governance explicitly:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output `
	-Sections entra-governance
```

Collect Intune enrollment and Windows Autopilot deployment-profile configuration explicitly:

```powershell
./collector/Invoke-Collector.ps1 `
	-GraphToken $GraphToken `
	-OutputRoot ./output `
	-Sections intune-enrollment
```

Run only the on-prem section without a Graph token:

```powershell
./collector/Invoke-Collector.ps1 `
	-OutputRoot ./output `
	-Sections onprem-ad-gpo
```

Run the on-prem section under a different AD/GPO credential context while keeping the collector process identity unchanged:

```powershell
$ADCredential = Get-Credential

./collector/Invoke-Collector.ps1 `
	-ADCredential $ADCredential `
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

Generate the deterministic offline catalog after a run reaches terminal `Completed` or `CompletedWithErrors` state:

```powershell
./collector/Export-KnowledgeCatalog.ps1 `
	-RunPath ./output/<runId>
```

Catalog generation is fully offline. It reads only persisted run artifacts, never requires a Graph token or on-prem provider access, and does not modify raw snapshots, checkpoints, or the run manifest.

Validate the completed offline package before handing it to an operator or external consumer:

```powershell
./collector/Test-KnowledgePackage.ps1 `
	-RunPath ./output/<runId>
```

For compact machine-readable output:

```powershell
./collector/Test-KnowledgePackage.ps1 `
	-RunPath ./output/<runId> `
	-AsJson
```

The intended offline handoff is **collect -> catalog -> validate -> consume/question**. Package validation is provider-independent and read-only: it reuses the catalog generator's strict persisted-evidence checks in memory, verifies that the stored catalog exactly matches the canonical model implied by the manifest/checkpoints/snapshots, and never repairs or rewrites source evidence.

## CLI Parameters

Collector parameters:

- GraphToken: optional existing Microsoft Graph bearer token. A Graph-backed run requires `GraphToken`, `GraphTokenProvider`, or both. Static-token-only behavior remains backward compatible; a 401 is not treated as transient and cannot be renewed without a provider.
- GraphTokenProvider: optional scriptblock for renewable Microsoft Graph authentication. It receives one positional Boolean `ForceRefresh` argument and must return exactly one non-empty bearer token string. Provider-only execution lazily acquires and caches the first token. When a provider is available, one terminating 401 force-refreshes exactly once for that request; the replacement bearer is reused in memory by later requests. The callback and tokens are never serialized; run metadata records only whether each authentication input was supplied. See [docs/graph-authentication.md](docs/graph-authentication.md).
- ADCredential: optional `PSCredential` used only for `onprem-ad-gpo`. On Windows, the collector applies it as a net-only impersonation context so AD and GroupPolicy network access can use a different domain account while local process/filesystem access remains under the process identity. The credential object/password is never persisted; run metadata records only whether an alternate credential was supplied.
- OutputRoot (mandatory): root output folder containing per-run artifacts.
- Stages: All, Stage1, Stage2, Stage3. Default is All.
- Sections: entra-apps, entra-pim, entra-ca, entra-governance, intune-core, intune-enrollment, onprem-ad-gpo. The legacy default remains `entra-apps,entra-pim,intune-core,onprem-ad-gpo`; `entra-ca`, `entra-governance`, and `intune-enrollment` must be selected explicitly.
- Resume: resume the valid run named by `current-run.json`; if that marker is unusable, fall back to the latest valid collector run under OutputRoot. If no valid prior run exists, fail without creating or initializing run state.
- ReprocessFailedOnly: during resume, rerun failed, in-progress, missing, missing-artifact, or invalid-prior-success batches. Stage1 and Stage2 reuse a succeeded batch only after compatible-plan and canonical snapshot schema-version/identity/cardinality validation against current planned work. Stage3 also revalidates the canonical snapshot schema version, identity, and checkpoint/snapshot/actual output cardinality after compatible-plan validation, but does not require relationship output count to equal source batch count because one source object may legitimately produce multiple relationship rows.
- Force: reserved execution switch included in run metadata for explicit operator intent.
- BatchSize: batch size for snapshot partitioning. Default 100. A different BatchSize is an incompatible resume plan and is rejected rather than reinterpreting existing batch IDs. Stage2 `onprem-ad-gpo/gpoReports` deliberately overrides this to one GPO per artifact because policy-report XML can be large and each GPO must remain independently resumable.
- MaxRetries: retry count for transient Graph failures. Default 5.
- BaseBackoffSeconds: base exponential backoff delay. Default 2.
- MaxBackoffSeconds: backoff upper bound and Retry-After cap. Default 30.
- ThrottleMilliseconds: delay before each Graph request attempt. Default 100. Entra application/service-principal credential reads that explicitly select `keyCredentials` enforce at least 400 ms per request attempt to stay at or below Microsoft's documented 150 requests/minute tenant boundary.

Offline catalog parameters:

- RunPath (mandatory): path to one completed collector run directory, for example `./output/<runId>`.
- ExpectedRunId: optional explicit run identity guard. When supplied, catalog generation fails unless it matches both the run directory and persisted manifest `runId`.

Offline package validation parameters:

- RunPath (mandatory): path to the terminal run package whose persisted catalog and source evidence must agree.
- ExpectedRunId: optional explicit run identity guard applied before package comparison.
- AsJson: return one compact JSON result for automation instead of the default PowerShell result object. The result exposes only validation status/counts/path/message metadata and never collected payload rows.

## Stage and Section Model

Stage1 inventory families:

- entra-apps:
	- applications from /v1.0/applications
	- servicePrincipals from /v1.0/servicePrincipals
	- groups from /v1.0/groups
- entra-pim:
	- roleAssignmentScheduleInstances from /v1.0/roleManagement/directory/roleAssignmentScheduleInstances
	- roleEligibilityScheduleInstances from /v1.0/roleManagement/directory/roleEligibilityScheduleInstances
- entra-ca (opt-in):
	- conditionalAccessPolicies from /v1.0/identity/conditionalAccess/policies
	- namedLocations from /v1.0/identity/conditionalAccess/namedLocations
	- authenticationStrengthPolicies from /v1.0/policies/authenticationStrengthPolicies
	- authenticationContextClassReferences from /v1.0/identity/conditionalAccess/authenticationContextClassReferences
- entra-governance (opt-in):
	- administrativeUnits from /v1.0/directory/administrativeUnits
	- directoryRoles from /v1.0/directoryRoles
	- roleDefinitions from /v1.0/roleManagement/directory/roleDefinitions
	- roleAssignments from /v1.0/roleManagement/directory/roleAssignments
- intune-core:
	- mobileApps from /v1.0/deviceAppManagement/mobileApps
	- deviceManagementScripts from /beta/deviceManagement/deviceManagementScripts
	- deviceCompliancePolicies from /v1.0/deviceManagement/deviceCompliancePolicies
	- assignmentFilters from /beta/deviceManagement/assignmentFilters
	- configurationPolicies from /beta/deviceManagement/configurationPolicies, admitting only `templateReference.templateFamily` `none` or `deviceConfigurationPolicies`
	- deviceConfigurations from /v1.0/deviceManagement/deviceConfigurations
	- securityConfigurationPolicies from /beta/deviceManagement/configurationPolicies, admitting only `endpointSecurityAntivirus`, `endpointSecurityDiskEncryption`, `endpointSecurityFirewall`, `endpointSecurityEndpointDetectionAndResponse`, `endpointSecurityAttackSurfaceReduction`, `endpointSecurityAccountProtection`, `endpointSecurityApplicationControl`, `endpointSecurityEndpointPrivilegeManagement`, or `baseline`
	- securityConfigurationPolicyTemplates from /beta/deviceManagement/configurationPolicyTemplates, filtered to the same accepted security/baseline template-family set
	- securityBaselineTemplates from /beta/deviceManagement/templates, admitting `#microsoft.graph.securityBaselineTemplate` or reviewed security/baseline template types
	- securityBaselineIntents from /beta/deviceManagement/intents, admitting only intents whose `templateId` resolves to an admitted securityBaselineTemplates row; `isMigratingToConfigurationPolicy` is retained
- intune-enrollment (opt-in):
	- deviceEnrollmentConfigurations from /v1.0/deviceManagement/deviceEnrollmentConfigurations, preserving Graph-returned derived enrollment configuration types such as enrollment restrictions, Windows Hello for Business enrollment configuration, and Enrollment Status Page/completion-page configuration
	- windowsAutopilotDeploymentProfiles from /beta/deviceManagement/windowsAutopilotDeploymentProfiles, preserving deployment-profile/OOBE/ESP configuration and the `hardwareHashExtractionEnabled` configuration flag without requesting any Autopilot device identity or hardware-hash value
- onprem-ad-gpo:
	- domains from Get-ADForest
	- organizationalUnits from Get-ADOrganizationalUnit per domain in Get-ADForest.Domains
	- groups from Get-ADGroup per domain in Get-ADForest.Domains
	- gpos from Get-GPO -All per domain in Get-ADForest.Domains

Stage2 detail collection:

- Graph families are collected by id from Stage1 inventory.
- `entra-apps` also writes separate `applicationCredentials` and `servicePrincipalCredentials` families. These request `id,keyCredentials,passwordCredentials`, enforce the credential-specific throttle floor, and persist an allowlisted metadata shape that excludes raw key material and password secret text.
- `entra-ca` collects the same four Conditional Access configuration families by stable id using Microsoft Graph v1.0. Policy details preserve policy conditions, grant controls, session controls, state, template identity, and other Graph-returned configuration needed for offline explanation; named-location, authentication-strength, and authentication-context details remain separate canonical families.
- `entra-governance` collects administrative units, activated directory roles, role definitions, and active role assignments by stable id using Microsoft Graph v1.0. Active/PIM `roleDefinitionId` values resolve directly against role-definition IDs. Administrative-unit scoped-role `roleId` values resolve first against `directoryRoles`, whose `roleTemplateId` can then match the role definition `templateId`; the existing PIM schedule families are not duplicated or renamed.
- `intune-core` collects compliance-policy details from `/v1.0/deviceManagement/deviceCompliancePolicies/{id}` and assignment-filter details from `/beta/deviceManagement/assignmentFilters/{id}`. Raw Graph policy/filter configuration remains authoritative so platform-specific compliance requirements and filter rules are reviewable offline; no device/user compliance-result endpoint is part of this family.
- `intune-core` also collects admitted general configuration-policy details from `/beta/deviceManagement/configurationPolicies/{id}` and classic typed profile details from `/v1.0/deviceManagement/deviceConfigurations/{id}`. `configurationPolicySettings` follows the paged beta `/configurationPolicies/{id}/settings` relationship and stores one wrapper per policy (`policyId`, `settingCount`, `settings`) so complete configured-setting evidence remains tied to the Stage1 policy identity without changing Stage2 source cardinality.
- #178 security/baseline detail is separate from the general #177 family: `securityConfigurationPolicies` and `securityConfigurationPolicyTemplates` read their beta objects by id, and `securityConfigurationPolicySettings` reads paged `/beta/deviceManagement/configurationPolicies/{id}/settings` with one wrapper per admitted security policy. Legacy `securityBaselineTemplates` and `securityBaselineIntents` read beta template/intent detail by id; `securityBaselineIntentSettings` reads paged `/beta/deviceManagement/intents/{id}/settings` with one wrapper per admitted legacy intent. This preserves migration-era evidence rather than assuming every baseline has already moved to modern configuration policies.
- `intune-enrollment` reads `deviceEnrollmentConfigurations` detail from `/v1.0/deviceManagement/deviceEnrollmentConfigurations/{id}` and Windows Autopilot deployment-profile detail from `/beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}`. Raw derived-type/profile configuration remains authoritative; the collector does not traverse assigned devices or device-identity relationships.
- Terms-of-Use agreement payloads are not collected in v1 because the Microsoft Graph agreement read surface does not support application permissions. Conditional Access policies still expose their Terms-of-Use IDs through the Stage3 reference family rather than hiding those dependencies or requiring delegated authentication.
- Ordinary on-prem families are collected by object identity plus persisted domain context from Stage1 inventory. Stage2 `gpoReports` is an additive detail family driven by Stage1 `gpos`: it invokes read-only `Get-GPOReport` by persisted GPO GUID and domain with XML output, stores only the complete `Computer` and `User` configuration subtrees, and records explicit side presence. Each GPO is written to its own artifact. Root-level link, delegation, security-filtering, and WMI/filter topology is deliberately not copied into this Stage2 family because the corresponding applicability evidence is owned by the Stage3 relationship families described below. Before persistence, explicit credential-bearing XML element/attribute names such as `cpassword`, password/secret/private-key/client-secret fields are replaced with `[REDACTED]`; ordinary policy settings such as password-length configuration remain reviewable. This boundary does not claim to discover secrets hidden inside arbitrary operator-authored registry values or scripts.
- Stage2 hard-fails unless the required Stage1 family has a completed persisted plan, every expected batch is Succeeded, and every expected succeeded batch still has its artifact.
- Stage2 persists its own plan before processing so resume cannot silently reuse numeric batch IDs after Stage1 input, order, membership, or BatchSize changes.
- During Stage2 resume, a prior successful Graph or on-prem batch is reused only when its existing canonical snapshot declares supported schema version `1.0`, matches current run/stage/section/family/batch identity, and agrees with current planned/checkpoint/snapshot item cardinality; an invalid prior success is reprocessed through the normal Stage2 write/checkpoint path. Paged settings families retain one wrapper per source policy/intent so downstream cardinality remains bound to Stage1 source identity rather than page count.

Stage3 relationship families:

- ACL metadata: domainRootAcl, ouAcl, gpoPermissions
- Membership metadata: groupMembers, groupMembersOnPrem
- GPO applicability metadata: gpoScopeLinks, gpoScopeInheritance, gpoWmiFilterAssociations; security filtering remains represented by canonical gpoPermissions rows whose `PermissionLevel` is `GpoApply`.
- Assignment metadata: mobileAppAssignments, deviceManagementScriptAssignments, deviceCompliancePolicyAssignments, configurationPolicyAssignments, deviceConfigurationAssignments, securityConfigurationPolicyAssignments, securityBaselineIntentAssignments, deviceEnrollmentConfigurationAssignments, windowsAutopilotDeploymentProfileAssignments, servicePrincipalAppRoleAssignedTo
- Intune compliance assignments: `deviceCompliancePolicyAssignments` reads `/beta/deviceManagement/deviceCompliancePolicies/{id}/assignments` from persisted compliance-policy inventory. Rows normalize assignment/source identity plus target/filter references; explicit group IDs use `entra.group`, explicit Entra object IDs use `entra.directory-object`, assignment-filter IDs use `intune.assignment-filter`, and selector/other target shapes remain `intune.assignment-target` rather than being guessed into stronger types. Beta is used here specifically to retain assignment filter ID/type include/exclude context.
- Intune general configuration assignments: `configurationPolicyAssignments` reads `/beta/deviceManagement/configurationPolicies/{id}/assignments`; `deviceConfigurationAssignments` reads `/beta/deviceManagement/deviceConfigurations/{id}/assignments`. Both preserve assignment ID, source/sourceId, intent when Graph supplies it, target type/identity, and assignment-filter ID/type. Group IDs use `entra.group`, explicit Entra object IDs use `entra.directory-object`, filter IDs use `intune.assignment-filter`, and other selectors/targets remain `intune.assignment-target`. The existing `assignmentFilters` family remains the canonical filter-definition evidence and is not duplicated.
- Intune security/baseline assignments: `securityConfigurationPolicyAssignments` reads `/beta/deviceManagement/configurationPolicies/{id}/assignments` only for persisted securityConfigurationPolicies; `securityBaselineIntentAssignments` reads `/beta/deviceManagement/intents/{id}/assignments` only for persisted securityBaselineIntents. Both reuse the conservative assignment identity contract, including Configuration Manager `collectionId` preservation and filter include/exclude metadata. Modern and legacy sources remain distinguishable as `intune.security-configuration-policy` and `intune.security-baseline-intent`.
- Intune enrollment assignments: `deviceEnrollmentConfigurationAssignments` reads `/v1.0/deviceManagement/deviceEnrollmentConfigurations/{id}/assignments`; `windowsAutopilotDeploymentProfileAssignments` derives assignment rows from `GET /beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}?$expand=assignments`. This uses the profile's documented `assignments` relationship without traversing `windowsAutopilotDeviceIdentities` or `assignedDevices`. Enrollment-configuration assignment targets preserve stable groups/directory objects or conservative selector identities. Autopilot assignments also preserve assignment-filter IDs/types and Configuration Manager `collectionId` where supplied. Source domains remain distinct as `intune.device-enrollment-configuration` and `intune.windows-autopilot-deployment-profile`.
- Entra federated trust metadata: applicationFederatedIdentityCredentials from each Stage1 application, limited to id/name/issuer/subject/audiences/description
- Delegated grants: delegatedGrants from /v1.0/oauth2PermissionGrants
- PIM relationship edges: pimScheduleEdges derived from Stage1 PIM schedule instances
- Conditional Access policy references: conditionalAccessPolicyReferences derived from Stage1 policies. Rows identify policy references to users, groups, role templates, application client IDs, service principals, named locations, authentication contexts, authentication-strength policies, Terms-of-Use IDs, custom authentication factors, external tenants, policy templates, user actions, and special Conditional Access selectors without performing live Stage3 provider calls.
- Entra governance membership: `administrativeUnitMembers` collects supported members for each persisted administrative unit; `administrativeUnitScopedRoleMembers` records scoped-role membership under the administrative-unit parent.
- Active Entra role governance: `activeRoleAssignmentEdges` is derived locally from persisted Stage1 role assignments and records principal ID/domain, role-definition ID/domain, and normalized scope. Tenant scope `/`, administrative-unit scope `/administrativeUnits/{id}`, app scope, and other directory-object/directory-scope values remain distinguishable offline.
- GPO direct scope links: `gpoScopeLinks` is driven by persisted Stage1 `gpos` and calls read-only `Get-GPOReport -Guid <guid> -Domain <persisted-domain> -ReportType Xml`. It reads only root `LinksTo` relationship nodes, retaining source-native scope path/name plus enabled and enforced (`NoOverride`) state. Each GPO produces one wrapper with `linkCount` and `links[]`, including a successful zero-link wrapper. The Stage2 Computer/User setting payload is not duplicated here.
- GPO inheritance: `gpoScopeInheritance` requires both Stage1 `domains` and `organizationalUnits`. Domain DNS identity is resolved to its DN with read-only `Get-ADDomain`, then `Get-GPInheritance -Target <domain-or-ou-DN> -Domain <persisted-domain>` preserves `GpoInheritanceBlocked`, direct links, and the provider-ordered effective/applied `InheritedGpoLinks`. One wrapper per domain/OU keeps zero direct/effective links explicit. `Get-GPInheritance` is intentionally limited to the domain/OU target types the cmdlet supports; broader direct targets exposed by GPO report `LinksTo` remain available through `gpoScopeLinks`.
- GPO WMI-filter association: `gpoWmiFilterAssociations` is driven by Stage1 `gpos`, reads `Get-GPO -Guid <guid> -Domain <persisted-domain>`, and persists explicit `hasWmiFilter = false` or the filter's provider-native stable `Path` plus `Name` and `Description`. No independent WMI-filter inventory is fabricated.
- GPO security filtering is not duplicated. `gpoPermissions` remains the canonical permission/delegation family, and rows with `PermissionLevel = GpoApply` are the offline security-filter evidence. Other permission levels stay available for delegation/ACL explanation.
- On-prem relationship families use persisted Stage1 domain context where cmdlets support domain targeting.
- None of the GPO applicability families attempts RSoP/gpresult or predicts a device/user's final winning policy settings; they preserve configuration topology only.
- Stage3 applies the same completed Stage1 plan readiness rule to every required dependency and persists its own compatible resume plan before processing relationship batches.
- During Stage3 resume, a prior successful batch is reused only when its canonical snapshot is readable/non-null, declares supported schema version `1.0`, matches current run/stage/section/family/batch identity, and checkpoint `itemCount`/`successCount`, snapshot `itemCount`, and actual `items.Count` agree with zero recorded failures. The current Stage3 plan binds the source batch; relationship output count is intentionally not required to equal source batch cardinality.

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
		catalog/
			knowledge-catalog.json   # created explicitly by Export-KnowledgeCatalog.ps1
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

The current supported snapshot `schemaVersion` is string `1.0`. Resume reuse and downstream snapshot loading fail closed when a persisted snapshot omits that field, stores it with a non-string type, or declares an unsupported version.

For on-prem snapshots, sourceName records concrete cmdlet names and requestContext includes cmdletNames for concrete execution traceability. `gpoReports` additionally records its Stage1 `gpos` dependency, XML report type, Computer/User evidence sections, credential-field redaction state, and effective one-GPO batch size. Stage3 GPO topology snapshots record their Stage1 dependency family/families and the concrete `Get-GPOReport`, `Get-ADDomain`/`Get-GPInheritance`, or `Get-GPO` cmdlet provenance used for that relationship family.

## Offline Knowledge Catalog v1 Contract

Raw snapshots, checkpoints, and the run manifest remain the source of truth. Offline knowledge-store v1 is a **derived deterministic catalog/index** over those files; it is not a second tenant datastore and does not transform raw evidence into reconstruction-ready objects.

The v1 contract is owned by `collector/schemas/catalog.schema.json`. `collector/Export-KnowledgeCatalog.ps1` materializes the derived file at `catalog/knowledge-catalog.json` beneath a terminal run directory. Catalog generation is deliberately explicit: normal `Invoke-Collector.ps1` collection does not automatically emit or refresh the catalog.

The generator discovers families from canonical persisted checkpoints, validates terminal manifest/checkpoint-summary coherence, and admits successful batches only after canonical snapshot schema, run/stage/section/family/batch identity, item cardinality, and Stage1 plan fingerprint checks. A `Completed` manifest rejects any non-success checkpoint state. `CompletedWithErrors` can index validated successful evidence while retaining its incomplete-coverage status, but terminal evidence containing an `InProgress` batch is rejected.

Regeneration is deterministic and idempotent. The catalog has no generation timestamp; arrays use stable ordering; unchanged source evidence produces byte-identical compact JSON. Persistence uses a same-directory temporary file plus atomic replacement. Validation occurs before replacement, so failed regeneration leaves any previously valid catalog untouched.

`collector/Test-KnowledgePackage.ps1` is the provider-independent read-only handoff gate. Its validation module invokes the existing catalog module's strict persisted-evidence pipeline in module scope to recompute the canonical expected catalog in memory, then structurally compares the stored catalog against that model. This detects stale run/manifest identity, missing or malformed checkpoint/snapshot evidence, unsupported schema versions, descriptor/path/count/provenance mismatches, and broken dependency/relationship descriptors without generating a replacement catalog or touching source files. The default result is a concise PowerShell object; `-AsJson` emits the same payload-safe status/count/message data as compact JSON.

The catalog contract requires:

- `schemaVersion` `1.0` and deterministic `catalogId` `catalog-v1:<runId>`;
- the run id and terminal source-manifest identity/status;
- one metadata-only descriptor per admitted raw snapshot with explicit run/stage/section/family/batch identity, canonical forward-slash relative snapshot path, canonical checkpoint relative path, snapshot/checkpoint schema versions, item count, and bounded provenance (`sourceType`, `sourceName`, `apiVersion`, `isBeta`);
- artifact `kind` values `inventory`, `detail`, and `relationship`, with the v1 stage mapping `stage1 -> inventory`, `stage2 -> detail`, `stage3 -> relationship`;
- dependency descriptors that link consumer and provider stage/section/family owners, distinguishing required `execution-input` dependencies from offline `reference` links;
- Stage3 relationship descriptors that publish a relationship type plus one or more source and target identity domains so an offline consumer can interpret edge direction without inventing object semantics.

The catalog includes `entra-ca` as a first-class section. Its four Stage2 families depend on their same-named Stage1 inventories, and `conditionalAccessPolicyReferences` depends on Stage1 `conditionalAccessPolicies`. The Stage3 catalog relationship type is `policy-reference`, with source domain `entra.conditional-access-policy` and target domains matching the explicit Conditional Access reference vocabulary documented above.

The catalog also includes `entra-governance` without a schema-version bump. Its four Stage2 families depend on the same-named Stage1 inventories; administrative-unit membership/scoped-role relationships depend on Stage1 `administrativeUnits`; active role edges depend on Stage1 `roleAssignments`. Governance and existing PIM relationship descriptors use stable role identity domains, while `directoryRoles` supplies the activated-role ID/`roleTemplateId` bridge needed to interpret scoped-role membership. This allows offline role resolution without making PIM execution depend on the optional governance section.

The `intune-core` catalog contract is additive without a schema-version bump. Compliance and #177 general configuration families retain their established execution-input and assignment relationship mappings. #178 adds Stage2 execution-input dependencies from securityConfigurationPolicies/securityConfigurationPolicySettings to Stage1 securityConfigurationPolicies, securityConfigurationPolicyTemplates to its same-named Stage1 family, securityBaselineTemplates to its same-named Stage1 family, and securityBaselineIntents/securityBaselineIntentSettings to Stage1 securityBaselineIntents. Stage3 securityConfigurationPolicyAssignments and securityBaselineIntentAssignments depend on their corresponding policy/intent Stage1 inventories. Two explicit `reference` dependencies make offline template resolution reviewable without misrepresenting collection order: Stage2 securityConfigurationPolicies references Stage1 securityConfigurationPolicyTemplates, and Stage2 securityBaselineIntents references Stage1 securityBaselineTemplates. Assignment relationships use distinct source domains (`intune.security-configuration-policy`, `intune.security-baseline-intent`) and the existing target domains (`entra.group`, `entra.directory-object`, `intune.assignment-filter`, `intune.assignment-target`). Assignment filters remain canonical under #176 and are not duplicated or modeled as execution prerequisites.

The catalog also treats opt-in `intune-enrollment` as a first-class section without changing catalog schema version. Stage2 `deviceEnrollmentConfigurations` and `windowsAutopilotDeploymentProfiles` depend on their same-named Stage1 inventories. Stage3 `deviceEnrollmentConfigurationAssignments` depends on Stage1 `deviceEnrollmentConfigurations`; `windowsAutopilotDeploymentProfileAssignments` depends on Stage1 `windowsAutopilotDeploymentProfiles`. Relationship sources are `intune.device-enrollment-configuration` and `intune.windows-autopilot-deployment-profile`; targets use stable Entra group/directory-object identities when available plus conservative `intune.assignment-target`, with Autopilot filter IDs represented by `intune.assignment-filter`. The catalog does not copy enrollment/profile payloads or make the `intune-core/assignmentFilters` family an execution prerequisite.

The on-prem catalog keeps Stage2 `gpoReports` as an `execution-input` consumer of Stage1 `onprem-ad-gpo/gpos` and adds three Stage3 topology contracts without a schema-version bump. `gpoScopeLinks` and `gpoWmiFilterAssociations` depend on Stage1 `gpos`; `gpoScopeInheritance` depends on both Stage1 `domains` and `organizationalUnits`. Relationship descriptors are `policy-link` (`gpo.policy -> ad.scope`), `policy-inheritance` (`ad.scope -> gpo.policy`), and `policy-filter` (`gpo.policy -> gpo.wmi-filter`). Existing `gpoPermissions` remains the `acl` relationship from `gpo.policy` to `ad.security-principal`, including `GpoApply` security-filter evidence. The catalog copies none of the topology payload rows; consumers follow artifact paths to canonical Stage3 snapshots.

Catalog descriptors deliberately do **not** copy snapshot `items`, `requestContext`, credential payloads, or other raw tenant content. Consumers follow `relativePath` back to canonical snapshots when payload data is needed. Existing credential boundaries therefore remain unchanged: raw key material and password secret text are still excluded by the collector, GPO report evidence redacts explicit credential-bearing XML fields before persistence, and the catalog adds no new secret-bearing surface.

For v1, "offline queryable" means that after a catalog is generated and validated, a consumer can discover available families, navigate Stage1 inventory to dependent Stage2/Stage3 evidence, identify relationship source/target identity domains, and locate canonical raw JSON without contacting Microsoft Graph or an on-prem provider. It does **not** imply a database/query service, embeddings/vector search, LLM runtime, UI, or tenant reconstruction/import/export model.

Catalog generation/validation must fail closed rather than repair or silently omit required evidence when the source manifest is non-terminal, a referenced checkpoint/snapshot is missing or unreadable, run/stage/section/family/batch identity disagrees with its descriptor/path, a checkpoint batch is not a valid persisted success, item counts disagree, or a referenced manifest/checkpoint/snapshot schema version is unsupported. `CompletedWithErrors` is a terminal run status the catalog can represent, but it must not be interpreted as proof of full collection coverage.

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
- GPO policy-setting evidence from read-only XML reports, bound to stable GPO GUID/domain identity and split into Computer/User configuration evidence.
- GPO applicability topology: direct scope links, domain/OU inheritance/effective-link evidence, WMI-filter association, and security-filter permission evidence, all as read-only configuration metadata rather than resultant client policy.
- Intune compliance-policy configuration, assignment filters, general Settings Catalog/non-security configuration policies, classic device configurations, modern endpoint-security/security-baseline policies/templates, legacy security-baseline templates/intents, configured settings, migration context, and assignment targeting/filter context.
- Opt-in Intune tenant enrollment configuration and Windows Autopilot deployment-profile configuration/assignments, without individual device identity or hardware-hash export.
- Conditional Access policy/configuration metadata and explicit offline policy references.
- Administrative-unit, activated directory-role, directory-role-definition, and active-role-assignment configuration metadata plus scoped governance relationships.
- ACLs, memberships, assignments, grants, role-governance edges, policy references, and GPO applicability edges treated as metadata.

Out of scope:

- Mailbox or collaboration workloads.
- Defender telemetry domains, detections, signals, or endpoint-health streams.
- Audit and sign-in stream ingestion.
- Intune per-device/per-user compliance, configuration, endpoint-security, baseline, enrollment, or deployment status/state; device/user status collections; state summaries; per-setting status/results; reports; or remediation.
- Autopilot device identities/imports, assigned-device relationships, serial/product-key/device-account-password data, actual hardware-hash values, enrollment event history, and Apple/third-party enrollment service-connection/token surfaces.
- GPO backup/import/reconstruction artifacts or mutation; RSoP/gpresult, per-user/per-device client policy-processing telemetry, or simulation of final winning policy; credential/password/private-key/secret values from GPO report evidence.
- Conditional Access simulation/evaluation, mutation, remediation, or operational sign-in/risk history.
- Role activation event history, access-review execution/history, entitlement workflow execution, or governance mutation.
