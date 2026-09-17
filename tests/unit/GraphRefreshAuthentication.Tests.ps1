[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester mock scriptblocks receive production command parameters while individual scenarios inspect only the authentication fields they need.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.SecurityContext.Graph.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.Graph.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Refreshable Microsoft Graph authentication' {
    BeforeEach {
        $script:authorizationHeaders = [System.Collections.Generic.List[string]]::new()
    }

    It 'keeps static token requests backward compatible and does not retry a 401 without a refresh source' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            $script:authorizationHeaders.Add([string]$Headers.Authorization)
            throw [System.Exception]::new('Response status code does not indicate success: 401 (Unauthorized).')
        }

        $threw = $false
        try {
            Invoke-CollectorGraphRequest -GraphToken 'static-token' -Endpoint '/v1.0/test' -ThrottleMilliseconds 0 -MaxRetries 5 | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch '401') {
                throw ('Expected the original static-token 401 to surface; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected static-token request to fail on 401.'
        }
        if (($script:authorizationHeaders -join ',') -ne 'Bearer static-token') {
            throw ('Expected one static bearer attempt; actual headers: {0}' -f ($script:authorizationHeaders -join ','))
        }
        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 1 -Exactly
    }

    It 'lazily acquires a provider-only token once and reuses it across requests' {
        $providerState = [pscustomobject]@{ Calls = 0; Forced = 0 }
        $provider = {
            param([bool]$ForceRefresh)
            $providerState.Calls++
            if ($ForceRefresh) {
                $providerState.Forced++
            }
            'provider-token'
        }.GetNewClosure()
        $authState = New-CollectorGraphAuthState -GraphToken $null -GraphTokenProvider $provider

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            $script:authorizationHeaders.Add([string]$Headers.Authorization)
            [pscustomobject]@{ id = 'ok' }
        }

        Invoke-CollectorGraphRequest -GraphToken $authState -Endpoint '/v1.0/first' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null
        Invoke-CollectorGraphRequest -GraphToken $authState -Endpoint '/v1.0/second' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null

        if ($providerState.Calls -ne 1 -or $providerState.Forced -ne 0) {
            throw ('Expected one non-forced provider acquisition; calls={0}, forced={1}.' -f $providerState.Calls, $providerState.Forced)
        }
        if (($script:authorizationHeaders -join ',') -ne 'Bearer provider-token,Bearer provider-token') {
            throw ('Expected the provider token to be cached in memory; actual headers: {0}' -f ($script:authorizationHeaders -join ','))
        }
    }

    It 'force-refreshes exactly once after 401 and reuses the replacement token later' {
        $providerState = [pscustomobject]@{ Calls = 0; Forced = 0 }
        $provider = {
            param([bool]$ForceRefresh)
            $providerState.Calls++
            if (-not $ForceRefresh) {
                throw 'The static token should be used before a forced refresh is needed.'
            }
            $providerState.Forced++
            'replacement-token'
        }.GetNewClosure()
        $authState = New-CollectorGraphAuthState -GraphToken 'expired-token' -GraphTokenProvider $provider

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            $authorization = [string]$Headers.Authorization
            $script:authorizationHeaders.Add($authorization)
            if ($authorization -eq 'Bearer expired-token') {
                throw [System.Exception]::new('Response status code does not indicate success: 401 (Unauthorized).')
            }
            [pscustomobject]@{ id = 'ok' }
        }

        Invoke-CollectorGraphRequest -GraphToken $authState -Endpoint '/v1.0/first' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null
        Invoke-CollectorGraphRequest -GraphToken $authState -Endpoint '/v1.0/second' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null

        if ($providerState.Calls -ne 1 -or $providerState.Forced -ne 1) {
            throw ('Expected exactly one forced refresh; calls={0}, forced={1}.' -f $providerState.Calls, $providerState.Forced)
        }
        $expected = 'Bearer expired-token,Bearer replacement-token,Bearer replacement-token'
        if (($script:authorizationHeaders -join ',') -ne $expected) {
            throw ('Expected expired -> replacement -> cached replacement sequence; actual: {0}' -f ($script:authorizationHeaders -join ','))
        }
    }

    It 'bounds a persistent 401 to one forced refresh for the request' {
        $providerState = [pscustomobject]@{ Calls = 0; Forced = 0 }
        $provider = {
            param([bool]$ForceRefresh)
            $providerState.Calls++
            if ($ForceRefresh) {
                $providerState.Forced++
            }
            'replacement-token'
        }.GetNewClosure()
        $authState = New-CollectorGraphAuthState -GraphToken 'expired-token' -GraphTokenProvider $provider

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            $script:authorizationHeaders.Add([string]$Headers.Authorization)
            throw [System.Exception]::new('Response status code does not indicate success: 401 (Unauthorized).')
        }

        $threw = $false
        try {
            Invoke-CollectorGraphRequest -GraphToken $authState -Endpoint '/v1.0/test' -ThrottleMilliseconds 0 -MaxRetries 5 | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected persistent 401 to fail after the bounded refresh attempt.'
        }
        if ($providerState.Calls -ne 1 -or $providerState.Forced -ne 1) {
            throw ('Expected one forced refresh on persistent 401; calls={0}, forced={1}.' -f $providerState.Calls, $providerState.Forced)
        }
        if (($script:authorizationHeaders -join ',') -ne 'Bearer expired-token,Bearer replacement-token') {
            throw ('Expected exactly two HTTP attempts across the auth refresh boundary; actual: {0}' -f ($script:authorizationHeaders -join ','))
        }
        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 2 -Exactly
    }

    It 'fails clearly when the token provider throws without leaking the provider error text' {
        $secretSentinel = 'provider-secret-material-must-not-leak'
        $provider = {
            param([bool]$ForceRefresh)
            throw 'provider-secret-material-must-not-leak'
        }
        $authState = New-CollectorGraphAuthState -GraphToken $null -GraphTokenProvider $provider

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            throw 'HTTP must not execute when token acquisition fails.'
        }

        $threw = $false
        try {
            Invoke-CollectorGraphRequest -GraphToken $authState -Endpoint '/v1.0/test' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'GraphTokenProvider failed') {
                throw ('Expected bounded provider failure message; actual: {0}' -f $_.Exception.Message)
            }
            if ($_.Exception.Message -match [regex]::Escape($secretSentinel)) {
                throw 'Provider exception text leaked through the authentication boundary.'
            }
        }

        if (-not $threw) {
            throw 'Expected provider exception to fail token acquisition.'
        }
        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects empty provider output before HTTP execution' {
        $authState = New-CollectorGraphAuthState -GraphToken $null -GraphTokenProvider { param([bool]$ForceRefresh) '' }

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            throw 'HTTP must not execute for empty token-provider output.'
        }

        $threw = $false
        try {
            Invoke-CollectorGraphRequest -GraphToken $authState -Endpoint '/v1.0/test' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'exactly one non-empty token string') {
                throw ('Expected empty token-provider output rejection; actual: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected empty token-provider output to fail.'
        }
        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 0 -Exactly
    }
}

Describe 'Refreshable Graph authentication persistence boundary' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-graph-auth-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts provider-only Graph execution and persists only non-secret authentication facts' {
        $secretSentinel = 'manifest-secret-token-must-not-appear'
        $provider = {
            param([bool]$ForceRefresh)
            'manifest-secret-token-must-not-appear'
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            return @()
        }

        $result = Start-CollectorRun -GraphTokenProvider $provider -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps')
        $manifestRaw = Get-Content -LiteralPath $result.manifestPath -Raw
        $manifest = $manifestRaw | ConvertFrom-Json

        if ($manifest.parameters.graphTokenSupplied -ne $false) {
            throw 'Expected provider-only run to persist graphTokenSupplied=false.'
        }
        if ($manifest.parameters.graphTokenProviderSupplied -ne $true) {
            throw 'Expected provider-only run to persist graphTokenProviderSupplied=true.'
        }
        if ($manifestRaw -match [regex]::Escape($secretSentinel)) {
            throw 'Run manifest persisted Graph token/provider secret material.'
        }
        if ($result.status -ne 'Completed') {
            throw ('Expected provider-only mocked run to complete; actual: {0}' -f $result.status)
        }
    }
}
