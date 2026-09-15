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
3. Stage3 collects relationship metadata (ACLs, memberships, assignments, delegated grants, PIM edges, policy references, and role-governance edges) from Stage1 artifacts.

ACLs, memberships, assignments, grants, policy references, and role-governance edges are classified as metadata.

## Concretized Implementation Layout

- CLI entry: collector/Invoke-Collector.ps1
- Offline catalog command: collector/Export-KnowledgeCatalog.ps1
- Offline package validation command: collector/Test-KnowledgePackage.ps1
- Orchestration: collector/modules/Collector.Orchestrator.psm1
- Stage modules:
  - collector/modules/Collector.Stage1.Inventory.psm1
  - collector/modules/Collector.Stage2.Details.psm1
  - collector/modules/Collector.Stage3.Relationships.psm1
  - collector/modules/Collector.Stage.EntraConditionalAccess.psm1 — bounded Conditional Access routing/derivation that reuses the existing Stage1/2/3 execution seams rather than duplicating checkpoint/provenance machinery.
  - collector/modules/Collector.Stage.EntraGovernance.psm1 — bounded administrative-boundary/role-governance routing and derived active-role edges that reuse the same Stage1/2/3 execution seams.
  - collector/modules/Collector.Stage.IntuneCompliance.psm1 — Intune augmentation entry invoked by the orchestrator for `intune-core`; it owns compliance collection and delegates bounded general-configuration and security/baseline extensions while preserving one public Intune policy section/hook.
  - collector/modules/Collector.Stage.IntuneConfiguration.psm1 — bounded Settings Catalog/device-configuration profile collection, settings paging, admission filtering, and assignment normalization that reuses the Stage1/2/3 owner-module seams.
  - collector/modules/Collector.Stage.IntuneSecurity.psm1 — bounded modern endpoint-security/security-baseline and legacy baseline intent collection, settings paging, template admission, migration context, and assignment normalization using the same Stage1/2/3 execution seams.
  - collector/modules/Collector.Stage.IntuneEnrollment.psm1 — opt-in tenant enrollment and Windows Autopilot deployment-profile configuration/assignment collection using the existing Stage1/2/3 execution seams while keeping its distinct service-configuration permission out of legacy defaults.
- Providers:
  - collector/modules/Collector.Provider.Graph.psm1
  - collector/modules/Collector.Provider.OnPrem.psm1
- Control and storage:
  - collector/modules/Collector.Storage.Artifacts.psm1
  - collector/modules/Collector.Storage.Checkpoints.psm1
  - collector/modules/Collector.Storage.Catalog.psm1
  - collector/modules/Collector.Validation.Package.psm1
  - collector/modules/Collector.Common.Retry.psm1
  - collector/modules/Collector.Common.Provenance.psm1
- Schemas:
  - collector/schemas/snapshot.schema.json
  - collector/schemas/checkpoint.schema.json
  - collector/schemas/manifest.schema.json
  - collector/schemas/catalog.schema.json

## Architecture Boundaries

### In Scope

- Entra application, service principal, group, PIM schedule, Conditional Access, administrative-unit, activated directory-role, directory-role-definition, and active-role-assignment configuration metadata.
- Intune application, script, compliance-policy, assignment-filter, admitted general Settings Catalog/device-configuration policy, classic device-configuration profile, modern endpoint-security/security-baseline policy/template, legacy security-baseline template/intent, configured-setting, migration-state, and assignment target/filter metadata.
- Opt-in Intune tenant enrollment configuration and Windows Autopilot deployment-profile configuration/assignment metadata.
- On-prem forest/domain/OU/group/GPO metadata via AD and Group Policy cmdlets, including read-only GPO Computer/User policy-setting evidence bound to stable GPO GUID/domain identity.
- Relationship metadata for ACLs, memberships, assignments, delegated grants, PIM schedule edges, Conditional Access policy references, administrative-unit memberships/scoped roles, active role assignments, and Intune compliance/configuration/security/enrollment targeting.

Bearer-authenticated absolute Graph request and pagination URIs are restricted to the collector's public Microsoft Graph HTTPS origin (`https://graph.microsoft.com:443`); insecure, cross-origin, alternate-port, and user-info-bearing absolute URIs fail before HTTP execution.

### Out of Scope

- Mailbox or collaboration workloads.
- Defender telemetry domains, detections, signals, endpoint-health streams, or operational security events.
- Audit and sign-in stream ingestion.
- Intune per-device/per-user compliance/configuration/endpoint-security/baseline/enrollment state, policy-result/status overview, device/user state summaries, per-setting status/result/report telemetry, enrollment events, or remediation.
- Windows Autopilot device identities/imports, assigned-device relationships, serial/product-key/device-account-password data, actual hardware-hash values, and Apple/third-party enrollment service-connection/token surfaces.
- GPO backup/import/reconstruction artifacts or mutation, RSoP/gpresult/client policy-processing telemetry, and credential/password/private-key/secret values from GPO report evidence. Normalized GPO link/inheritance/WMI/security-filtering applicability topology remains a separate relationship responsibility rather than part of Stage2 policy-setting evidence.
- Conditional Access policy simulation/evaluation, sign-in/risk history, or remediation.
- Role activation event history, access reviews, entitlement workflow execution/history, or governance mutation.
- Configuration mutation through the collector; the normal Graph provider request boundary is GET-only and exposes no mutation/body request surface.

## Stage and Section Model

Supported sections are:

- entra-apps
- entra-pim
- entra-ca
- entra-governance
- intune-core
- intune-enrollment
- onprem-ad-gpo

`entra-ca`, `entra-governance`, and `intune-enrollment` are deliberately **opt-in**. The historical default section set remains `entra-apps`, `entra-pim`, `intune-core`, and `onprem-ad-gpo` so upgrading the collector does not silently introduce new permission dependencies. Explicitly selecting any optional section makes it a normal Graph-backed section and therefore requires a Graph token.

`entra-governance` is separate from `entra-pim` because administrative-unit reads require application permission `AdministrativeUnit.Read.All`, while activated directory roles, role definitions, active role assignments, and administrative-unit scoped-role membership reads require `RoleManagement.Read.Directory`. Existing PIM schedule collection remains canonical and is not duplicated under the governance section.

`intune-enrollment` is separate from `intune-core` because enrollment service configuration requires application permission `DeviceManagementServiceConfig.Read.All`, whereas the existing Intune policy/configuration families use `DeviceManagementConfiguration.Read.All`. The split preserves the legacy default permission boundary while still allowing enrollment evidence to participate in the same run/package model when explicitly selected.

Representative Stage1 families and sources:

- entra-apps:
  - /v1.0/applications
  - /v1.0/servicePrincipals
  - /v1.0/groups
- entra-pim:
  - /v1.0/roleManagement/directory/roleAssignmentScheduleInstances
  - /v1.0/roleManagement/directory/roleEligibilityScheduleInstances
- entra-ca:
  - `conditionalAccessPolicies` from /v1.0/identity/conditionalAccess/policies
  - `namedLocations` from /v1.0/identity/conditionalAccess/namedLocations
  - `authenticationStrengthPolicies` from /v1.0/policies/authenticationStrengthPolicies
  - `authenticationContextClassReferences` from /v1.0/identity/conditionalAccess/authenticationContextClassReferences
- entra-governance:
  - `administrativeUnits` from /v1.0/directory/administrativeUnits
  - `directoryRoles` from /v1.0/directoryRoles
  - `roleDefinitions` from /v1.0/roleManagement/directory/roleDefinitions
  - `roleAssignments` from /v1.0/roleManagement/directory/roleAssignments
- intune-core:
  - `mobileApps` from /v1.0/deviceAppManagement/mobileApps
  - `deviceManagementScripts` from /beta/deviceManagement/deviceManagementScripts
  - `deviceCompliancePolicies` from /v1.0/deviceManagement/deviceCompliancePolicies
  - `assignmentFilters` from /beta/deviceManagement/assignmentFilters
  - `configurationPolicies` from /beta/deviceManagement/configurationPolicies after explicit general-configuration template-family admission (`none`, `deviceConfigurationPolicies` only)
  - `deviceConfigurations` from /v1.0/deviceManagement/deviceConfigurations
  - `securityConfigurationPolicies` from /beta/deviceManagement/configurationPolicies after explicit security/baseline template-family admission
  - `securityConfigurationPolicyTemplates` from /beta/deviceManagement/configurationPolicyTemplates after the same security/baseline family admission
  - `securityBaselineTemplates` from /beta/deviceManagement/templates after reviewed legacy security-template admission
  - `securityBaselineIntents` from /beta/deviceManagement/intents when `templateId` resolves to an admitted securityBaselineTemplates row
- intune-enrollment:
  - `deviceEnrollmentConfigurations` from /v1.0/deviceManagement/deviceEnrollmentConfigurations
  - `windowsAutopilotDeploymentProfiles` from /beta/deviceManagement/windowsAutopilotDeploymentProfiles
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
- PIM, Conditional Access, governance, and Intune Stage2 families retain their Graph resource response behavior until separately reviewed property contracts exist for those surfaces.

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

### Conditional Access configuration boundary

`entra-ca` is a configuration-only section designed to answer offline questions such as which Conditional Access policies exist, how they are configured, and which identities/configuration objects they reference. It intentionally does not collect sign-in evaluation results, audit history, risky-user/sign-in data, or Defender telemetry.

- Stage1 inventories four stable configuration families: policies, named locations, authentication-strength policies, and authentication-context class references.
- Stage2 reads the same four resources by stable id through Microsoft Graph v1.0. The normal Graph response is retained as raw evidence; no policy-evaluation model or tenant-reconstruction transform is introduced.
- `Collector.Stage.EntraConditionalAccess.psm1` is a thin extension owner. It invokes the existing Stage1/Stage2/Stage3 private execution helpers in their owner-module session state, preserving the shared provenance, checkpoint, zero-item, retry, and resume contracts rather than creating parallel implementations.
- Stage3 `conditionalAccessPolicyReferences` is derived locally from Stage1 policy inventory and performs no live Stage3 Graph request. Each row records `policyId`, `referenceType`, `direction`, `sourcePath`, `targetId`, and `targetIdentityDomain`.
- Policy references distinguish stable object identifiers from Conditional Access selector constants such as `All`, `AllTrusted`, `Office365`, `MicrosoftAdminPortals`, `ServicePrincipalsInMyTenant`, and guest/external selectors. Selectors use the `entra.conditional-access-selector` identity domain instead of being misrepresented as tenant objects.
- Stable reference domains include users, groups, directory-role templates, application client IDs, service principals, named locations, authentication contexts, authentication-strength policies, external tenants, policy templates, user actions, Terms-of-Use IDs, and custom authentication-factor IDs.
- Terms-of-Use agreement payloads are not collected in this slice because the Microsoft Graph v1 agreement read surface does not support application permissions. Policies still expose Terms-of-Use IDs as explicit references so offline consumers can see the dependency without forcing the collector into delegated authentication.
- `entra-ca` remains opt-in because its Graph permission requirements are distinct from the historical default sections. The caller's Graph token must authorize every selected CA resource surface; the collector does not attempt privilege escalation or alternate delegated authentication.

### Entra administrative governance boundary

`entra-governance` captures static administrative boundaries and active role-governance configuration without changing the existing PIM model.

- Stage1 inventories `administrativeUnits`, `directoryRoles`, `roleDefinitions`, and `roleAssignments` from Microsoft Graph v1.0.
- Stage2 reads the same four resources by stable id so administrative boundaries, activated role instances, role definitions, and active assignments remain reviewable offline configuration evidence.
- `directoryRoles` supplies the activated-role bridge required by administrative-unit scoped-role membership: a scoped-role row's `roleId` resolves to a `directoryRole.id`, and that role's `roleTemplateId` can then be matched to `roleDefinition.templateId` for reviewable role metadata.
- `Collector.Stage.EntraGovernance.psm1` is a thin extension owner that invokes the existing Stage1/Stage2/Stage3 private execution helpers in their owner-module session state, preserving checkpoint, provenance, retry, zero-item, and resume behavior.
- Stage3 `administrativeUnitMembers` reads `/v1.0/directory/administrativeUnits/{id}/members` from persisted administrative-unit inventory.
- Stage3 `administrativeUnitScopedRoleMembers` reads `/v1.0/directory/administrativeUnits/{id}/scopedRoleMembers` from persisted administrative-unit inventory.
- Stage3 `activeRoleAssignmentEdges` is derived locally from persisted Stage1 `roleAssignments`; it performs no live Stage3 provider request for role assignments.
- Active-role edge conversion runs inside the checkpointed Stage3 batch collector. A malformed assignment therefore records failed-batch evidence while preserving valid rows from the same source batch, and `-Resume -ReprocessFailedOnly` can retry that failed batch rather than aborting the whole invocation before checkpoint creation.
- Active-role edges retain assignment ID, principal ID/domain, role-definition ID/domain, and normalized scope. Directory scope `/` is tenant scope (`entra.tenant`); `/administrativeUnits/{id}` is an administrative-unit scope; other slash-prefixed values remain directory-object scope; `appScopeId` is `entra.app-scope`; other non-empty directory scope values remain `entra.directory-scope` rather than being guessed into a stronger type.
- Principal IDs are represented as `entra.directory-object` because active assignments can target users, role-assignable groups, or service principals. Full principal payloads are not duplicated into governance evidence.
- Both existing PIM schedule edges and governance active-role edges use the `entra.directory-role-definition` identity domain. When `entra-governance` is selected, an offline consumer can therefore resolve either PIM or active-assignment `roleDefinitionId` values against the collected role-definition metadata by stable ID without making PIM execution depend on governance collection.
- Existing `entra-pim` Stage1/Stage2 schedule-instance families and Stage3 `pimScheduleEdges` remain canonical. `entra-governance` does not create competing PIM schedule families or activation-history evidence.

### Intune compliance configuration boundary

Intune compliance is an additive configuration slice inside the existing default `intune-core` section. It deliberately reuses the canonical app/script section rather than introducing a second Intune execution model.

- `Collector.Stage.IntuneCompliance.psm1` is the current Intune augmentation entry invoked whenever `intune-core` is selected. It collects compliance evidence and delegates the general configuration-policy/profile slice to `Collector.Stage.IntuneConfiguration.psm1` and the security/baseline slice to `Collector.Stage.IntuneSecurity.psm1`; the top-level orchestrator therefore retains one stable Intune policy hook.
- Stage1 `deviceCompliancePolicies` reads `/v1.0/deviceManagement/deviceCompliancePolicies`; Stage2 reads `/v1.0/deviceManagement/deviceCompliancePolicies/{id}`. The platform-specific policy `@odata.type` and normal Graph-returned configuration remain raw evidence for offline review.
- Stage1 `assignmentFilters` reads `/beta/deviceManagement/assignmentFilters`; Stage2 reads `/beta/deviceManagement/assignmentFilters/{id}`. Assignment-filter definitions are canonical configuration evidence because assignment rows can refer to filter IDs that otherwise cannot be interpreted offline.
- Stage3 `deviceCompliancePolicyAssignments` is driven from persisted Stage1 `deviceCompliancePolicies` and reads `/beta/deviceManagement/deviceCompliancePolicies/{id}/assignments`. Beta is intentionally bounded to the filter/assignment contract so `deviceAndAppManagementAssignmentFilterId` and `deviceAndAppManagementAssignmentFilterType` include/exclude semantics are preserved.
- All accepted reads use application permission `DeviceManagementConfiguration.Read.All`; Microsoft Graph Intune APIs also require an active Intune license for the tenant. The collector does not acquire permissions, switch to delegated auth, or invoke mutation APIs.
- Assignment rows normalize only relationship metadata: assignment/source identity, target OData/target type, stable target ID when available, conservative target identity domain, assignment-filter ID/type, and filter identity domain. Explicit `groupId` is `entra.group`; explicit `entraObjectId` is `entra.directory-object`; filter IDs are `intune.assignment-filter`; all other selector/target forms remain `intune.assignment-target` rather than being guessed into stronger tenant-object semantics.
- The transform is intentionally non-throwing for unfamiliar target shapes. Unknown-but-readable assignment targets remain reviewable through raw target type/fallback identity instead of causing one unusual target to discard otherwise valid assignment evidence.
- Device/user compliance state, device status/user status collections, status overviews, setting-state summaries, Defender signals, and remediation are not collected by this slice.

### Intune configuration policy and profile boundary

#177 extends `intune-core` with the two configuration surfaces users see as modern Settings Catalog/device configuration policies and classic device configurations, without swallowing endpoint-security/baseline/enrollment ownership.

- Stage1 `configurationPolicies` requests `/beta/deviceManagement/configurationPolicies`, then applies an explicit persisted-evidence admission rule: only `templateReference.templateFamily` values `none` and `deviceConfigurationPolicies` are admitted. Known endpoint-security families, `baseline`, `enrollmentConfiguration`, `deviceConfigurationScripts`, `windowsOsRecoveryPolicies`, `companyPortal`, `appQuietTime`, and `unknownFutureValue` are excluded from this child. This keeps #178/#181 and future grooming boundaries honest even though Microsoft Graph exposes several policy families through the same resource type.
- Stage1 `deviceConfigurations` requests `/v1.0/deviceManagement/deviceConfigurations`. The raw `@odata.type` remains part of inventory/detail evidence so classic platform/profile types stay distinguishable.
- Stage2 `configurationPolicies` requests `/beta/deviceManagement/configurationPolicies/{id}` for each admitted Stage1 policy. Stage2 `deviceConfigurations` requests `/v1.0/deviceManagement/deviceConfigurations/{id}` for each classic profile.
- Stage2 `configurationPolicySettings` is driven by Stage1 `configurationPolicies` and requests the paged `/beta/deviceManagement/configurationPolicies/{id}/settings` collection. It emits exactly one wrapper per source policy: `policyId`, `settingCount`, and the complete paged `settings` array. This preserves Stage2 plan/output cardinality and normal resume validation while retaining all configured setting-instance payloads needed offline.
- The specialized settings path still uses the shared Stage2 checkpoint, batch-decision, artifact, provenance, resume-validation, retry, paging, and zero-item primitives in the Stage2 owner module session. It does not introduce another persistence format or numeric-batch interpretation.
- Stage3 `configurationPolicyAssignments` uses `/beta/deviceManagement/configurationPolicies/{id}/assignments`; `deviceConfigurationAssignments` uses `/beta/deviceManagement/deviceConfigurations/{id}/assignments`. Beta is bounded to assignments so assignment-filter ID/type survives for both modern and classic policy surfaces; classic inventory/detail remains v1.0.
- Assignment normalization preserves assignment ID, source/sourceId and intent when present, target OData/type, stable target ID when available, and filter ID/type. Group IDs are `entra.group`, explicit Entra object IDs are `entra.directory-object`, filter IDs are `intune.assignment-filter`, Configuration Manager collections preserve `collectionId`, and all other selectors/targets remain conservative `intune.assignment-target`.
- The #176 `assignmentFilters` family remains the only filter-definition owner. Assignment collection does not require a live filter expansion and the catalog does not falsely model filter evidence as an execution prerequisite.
- Application permission remains `DeviceManagementConfiguration.Read.All` with an active Intune tenant license. Every call is GET-only.
- Explicitly excluded operational relationships include classic `deviceStatuses`, `userStatuses`, status-overview/setting-summary/report surfaces and modern per-device/per-user/per-setting status. Endpoint-security templates/baselines and enrollment/onboarding policy families are excluded from #177 even where the generic configuration-policy resource can expose them.

### Intune endpoint-security and security-baseline boundary

#178 owns security configuration that #177 deliberately excluded. It covers both the modern configuration-policy model and the still-documented legacy baseline intent model because legacy intents expose `isMigratingToConfigurationPolicy`; assuming universal migration would make offline evidence incomplete for tenants still carrying legacy baselines.

Modern beta families:

- Stage1 `securityConfigurationPolicies` reads `/beta/deviceManagement/configurationPolicies` and admits only template families `endpointSecurityAntivirus`, `endpointSecurityDiskEncryption`, `endpointSecurityFirewall`, `endpointSecurityEndpointDetectionAndResponse`, `endpointSecurityAttackSurfaceReduction`, `endpointSecurityAccountProtection`, `endpointSecurityApplicationControl`, `endpointSecurityEndpointPrivilegeManagement`, and `baseline`.
- Stage1 `securityConfigurationPolicyTemplates` reads `/beta/deviceManagement/configurationPolicyTemplates` and applies the same admitted template-family set, retaining stable template/base/version/displayVersion/lifecycle/platform/technology/family metadata in raw evidence.
- Stage2 `securityConfigurationPolicies` and `securityConfigurationPolicyTemplates` read the corresponding beta resources by stable id.
- Stage2 `securityConfigurationPolicySettings` reads paged `/beta/deviceManagement/configurationPolicies/{id}/settings`, emitting one wrapper per security policy (`policyId`, `settingCount`, `settings`) so page count does not alter source cardinality or resume semantics.
- Stage3 `securityConfigurationPolicyAssignments` reads `/beta/deviceManagement/configurationPolicies/{id}/assignments` only from persisted securityConfigurationPolicies inventory.

Legacy beta families:

- Stage1 `securityBaselineTemplates` reads `/beta/deviceManagement/templates` and admits `#microsoft.graph.securityBaselineTemplate` plus reviewed security/baseline `templateType` values (`securityBaseline`, `advancedThreatProtectionSecurityBaseline`, `securityTemplate`, `microsoftEdgeSecurityBaseline`, `microsoftOffice365ProPlusSecurityBaseline`, `cloudPC`).
- Stage1 `securityBaselineIntents` reads `/beta/deviceManagement/intents` and admits only intents whose `templateId` resolves to an admitted securityBaselineTemplates ID. `isMigratingToConfigurationPolicy` remains raw reviewable evidence.
- Stage2 `securityBaselineTemplates` and `securityBaselineIntents` read their beta resources by id.
- Stage2 `securityBaselineIntentSettings` reads paged `/beta/deviceManagement/intents/{id}/settings`, emitting one wrapper per legacy intent (`intentId`, `settingCount`, `settings`).
- Stage3 `securityBaselineIntentAssignments` reads `/beta/deviceManagement/intents/{id}/assignments` only from persisted securityBaselineIntents inventory.

Cross-cutting security policy rules:

- Every accepted #178 call is GET-only beta Microsoft Graph configuration metadata under the existing `DeviceManagementConfiguration.Read.All` application-permission boundary and active Intune-license requirement.
- Modern and legacy assignment rows reuse the conservative target/filter identity contract from #176/#177, including stable Configuration Manager `collectionId` preservation. Modern source identity is `intune.security-configuration-policy`; legacy source identity is `intune.security-baseline-intent`.
- The catalog models Stage2/Stage3 source families as `execution-input` dependencies. It also emits reviewed `reference` dependencies from Stage2 securityConfigurationPolicies to Stage1 securityConfigurationPolicyTemplates and from Stage2 securityBaselineIntents to Stage1 securityBaselineTemplates so template IDs are navigable offline without pretending template evidence controls runtime collection order.
- Modern/legacy per-device or per-user policy state is excluded. Legacy `deviceStates`, `userStates`, `deviceStateSummary`, `userStateSummary`, `deviceSettingStateSummaries`, template device-state summaries, Defender detections/signals, endpoint-health streams, reports, remediation, and mutation are not requested or persisted.
- Reusable setting definitions/template-setting catalogs remain out of scope unless a later demonstrated offline-questioning gap is separately groomed.

### Intune enrollment and onboarding boundary

#181 is an opt-in configuration-only section because its permission surface differs from `intune-core`.

- `Collector.Stage.IntuneEnrollment.psm1` is invoked only when `intune-enrollment` is explicitly selected; the legacy default sections and `intune-core` execution path remain unchanged.
- Stage1 `deviceEnrollmentConfigurations` reads `/v1.0/deviceManagement/deviceEnrollmentConfigurations`; Stage2 reads `/v1.0/deviceManagement/deviceEnrollmentConfigurations/{id}`. Graph-returned derived types remain raw evidence, including Enrollment Status Page/completion-page, platform restrictions, Windows Hello for Business enrollment configuration, notifications, restore, and other service-returned enrollment configuration types.
- Stage3 `deviceEnrollmentConfigurationAssignments` reads `/v1.0/deviceManagement/deviceEnrollmentConfigurations/{id}/assignments` from persisted Stage1 inventory. Stable group IDs are `entra.group`, explicit Entra object IDs are `entra.directory-object`, and all-users/all-devices/other selector shapes remain conservative `intune.assignment-target`.
- Stage1 `windowsAutopilotDeploymentProfiles` reads `/beta/deviceManagement/windowsAutopilotDeploymentProfiles`; Stage2 reads `/beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}`. The raw profile preserves subtype/OData identity, OOBE and Enrollment Status Screen configuration, naming/preprovisioning settings, role scope tags, and the `hardwareHashExtractionEnabled` configuration flag.
- Stage3 `windowsAutopilotDeploymentProfileAssignments` derives assignments from `GET /beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}?$expand=assignments`. This uses the profile resource's documented `assignments` relationship and OData query support while avoiding the generated assignment-list method's device-identity-scoped navigation path. It preserves group/directory-object targets, filter ID/type, conservative selector identities, and Configuration Manager `collectionId` where present.
- Every accepted #181 call is GET-only under application permission `DeviceManagementServiceConfig.Read.All` and the active Intune-license requirement. The collector does not acquire permissions, switch auth mode, or invoke sync/mutation actions.
- The profile's hardware-hash extraction **setting** is configuration metadata; #181 never requests `windowsAutopilotDeviceIdentities`, imported identities/uploads, assigned-device relationships, serial/product-key/device-account-password data, or an actual hardware-hash value.
- Managed-device status, enrollment/deployment events or state, device health, remediation, and Apple/third-party enrollment service-connection/token surfaces are excluded.
- Stage2/Stage3 catalog dependencies remain local to `intune-enrollment`. Autopilot assignment-filter IDs may reference canonical `intune-core/assignmentFilters` conceptually, but filter evidence is not an execution prerequisite and no cross-section execution edge is introduced.

### On-prem GPO policy-setting evidence boundary

#179 extends the existing `onprem-ad-gpo` Stage2 owner with policy-setting evidence without creating a second GPO inventory, backup model, or applicability topology owner.

- Stage1 `gpos` remains the canonical GPO identity inventory. Each row carries the stable GPO GUID plus persisted domain context.
- Stage2 `gpoReports` depends on Stage1 `gpos` and invokes `Get-GPOReport -Guid <guid> -Domain <persisted-domain> -ReportType Xml`; display name is descriptive only and is never the join key.
- The provider parses the report and persists the complete direct `Computer` and `User` XML configuration subtrees in a wrapper containing `gpoId`, `domainContext`, `displayName`, report type, explicit side-presence flags, and a credential-redaction count. Root-level report material such as links and delegation context is not copied into this family.
- Report XML is intentionally preserved rather than incompletely normalized. Group Policy extension-specific setting structures differ, and the raw sanitized Computer/User subtrees are the reviewable source evidence for what the GPO configures.
- Each GPO report is one Stage2 batch/artifact regardless of the caller's general BatchSize. This bounds large XML artifacts and makes a single large/problematic GPO independently resumable without adding a second persistence mechanism.
- Before persistence, explicit credential-bearing XML element or attribute names are redacted to `[REDACTED]`, including `cpassword`, password/secret/private-key/client-secret forms. Ordinary policy settings such as password-length values are not redacted merely because their setting name contains the word `Password`. This is a fail-closed contract for recognized credential fields, not a claim that arbitrary operator-authored registry/script content can be semantically inspected for every possible secret.
- Stage2 provenance records `Get-GPOReport`, XML report type, Stage1 `gpos` dependency, persisted-domain targeting, Computer/User evidence selection, credential-field redaction, and effective batch size 1.
- The offline catalog adds only the normal `execution-input` dependency `stage2/onprem-ad-gpo/gpoReports -> stage1/onprem-ad-gpo/gpos`; raw report payload remains exclusively in the canonical snapshot artifact.
- Normalized links, inheritance, WMI-filter association, and security-filter/applicability topology are deliberately not owned here. They remain the subsequent Stage3 relationship responsibility (#180), while existing `gpoPermissions` remains canonical for current GPO permission evidence.
- GPO backup/import/reconstruction, mutation, RSoP/gpresult, and per-user/per-device client policy-processing telemetry remain outside the product boundary.

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
  - Stage1 and Stage2 reuse a Succeeded batch only after current-input plan compatibility is established and the canonical snapshot is readable/non-null, declares supported schema version `1.0`, matches current run/stage/section/family/batch identity, and agrees with current planned/checkpoint/snapshot item cardinality;
  - a Stage1 or Stage2 prior success that fails that validation is recorded as non-success and reprocessed through that stage's normal write/checkpoint path in the same resume invocation without deleting the artifact first;
  - Stage3 also reuses a Succeeded batch only after current-input plan compatibility and canonical snapshot validation. The snapshot must be readable/non-null, declare supported schema version `1.0`, match current run/stage/section/family/batch identity, and agree across checkpoint `itemCount`/`successCount`, snapshot `itemCount`, and actual `items.Count`, with zero checkpoint failures;
  - Stage3 intentionally does not require relationship output `itemCount` to equal the source batch item count because relationship collectors may emit multiple output rows per source object. The compatible Stage3 plan binds source identity/cardinality separately from output-cardinality validation;
  - a Stage3 prior success that fails validation is recorded as non-success and reprocessed through the normal Stage3 collector/write/checkpoint path in the same resume invocation without deleting the artifact first.
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
- derived catalog, when explicitly generated:
  - output/<runId>/catalog/knowledge-catalog.json

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

The current supported snapshot `schemaVersion` is string `1.0`. Persisted snapshots with a missing, non-string, or unsupported version fail closed at both successful-resume reuse and shared downstream snapshot loading.

For on-prem families, sourceName is cmdlet-specific and requestContext includes cmdletNames for concrete execution traceability. `gpoReports` additionally records its source `gpos` dependency, XML report type, evidence-section/redaction choices, and effective one-GPO batch size.

## Offline Knowledge Catalog v1

The offline catalog is a justified boundary between provider-specific collection and provider-independent offline consumption. It owns **discovery and navigation metadata only**. Raw snapshots/checkpoints/manifest remain authoritative evidence, and the catalog never becomes a second source of tenant truth.

### Durable owner and path

- Schema owner: `collector/schemas/catalog.schema.json`.
- Runtime owner: `collector/modules/Collector.Storage.Catalog.psm1`.
- Catalog operator command: `collector/Export-KnowledgeCatalog.ps1 -RunPath output/<runId>`.
- Package-validation owner: `collector/modules/Collector.Validation.Package.psm1`.
- Package-validation command: `collector/Test-KnowledgePackage.ps1 -RunPath output/<runId>`.
- Derived artifact: `output/<runId>/catalog/knowledge-catalog.json`.
- Catalog schema version: string `1.0`.
- Stable catalog identity: `catalog-v1:<runId>`.
- Generation and validation are explicit and offline; normal `Invoke-Collector.ps1` collection does not automatically emit, refresh, or validate the catalog.

The stable `catalogId` identifies the v1 catalog for a run. It is not a random GUID or generation timestamp. Regenerating a catalog from unchanged source evidence therefore produces the same identity and deterministic content rather than churn caused by generation time.

`entra-ca`, `entra-governance`, the additive Intune compliance/general-configuration/security-baseline families, opt-in `intune-enrollment`, and the additive on-prem `gpoReports` detail family use the existing v1 stage/kind, artifact-descriptor, dependency, and relationship schema shapes and therefore do not require a catalog schema-version bump.

### Runtime generation boundary

Catalog generation consumes only persisted local evidence. The catalog module imports storage/checkpoint/provenance modules and no Graph or on-prem provider module. Checkpoints are the discovery index; the generator does not infer collection families by heuristically walking raw snapshot directories.

Before a snapshot is admitted, generation verifies terminal manifest/run identity, current checkpoint-summary agreement, canonical checkpoint plan/batch identity, succeeded-batch count integrity, canonical snapshot existence/readability/schema/identity/cardinality, and the Stage1 persisted plan fingerprint. Checkpoint, batch, and snapshot timestamps must not be newer than the terminal manifest completion timestamp.

A `Completed` manifest requires all checkpoint batches to be successful. A `CompletedWithErrors` manifest may produce a catalog containing only validated successful batches, while `runStatus` preserves the incomplete-coverage fact. Any terminal package that still contains an `InProgress` batch is rejected. A successful zero-item family remains represented by its successful empty snapshot.

Execution-input, reviewed reference dependencies, and Stage3 relationship identity-domain descriptors are emitted only for admitted consumer families. Required Stage1 providers must also resolve to admitted evidence; otherwise generation fails instead of publishing a broken navigation edge. Reference dependencies are explicit static contracts, not guessed from arbitrary payload fields. #178 currently uses this vocabulary for modern policy→template and legacy intent→template offline navigation.

The final document is serialized without a generation timestamp and with deterministic array ordering. It is first written to a same-directory temporary file and round-tripped as JSON, then atomically replaces the prior catalog. All source validation precedes replacement, so a failed regeneration leaves the previous catalog untouched.

### Provider-independent package validation boundary

Package validation is a read-only handoff gate after catalog generation and before external consumption. `Collector.Validation.Package.psm1` imports the catalog module but does not import Graph or on-prem provider modules and exposes no source-write path.

To avoid a second, weaker parser stack, the validator invokes the catalog module's existing strict persisted-evidence functions in that module's own session state and recomputes the canonical expected catalog **in memory only**. It then reads the persisted `catalog/knowledge-catalog.json` and performs a recursive structural comparison against that canonical model. Object property sets and case, array ordering/counts, scalar types/values, catalog/run identity, source-manifest identity, artifact descriptors, dependency endpoints, and relationship descriptors must all agree. The source-manifest timestamp comparison deliberately accepts the cross-runtime JSON materialization used by the collector (`string`, `DateTime`, or `DateTimeOffset`) and compares canonical UTC time.

Because the expected model is built through the generator's existing evidence pipeline, validation also reuses terminal-manifest checks, checkpoint-summary coherence, strict checkpoint loading, batch success/count rules, canonical snapshot existence/schema/identity/cardinality, Stage1 fingerprint validation, dependency resolution, and relationship-family semantics. A stale catalog therefore fails even when its JSON is syntactically valid.

Validation never regenerates the catalog, repairs evidence, rewrites the manifest/checkpoints/snapshots, or contacts a provider. The default command output is one payload-safe PowerShell result object with `valid`, `status`, run/catalog identity, validated artifact/family/dependency/relationship counts, and a concise message. `-AsJson` emits the same result as compact JSON for machine handoff. Failure messages identify the contract/path that failed but do not include raw snapshot `items` or `requestContext` content.

The operator flow is therefore:

`collect -> catalog -> validate -> consume`

### Artifact descriptors

Every admitted raw snapshot is represented by one metadata-only descriptor containing:

- `runId`, `stage`, `section`, `family`, and `batchId`;
- `kind`, where v1 requires `stage1 -> inventory`, `stage2 -> detail`, and `stage3 -> relationship`;
- canonical forward-slash `relativePath` to the raw snapshot and `checkpointRelativePath` to its checkpoint;
- persisted `snapshotSchemaVersion` and `checkpointSchemaVersion`;
- validated `itemCount`;
- bounded provenance: `sourceType`, `sourceName`, `apiVersion`, and `isBeta`.

The descriptor does not copy `items`, `requestContext`, credentials, relationship rows, or other tenant payload. An offline consumer follows the relative path to the canonical raw snapshot when payload data is needed. Artifact descriptors are logically unique by `(runId, stage, section, family, batchId)` and must be emitted in ordinal stage/section/family/batchId order so regeneration from unchanged evidence is deterministic. A completed-run catalog contains at least one artifact descriptor; legitimate zero-item families are still represented by their successful empty snapshot artifact.

### Dependency descriptors

Dependencies are normalized separately from artifact rows. Each descriptor identifies a `consumer` and `provider` using stage/section/family/kind plus one of two v1 dependency types:

- `execution-input` — the consumer collection requires the provider family as collection input. Current examples are Stage2/Stage3 families driven from Stage1 inventory.
- `reference` — the consumer payload contains stable identity references to the provider domain/family for offline navigation, but provider evidence is not necessarily a runtime collection prerequisite.

Stage2 execution-input mapping follows existing collection ownership: ordinary detail families depend on same-named Stage1 inventory; `applicationCredentials` depends on Stage1 `applications`; `servicePrincipalCredentials` depends on Stage1 `servicePrincipals`. The four `entra-ca` Stage2 detail families, the four `entra-governance` Stage2 detail families, and Intune `deviceCompliancePolicies`/`assignmentFilters` each depend on the same-named Stage1 inventory family. Intune general `configurationPolicies` and `configurationPolicySettings` both depend on Stage1 `configurationPolicies`; classic Stage2 `deviceConfigurations` depends on Stage1 `deviceConfigurations`. #178 adds `securityConfigurationPolicies` and `securityConfigurationPolicySettings` → Stage1 securityConfigurationPolicies, securityConfigurationPolicyTemplates → same-named Stage1, securityBaselineTemplates → same-named Stage1, and securityBaselineIntents/securityBaselineIntentSettings → Stage1 securityBaselineIntents. `intune-enrollment` Stage2 `deviceEnrollmentConfigurations` and `windowsAutopilotDeploymentProfiles` depend on their same-named Stage1 inventories. On-prem Stage2 `gpoReports` depends on Stage1 `onprem-ad-gpo/gpos`, while existing Stage2 `gpos` remains the canonical same-family GPO metadata detail.

Reviewed current `reference` dependencies are:

| Consumer | Stage1 reference provider |
| --- | --- |
| stage2 / intune-core / securityConfigurationPolicies | intune-core / securityConfigurationPolicyTemplates |
| stage2 / intune-core / securityBaselineIntents | intune-core / securityBaselineTemplates |

Current Stage3 execution-input dependencies are:

| Stage3 family | Stage1 provider family |
| --- | --- |
| groupMembers | entra-apps / groups |
| servicePrincipalAppRoleAssignedTo | entra-apps / servicePrincipals |
| applicationFederatedIdentityCredentials | entra-apps / applications |
| delegatedGrants | entra-apps / servicePrincipals |
| pimScheduleEdges | entra-pim / roleAssignmentScheduleInstances and roleEligibilityScheduleInstances |
| conditionalAccessPolicyReferences | entra-ca / conditionalAccessPolicies |
| administrativeUnitMembers | entra-governance / administrativeUnits |
| administrativeUnitScopedRoleMembers | entra-governance / administrativeUnits |
| activeRoleAssignmentEdges | entra-governance / roleAssignments |
| mobileAppAssignments | intune-core / mobileApps |
| deviceManagementScriptAssignments | intune-core / deviceManagementScripts |
| deviceCompliancePolicyAssignments | intune-core / deviceCompliancePolicies |
| configurationPolicyAssignments | intune-core / configurationPolicies |
| deviceConfigurationAssignments | intune-core / deviceConfigurations |
| securityConfigurationPolicyAssignments | intune-core / securityConfigurationPolicies |
| securityBaselineIntentAssignments | intune-core / securityBaselineIntents |
| deviceEnrollmentConfigurationAssignments | intune-enrollment / deviceEnrollmentConfigurations |
| windowsAutopilotDeploymentProfileAssignments | intune-enrollment / windowsAutopilotDeploymentProfiles |
| domainRootAcl | onprem-ad-gpo / domains |
| ouAcl | onprem-ad-gpo / organizationalUnits |
| gpoPermissions | onprem-ad-gpo / gpos |
| groupMembersOnPrem | onprem-ad-gpo / groups |

No execution-input edge is added from `entra-pim` to `entra-governance`: PIM collection remains valid independently. Offline role-definition resolution is instead provided by stable `roleDefinitionId` plus the shared `entra.directory-role-definition` identity domain when governance evidence is present. Administrative-unit scoped-role resolution uses governance `directoryRoles` as the activated-role ID/role-template bridge and likewise does not change PIM execution requirements.

No execution-input edge is added from Intune assignment families to `assignmentFilters`. Filters are independent configuration evidence collected canonically by #176; assignment rows retain filter IDs/types as stable relationship references without making collection of the assignment itself depend on filter expansion. This also applies to opt-in Autopilot assignments: selecting `intune-enrollment` does not require `intune-core` execution merely because an assignment may carry a filter ID.

This dependency vocabulary is intentionally small. New domain-family work may add descriptors but must not require a second catalog mechanism.

### Relationship semantics and identity domains

Each Stage3 family has one catalog relationship descriptor with a stable `relationshipType` plus one or more source and target identity domains. Identity domains describe **what identifiers mean**, not a reconstructed tenant object schema. A family may list multiple domains where a relationship can legitimately target more than one identity class.

V1 identity-domain semantics for current relationship families are:

| Stage3 family | Relationship type | Source identity domain(s) | Target identity domain(s) |
| --- | --- | --- | --- |
| domainRootAcl | acl | `ad.domain` | `ad.security-principal` |
| ouAcl | acl | `ad.organizational-unit` | `ad.security-principal` |
| gpoPermissions | acl | `gpo.policy` | `ad.security-principal` |
| groupMembers | membership | `entra.group` | `entra.directory-object` |
| groupMembersOnPrem | membership | `ad.group` | `ad.directory-object` |
| mobileAppAssignments | assignment | `intune.mobile-app` | `intune.assignment-target` |
| deviceManagementScriptAssignments | assignment | `intune.device-management-script` | `intune.assignment-target` |
| deviceCompliancePolicyAssignments | assignment | `intune.device-compliance-policy` | `entra.group`, `entra.directory-object`, `intune.assignment-filter`, `intune.assignment-target` |
| configurationPolicyAssignments | assignment | `intune.configuration-policy` | `entra.group`, `entra.directory-object`, `intune.assignment-filter`, `intune.assignment-target` |
| deviceConfigurationAssignments | assignment | `intune.device-configuration` | `entra.group`, `entra.directory-object`, `intune.assignment-filter`, `intune.assignment-target` |
| securityConfigurationPolicyAssignments | assignment | `intune.security-configuration-policy` | `entra.group`, `entra.directory-object`, `intune.assignment-filter`, `intune.assignment-target` |
| securityBaselineIntentAssignments | assignment | `intune.security-baseline-intent` | `entra.group`, `entra.directory-object`, `intune.assignment-filter`, `intune.assignment-target` |
| deviceEnrollmentConfigurationAssignments | assignment | `intune.device-enrollment-configuration` | `entra.group`, `entra.directory-object`, `intune.assignment-target` |
| windowsAutopilotDeploymentProfileAssignments | assignment | `intune.windows-autopilot-deployment-profile` | `entra.group`, `entra.directory-object`, `intune.assignment-filter`, `intune.assignment-target` |
| servicePrincipalAppRoleAssignedTo | assignment | `entra.service-principal` | `entra.directory-object` |
| applicationFederatedIdentityCredentials | federated-trust | `entra.application` | `entra.federated-identity-credential` |
| delegatedGrants | grant | `entra.service-principal` | `entra.service-principal`, `entra.directory-object` |
| pimScheduleEdges | role-governance | `entra.pim-role-assignment-schedule-instance`, `entra.pim-role-eligibility-schedule-instance` | `entra.directory-object`, `entra.directory-role-definition`, `entra.directory-scope`, `entra.app-scope` |
| conditionalAccessPolicyReferences | policy-reference | `entra.conditional-access-policy` | `entra.user`, `entra.group`, `entra.directory-role-template`, `entra.application-app-id`, `entra.service-principal`, `entra.named-location`, `entra.authentication-context`, `entra.authentication-strength-policy`, `entra.terms-of-use`, `entra.custom-authentication-factor`, `entra.tenant`, `entra.conditional-access-template`, `entra.conditional-access-user-action`, `entra.conditional-access-selector` |
| administrativeUnitMembers | membership | `entra.administrative-unit` | `entra.directory-object` |
| administrativeUnitScopedRoleMembers | role-governance | `entra.administrative-unit` | `entra.directory-role`, `entra.user` |
| activeRoleAssignmentEdges | role-governance | `entra.role-assignment` | `entra.directory-object`, `entra.directory-role-definition`, `entra.tenant`, `entra.administrative-unit`, `entra.app-scope`, `entra.directory-scope` |

The catalog does not assert that every raw row contains a single field named `sourceId` or `targetId`; it declares the identity domains the family contract uses so the offline consumer can interpret family-specific raw rows without guessing cross-family meaning.

### Source compatibility and fail-closed generation/validation

A v1 catalog is bound to the canonical `manifest/run-manifest.json`. Its source-manifest descriptor records the manifest schema version, terminal status, completion timestamp, and invocation count. The catalog admits only manifest schema versions currently supported by the collector (`1.0` and `1.1`), checkpoint schema `1.0`, snapshot schema `1.0`, and catalog schema `1.0`.

Catalog freshness is bound to the canonical manifest's exact `status`, `completedUtc`, and invocation count. Top-level `runStatus` and `sourceManifest.status` must both equal the canonical manifest status. If a run is resumed after catalog generation and any of those source-manifest facts change, the existing catalog is stale and must be regenerated before it is treated as current offline evidence.

Catalog generation/validation must fail closed rather than rewrite, repair, or silently skip evidence when any required contract is violated, including:

- source manifest missing/unreadable, non-terminal, unsupported, runId-mismatched, or different from the catalog's recorded status/completion/invocation identity;
- referenced checkpoint or raw snapshot missing/unreadable;
- descriptor identity not matching run/stage/section/family/batch identity and canonical relative paths;
- checkpoint batch not representing a schema-valid persisted `Succeeded` batch for the descriptor;
- checkpoint/snapshot/actual item counts disagreeing under the existing stage cardinality rules;
- referenced snapshot/checkpoint schema version unsupported;
- duplicate logical artifact, dependency, or relationship descriptors;
- dependency endpoints naming evidence that the catalog cannot resolve where the dependency is required for package navigation.

`CompletedWithErrors` is terminal source-manifest evidence and may be represented, but it is not proof that all selected families were collected. Consumers and the package validator preserve that distinction rather than interpreting catalog existence as full-coverage success.

### Determinism, security, and product boundary

Catalog arrays use deterministic ordinal ordering and stable relative paths. No generation timestamp is required by v1 because a wall-clock value would create churn without improving source-evidence identity.

The catalog inherits existing credential/privacy boundaries and deliberately copies less provenance than a snapshot: no `requestContext`, Graph token, secret text, raw key material, payload row, or provider response body is permitted in artifact descriptors. Entra credential evidence remains allowlisted. GPO `gpoReports` sanitizes recognized credential-bearing Computer/User XML fields **before** snapshot persistence, while retaining ordinary policy-setting values; the catalog only points to those canonical sanitized snapshots and never copies their XML payload.

For v1, "offline queryable" means a consumer can discover available evidence, follow inventory/detail/relationship dependencies, understand relationship identity domains, and locate raw JSON without Graph/on-prem access. It does not mean database-backed query execution, embeddings/vector search, LLM prompting, UI, or tenant reconstruction/export/import. The intended package flow is:

`collect -> catalog -> validate -> consume`

The catalog contract is the stable seam between collection and later offline consumers; runtime generation and package validation are separate responsibilities so neither provider-specific code nor AI/query machinery leaks into raw collection.

## Retry and Throttle Model

- Graph requests use centralized retry logic.
- Transient retries include HTTP 429, 500, 502, 503, 504 and timeout-class failures.
- Retry-After is honored when present.
- Exponential backoff with jitter is applied within configured min/max bounds.
- Throttle delay is applied before Graph requests.
- Key-credential Stage2 reads have a 400 ms minimum pre-request throttle to stay at or below the documented 150 requests/minute tenant boundary.

## Failure Behavior

- On-prem command absence or runtime failures are recorded as failed batches in checkpoints and manifest entries.
- Graph collection failures, including missing permissions for explicitly selected `entra-ca`, `entra-governance`, or `intune-enrollment`, and Intune configuration/security reads under `intune-core`, are localized to section/family batches where possible and remain visible in checkpoints/manifest evidence.
- Failures are localized to section/family batches where possible and do not force a full process crash unless inventory-first gating or orchestration integrity fails.
- Historical failures remain visible in cumulative manifest state after a later successful resume invocation.

## Deferred Decisions

Remaining deferred decisions after the current implementation:

- Long-term retention and archival strategy for output snapshots.
- Optional future parallelism model beyond current sequential batch orchestration.
- Optional policy for explicit collector-side privacy transformations beyond the currently bounded credential-field redaction contracts.
