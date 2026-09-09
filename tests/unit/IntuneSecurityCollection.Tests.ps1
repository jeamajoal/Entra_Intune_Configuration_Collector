BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Intune endpoint security and baseline collection' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-intune-security-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/deviceAppManagement/mobileApps' { return @() }
                '/beta/deviceManagement/deviceManagementScripts' { return @() }
                '/v1.0/deviceManagement/deviceCompliancePolicies' { return @() }
                '/beta/deviceManagement/assignmentFilters' { return @() }
                '/v1.0/deviceManagement/deviceConfigurations' { return @() }
                '/beta/deviceManagement/configurationPolicies' {
                    return @(
                        [pscustomobject]@{
                            id = 'security-policy-1'
                            name = 'Endpoint firewall'
                            platforms = 'windows10'
                            technologies = 'mdm'
                            templateReference = [pscustomobject]@{ templateFamily = 'endpointSecurityFirewall'; templateId = 'security-template-1'; templateDisplayVersion = '3' }
                        },
                        [pscustomobject]@{
                            id = 'baseline-policy-1'
                            name = 'Modern security baseline'
                            platforms = 'windows10'
                            technologies = 'mdm'
                            templateReference = [pscustomobject]@{ templateFamily = 'baseline'; templateId = 'baseline-template-1'; templateDisplayVersion = '24H2' }
                        },
                        [pscustomobject]@{
                            id = 'enrollment-policy'
                            name = 'Enrollment policy owned by issue 181'
                            templateReference = [pscustomobject]@{ templateFamily = 'enrollmentConfiguration'; templateId = 'enrollment-template' }
                        },
                        [pscustomobject]@{
                            id = 'future-policy'
                            name = 'Future policy'
                            templateReference = [pscustomobject]@{ templateFamily = 'unknownFutureValue'; templateId = 'future-template' }
                        }
                    )
                }
                '/beta/deviceManagement/configurationPolicyTemplates' {
                    return @(
                        [pscustomobject]@{
                            id = 'security-template-1'
                            baseId = 'security-base-1'
                            version = 3
                            displayVersion = '3'
                            lifecycleState = 'active'
                            platforms = 'windows10'
                            technologies = 'mdm'
                            templateFamily = 'endpointSecurityFirewall'
                        },
                        [pscustomobject]@{
                            id = 'baseline-template-1'
                            baseId = 'baseline-base-1'
                            version = 7
                            displayVersion = '24H2'
                            lifecycleState = 'active'
                            platforms = 'windows10'
                            technologies = 'mdm'
                            templateFamily = 'baseline'
                        },
                        [pscustomobject]@{
                            id = 'nonsecurity-template'
                            templateFamily = 'deviceConfigurationPolicies'
                        }
                    )
                }
                '/beta/deviceManagement/templates' {
                    return @(
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.securityBaselineTemplate'
                            id = 'legacy-template-1'
                            displayName = 'Legacy baseline derived type'
                            versionInfo = '23H2'
                            isDeprecated = $false
                            templateType = 'specializedDevices'
                            platformType = 'windows10AndLater'
                            templateSubtype = 'none'
                        },
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.deviceManagementTemplate'
                            id = 'legacy-template-2'
                            displayName = 'Edge security baseline'
                            versionInfo = '128'
                            isDeprecated = $false
                            templateType = 'microsoftEdgeSecurityBaseline'
                            platformType = 'windows10AndLater'
                            templateSubtype = 'none'
                        },
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.deviceManagementTemplate'
                            id = 'generic-template'
                            displayName = 'Generic template'
                            templateType = 'deviceConfiguration'
                        }
                    )
                }
                '/beta/deviceManagement/intents' {
                    return @(
                        [pscustomobject]@{ id = 'legacy-intent-1'; displayName = 'Legacy baseline intent'; templateId = 'legacy-template-1'; isMigratingToConfigurationPolicy = $true },
                        [pscustomobject]@{ id = 'legacy-intent-2'; displayName = 'Edge baseline intent'; templateId = 'legacy-template-2'; isMigratingToConfigurationPolicy = $false },
                        [pscustomobject]@{ id = 'generic-intent'; displayName = 'Generic intent'; templateId = 'generic-template'; isMigratingToConfigurationPolicy = $false }
                    )
                }
                default { throw ('Unexpected Intune security Stage1 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/beta/deviceManagement/configurationPolicies/security-policy-1' {
                    return [pscustomobject]@{ id = 'security-policy-1'; name = 'Endpoint firewall'; platforms = 'windows10'; technologies = 'mdm'; templateReference = [pscustomobject]@{ templateFamily = 'endpointSecurityFirewall'; templateId = 'security-template-1'; templateDisplayVersion = '3' } }
                }
                '/beta/deviceManagement/configurationPolicies/baseline-policy-1' {
                    return [pscustomobject]@{ id = 'baseline-policy-1'; name = 'Modern security baseline'; platforms = 'windows10'; technologies = 'mdm'; templateReference = [pscustomobject]@{ templateFamily = 'baseline'; templateId = 'baseline-template-1'; templateDisplayVersion = '24H2' } }
                }
                '/beta/deviceManagement/configurationPolicyTemplates/security-template-1' {
                    return [pscustomobject]@{ id = 'security-template-1'; baseId = 'security-base-1'; version = 3; displayVersion = '3'; lifecycleState = 'active'; platforms = 'windows10'; technologies = 'mdm'; templateFamily = 'endpointSecurityFirewall' }
                }
                '/beta/deviceManagement/configurationPolicyTemplates/baseline-template-1' {
                    return [pscustomobject]@{ id = 'baseline-template-1'; baseId = 'baseline-base-1'; version = 7; displayVersion = '24H2'; lifecycleState = 'active'; platforms = 'windows10'; technologies = 'mdm'; templateFamily = 'baseline' }
                }
                '/beta/deviceManagement/templates/legacy-template-1' {
                    return [pscustomobject]@{ '@odata.type' = '#microsoft.graph.securityBaselineTemplate'; id = 'legacy-template-1'; displayName = 'Legacy baseline derived type'; versionInfo = '23H2'; isDeprecated = $false; templateType = 'specializedDevices'; platformType = 'windows10AndLater' }
                }
                '/beta/deviceManagement/templates/legacy-template-2' {
                    return [pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceManagementTemplate'; id = 'legacy-template-2'; displayName = 'Edge security baseline'; versionInfo = '128'; isDeprecated = $false; templateType = 'microsoftEdgeSecurityBaseline'; platformType = 'windows10AndLater' }
                }
                '/beta/deviceManagement/intents/legacy-intent-1' {
                    return [pscustomobject]@{ id = 'legacy-intent-1'; displayName = 'Legacy baseline intent'; templateId = 'legacy-template-1'; isMigratingToConfigurationPolicy = $true }
                }
                '/beta/deviceManagement/intents/legacy-intent-2' {
                    return [pscustomobject]@{ id = 'legacy-intent-2'; displayName = 'Edge baseline intent'; templateId = 'legacy-template-2'; isMigratingToConfigurationPolicy = $false }
                }
                default { throw ('Unexpected Intune security Stage2 detail endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/beta/deviceManagement/configurationPolicies/security-policy-1/settings' {
                    return @(
                        [pscustomobject]@{ id = 'security-setting-1'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'firewall-enable'; simpleSettingValue = [pscustomobject]@{ value = $true } } },
                        [pscustomobject]@{ id = 'security-setting-2'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'firewall-profile'; choiceSettingValue = [pscustomobject]@{ value = 'domain' } } }
                    )
                }
                '/beta/deviceManagement/configurationPolicies/baseline-policy-1/settings' {
                    return @([pscustomobject]@{ id = 'baseline-setting-1'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'baseline-control'; simpleSettingValue = [pscustomobject]@{ value = 1 } } })
                }
                '/beta/deviceManagement/intents/legacy-intent-1/settings' {
                    return @([pscustomobject]@{ id = 'legacy-setting-1'; definitionId = 'legacy-def-1'; valueJson = '{"value":true}' })
                }
                '/beta/deviceManagement/intents/legacy-intent-2/settings' { return @() }
                default { throw ('Unexpected Intune security Stage2 collection endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/beta/deviceManagement/configurationPolicies/security-policy-1/assignments' {
                    return @([pscustomobject]@{
                        id = 'security-assignment-group'
                        source = 'direct'
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                            groupId = 'security-group-1'
                            deviceAndAppManagementAssignmentFilterId = 'filter-1'
                            deviceAndAppManagementAssignmentFilterType = 'include'
                        }
                    })
                }
                '/beta/deviceManagement/configurationPolicies/baseline-policy-1/assignments' {
                    return @([pscustomobject]@{
                        id = 'security-assignment-configmgr'
                        source = 'direct'
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.configurationManagerCollectionAssignmentTarget'
                            collectionId = 'security-collection-7'
                            deviceAndAppManagementAssignmentFilterId = $null
                            deviceAndAppManagementAssignmentFilterType = 'none'
                        }
                    })
                }
                '/beta/deviceManagement/intents/legacy-intent-1/assignments' {
                    return @([pscustomobject]@{
                        id = 'legacy-assignment-directory-object'
                        source = 'direct'
                        intent = 'apply'
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.scopeTagGroupAssignmentTarget'
                            targetType = 'user'
                            entraObjectId = 'legacy-directory-object-1'
                            deviceAndAppManagementAssignmentFilterId = 'filter-2'
                            deviceAndAppManagementAssignmentFilterType = 'exclude'
                        }
                    })
                }
                '/beta/deviceManagement/intents/legacy-intent-2/assignments' { return @() }
                default { throw ('Unexpected Intune security Stage3 endpoint: {0}' -f $Endpoint) }
            }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'admits modern security families plus legacy baseline templates and intents with configured settings' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        $policies = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-core/securityConfigurationPolicies/batch-0001.json') -Raw | ConvertFrom-Json
        $policies.apiVersion | Should -Be 'beta'
        [bool]$policies.isBeta | Should -BeTrue
        @($policies.items).Count | Should -Be 2
        @($policies.items.id) | Should -Contain 'security-policy-1'
        @($policies.items.id) | Should -Contain 'baseline-policy-1'
        @($policies.items.id) | Should -Not -Contain 'enrollment-policy'
        @($policies.items.id) | Should -Not -Contain 'future-policy'
        @($policies.requestContext.admittedTemplateFamilies) | Should -Contain 'endpointSecurityFirewall'
        @($policies.requestContext.admittedTemplateFamilies) | Should -Contain 'baseline'

        $modernTemplates = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-core/securityConfigurationPolicyTemplates/batch-0001.json') -Raw | ConvertFrom-Json
        @($modernTemplates.items).Count | Should -Be 2
        $firewallTemplate = @($modernTemplates.items | Where-Object { $_.id -eq 'security-template-1' })[0]
        [int]$firewallTemplate.version | Should -Be 3
        $firewallTemplate.displayVersion | Should -Be '3'
        $firewallTemplate.lifecycleState | Should -Be 'active'

        $legacyTemplates = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-core/securityBaselineTemplates/batch-0001.json') -Raw | ConvertFrom-Json
        @($legacyTemplates.items).Count | Should -Be 2
        @($legacyTemplates.items.id) | Should -Contain 'legacy-template-1'
        @($legacyTemplates.items.id) | Should -Contain 'legacy-template-2'
        @($legacyTemplates.items.id) | Should -Not -Contain 'generic-template'

        $legacyIntents = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-core/securityBaselineIntents/batch-0001.json') -Raw | ConvertFrom-Json
        @($legacyIntents.items).Count | Should -Be 2
        @($legacyIntents.items.id) | Should -Not -Contain 'generic-intent'
        [bool](@($legacyIntents.items | Where-Object { $_.id -eq 'legacy-intent-1' })[0].isMigratingToConfigurationPolicy) | Should -BeTrue

        $modernSettings = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/intune-core/securityConfigurationPolicySettings/batch-0001.json') -Raw | ConvertFrom-Json
        $modernSettings.requestContext.responseShape | Should -Be 'one-wrapper-per-policy'
        [bool]$modernSettings.requestContext.paging | Should -BeTrue
        $firewallSettings = @($modernSettings.items | Where-Object { $_.policyId -eq 'security-policy-1' })[0]
        [int]$firewallSettings.settingCount | Should -Be 2
        @($firewallSettings.settings).Count | Should -Be 2

        $legacySettings = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/intune-core/securityBaselineIntentSettings/batch-0001.json') -Raw | ConvertFrom-Json
        $legacySettings.requestContext.responseShape | Should -Be 'one-wrapper-per-intent'
        $intentSettings = @($legacySettings.items | Where-Object { $_.intentId -eq 'legacy-intent-1' })[0]
        [int]$intentSettings.settingCount | Should -Be 1
        @($intentSettings.settings).Count | Should -Be 1

        $intentDetail = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/intune-core/securityBaselineIntents/batch-0001.json') -Raw | ConvertFrom-Json
        [bool](@($intentDetail.items | Where-Object { $_.id -eq 'legacy-intent-1' })[0].isMigratingToConfigurationPolicy) | Should -BeTrue
    }

    It 'normalizes modern and legacy security assignments including filters and Configuration Manager collections' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage3') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        $modern = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/intune-core/securityConfigurationPolicyAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        $group = @($modern.items | Where-Object { $_.parentId -eq 'security-policy-1' })[0].relationships[0]
        $group.targetId | Should -Be 'security-group-1'
        $group.targetIdentityDomain | Should -Be 'entra.group'
        $group.assignmentFilterId | Should -Be 'filter-1'
        $group.assignmentFilterType | Should -Be 'include'
        $group.assignmentFilterIdentityDomain | Should -Be 'intune.assignment-filter'

        $configManager = @($modern.items | Where-Object { $_.parentId -eq 'baseline-policy-1' })[0].relationships[0]
        $configManager.targetOdataType | Should -Be '#microsoft.graph.configurationManagerCollectionAssignmentTarget'
        $configManager.targetId | Should -Be 'security-collection-7'
        $configManager.collectionId | Should -Be 'security-collection-7'
        $configManager.targetIdentityDomain | Should -Be 'intune.assignment-target'

        $legacy = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/intune-core/securityBaselineIntentAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        $directoryObject = @($legacy.items | Where-Object { $_.parentId -eq 'legacy-intent-1' })[0].relationships[0]
        $directoryObject.targetId | Should -Be 'legacy-directory-object-1'
        $directoryObject.targetIdentityDomain | Should -Be 'entra.directory-object'
        $directoryObject.assignmentFilterId | Should -Be 'filter-2'
        $directoryObject.assignmentFilterType | Should -Be 'exclude'
        $directoryObject.intent | Should -Be 'apply'
    }

    It 'preserves zero-item and resume behavior without calling status Defender or remediation telemetry' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            if ($Endpoint -match 'status|state|report|detection|defender|remediation|health') {
                throw ('Operational security telemetry endpoint must not be called: {0}' -f $Endpoint)
            }
            return @()
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            throw ('Stage2 detail must not call Graph when security inventory is empty: {0}' -f $Endpoint)
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            throw ('Stage2 settings must not call Graph when security inventory is empty: {0}' -f $Endpoint)
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            throw ('Stage3 must not call Graph when security inventory is empty: {0}' -f $Endpoint)
        }

        $initial = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $initial.status | Should -Be 'Completed'

        foreach ($identity in @(
            @{ Stage = 'stage1'; Family = 'securityConfigurationPolicies' },
            @{ Stage = 'stage1'; Family = 'securityConfigurationPolicyTemplates' },
            @{ Stage = 'stage1'; Family = 'securityBaselineTemplates' },
            @{ Stage = 'stage1'; Family = 'securityBaselineIntents' },
            @{ Stage = 'stage2'; Family = 'securityConfigurationPolicies' },
            @{ Stage = 'stage2'; Family = 'securityConfigurationPolicySettings' },
            @{ Stage = 'stage2'; Family = 'securityConfigurationPolicyTemplates' },
            @{ Stage = 'stage2'; Family = 'securityBaselineTemplates' },
            @{ Stage = 'stage2'; Family = 'securityBaselineIntents' },
            @{ Stage = 'stage2'; Family = 'securityBaselineIntentSettings' },
            @{ Stage = 'stage3'; Family = 'securityConfigurationPolicyAssignments' },
            @{ Stage = 'stage3'; Family = 'securityBaselineIntentAssignments' }
        )) {
            $snapshot = Get-Content -LiteralPath (Join-Path $initial.runPath ('{0}/intune-core/{1}/batch-0001.json' -f $identity.Stage, $identity.Family)) -Raw | ConvertFrom-Json
            [int]$snapshot.itemCount | Should -Be 0
            @($snapshot.items).Count | Should -Be 0
        }

        $resumed = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-core') -Resume -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $resumed.runId | Should -Be $initial.runId
        $resumed.status | Should -Be 'Completed'
    }
}
