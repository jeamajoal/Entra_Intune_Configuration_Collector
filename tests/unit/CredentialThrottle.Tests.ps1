[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester module-scope mocks intentionally share fixture state through globals that are created and removed by this test file.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.Graph.psm1') -Force -ErrorAction Stop
}

Describe 'Credential request throttle enforcement' {
    BeforeEach {
        $global:CollectorCredentialThrottleSleeps = New-Object 'System.Collections.Generic.List[int]'
        $global:CollectorCredentialThrottleAttempts = 0

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Start-Sleep -MockWith {
            $global:CollectorCredentialThrottleSleeps.Add([int]$Milliseconds) | Out-Null
        }

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            $global:CollectorCredentialThrottleAttempts++
            if ($global:CollectorCredentialThrottleAttempts -eq 1) {
                throw [System.TimeoutException]::new('transient timeout')
            }

            [pscustomobject]@{ id = 'provider-retry-success' }
        }
    }

    AfterEach {
        Remove-Variable -Name CollectorCredentialThrottleSleeps -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name CollectorCredentialThrottleAttempts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'applies the 400 millisecond floor before both the initial request and a retry' {
        Invoke-CollectorGraphRequest -GraphToken 'test-token' -Endpoint '/v1.0/applications/object-1?$select=id,keyCredentials,passwordCredentials' -MaxRetries 1 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 400 | Out-Null

        if ([int]$global:CollectorCredentialThrottleAttempts -ne 2) {
            throw ('Expected two HTTP attempts; actual ' + $global:CollectorCredentialThrottleAttempts + '.')
        }
        if ($global:CollectorCredentialThrottleSleeps.Count -ne 2) {
            throw ('Expected one throttle sleep per HTTP attempt; actual ' + $global:CollectorCredentialThrottleSleeps.Count + '.')
        }
        foreach ($sleep in $global:CollectorCredentialThrottleSleeps) {
            if ([int]$sleep -ne 400) {
                throw ('Expected every retry attempt to use 400 ms throttle; actual ' + $sleep + '.')
            }
        }
    }
}
