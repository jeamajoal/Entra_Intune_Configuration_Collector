# Collector Permissions and Dependency Governance

This document explains how to use and maintain the collector's authorization/dependency contract.

The canonical machine-readable inventory is [`docs/permissions/permission-matrix.json`](permissions/permission-matrix.json). It records the exact Graph endpoint templates and on-prem external commands used by the current collector, the read-only permission profile for each Graph request, the reviewed Microsoft Learn source URLs, and the Windows module/provider dependencies for `onprem-ad-gpo`.

## Operating model

Application permissions are the recommended contract for unattended collection. The collector accepts a bearer token and does not inspect or grant permissions itself. Delegated tokens can also work where Microsoft supports delegated access, but the signed-in user can additionally need a supported Microsoft Entra role even when the OAuth scope is present.

The matrix is a governance artifact, not runtime configuration. Collector modules remain the source of executable behavior; conformance tests force the two surfaces to move together when endpoint or cmdlet contracts change.

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

These are the union of the family-level profiles, not a claim that every permission is required for every stage/family. Use the JSON matrix when building a narrower token for a subset of the collector.

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

`onprem-ad-gpo` does not require a Graph token. It requires Windows/domain connectivity plus these command surfaces:

- **ActiveDirectory (RSAT AD DS/LDS tools):** `Get-ADForest`, `Get-ADDomain`, `Get-ADOrganizationalUnit`, `Get-ADGroup`, `Get-ADGroupMember`, and the `ActiveDirectory` PowerShell provider.
- **GroupPolicy (RSAT Group Policy Management Tools):** `Get-GPO`, `Get-GPOReport`, `Get-GPPermission`, `Get-GPInheritance`.
- **Built-in PowerShell:** `Get-Acl`, `New-PSDrive`, `Remove-PSDrive`.

Run under an identity that can read the targeted forest/domain directory objects, GPO configuration, Group Policy permissions/inheritance, and AD provider ACLs. The collector does not require mutation rights.

## 403 and authorization failures

A `403 Forbidden` or equivalent authorization failure has two separate troubleshooting paths:

1. verify the token/identity actually has the matrix permission(s), admin consent, required delegated user role, tenant license, and target visibility needed for the failing endpoint; and
2. verify the repository matrix is still current for that endpoint.

Do not “fix” a 403 by adding broad `ReadWrite` permissions. If Microsoft changed an API permission contract, update the matrix, its Microsoft Learn source, the human guidance, and the conformance evidence in the same PR.

## Lifecycle gate

Any change that adds, removes, or changes a collector section, family, Microsoft Graph endpoint, API version, or on-prem external cmdlet/provider dependency must review and update the permission matrix in the same PR.

During grooming/implementation:

1. identify the exact GET endpoint/cmdlet actually added or changed;
2. verify the current Microsoft Learn permission contract (or Microsoft Windows module documentation for on-prem dependencies);
3. prefer a read-only application permission compatible with unattended collection;
4. record delegated permission/role caveats separately rather than treating delegated OAuth scope as the entire authorization contract;
5. update `lastReviewedUtc`, affected matrix request/family entries, and source URLs;
6. run dual-runtime aggregate validation.

`tests/unit/PermissionMatrixConformance.Tests.ps1` keeps the global Graph endpoint set, on-prem external-command set, section vocabulary, permission-profile, and durable-documentation guards aligned with the matrix. `tests/unit/GraphPermissionRouteConformance.Tests.ps1` independently derives production Graph `section | stage | family | endpoint-template` tuples from collector PowerShell AST and requires exact equality with the matrix, so family or stage drift cannot hide behind an unchanged global endpoint set.

## Review record

- Matrix schema: `1.0`
- Last permission review: `2026-09-15`
- Source baseline: `11da32287a836ea13edaa2b8499102a2900d49e0`
- Review sources: current Microsoft Learn Graph API/permission documentation linked directly from the JSON matrix.
