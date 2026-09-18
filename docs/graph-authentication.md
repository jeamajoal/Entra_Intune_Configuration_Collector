# Microsoft Graph authentication lifecycle

The collector supports two Microsoft Graph authentication inputs:

- `GraphToken`: an existing bearer token string. This remains backward compatible for short runs and direct provider calls.
- `GraphTokenProvider`: an optional scriptblock that can obtain a current bearer token during a long-running collection.

Graph authentication belongs only to the `microsoft-graph` provider and the `https://graph.microsoft.com/` resource boundary. The refreshable-token feature does not permit bearer forwarding to another origin and does not change the read-only Graph request boundary.

## Why a refreshable provider exists

Microsoft Entra access tokens are intentionally short lived. A collector run can legitimately take longer than one token lifetime, especially when Stage2 performs one detail request per Stage1 inventory object. Supplying one immutable token for the whole run can therefore produce late-run `401 Unauthorized` failures even though the same permissions and token worked earlier in the run.

`GraphTokenProvider` gives the collector a narrow renewal seam without introducing Microsoft Graph SDK, MSAL, client-secret, or certificate dependencies into the collector itself.

## Callback contract

Pass a scriptblock that accepts one positional Boolean argument:

```powershell
param([bool]$ForceRefresh)
```

The callback must return exactly one non-empty bearer token string on the success output stream.

- `$ForceRefresh -eq $false`: obtain the current usable Microsoft Graph token. A provider-only run uses this for its first Graph request.
- `$ForceRefresh -eq $true`: bypass provider-owned token caching and obtain a replacement token after Microsoft Graph returned HTTP 401.

The collector keeps only the returned bearer token and callback reference in an in-memory authentication state object. That state is never written to the run manifest, checkpoints, snapshots, or catalog.

## Runtime behavior

When only `GraphToken` is supplied, behavior remains unchanged: the static token is used for every request and a 401 fails without authentication retry.

When only `GraphTokenProvider` is supplied, the first Graph request invokes the callback with `$false`. The returned token is cached in memory and reused until a request returns 401.

When both inputs are supplied, `GraphToken` is the initial bearer. `GraphTokenProvider` is not called unless a request returns 401.

For a request that returns 401 and has a refresh provider available:

1. The collector invokes the provider once with `$true`.
2. The replacement token becomes the in-memory current bearer.
3. The same Graph request is attempted once with the replacement token.
4. A second 401 marks Graph authentication terminal for the invocation and terminates the request. The collector does not enter a refresh loop.

Timeouts, HTTP 429, and HTTP 5xx continue to use the existing bounded transient retry policy. HTTP 401 is deliberately outside that generic retry set.

A replacement token is shared by later Stage1, Stage2, and Stage3 requests in the same invocation, so the collector does not replay a bearer already known to be expired for every inventory object.

If authentication becomes terminal (provider acquisition/refresh failure, static-token 401 with no refresh source, or a second 401 after refresh), the in-memory auth state clears the current bearer and records only a sanitized terminal condition. Later Graph calls in that invocation fail before HTTP or token-provider execution. Per-object Stage2/Stage3 fan-out batches stop on the first terminal-authentication error, preserve already collected successes, record that failed object once, and represent the remaining source objects with compact `_collectorNotAttemptedReason = 'terminal-authentication'` placeholders. The failed batch remains eligible for deterministic failed-only reprocessing after authentication is repaired.

## Unattended usage pattern

The token provider owns the mechanism used to acquire a token. For example, an existing certificate-based app-only helper can be wrapped without exposing the certificate or token to collector persistence:

```powershell
$graphTokenProvider = {
    param([bool]$ForceRefresh)

    # Call the organization's existing app-only token helper here.
    # The helper may use $ForceRefresh to bypass its own cache.
    Get-OrganizationGraphAccessToken -ForceRefresh:$ForceRefresh
}

./collector/Invoke-Collector.ps1 `
    -GraphTokenProvider $graphTokenProvider `
    -OutputRoot ./output
```

If an initial token has already been acquired, it may be supplied together with the provider:

```powershell
./collector/Invoke-Collector.ps1 `
    -GraphToken $GraphToken `
    -GraphTokenProvider $graphTokenProvider `
    -OutputRoot ./output
```

The provider should write diagnostics to an appropriate non-success stream rather than emitting additional success objects because its success output must contain exactly one token string.

## Persistence and secret boundary

Run metadata records only these booleans:

- `graphTokenSupplied`
- `graphTokenProviderSupplied`

The collector does not serialize:

- the initial bearer token;
- a refreshed bearer token;
- the provider scriptblock;
- client secrets or refresh tokens;
- certificate private-key material;
- the live Graph authentication-state object.

Provider exceptions are surfaced through a bounded generic token-acquisition error so provider exception text is not copied into collector failure evidence.

## Failure behavior

The following conditions terminate Graph authentication rather than silently retrying forever:

- no static token and no provider for a selected Graph-backed section;
- provider failure;
- provider output that is empty, non-string, or contains more than one success object;
- a second 401 after the single forced refresh attempt;
- a forced refresh request when no refresh provider exists.

These authentication failures are distinct from retryable timeout, 429, and 5xx conditions. Once one occurs on the shared runtime auth state, the invocation does not keep calling Microsoft Graph or the token provider with authentication already proven unusable.
