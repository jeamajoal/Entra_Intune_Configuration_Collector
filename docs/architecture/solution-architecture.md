# Solution Architecture

## Status

- Discovery completion date: 2026-09-04
- Discovery state: accepted by repository owner
- Readiness state: canonical live readiness and execution status is tracked in GitHub Issue #1

## Accepted High-Level Solution

Build a self-contained PowerShell automation that collects configuration metadata from Microsoft Entra ID, Microsoft Intune, and on-premises Active Directory with Group Policy, so downstream AI agents can answer environment questions from evidence.

The automation is explicitly non-waterfall:

1. Pull inventory first and save JSON text files.
2. Enrich metadata in later stages.
3. Recover or rerun individual sections or stages without restarting full collection.

ACLs, memberships, and assignments are explicitly classified as metadata.

## Architecture Boundaries

### In Scope

- Entra tenant and identity governance configuration metadata.
- Intune configuration metadata including applications, scripts, remediation scripts, compliance scripts, enrollment configurations, and policy families.
- Authorization metadata including membership relationships, role assignments, app role assignments, delegated grants, PIM active or eligible assignment schedules, and targeted ACL surfaces.
- On-prem AD DS and classic GPO collection for all domains in the forest.

### Out of Scope

- Mailbox, Teams, SharePoint, and other M365 workload content surfaces.
- Defender-specific telemetry domains.
- Audit and sign-in event streams.
- Explicit collector-side privacy filtering policy owned by the script.

### Operator Boundary

- The collector writes raw metadata as retrieved.
- Privacy and handling policy is operator-managed downstream.

## Execution Model

### Stage 1 Inventory

- Enumerate inventory object lists by source and section.
- Persist inventory snapshots in JSON text files.
- Write per-section stage checkpoint and run manifest.

### Stage 2 Metadata Object Detail

- Read Stage 1 inventory as the source of truth.
- Retrieve detailed metadata for each object type in batches.
- Persist per-object-type metadata snapshots.
- Resume from last successful batch using checkpoints.

### Stage 3 Metadata Relationships

- Build metadata edges for ACLs, memberships, and assignments.
- Persist relationship snapshots independently from object snapshots.
- Support selective rerun by relationship family.

### Stage 4 Recovery and Partial Operations

- Resume a failed run from stage or section checkpoints.
- Execute one section across all stages.
- Execute one stage across all sections.
- Reprocess only missing or failed batches.

## Canonical Data Shape

### Raw Snapshot Layer

- Source-native response payloads by collector and endpoint.
- One file per logical page or batch to simplify retry and evidence replay.

### Normalized Metadata Layer

- Entities: principals, groups, service principals, applications, policies, devices, domains, OUs, GPOs, and related objects.
- Metadata relationships: member-of, assigned-to, role-binding, app-grant, scope-binding, and ACL-right.
- Provenance attributes: collector id, endpoint or cmdlet, API version, run id, timestamp, and checkpoint id.

### Run Control Artifacts

- Run manifest with stage, section, counts, status, and failure details.
- Checkpoint ledger keyed by stage and section.

## Accepted Material Decisions

1. Primary cloud collector interface is Microsoft Graph.
2. On-prem AD and GPO are collected directly with Windows PowerShell AD or GPO capabilities where Graph is not authoritative.
3. Forest scope is all domains.
4. ACL depth target is GPO, OU, and domain root.
5. PIM active and eligible schedules are included.
6. Service principal app role assignments and delegated grants are included.
7. Enterprise apps and app registrations are included.
8. Intune applications, scripts, remediation scripts, compliance scripts, and enrollment configuration families are included.
9. Collector execution is staged and resumable, not waterfall.
10. ACLs, memberships, and assignments are metadata.

## Authoritative Product and API Evidence

The following first-party Microsoft documentation confirms capability coverage used by this architecture:

- Microsoft Graph service principals list:
  - https://learn.microsoft.com/en-us/graph/api/serviceprincipal-list?view=graph-rest-1.0
- Microsoft Graph oauth2PermissionGrants list:
  - https://learn.microsoft.com/en-us/graph/api/oauth2permissiongrant-list?view=graph-rest-1.0
- Microsoft Graph applications list:
  - https://learn.microsoft.com/en-us/graph/api/application-list?view=graph-rest-1.0
- Conditional Access policies list:
  - https://learn.microsoft.com/en-us/graph/api/conditionalaccessroot-list-policies?view=graph-rest-1.0
- Named locations list:
  - https://learn.microsoft.com/en-us/graph/api/conditionalaccessroot-list-namedlocations?view=graph-rest-1.0
- Authentication methods policy get:
  - https://learn.microsoft.com/en-us/graph/api/authenticationmethodspolicy-get?view=graph-rest-1.0
- Intune mobile apps list:
  - https://learn.microsoft.com/en-us/graph/api/intune-apps-mobileapp-list?view=graph-rest-1.0
- Intune device management scripts list:
  - https://learn.microsoft.com/en-us/graph/api/intune-devices-devicemanagementscript-list?view=graph-rest-beta
- Intune device health scripts list:
  - https://learn.microsoft.com/en-us/graph/api/intune-devices-devicehealthscript-list?view=graph-rest-beta
- Intune compliance policies list:
  - https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicy-list?view=graph-rest-1.0
- Intune device compliance scripts list:
  - https://learn.microsoft.com/en-us/graph/api/intune-devices-devicecompliancescript-list?view=graph-rest-beta
- Intune managed app policies list:
  - https://learn.microsoft.com/en-us/graph/api/intune-mam-managedapppolicy-list?view=graph-rest-beta
- Intune targeted managed app protections list:
  - https://learn.microsoft.com/en-us/graph/api/intune-mam-targetedmanagedappprotection-list?view=graph-rest-beta
- Intune enrollment configurations list:
  - https://learn.microsoft.com/en-us/graph/api/intune-onboarding-deviceenrollmentconfiguration-list?view=graph-rest-beta
- Intune Windows Autopilot device identities list:
  - https://learn.microsoft.com/en-us/graph/api/intune-enrollment-windowsautopilotdeviceidentity-list?view=graph-rest-beta
- Intune Azure AD Windows Autopilot deployment profiles list:
  - https://learn.microsoft.com/en-us/graph/api/intune-enrollment-azureadwindowsautopilotdeploymentprofile-list?view=graph-rest-beta
- Intune device management intents list:
  - https://learn.microsoft.com/en-us/graph/api/intune-deviceintent-devicemanagementintent-list?view=graph-rest-beta

## Security and Risk Rationale

- Primary risk addressed: incomplete or non-recoverable collection that produces weak or stale evidence for authorization reasoning.
- Primary mitigations selected:
  - staged execution,
  - checkpoint and resume,
  - section-scoped reruns,
  - separation of inventory and enrichment.
- Complexity deliberately accepted:
  - multi-stage orchestration and checkpoint artifacts,
  - beta endpoint support tagging for required Intune surfaces.
- Complexity deliberately avoided:
  - deep real-time streaming,
  - full event telemetry ingestion,
  - mandatory collector-side privacy transformation logic.

## Open, Deferred, and Non-Scope Tracking

### Open Decisions

- None required to start first development cycle.

### Deferred Decisions

- Final directory layout naming for raw versus normalized artifacts.
- Parallelism defaults and throttle budgets per endpoint family.
- Long-term retention and archival strategy for collected snapshots.

### Explicit Non-Scope

- Mailbox, Teams, SharePoint workload content and configuration.
- Defender telemetry domains.
- Audit or sign-in streams.

## First-Cycle Implementation Outcome Target

Deliver a PowerShell collector skeleton that:

1. Executes inventory and metadata stages independently.
2. Supports checkpoints and stage or section resume.
3. Persists JSON artifacts with manifest and per-stage status.
4. Covers representative vertical slices for Entra, Intune, and on-prem AD or GPO metadata collection.
