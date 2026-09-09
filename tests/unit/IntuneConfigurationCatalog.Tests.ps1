BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

Describe 'Intune configuration catalog semantics' {
    It 'maps Stage2 and Stage3 execution inputs to their Stage1 configuration inventories' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-core'; family = 'configurationPolicies' },
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-core'; family = 'deviceConfigurations' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'configurationPolicies' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'configurationPolicySettings' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'deviceConfigurations' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'configurationPolicyAssignments' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'deviceConfigurationAssignments' }
            )

            $dependencies = @(Get-CollectorCatalogDependencySet -Artifacts $artifacts)
            @($dependencies).Count | Should -Be 5

            foreach ($family in @('configurationPolicies', 'configurationPolicySettings', 'configurationPolicyAssignments')) {
                $dependency = @($dependencies | Where-Object { $_.consumer.family -eq $family })[0]
                $dependency.provider.family | Should -Be 'configurationPolicies'
                $dependency.dependencyType | Should -Be 'execution-input'
            }
            foreach ($family in @('deviceConfigurations', 'deviceConfigurationAssignments')) {
                $dependency = @($dependencies | Where-Object { $_.consumer.family -eq $family })[0]
                $dependency.provider.family | Should -Be 'deviceConfigurations'
                $dependency.dependencyType | Should -Be 'execution-input'
            }
        }
    }

    It 'publishes distinct modern and classic assignment source identity domains' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'configurationPolicyAssignments' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'deviceConfigurationAssignments' }
            )

            $relationships = @(Get-CollectorCatalogRelationshipSet -Artifacts $artifacts)
            $modern = @($relationships | Where-Object { $_.family -eq 'configurationPolicyAssignments' })[0]
            $classic = @($relationships | Where-Object { $_.family -eq 'deviceConfigurationAssignments' })[0]

            $modern.relationshipType | Should -Be 'assignment'
            @($modern.sourceIdentityDomains) | Should -Contain 'intune.configuration-policy'
            @($classic.sourceIdentityDomains) | Should -Contain 'intune.device-configuration'
            foreach ($relationship in @($modern, $classic)) {
                @($relationship.targetIdentityDomains) | Should -Contain 'entra.group'
                @($relationship.targetIdentityDomains) | Should -Contain 'entra.directory-object'
                @($relationship.targetIdentityDomains) | Should -Contain 'intune.assignment-filter'
                @($relationship.targetIdentityDomains) | Should -Contain 'intune.assignment-target'
            }
        }
    }
}
