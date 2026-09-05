$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.Graph.psm1') -Force -ErrorAction Stop

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

    It 'issues supported Graph requests as GET' {
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
}
