# Graph authentication lifecycle architecture

## Owner

`Collector.SecurityContext.Graph.psm1` owns the in-memory authentication state for the `microsoft-graph` provider. `Collector.Provider.Graph.psm1` owns request-time token resolution and the one-time 401 refresh boundary. Stage modules do not acquire or refresh tokens.

## Inputs

`Start-CollectorRun` accepts two optional public inputs:

- `GraphToken` — static bearer token.
- `GraphTokenProvider` — scriptblock callback accepting one Boolean `ForceRefresh` argument and returning exactly one non-empty token string.

A Graph-backed section requires at least one input. On-prem-only execution requires neither.

## In-memory state

The orchestrator creates one `Collector.GraphAuthState` object per invocation. It contains only:

- `currentToken` — the current bearer, initially the supplied static token when present;
- `tokenProvider` — the supplied callback when present.

For compatibility with existing stage code, this state is stored in the runtime context's established `GraphToken` slot and passed opaquely to the Graph provider. Direct provider callers may continue passing a literal token string.

The state object is runtime-only and must never be placed in persisted invocation parameters, manifests, checkpoints, snapshots, or catalog output.

## Request algorithm

For every Graph request:

1. Validate the resolved URI against the existing `https://graph.microsoft.com/` origin boundary.
2. Resolve the current bearer from the authentication input.
3. Execute the request through the existing transient retry policy, which handles timeout/429/5xx only.
4. If the request terminates with HTTP 401 and a token provider exists, force-refresh exactly once.
5. Store the replacement bearer in the shared auth state and retry the Graph request once through the normal transient retry policy.
6. If that refreshed request also returns 401, fail immediately; do not refresh again for that request.

A later independent request may force-refresh once if the replacement token eventually expires later in the same long-running invocation.

## Failure boundaries

Authentication acquisition and authorization are deliberately distinct from transient transport/service retry behavior:

- 401 is observable to the Graph provider but is not in `Invoke-CollectorRetry`'s transient status list.
- Provider exceptions are replaced with a generic acquisition error so callback exception text is not copied into durable run evidence.
- Empty, multi-object, or non-string provider output is rejected before HTTP execution.
- A static-token-only 401 is not retried as an authentication refresh.

## Persistence contract

Persisted run parameters record only:

- `graphTokenSupplied`;
- `graphTokenProviderSupplied`.

No bearer, callback text/object, refresh token, client secret, private-key material, or live auth-state object may be serialized.

## Dependency policy

This seam intentionally introduces no Graph SDK, MSAL, Az, or Microsoft.Graph PowerShell module dependency. Token acquisition remains an injected operator/application concern so the collector stays compatible with both PowerShell 7 and Windows PowerShell 5.1 and does not own tenant-specific credential storage.
