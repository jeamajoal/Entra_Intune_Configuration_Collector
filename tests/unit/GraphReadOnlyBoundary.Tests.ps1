BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.Graph.psm1') -Force -ErrorAction Stop
}

Describe 'Graph provider read-only boundary' {
    It 'does not expose mutation or request-body parameters' {
        $command = Get-Command -Name Invoke-CollectorGraphRequest -ErrorAction Stop

        if ($command.Parameters.ContainsKey('Method')) {
            throw 'Invoke-CollectorGraphRequest must not expose a Method parameter.'
        }

        if ($command.Parameters.ContainsKey('Body')) {
            throw 'Invoke-CollectorGraphRequest must not expose a Body parameter.'
        }
    }

    It 'rejects mutation method arguments before any Graph request can run' {
        foreach ($method in @('POST', 'PATCH', 'PUT', 'DELETE')) {
            $threw = $false
            try {
                Invoke-CollectorGraphRequest -GraphToken 'test-token' -Endpoint '/v1.0/test' -Method $method -ThrottleMilliseconds 0 -MaxRetries 0
            }
            catch {
                $threw = $true
                if (-not ($_.Exception -is [System.Management.Automation.ParameterBindingException])) {
                    throw ('Expected ParameterBindingException for method {0}; actual {1}.' -f $method, $_.Exception.GetType().FullName)
                }
            }

            if (-not $threw) {
                throw ('Expected unsupported Graph mutation method {0} to be rejected.' -f $method)
            }
        }
    }

    It 'issues supported relative Graph requests as GET' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{ id = 'ok' }
        }

        $result = Invoke-CollectorGraphRequest -GraphToken 'test-token' -Endpoint '/v1.0/test' -ThrottleMilliseconds 0 -MaxRetries 0

        if ($result.id -ne 'ok') {
            throw ('Expected mocked Graph response id ok; actual ' + [string]$result.id + '.')
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/v1.0/test'
        }
    }

    It 'validates the final resolved URI for crafted relative endpoints' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            throw 'Invoke-RestMethod must not run for a rejected Graph URI.'
        }

        $threw = $false
        try {
            Invoke-CollectorGraphRequest -GraphToken 'test-token' -Endpoint '@example.invalid/path' -ThrottleMilliseconds 0 -MaxRetries 0
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Microsoft Graph HTTPS origin') {
                throw ('Expected crafted relative endpoint origin rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected crafted relative Graph endpoint to be rejected.'
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 0 -Exactly
    }

    It 'allows same-origin HTTPS absolute Graph requests as GET' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{ id = 'absolute-ok' }
        }

        $endpoint = 'https://graph.microsoft.com/v1.0/test?$top=1'
        $result = Invoke-CollectorGraphRequest -GraphToken 'test-token' -Endpoint $endpoint -AbsoluteUri -ThrottleMilliseconds 0 -MaxRetries 0

        if ($result.id -ne 'absolute-ok') {
            throw ('Expected mocked absolute Graph response id absolute-ok; actual ' + [string]$result.id + '.')
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/v1.0/test?$top=1'
        }
    }

    It 'rejects insecure or different-origin absolute Graph requests before HTTP execution' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            throw 'Invoke-RestMethod must not run for a rejected Graph URI.'
        }

        $rejectedEndpoints = @(
            'http://graph.microsoft.com/v1.0/test',
            'https://example.invalid/v1.0/test',
            'https://graph.microsoft.com:444/v1.0/test',
            'https://user@graph.microsoft.com/v1.0/test'
        )

        foreach ($endpoint in $rejectedEndpoints) {
            $threw = $false
            try {
                Invoke-CollectorGraphRequest -GraphToken 'test-token' -Endpoint $endpoint -AbsoluteUri -ThrottleMilliseconds 0 -MaxRetries 0
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'Microsoft Graph HTTPS origin') {
                    throw ('Expected Graph origin rejection for {0}; actual error: {1}' -f $endpoint, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected absolute Graph endpoint to be rejected: {0}' -f $endpoint)
            }
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 0 -Exactly
    }

    It 'does not follow a cross-origin pagination link with the bearer request seam' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            if ($Uri -eq 'https://graph.microsoft.com/v1.0/test') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'first' })
                    '@odata.nextLink' = 'https://example.invalid/next'
                }
            }

            throw ('Unexpected HTTP request URI: {0}' -f $Uri)
        }

        $threw = $false
        try {
            Invoke-CollectorGraphCollection -GraphToken 'test-token' -Endpoint '/v1.0/test' -ThrottleMilliseconds 0 -MaxRetries 0
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Microsoft Graph HTTPS origin') {
                throw ('Expected cross-origin pagination rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected a cross-origin @odata.nextLink to be rejected.'
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -eq 'https://graph.microsoft.com/v1.0/test'
        }
    }
}
