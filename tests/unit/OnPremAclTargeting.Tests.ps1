$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

function global:Get-ADDomain {
    [CmdletBinding()]
    param(
        [string]$Identity,
        [string]$Server
    )

    $global:CollectorAdDomainCalls.Add([pscustomobject]@{ Identity = $Identity; Server = $Server }) | Out-Null
    [pscustomobject]@{ DistinguishedName = ('DC={0},DC=test' -f $Identity.Split('.')[0]) }
}

function global:New-PSDrive {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$PSProvider,
        [string]$Root,
        [string]$Server,
        [string]$Scope
    )

    $global:CollectorNewDriveCalls.Add([pscustomobject]@{
        Name = $Name
        PSProvider = $PSProvider
        Root = $Root
        Server = $Server
        Scope = $Scope
    }) | Out-Null
    [pscustomobject]@{ Name = $Name }
}

function global:Get-Acl {
    [CmdletBinding()]
    param(
        [string]$LiteralPath,
        [string]$Path
    )

    $global:CollectorAclCalls.Add([pscustomobject]@{ LiteralPath = $LiteralPath; Path = $Path }) | Out-Null
    if ($global:CollectorAclShouldThrow) {
        throw 'simulated ACL read failure'
    }
    [pscustomobject]@{ Owner = 'TEST\Owner'; Access = @() }
}

function global:Remove-PSDrive {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Scope,
        [switch]$Force
    )

    $global:CollectorRemoveDriveCalls.Add([pscustomobject]@{ Name = $Name; Scope = $Scope }) | Out-Null
}

function Test-CollectorResultHasError {
    param([object]$Result)

    return $null -ne $Result -and
        $Result.PSObject.Properties.Match('_collectorError').Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$Result._collectorError)
}

Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.OnPrem.psm1') -Force -ErrorAction Stop

Describe 'On-prem ACL domain targeting' {
    BeforeEach {
        $global:CollectorAdDomainCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorNewDriveCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorAclCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorRemoveDriveCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorAclShouldThrow = $false
    }

    AfterAll {
        Remove-Item Function:\Get-ADDomain -ErrorAction SilentlyContinue
        Remove-Item Function:\New-PSDrive -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-Acl -ErrorAction SilentlyContinue
        Remove-Item Function:\Remove-PSDrive -ErrorAction SilentlyContinue
        Remove-Variable CollectorAdDomainCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CollectorNewDriveCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CollectorAclCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CollectorRemoveDriveCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CollectorAclShouldThrow -Scope Global -ErrorAction SilentlyContinue
    }

    It 'targets a domain-root ACL read to the persisted domain context' {
        $result = @(Invoke-CollectorOnPremRelationshipFamily -Family 'domainRootAcl' -InventoryItems @(
            [pscustomobject]@{ id = 'alpha.test'; domainId = 'alpha.test' }
        ))

        if ($result.Count -ne 1 -or (Test-CollectorResultHasError -Result $result[0])) {
            throw 'Expected one successful domain-root ACL result.'
        }
        if ($global:CollectorAdDomainCalls.Count -ne 1 -or $global:CollectorAdDomainCalls[0].Server -ne 'alpha.test') {
            throw 'Expected Get-ADDomain to use persisted alpha.test server context.'
        }
        if ($global:CollectorNewDriveCalls.Count -ne 1 -or $global:CollectorNewDriveCalls[0].Server -ne 'alpha.test') {
            throw 'Expected temporary AD drive to target alpha.test.'
        }
        if ($global:CollectorAclCalls.Count -ne 1 -or [string]::IsNullOrWhiteSpace($global:CollectorAclCalls[0].LiteralPath) -or $global:CollectorAclCalls[0].Path) {
            throw 'Expected domain-root ACL to use LiteralPath and never Path.'
        }
        if ([string]$result[0].path -ne 'AD:\DC=alpha,DC=test' -or [string]$result[0].path -match 'CollectorAD') {
            throw ('Expected stable persisted domain-root path AD:\DC=alpha,DC=test; actual ' + [string]$result[0].path + '.')
        }
        if ($global:CollectorRemoveDriveCalls.Count -ne 1 -or $global:CollectorRemoveDriveCalls[0].Name -ne $global:CollectorNewDriveCalls[0].Name) {
            throw 'Expected temporary AD drive to be removed after successful ACL read.'
        }
    }

    It 'uses separate domain targets and literal DNs for multiple forest domains' {
        $items = @(
            [pscustomobject]@{ id = 'OU=Ops[1],DC=alpha,DC=test'; domainId = 'alpha.test' },
            [pscustomobject]@{ id = 'OU=Ops*,DC=beta,DC=test'; domainId = 'beta.test' }
        )

        $results = @(Invoke-CollectorOnPremRelationshipFamily -Family 'ouAcl' -InventoryItems $items)
        $errorResults = @($results | Where-Object { Test-CollectorResultHasError -Result $_ })
        if ($results.Count -ne 2 -or $errorResults.Count -ne 0) {
            throw 'Expected two successful OU ACL results.'
        }

        $servers = @($global:CollectorNewDriveCalls | ForEach-Object { $_.Server }) -join ','
        if ($servers -ne 'alpha.test,beta.test') {
            throw ('Expected independent alpha/beta AD drive targets; actual ' + $servers + '.')
        }

        $literalPaths = @($global:CollectorAclCalls | ForEach-Object { [string]$_.LiteralPath })
        if (-not $literalPaths[0].EndsWith('OU=Ops[1],DC=alpha,DC=test') -or -not $literalPaths[1].EndsWith('OU=Ops*,DC=beta,DC=test')) {
            throw 'Expected persisted special-character DNs to be passed through LiteralPath unchanged.'
        }
        if (@($global:CollectorAclCalls | Where-Object { $_.Path }).Count -ne 0) {
            throw 'Expected no wildcard-aware Path binding for OU ACL reads.'
        }

        $persistedPaths = @($results | ForEach-Object { [string]$_.path })
        if ($persistedPaths[0] -ne 'AD:\OU=Ops[1],DC=alpha,DC=test' -or $persistedPaths[1] -ne 'AD:\OU=Ops*,DC=beta,DC=test') {
            throw ('Expected stable AD:\<DN> output paths; actual ' + ($persistedPaths -join ', ') + '.')
        }
        if (@($persistedPaths | Where-Object { $_ -match 'CollectorAD' }).Count -ne 0) {
            throw 'Expected temporary randomized drive names to remain internal and never be persisted.'
        }
        if ($global:CollectorRemoveDriveCalls.Count -ne 2) {
            throw 'Expected each temporary AD drive to be removed.'
        }
    }

    It 'removes the temporary AD drive when ACL retrieval fails' {
        $global:CollectorAclShouldThrow = $true
        $result = @(Invoke-CollectorOnPremRelationshipFamily -Family 'ouAcl' -InventoryItems @(
            [pscustomobject]@{ id = 'OU=Fail,DC=alpha,DC=test'; domainId = 'alpha.test' }
        ))

        if ($result.Count -ne 1 -or -not (Test-CollectorResultHasError -Result $result[0])) {
            throw 'Expected ACL failure to remain attributable on the item.'
        }
        if ($global:CollectorNewDriveCalls.Count -ne 1 -or $global:CollectorRemoveDriveCalls.Count -ne 1) {
            throw 'Expected failed ACL read to clean up its temporary AD drive.'
        }
        if ($global:CollectorRemoveDriveCalls[0].Name -ne $global:CollectorNewDriveCalls[0].Name) {
            throw 'Expected cleanup to remove the same temporary drive that was created.'
        }
    }
}