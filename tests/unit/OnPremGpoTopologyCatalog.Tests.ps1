BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop
}

Describe 'GPO topology offline catalog contracts' {
    It 'emits execution-input dependencies and relationship identity domains for each topology family' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage1'; section = 'onprem-ad-gpo'; family = 'gpos' },
                [pscustomobject]@{ stage = 'stage1'; section = 'onprem-ad-gpo'; family = 'domains' },
                [pscustomobject]@{ stage = 'stage1'; section = 'onprem-ad-gpo'; family = 'organizationalUnits' },
                [pscustomobject]@{ stage = 'stage3'; section = 'onprem-ad-gpo'; family = 'gpoScopeLinks' },
                [pscustomobject]@{ stage = 'stage3'; section = 'onprem-ad-gpo'; family = 'gpoScopeInheritance' },
                [pscustomobject]@{ stage = 'stage3'; section = 'onprem-ad-gpo'; family = 'gpoWmiFilterAssociations' }
            )

            $dependencies = @(Get-CollectorCatalogDependencySet -Artifacts $artifacts)
            $dependencies.Count | Should -Be 4

            $linksDependency = @($dependencies | Where-Object { $_.consumer.family -eq 'gpoScopeLinks' })
            $linksDependency.Count | Should -Be 1
            $linksDependency[0].dependencyType | Should -Be 'execution-input'
            $linksDependency[0].provider.family | Should -Be 'gpos'

            $inheritanceDependencies = @($dependencies | Where-Object { $_.consumer.family -eq 'gpoScopeInheritance' })
            $inheritanceDependencies.Count | Should -Be 2
            @($inheritanceDependencies.provider.family) | Should -Contain 'domains'
            @($inheritanceDependencies.provider.family) | Should -Contain 'organizationalUnits'

            $wmiDependency = @($dependencies | Where-Object { $_.consumer.family -eq 'gpoWmiFilterAssociations' })
            $wmiDependency.Count | Should -Be 1
            $wmiDependency[0].provider.family | Should -Be 'gpos'

            $relationships = @(Get-CollectorCatalogRelationshipSet -Artifacts $artifacts)
            $relationships.Count | Should -Be 3

            $links = @($relationships | Where-Object { $_.family -eq 'gpoScopeLinks' })[0]
            $links.relationshipType | Should -Be 'policy-link'
            @($links.sourceIdentityDomains) | Should -Contain 'gpo.policy'
            @($links.targetIdentityDomains) | Should -Contain 'ad.scope'

            $inheritance = @($relationships | Where-Object { $_.family -eq 'gpoScopeInheritance' })[0]
            $inheritance.relationshipType | Should -Be 'policy-inheritance'
            @($inheritance.sourceIdentityDomains) | Should -Contain 'ad.scope'
            @($inheritance.targetIdentityDomains) | Should -Contain 'gpo.policy'

            $wmi = @($relationships | Where-Object { $_.family -eq 'gpoWmiFilterAssociations' })[0]
            $wmi.relationshipType | Should -Be 'policy-filter'
            @($wmi.sourceIdentityDomains) | Should -Contain 'gpo.policy'
            @($wmi.targetIdentityDomains) | Should -Contain 'gpo.wmi-filter'
        }
    }
}
