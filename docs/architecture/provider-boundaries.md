# Provider and Audience Boundaries

This document owns the durable authentication/resource boundary introduced by Issue #214. It complements the executable architecture in `solution-architecture.md`; it is governance metadata and does not make the permission matrix executable runtime configuration.

## Current providers

### `microsoft-graph`

- Provider kind: OAuth REST.
- Production provenance `sourceType`: `Graph`.
- OAuth resource/audience: `https://graph.microsoft.com/`.
- Allowed absolute-request origin: `https://graph.microsoft.com`.
- Runtime token input: the existing `GraphToken` collector parameter when any Graph-backed section is selected.
- Ownership: every currently implemented Entra and Intune Graph route in the permission matrix.

The existing Graph provider remains the runtime authority for origin enforcement. `Resolve-CollectorGraphUri` continues to reject insecure, cross-origin, alternate-port, and user-info-bearing absolute URIs before HTTP execution. The permission matrix does not replace that enforcement or introduce a universal HTTP/provider abstraction.

### `onprem-windows`

- Provider kind: local PowerShell/Windows execution.
- Production provenance `sourceType`: `OnPrem`.
- Authentication boundary: the current Windows/domain execution identity by default, or an explicitly supplied `ADCredential` used only for the `onprem-ad-gpo` stage invocation.
- Explicit-credential mode: Windows `LOGON32_LOGON_NEW_CREDENTIALS` / `LOGON32_PROVIDER_WINNT50` plus `WindowsIdentity.RunImpersonated`, which preserves the collector's local process/filesystem identity while using the alternate credential for outbound AD/GPO network authentication.
- OAuth resource/audience: none.
- Allowed HTTP origin: none.
- Ownership: every current AD/GPO cmdlet family.

An `onprem-ad-gpo`-only run therefore remains Graph-token independent. Supplying `ADCredential` does not grant permissions and does not change the Graph provider token/audience boundary. The live `PSCredential` remains in memory only; durable run metadata records only whether an alternate AD credential was supplied and never serializes the credential/password.

The credential context is deliberately applied around the complete on-prem stage invocation rather than passed individually to AD cmdlets. This is required because GroupPolicy cmdlets such as `Get-GPO` and `Get-GPOReport` do not expose a `-Credential` parameter. Scoping the impersonation to `onprem-ad-gpo` also keeps Graph/Intune HTTP outside the alternate Windows network credential context.

## Provider-aware route contract

Issue #201 established exact production Graph route conformance at:

`section | stage | family | endpoint-template`

Issue #214 extends that ownership contract by composing the same production extractor with the provider registry:

`provider | section | stage | family | endpoint-template`

`tests/unit/ProviderOwnershipConformance.Tests.ps1` reuses the #201 setup/extractor rather than maintaining a second production route table. Provider, audience, and origin mutations must fail even when section/stage/family/endpoint values are unchanged.

For on-prem collection, each matrix family also declares its provider explicitly and remains cross-checked against the existing cmdlet/provenance contract.

## Adding a future distinct provider

Do not add placeholder providers. A provider is introduced only in the same change that adds its first real consuming route.

A future distinct API such as Defender/MDE under #210 must declare, in the same implementation slice:

1. a stable provider ID;
2. provider kind and production provenance/source type;
3. OAuth resource/audience, when authenticated by OAuth;
4. allowed origin/base URI enforced by that provider;
5. the actual runtime token/input boundary consumed by the route;
6. provider ownership on every new family;
7. permission profiles scoped to that provider/resource rather than inferred from permission names; and
8. provider-aware conformance/mutation coverage.

A Microsoft Graph token or permission name must never be assumed valid for another API resource. Conversely, local/on-prem execution identity is not represented as an OAuth audience.

## Non-goals

This boundary does **not** introduce:

- a generic provider interface/factory;
- a universal HTTP transport wrapper;
- a Defender/MDE token parameter before a Defender/MDE route exists;
- empty provider/section/family placeholders;
- runtime loading of `permission-matrix.json`;
- credential, tenant ID, token, or secret material in governance files.
