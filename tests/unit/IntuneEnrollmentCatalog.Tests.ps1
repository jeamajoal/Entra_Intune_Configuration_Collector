BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}

Describe 'Intune enrollment catalog semantics' {
    It 'accepts intune-enrollment as a catalog section' {
        InModuleScope 'Collector.Storage.Catalog' {
            { Assert-CollectorCatalogIdentityShape -Stage 'stage1' -Section 'intune-enrollment' -Family 'deviceEnrollmentConfigurations' } | Should -Not -Throw
        }
    }

    It 'maps enrollment detail and assignment execution inputs' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-enrollment'; family = 'deviceEnrollmentConfigurations' },
                [pscustomobject]@{ stage = 'stage1'; section = 'intune-enrollment'; family = 'windowsAutopilotDeploymentProfiles' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-enrollment'; family = 'deviceEnrollmentConfigurations' },
                [pscustomobject]@{ stage = 'stage2'; section = 'intune-enrollment'; family = 'windowsAutopilotDeploymentProfiles' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-enrollment'; family = 'deviceEnrollmentConfigurationAssignments' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-enrollment'; family = 'windowsAutopilotDeploymentProfileAssignments' }
            )

            $dependencies = @(Get-CollectorCatalogDependencySet -Artifacts $artifacts)
            $dependencies.Count | Should -Be 4
            @($dependencies | Where-Object { $_.dependencyType -eq 'execution-input' }).Count | Should -Be 4
            @($dependencies | Where-Object { $_.dependencyType -eq 'reference' }).Count | Should -Be 0

            foreach ($family in @('deviceEnrollmentConfigurations', 'deviceEnrollmentConfigurationAssignments')) {
                $dependency = @($dependencies | Where-Object { $_.consumer.family -eq $family })[0]
                $dependency.provider.section | Should -Be 'intune-enrollment'
                $dependency.provider.family | Should -Be 'deviceEnrollmentConfigurations'
            }
            foreach ($family in @('windowsAutopilotDeploymentProfiles', 'windowsAutopilotDeploymentProfileAssignments')) {
                $dependency = @($dependencies | Where-Object { $_.consumer.family -eq $family })[0]
                $dependency.provider.section | Should -Be 'intune-enrollment'
                $dependency.provider.family | Should -Be 'windowsAutopilotDeploymentProfiles'
            }
        }
    }

    It 'publishes distinct enrollment assignment identity domains' {
        InModuleScope 'Collector.Storage.Catalog' {
            $artifacts = @(
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-enrollment'; family = 'deviceEnrollmentConfigurationAssignments' },
                [pscustomobject]@{ stage = 'stage3'; section = 'intune-enrollment'; family = 'windowsAutopilotDeploymentProfileAssignments' }
            )

            $relationships = @(Get-CollectorCatalogRelationshipSet -Artifacts $artifacts)
            $enrollment = @($relationships | Where-Object { $_.family -eq 'deviceEnrollmentConfigurationAssignments' })[0]
            $autopilot = @($relationships | Where-Object { $_.family -eq 'windowsAutopilotDeploymentProfileAssignments' })[0]

            $enrollment.relationshipType | Should -Be 'assignment'
            @($enrollment.sourceIdentityDomains) | Should -Contain 'intune.device-enrollment-configuration'
            @($enrollment.targetIdentityDomains) | Should -Contain 'entra.group'
            @($enrollment.targetIdentityDomains) | Should -Contain 'entra.directory-object'
            @($enrollment.targetIdentityDomains) | Should -Contain 'intune.assignment-target'
            @($enrollment.targetIdentityDomains) | Should -Not -Contain 'intune.assignment-filter'

            $autopilot.relationshipType | Should -Be 'assignment'
            @($autopilot.sourceIdentityDomains) | Should -Contain 'intune.windows-autopilot-deployment-profile'
            @($autopilot.targetIdentityDomains) | Should -Contain 'entra.group'
            @($autopilot.targetIdentityDomains) | Should -Contain 'entra.directory-object'
            @($autopilot.targetIdentityDomains) | Should -Contain 'intune.assignment-filter'
            @($autopilot.targetIdentityDomains) | Should -Contain 'intune.assignment-target'
        }
    }
}
