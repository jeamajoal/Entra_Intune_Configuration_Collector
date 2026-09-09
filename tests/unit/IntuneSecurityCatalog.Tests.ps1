BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

Describe 'Intune security catalog semantics' {
    It 'maps modern and legacy security execution inputs and template references' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-core'; family = 'securityConfigurationPolicies' },
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-core'; family = 'securityConfigurationPolicyTemplates' },
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-core'; family = 'securityBaselineTemplates' },
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-core'; family = 'securityBaselineIntents' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'securityConfigurationPolicies' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'securityConfigurationPolicySettings' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'securityConfigurationPolicyTemplates' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'securityBaselineTemplates' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'securityBaselineIntents' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'securityBaselineIntentSettings' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'securityConfigurationPolicyAssignments' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'securityBaselineIntentAssignments' }
            )

            $dependencies = @(Get-CollectorCatalogDependencySet -Artifacts $artifacts)
            @($dependencies | Where-Object { $_.dependencyType -eq 'execution-input' }).Count | Should -Be 8
            @($dependencies | Where-Object { $_.dependencyType -eq 'reference' }).Count | Should -Be 2

            $modernReference = @($dependencies | Where-Object {
                $_.dependencyType -eq 'reference' -and
                $_.consumer.family -eq 'securityConfigurationPolicies'
            })[0]
            $modernReference.provider.family | Should -Be 'securityConfigurationPolicyTemplates'

            $legacyReference = @($dependencies | Where-Object {
                $_.dependencyType -eq 'reference' -and
                $_.consumer.family -eq 'securityBaselineIntents'
            })[0]
            $legacyReference.provider.family | Should -Be 'securityBaselineTemplates'

            foreach ($family in @('securityConfigurationPolicySettings', 'securityConfigurationPolicyAssignments')) {
                $dependency = @($dependencies | Where-Object { $_.dependencyType -eq 'execution-input' -and $_.consumer.family -eq $family })[0]
                $dependency.provider.family | Should -Be 'securityConfigurationPolicies'
            }
            foreach ($family in @('securityBaselineIntentSettings', 'securityBaselineIntentAssignments')) {
                $dependency = @($dependencies | Where-Object { $_.dependencyType -eq 'execution-input' -and $_.consumer.family -eq $family })[0]
                $dependency.provider.family | Should -Be 'securityBaselineIntents'
            }
        }
    }

    It 'publishes distinct modern and legacy security assignment identity domains' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'securityConfigurationPolicyAssignments' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-core'; family = 'securityBaselineIntentAssignments' }
            )

            $relationships = @(Get-CollectorCatalogRelationshipSet -Artifacts $artifacts)
            $modern = @($relationships | Where-Object { $_.family -eq 'securityConfigurationPolicyAssignments' })[0]
            $legacy = @($relationships | Where-Object { $_.family -eq 'securityBaselineIntentAssignments' })[0]

            $modern.relationshipType | Should -Be 'assignment'
            @($modern.sourceIdentityDomains) | Should -Contain 'intune.security-configuration-policy'
            @($legacy.sourceIdentityDomains) | Should -Contain 'intune.security-baseline-intent'
            foreach ($relationship in @($modern, $legacy)) {
                @($relationship.targetIdentityDomains) | Should -Contain 'entra.group'
                @($relationship.targetIdentityDomains) | Should -Contain 'entra.directory-object'
                @($relationship.targetIdentityDomains) | Should -Contain 'intune.assignment-filter'
                @($relationship.targetIdentityDomains) | Should -Contain 'intune.assignment-target'
            }
        }
    }

    It 'fails closed when a required template reference provider is absent' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-core'; family = 'securityConfigurationPolicies' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-core'; family = 'securityConfigurationPolicies' }
            )

            { Get-CollectorCatalogDependencySet -Artifacts $artifacts } | Should -Throw '*reference provider*securityConfigurationPolicyTemplates*'
        }
    }
}
