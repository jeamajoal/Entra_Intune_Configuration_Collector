# Collector Permissions and Dependency Governance

This document explains how to use and maintain the collector's authorization/dependency contract.

The canonical machine-readable inventory is [`docs/permissions/permission-matrix.json`](permissions/permission-matrix.json). It records the exact provider owner for every current family, Microsoft Graph endpoint templates and on-prem external commands, the read-only permission profile for each Graph request, the OAuth resource/audience for authenticated permission profiles, reviewed Microsoft Learn source URLs, and the Windows module/provider dependencies for `onprem-ad-gpo`.

## Operating model

Application permissions are the recommended contract for unattended collection. The collector accepts either an existing Microsoft Graph bearer through `-GraphToken`, a renewable callback through `-GraphTokenProvider`, or both; it does not inspect or grant permissions itself. For long-running unattended collection, prefer `GraphTokenProvider` so an expired bearer can be replaced during the same run. The callback contract, one-refresh-per-request 401 behavior, and secret boundary are documented in [`docs/graph-authentication.md`](graph-authentication.md). Delegated tokens can also work where Microsoft supports delegated access, but the signed-in user can additionally need a supported Microsoft Entra role even when the OAuth scope is present.

The matrix is a governance artifact, not runtime configuration. Collector modules remain the source of executable behavior; conformance tests force the two surfaces to move together when endpoint, cmdlet, provider, audience, or origin contracts change.

## Provider, resource, and permission model

A permission name is not enough to identify an authorization boundary. The matrix therefore models three separate concepts:

- **provider ID** — stable ownership of a route/cmdlet family;
- **resource/audience** — the OAuth resource for which an authenticated permission is valid; and
- **permission name** — the application/delegated permission granted on that resource.

Current real providers are intentionally limited to:

| Provider ID | Ownership | Authentication/resource contract |
| --- | --- | --- |
| `microsoft-graph` | Every current Graph-backed Entra/Intune route | OAuth bearer for `https://graph.microsoft.com/`, supplied as a static `GraphToken`, a renewable `GraphTokenProvider`, or both; absolute HTTP requests remain restricted by the Graph provider to origin `https://graph.microsoft.com/`. |
| `onprem-windows` | Every current AD/GPO cmdlet family | Current Windows/domain execution identity by default, or an optional explicit `ADCredential` applied as a Windows net-only impersonation context for the on-prem stage; no OAuth resource/audience and no Graph token. |

The provider registry is governance metadata only. It does not route requests at runtime and does not introduce a generic HTTP/provider abstraction.

A future distinct provider must be added only with its first real consuming route. For example, when a Defender/MDE route is implemented under #210, that same change must declare a distinct provider ID, its OAuth resource/audience, its allowed origin, the runtime token/input boundary actually consumed by that route, and the family/permission mapping. Do not pre-create an empty Defender provider or infer that a Microsoft Graph permission/token is valid for another API merely because permission names or data domains look related.

Origin enforcement remains provider-owned. `Resolve-CollectorGraphUri` remains the Microsoft Graph same-origin authority; this governance model does not replace it with a universal transport layer.

## Section-level application permission sets

| Section | Read-only application permissions used by current families |
| --- | --- |
| `entra-apps` | `Application.Read.All`, `Group.Read.All`, `Directory.Read.All` |
| `entra-pim` | `RoleAssignmentSchedule.Read.Directory`, `RoleEligibilitySchedule.Read.Directory` |
| `entra-ca` | `Policy.Read.All`, `Policy.Read.AuthenticationMethod`, `AuthenticationContext.Read.All` |
| `entra-governance` | `AdministrativeUnit.Read.All`, `RoleManagement.Read.Directory` |
| `intune-core` | `DeviceManagementApps.Read.All`, `DeviceManagementConfiguration.Read.All`, `DeviceManagementScripts.Read.All` |
| `intune-enrollment` | `DeviceManagementServiceConfig.Read.All` |
| `onprem-ad-gpo` | No Graph token required; see the Windows/on-prem prerequisites below. |

These are the union of the family-level profiles, not a claim that every permission is required for every stage/family. Use the JSON matrix when building a narrower token for a subset of the collector. All current authenticated profiles belong to `microsoft-graph` and explicitly declare `https://graph.microsoft.com/` as their resource audience.

`Directory.Read.All` is used for the current heterogeneous group-member/delegated-grant evidence. Microsoft documents `GroupMember.ReadBasic.All` for group-member IDs/basic access, but inaccessible member resource types can otherwise be returned with limited/null properties. The collector preserves raw relationship evidence, and `/oauth2PermissionGrants` independently requires `Directory.Read.All`, so the full `entra-apps` Stage1-3 contract already needs it.

Microsoft currently documents a write-flavored nesting permission as the nominal least permission for `GET /groups`; the collector does **not** require a write scope just to read groups. The matrix deliberately chooses the documented read-only `Group.Read.All` alternative.

For administrative-unit hidden membership, `Member.Read.Hidden` is an optional supplement. It is not part of the default required set because ordinary membership collection does not require it.

## Intune requirements

Microsoft Graph Intune APIs require an appropriately licensed Intune tenant. Current permission boundaries are intentionally split:

- app inventory/detail/assignment metadata uses `DeviceManagementApps.Read.All`;
- device-management script inventory/detail uses the dedicated `DeviceManagementScripts.Read.All`;
- script assignment reads, compliance, assignment filters, configuration policies/settings, classic configurations, endpoint-security/baseline configuration, and their assignment reads use `DeviceManagementConfiguration.Read.All`;
- enrollment and Windows Autopilot deployment-profile configuration uses `DeviceManagementServiceConfig.Read.All`.

This distinction matters because granting the configuration permission alone is no longer the durable contract for reading Intune script payloads.

## Delegated access

The matrix lists delegated permissions separately. A delegated scope is not always sufficient by itself:

- PIM schedule reads require the signed-in user to hold a supported Entra role for delegated operation.
- Conditional Access and authentication-context/authentication-strength reads have supported-role requirements for delegated access.
- Administrative-unit and role-management reads can also require supported Entra roles/custom role permissions.
- Intune permission scopes require administrator access and the tenant licensing noted above.

For repeatable unattended collection, prefer application permissions with admin consent and grant only the sections/families being collected.

## On-premises prerequisites

`onprem-ad-gpo` belongs to provider `onprem-windows` and does not require a Graph token or OAuth audience. It requires Windows/domain connectivity plus these command surfaces:

- **ActiveDirectory (RSAT AD DS/LDS tools):** `Get-ADForest`, `Get-ADDomain`, `Get-ADOrganizationalUnit`, `Get-ADGroup`, `Get-ADGroupMember`, and the `ActiveDirectory` PowerShell provider.
- **GroupPolicy (RSAT Group Policy Management Tools):** `Get-GPO`, `Get-GPOReport`, `Get-GPPermission`, `Get-GPInheritance`.
- **Built-in PowerShell:** `Get-Acl`, `New-PSDrive`, `Remove-PSDrive`.

By default, run under an identity that can read the targeted forest/domain directory objects, GPO configuration, Group Policy permissions/inheritance, and AD provider ACLs. The collector does not require mutation rights.

When the collector process identity should remain unchanged but AD/GPO reads need a different domain account, pass a `PSCredential` through `-ADCredential`. The collector applies that credential only around `onprem-ad-gpo` using Windows `LOGON32_LOGON_NEW_CREDENTIALS` / `LOGON32_PROVIDER_WINNT50` semantics (equivalent to a net-only logon for outbound network authentication). This is intentionally section-wide because GroupPolicy cmdlets do not expose a consistent `-Credential` parameter.

Example:

```powershell
$adCredential = Get-Credential -Message 'Credential used only for onprem-ad-gpo reads'

./collector/Invoke-Collector.ps1 `
    -GraphToken $GraphToken `
    -ADCredential $adCredential `
    -OutputRoot ./output
```

The live `PSCredential` is not written to manifests, checkpoints, snapshots, or logs. Durable invocation metadata records only `adCredentialSupplied = true|false`. The credential is not applied to Microsoft Graph/Intune provider calls. Supplying `ADCredential` on a non-Windows runtime fails closed because Windows impersonation is required.

## 401 and authentication renewal

A `401 Unauthorized` during a long Graph-backed run can mean the previously valid bearer expired. Static-token-only runs remain fail-closed because the collector has no authority to mint a replacement token. When `GraphTokenProvider` is supplied, the Graph provider force-refreshes exactly once for that request, retries once with the replacement bearer, and keeps the replacement only in the in-memory authentication state for later requests. A second 401 or provider failure terminates the request; 401 is not added to the generic transient retry policy.

The collector never persists the provider callback or any initial/refreshed bearer. Durable run metadata records only whether `GraphToken` and `GraphTokenProvider` were supplied. See [`docs/graph-authentication.md`](graph-authentication.md) for the callback contract and unattended usage pattern.

## 403 and authorization failures

A `403 Forbidden` or equivalent authorization failure has two separate troubleshooting paths:

1. verify that the token/identity is for the correct provider/resource and actually has the matrix permission(s), admin consent, required delegated user role, tenant license, and target visibility needed for the failing endpoint; and
2. verify the repository matrix is still current for that provider, route, and permission profile.

Do not “fix” a 403 by adding broad `ReadWrite` permissions. If Microsoft changed an API permission/resource contract, update the provider/audience metadata, affected matrix family/profile, Microsoft Learn source, human guidance, and conformance evidence in the same PR.

## Lifecycle gate

Any change that adds, removes, or changes a collector section, family, provider, Microsoft Graph endpoint, API version, resource/audience, allowed origin, or on-prem external cmdlet/provider dependency must review and update the permission matrix in the same PR.

During grooming/implementation:

1. identify the real provider and exact GET endpoint/cmdlet actually added or changed;
2. for authenticated providers, identify the OAuth resource/audience and provider-owned allowed origin before choosing permission names;
3. verify the current Microsoft Learn permission contract (or Microsoft Windows module documentation for on-prem dependencies);
4. prefer a read-only application permission compatible with unattended collection;
5. record delegated permission/role caveats separately rather than treating delegated OAuth scope as the entire authorization contract;
6. update `lastReviewedUtc`, affected provider/profile/family entries, and source URLs;
7. run dual-runtime aggregate validation.

`tests/unit/PermissionMatrixConformance.Tests.ps1` keeps the global Graph endpoint set, on-prem external-command set, section vocabulary, permission-profile, and durable-documentation guards aligned with the matrix. `tests/unit/GraphPermissionRouteConformance.Tests.ps1` independently derives production Graph `section | stage | family | endpoint-template` tuples from concrete Graph helper call sites and custom local routing declarations in collector PowerShell AST. Recognized Graph route shapes fail closed when their routing values cannot be resolved, and the resulting tuple set must exactly equal the matrix so family or stage drift cannot hide behind an unchanged global endpoint set.

`tests/unit/ProviderOwnershipConformance.Tests.ps1` composes directly with that #201 extractor: it reuses the exact production route tuples and adds the provider dimension, comparing `provider | section | stage | family | endpoint-template` against matrix ownership. It separately verifies provider IDs, resource/audience agreement, Graph origin ownership, local execution-identity ownership, and mutation cases for provider/audience/origin drift. No second hand-maintained production route table is introduced.

## Review record

- Matrix schema: `1.1`
- Last permission/provider review: `2026-09-16`
- Source baseline: `6d54f7ad72c4a21cee3e18d98d68d12fe8063d6f`
- Review sources: current Microsoft Learn Graph API/permission documentation linked directly from the JSON matrix.
