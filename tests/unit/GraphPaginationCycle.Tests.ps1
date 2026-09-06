BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.Graph.psm1') -Force -ErrorAction Stop
}

Describe 'Graph pagination cycle detection' {
    It 'rejects a self-referential same-origin nextLink before a duplicate HTTP request' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                value = @([pscustomobject]@{ id = 'first' })
                '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/test'
            }
        }

        $threw = $false
        try {
            Invoke-CollectorGraphCollection -GraphToken 'test-token' -Endpoint '/v1.0/test' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'pagination cycle' -or $_.Exception.Message -notmatch 'https://graph.microsoft.com/v1.0/test') {
                throw ('Expected explicit self-link pagination-cycle rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected self-referential Graph pagination to fail.'
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 1 -Exactly
    }

    It 'rejects a two-page A to B to A cycle before requesting A twice' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            if ($Uri -eq 'https://graph.microsoft.com/v1.0/a') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'a' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/b'
                }
            }

            if ($Uri -eq 'https://graph.microsoft.com/v1.0/b') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'b' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/a'
                }
            }

            throw ('Unexpected HTTP request URI: {0}' -f $Uri)
        }

        $threw = $false
        try {
            Invoke-CollectorGraphCollection -GraphToken 'test-token' -Endpoint '/v1.0/a' -ThrottleMilliseconds 0 -MaxRetries 0 | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'pagination cycle' -or $_.Exception.Message -notmatch 'https://graph.microsoft.com/v1.0/a') {
                throw ('Expected two-page pagination-cycle rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected A -> B -> A Graph pagination cycle to fail.'
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 2 -Exactly
        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/a'
        }
        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://graph.microsoft.com/v1.0/b'
        }
    }

    It 'preserves an ordinary finite two-page collection' {
        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            if ($Uri -eq 'https://graph.microsoft.com/v1.0/a') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'a' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/b'
                }
            }

            if ($Uri -eq 'https://graph.microsoft.com/v1.0/b') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'b' })
                }
            }

            throw ('Unexpected HTTP request URI: {0}' -f $Uri)
        }

        $result = @(Invoke-CollectorGraphCollection -GraphToken 'test-token' -Endpoint '/v1.0/a' -ThrottleMilliseconds 0 -MaxRetries 0)

        if ($result.Count -ne 2 -or [string]$result[0].id -ne 'a' -or [string]$result[1].id -ne 'b') {
            throw ('Expected finite pagination to return a,b exactly once; actual: {0}.' -f ((@($result | ForEach-Object { [string]$_.id })) -join ','))
        }

        Assert-MockCalled -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -Times 2 -Exactly
    }
}
