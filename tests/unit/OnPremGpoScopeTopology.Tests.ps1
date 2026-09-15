[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global command shims and captures are test-only so GroupPolicy/ActiveDirectory modules are not required in CI.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

    function global:Get-GPOReport {
        [CmdletBinding()]
        param(
            [Guid]$Guid,
            [string]$Domain,
            [ValidateSet('Xml', 'Html')]
            [string]$ReportType
        )
        $global:CollectorTopologyReportCalls.Add([pscustomobject]@{ Guid = $Guid; Domain = $Domain; ReportType = $ReportType }) | Out-Null
        return $global:CollectorTopologyReportXml
    }

    function global:Get-ADDomain {
        [CmdletBinding()]
        param([string]$Identity, [string]$Server)
        $global:CollectorTopologyDomainCalls.Add([pscustomobject]@{ Identity = $Identity; Server = $Server }) | Out-Null
        return [pscustomobject]@{ DistinguishedName = 'DC=example,DC=com' }
    }

    function global:Get-GPInheritance {
        [CmdletBinding()]
        param([string]$Target, [string]$Domain)
        $global:CollectorTopologyInheritanceCalls.Add([pscustomobject]@{ Target = $Target; Domain = $Domain }) | Out-Null
        return [pscustomobject]@{
            GpoInheritanceBlocked = 'Yes'
            GpoLinks = @(
                [pscustomobject]@{ GpoId = [Guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; DisplayName = 'Direct'; GpoDomainName = 'example.com'; Enabled = 'Yes'; Enforced = 'No'; Target = $Target; Order = 2 }
            )
            InheritedGpoLinks = @(
                [pscustomobject]@{ GpoId = [Guid]'11111111-2222-3333-4444-555555555555'; DisplayName = 'Enforced parent'; GpoDomainName = 'example.com'; Enabled = $true; Enforced = $true; Target = 'DC=example,DC=com'; Order = 1 },
                [pscustomobject]@{ GpoId = [Guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; DisplayName = 'Direct'; GpoDomainName = 'example.com'; Enabled = $true; Enforced = $false; Target = $Target; Order = 2 }
            )
        }
    }

    function global:Get-GPO {
        [CmdletBinding()]
        param([Guid]$Guid, [string]$Domain)
        $global:CollectorTopologyGpoCalls.Add([pscustomobject]@{ Guid = $Guid; Domain = $Domain }) | Out-Null
        if ($global:CollectorTopologyReturnWmiFilter) {
            return [pscustomobject]@{
                WmiFilter = [pscustomobject]@{
                    Path = 'MSFT_SomFilter.ID="{99999999-8888-7777-6666-555555555555}",Domain="example.com"'
                    Name = 'Windows 11 only'
                    Description = 'Test WMI filter'
                }
            }
        }
        return [pscustomobject]@{ WmiFilter = $null }
    }

    function global:Get-GPPermission {
        [CmdletBinding()]
        param([Guid]$Guid, [switch]$All, [string]$DomainName)
        if ($Guid -eq [Guid]::Empty -or -not $All -or [string]::IsNullOrWhiteSpace($DomainName)) {
            throw 'Expected GPO permission collection to use GUID, -All, and persisted domain context.'
        }
        return @(
            [pscustomobject]@{ Trustee = [pscustomobject]@{ Name = 'Domain Computers' }; PermissionLevel = 'GpoApply' },
            [pscustomobject]@{ Trustee = [pscustomobject]@{ Name = 'Policy Admins' }; PermissionLevel = 'GpoEdit' }
        )
    }

    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.OnPrem.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
}

Describe 'GPO scope topology provider evidence' {
    BeforeEach {
        $global:CollectorTopologyReportCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorTopologyDomainCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorTopologyInheritanceCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorTopologyGpoCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorTopologyReturnWmiFilter = $true
        $global:CollectorTopologyReportXml = @"
<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings">
  <LinksTo><SOMName>example.com</SOMName><SOMPath>example.com</SOMPath><Enabled>true</Enabled><NoOverride>false</NoOverride></LinksTo>
  <LinksTo><SOMName>Workstations</SOMName><SOMPath>example.com/Workstations</SOMPath><Enabled>false</Enabled><NoOverride>true</NoOverride></LinksTo>
  <Computer><ExtensionData /></Computer>
</GPO>
"@
    }

    AfterAll {
        foreach ($name in @('Get-GPOReport', 'Get-ADDomain', 'Get-GPInheritance', 'Get-GPO', 'Get-GPPermission')) {
            Remove-Item -LiteralPath ('Function:\{0}' -f $name) -ErrorAction SilentlyContinue
        }
        foreach ($name in @('CollectorTopologyReportCalls', 'CollectorTopologyDomainCalls', 'CollectorTopologyInheritanceCalls', 'CollectorTopologyGpoCalls', 'CollectorTopologyReturnWmiFilter', 'CollectorTopologyReportXml')) {
            Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'captures direct GPO scope links by persisted GUID/domain and preserves explicit zero-link state' {
        $gpoId = [Guid]'22222222-3333-4444-5555-666666666666'
        $item = [pscustomobject]@{ id = [string]$gpoId; displayName = 'Workstation Policy'; domainId = 'example.com' }
        $result = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoScopeLinks' -InventoryItems @($item))[0]

        $global:CollectorTopologyReportCalls.Count | Should -Be 1
        $global:CollectorTopologyReportCalls[0].Guid | Should -Be $gpoId
        $global:CollectorTopologyReportCalls[0].Domain | Should -Be 'example.com'
        $global:CollectorTopologyReportCalls[0].ReportType | Should -Be 'Xml'
        $result.gpoId | Should -Be ([string]$gpoId)
        $result.domainContext | Should -Be 'example.com'
        $result.linkCount | Should -Be 2
        $result.links[0].targetId | Should -Be 'example.com'
        $result.links[0].enabled | Should -BeTrue
        $result.links[0].enforced | Should -BeFalse
        $result.links[1].targetId | Should -Be 'example.com/Workstations'
        $result.links[1].enabled | Should -BeFalse
        $result.links[1].enforced | Should -BeTrue

        $global:CollectorTopologyReportXml = '<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings"><Computer /></GPO>'
        $empty = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoScopeLinks' -InventoryItems @($item))[0]
        $empty.linkCount | Should -Be 0
        @($empty.links).Count | Should -Be 0
        $empty.PSObject.Properties.Match('_collectorError').Count | Should -Be 0
    }

    It 'captures domain and OU inheritance with ordered direct/effective links and block state' {
        $domainEnvelope = [pscustomobject]@{
            dependencyFamily = 'domains'
            inventoryItem = [pscustomobject]@{ id = 'example.com'; name = 'example.com'; domainId = 'example.com' }
        }
        $ouEnvelope = [pscustomobject]@{
            dependencyFamily = 'organizationalUnits'
            inventoryItem = [pscustomobject]@{ id = 'OU=Workstations,DC=example,DC=com'; distinguishedName = 'OU=Workstations,DC=example,DC=com'; domainId = 'example.com' }
        }

        $results = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoScopeInheritance' -InventoryItems @($domainEnvelope, $ouEnvelope))
        $results.Count | Should -Be 2
        $global:CollectorTopologyDomainCalls.Count | Should -Be 1
        $global:CollectorTopologyDomainCalls[0].Identity | Should -Be 'example.com'
        $global:CollectorTopologyDomainCalls[0].Server | Should -Be 'example.com'
        $global:CollectorTopologyInheritanceCalls.Count | Should -Be 2
        $global:CollectorTopologyInheritanceCalls[0].Target | Should -Be 'DC=example,DC=com'
        $global:CollectorTopologyInheritanceCalls[1].Target | Should -Be 'OU=Workstations,DC=example,DC=com'

        foreach ($result in $results) {
            $result.inheritanceBlocked | Should -BeTrue
            $result.directLinkCount | Should -Be 1
            $result.directLinks[0].gpoId | Should -Be 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $result.directLinks[0].order | Should -Be 2
            $result.effectiveLinkCount | Should -Be 2
            $result.effectiveLinks[0].gpoId | Should -Be '11111111-2222-3333-4444-555555555555'
            $result.effectiveLinks[0].enforced | Should -BeTrue
            $result.effectiveLinks[1].gpoId | Should -Be 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        }
        $results[0].scopeType | Should -Be 'domain'
        $results[1].scopeType | Should -Be 'organizationalUnit'
    }

    It 'preserves provider-native WMI filter identity and explicit absence' {
        $gpoId = [Guid]'22222222-3333-4444-5555-666666666666'
        $item = [pscustomobject]@{ id = [string]$gpoId; displayName = 'Workstation Policy'; domainId = 'example.com' }

        $withFilter = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoWmiFilterAssociations' -InventoryItems @($item))[0]
        $withFilter.hasWmiFilter | Should -BeTrue
        $withFilter.wmiFilter.path | Should -Match '^MSFT_SomFilter\.ID='
        $withFilter.wmiFilter.name | Should -Be 'Windows 11 only'
        $global:CollectorTopologyGpoCalls[0].Guid | Should -Be $gpoId
        $global:CollectorTopologyGpoCalls[0].Domain | Should -Be 'example.com'

        $global:CollectorTopologyReturnWmiFilter = $false
        $withoutFilter = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoWmiFilterAssociations' -InventoryItems @($item))[0]
        $withoutFilter.hasWmiFilter | Should -BeFalse
        $withoutFilter.wmiFilter | Should -BeNullOrEmpty
    }

    It 'keeps GpoApply security-filter evidence inside canonical gpoPermissions' {
        $gpoId = [Guid]'22222222-3333-4444-5555-666666666666'
        $item = [pscustomobject]@{ id = [string]$gpoId; displayName = 'Workstation Policy'; domainId = 'example.com' }
        $result = @(Invoke-CollectorOnPremRelationshipFamily -Family 'gpoPermissions' -InventoryItems @($item))[0]

        @($result.permissions).Count | Should -Be 2
        @($result.permissions | Where-Object { $_.PermissionLevel -eq 'GpoApply' }).Count | Should -Be 1
        @($result.permissions | Where-Object { $_.PermissionLevel -eq 'GpoEdit' }).Count | Should -Be 1
    }
}

Describe 'GPO scope topology Stage3 integration' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-gpo-topology-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = @{
            RunPath = $script:testRoot
            RunId = 'gpo-topology-stage3'
            GraphToken = $null
            BatchSize = 100
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $false
            ReprocessFailedOnly = $false
        }

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorOnPremInventoryFamily -MockWith {
            param($Family)
            switch ($Family) {
                'domains' { @([pscustomobject]@{ id = 'example.com'; name = 'example.com'; domainId = 'example.com' }) }
                'organizationalUnits' { @([pscustomobject]@{ id = 'OU=Workstations,DC=example,DC=com'; distinguishedName = 'OU=Workstations,DC=example,DC=com'; domainId = 'example.com' }) }
                'groups' { @([pscustomobject]@{ id = 'CN=Group,DC=example,DC=com'; distinguishedName = 'CN=Group,DC=example,DC=com'; domainId = 'example.com' }) }
                'gpos' { @([pscustomobject]@{ id = '22222222-3333-4444-5555-666666666666'; displayName = 'Policy'; domainId = 'example.com' }) }
            }
        }
        Invoke-CollectorStage1 -Context $script:context -Sections @('onprem-ad-gpo') | Out-Null

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorOnPremRelationshipFamily -MockWith {
            param($Family, $InventoryItems)
            @([pscustomobject]@{ family = $Family; inputCount = @($InventoryItems).Count })
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) { Remove-Item -LiteralPath $script:testRoot -Recurse -Force }
    }

    It 'persists the three additive families with truthful Stage1 dependency provenance and resumes them independently' {
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('onprem-ad-gpo'))
        foreach ($family in @('gpoScopeLinks', 'gpoScopeInheritance', 'gpoWmiFilterAssociations')) {
            $row = @($results | Where-Object { $_.family -eq $family })
            $row.Count | Should -Be 1
            $row[0].succeededBatches | Should -Be 1
            $row[0].failedBatches | Should -Be 0
        }

        $linksSnapshot = Get-Content -LiteralPath (Join-Path $script:testRoot 'stage3/onprem-ad-gpo/gpoScopeLinks/batch-0001.json') -Raw | ConvertFrom-Json
        $linksSnapshot.requestContext.dependencyFamily | Should -Be 'gpos'
        @($linksSnapshot.requestContext.dependencyFamilies) | Should -Contain 'gpos'
        @($linksSnapshot.requestContext.cmdletNames) | Should -Contain 'Get-GPOReport'

        $inheritanceSnapshot = Get-Content -LiteralPath (Join-Path $script:testRoot 'stage3/onprem-ad-gpo/gpoScopeInheritance/batch-0001.json') -Raw | ConvertFrom-Json
        @($inheritanceSnapshot.requestContext.dependencyFamilies).Count | Should -Be 2
        @($inheritanceSnapshot.requestContext.dependencyFamilies) | Should -Contain 'domains'
        @($inheritanceSnapshot.requestContext.dependencyFamilies) | Should -Contain 'organizationalUnits'
        @($inheritanceSnapshot.requestContext.cmdletNames) | Should -Contain 'Get-GPInheritance'

        $script:context.Resume = $true
        $resume = @(Invoke-CollectorStage3 -Context $script:context -Sections @('onprem-ad-gpo'))
        foreach ($family in @('gpoScopeLinks', 'gpoScopeInheritance', 'gpoWmiFilterAssociations')) {
            $row = @($resume | Where-Object { $_.family -eq $family })
            $row[0].succeededBatches | Should -Be 0
            $row[0].skippedBatches | Should -Be 1
            $row[0].failedBatches | Should -Be 0
        }
    }
}
