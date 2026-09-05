[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The global captures calls made by a global command shim before the provider module is imported; it is test-only and removed during teardown.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

    function global:Get-GPPermission {
        [CmdletBinding()]
        param(
            [Guid]$Guid,
            [string]$Name,
            [switch]$All,
            [string]$DomainName
        )

        $global:CollectorGpoPermissionCalls.Add([pscustomobject]@{
            Guid = $Guid
            Name = $Name
            All = [bool]$All
            DomainName = $DomainName
        }) | Out-Null
        [pscustomobject]@{ Trustee = 'TEST\Trustee'; Permission = 'GpoRead' }
    }

    function Test-CollectorResultHasError {
        param([object]$Result)

        return $null -ne $Result -and
            $Result.PSObject.Properties.Match('_collectorError').Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$Result._collectorError)
    }

    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.OnPrem.psm1') -Force -ErrorAction Stop
}

Describe 'On-prem GPO permission identity' {
    BeforeEach {
        $global:CollectorGpoPermissionCalls = [System.Collections.Generic.List[object]]::new()
    }

    AfterAll {
        Remove-Item Function:\Get-GPPermission -ErrorAction SilentlyContinue
        Remove-Variable CollectorGpoPermissionCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'queries permissions by persisted GUID and domain rather than display name' {
        $gpoId = [Guid]'11111111-2222-3333-4444-555555555555'
        $result = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoPermissions' -InventoryItems @(
            [pscustomobject]@{
                id = [string]$gpoId
                displayName = 'Original Display Name'
                domainId = 'alpha.test'
            }
        ))

        if ($result.Count -ne 1 -or (Test-CollectorResultHasError -Result $result[0])) {
            throw 'Expected one successful GPO permission result.'
        }
        if ($global:CollectorGpoPermissionCalls.Count -ne 1) {
            throw 'Expected one Get-GPPermission call.'
        }

        $call = $global:CollectorGpoPermissionCalls[0]
        if ($call.Guid -ne $gpoId -or $call.DomainName -ne 'alpha.test' -or -not $call.All) {
            throw 'Expected Get-GPPermission -Guid with persisted domain context and -All.'
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$call.Name)) {
            throw 'Expected no display-name lookup parameter.'
        }
        if ($result[0].gpo -ne 'Original Display Name' -or $result[0].gpoId -ne [string]$gpoId) {
            throw 'Expected displayName to remain descriptive while GUID remains identity.'
        }
    }

    It 'keeps lookup identity stable when displayName changes' {
        $gpoId = [Guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $first = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoPermissions' -InventoryItems @(
            [pscustomobject]@{ id = [string]$gpoId; displayName = 'Before Rename'; domainId = 'alpha.test' }
        ))
        $second = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoPermissions' -InventoryItems @(
            [pscustomobject]@{ id = [string]$gpoId; displayName = 'After Rename'; domainId = 'alpha.test' }
        ))

        $firstHasError = Test-CollectorResultHasError -Result $first[0]
        $secondHasError = Test-CollectorResultHasError -Result $second[0]
        if ($firstHasError -or $secondHasError -or $global:CollectorGpoPermissionCalls.Count -ne 2) {
            throw 'Expected both renamed GPO permission lookups to succeed.'
        }
        if ($global:CollectorGpoPermissionCalls[0].Guid -ne $gpoId -or $global:CollectorGpoPermissionCalls[1].Guid -ne $gpoId) {
            throw 'Expected both display names to resolve the same persisted GUID identity.'
        }
        if ($global:CollectorGpoPermissionCalls[0].Name -or $global:CollectorGpoPermissionCalls[1].Name) {
            throw 'Expected rename stability without name-based lookup.'
        }
    }

    It 'returns a clear per-item error for missing or invalid persisted GUIDs' {
        $results = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoPermissions' -InventoryItems @(
            [pscustomobject]@{ displayName = 'Missing Id'; domainId = 'alpha.test' },
            [pscustomobject]@{ id = 'not-a-guid'; displayName = 'Invalid Id'; domainId = 'beta.test' }
        ))

        if ($results.Count -ne 2) {
            throw ('Expected two attributable GPO identity errors; actual ' + $results.Count + '.')
        }
        foreach ($result in $results) {
            if ([string]$result._collectorError -notmatch 'valid persisted GPO GUID') {
                throw ('Expected clear persisted-GUID error; actual ' + [string]$result._collectorError + '.')
            }
        }
        if ($global:CollectorGpoPermissionCalls.Count -ne 0) {
            throw 'Expected invalid/missing GUIDs to fail before Get-GPPermission is called.'
        }
    }
}
