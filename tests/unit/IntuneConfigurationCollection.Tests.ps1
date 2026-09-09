BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Intune configuration policy and profile collection' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-intune-configuration-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/deviceAppManagement/mobileApps' { return @() }
                '/beta/deviceManagement/deviceManagementScripts' { return @() }
                '/v1.0/deviceManagement/deviceCompliancePolicies' { return @() }
                '/beta/deviceManagement/assignmentFilters' { return @() }
                '/beta/deviceManagement/configurationPolicies' {
                    return @(
                        [pscustomobject]@{
                            id = 'settings-policy-1'
                            name = 'Settings catalog policy'
                            platforms = 'windows10'
                            technologies = 'mdm'
                            settingCount = 2
                            templateReference = [pscustomobject]@{ templateFamily = 'none'; templateId = $null }
                        },
                        [pscustomobject]@{
                            id = 'template-policy-1'
                            name = 'Device configuration policy template'
                            platforms = 'windows10'
                            technologies = 'mdm'
                            settingCount = 1
                            templateReference = [pscustomobject]@{ templateFamily = 'deviceConfigurationPolicies'; templateId = 'template-1' }
                        },
                        [pscustomobject]@{
                            id = 'endpoint-security-policy'
                            name = 'Firewall policy owned by issue 178'
                            templateReference = [pscustomobject]@{ templateFamily = 'endpointSecurityFirewall'; templateId = 'endpoint-template' }
                        },
                        [pscustomobject]@{
                            id = 'baseline-policy'
                            name = 'Security baseline owned by issue 178'
                            templateReference = [pscustomobject]@{ templateFamily = 'baseline'; templateId = 'baseline-template' }
                        },
                        [pscustomobject]@{
                            id = 'future-policy'
                            name = 'Future template family'
                            templateReference = [pscustomobject]@{ templateFamily = 'unknownFutureValue'; templateId = 'future-template' }
                        }
                    )
                }
                '/v1.0/deviceManagement/deviceConfigurations' {
                    return @([pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
                        id = 'classic-profile-1'
                        displayName = 'Classic custom profile'
                        version = 3
                    })
                }
                default { throw ('Unexpected Intune Stage1 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/beta/deviceManagement/configurationPolicies/settings-policy-1' {
                    return [pscustomobject]@{ id = 'settings-policy-1'; name = 'Settings catalog policy'; platforms = 'windows10'; technologies = 'mdm'; templateReference = [pscustomobject]@{ templateFamily = 'none' } }
                }
                '/beta/deviceManagement/configurationPolicies/template-policy-1' {
                    return [pscustomobject]@{ id = 'template-policy-1'; name = 'Device configuration policy template'; platforms = 'windows10'; technologies = 'mdm'; templateReference = [pscustomobject]@{ templateFamily = 'deviceConfigurationPolicies'; templateId = 'template-1' } }
                }
                '/v1.0/deviceManagement/deviceConfigurations/classic-profile-1' {
                    return [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; id = 'classic-profile-1'; displayName = 'Classic custom profile'; omaSettings = @([pscustomobject]@{ displayName = 'Example'; omaUri = './Device/Vendor/MSFT/Policy/Config/Example'; value = 'enabled' }) }
                }
                default { throw ('Unexpected Intune Stage2 detail endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/beta/deviceManagement/configurationPolicies/settings-policy-1/settings' {
                    return @(
                        [pscustomobject]@{ id = 'setting-1'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'def-1'; simpleSettingValue = [pscustomobject]@{ value = 'enabled' } } },
                        [pscustomobject]@{ id = 'setting-2'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'def-2'; choiceSettingValue = [pscustomobject]@{ value = 'choice-2' } } }
                    )
                }
                '/beta/deviceManagement/configurationPolicies/template-policy-1/settings' {
                    return @([pscustomobject]@{ id = 'setting-3'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'def-3'; simpleSettingValue = [pscustomobject]@{ value = 1 } } })
                }
                default { throw ('Unexpected Intune Stage2 collection endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/beta/deviceManagement/configurationPolicies/settings-policy-1/assignments' {
                    return @([pscustomobject]@{
                        id = 'modern-assignment-1'
                        source = 'direct'
                        sourceId = $null
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                            groupId = 'group-1'
                            deviceAndAppManagementAssignmentFilterId = 'filter-1'
                            deviceAndAppManagementAssignmentFilterType = 'include'
                        }
                    })
                }
                '/beta/deviceManagement/configurationPolicies/template-policy-1/assignments' { return @() }
                '/beta/deviceManagement/deviceConfigurations/classic-profile-1/assignments' {
                    return @([pscustomobject]@{
                        id = 'classic-assignment-1'
                        source = 'policySets'
                        sourceId = 'policy-set-1'
                        intent = 'apply'
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.scopeTagGroupAssignmentTarget'
                            targetType = 'user'
                            entraObjectId = 'directory-object-1'
                            deviceAndAppManagementAssignmentFilterId = 'filter-1'
                            deviceAndAppManagementAssignmentFilterType = 'exclude'
                        }
                    })
                }
                default { throw ('Unexpected Intune Stage3 endpoint: {0}' -f $Endpoint) }
            }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'filters modern policy families and preserves paged setting/profile configuration evidence' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        $inventory = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-core/configurationPolicies/batch-0001.json') -Raw | ConvertFrom-Json
        $inventory.apiVersion | Should -Be 'beta'
        [bool]$inventory.isBeta | Should -BeTrue
        @($inventory.items).Count | Should -Be 2
        @($inventory.items.id) | Should -Contain 'settings-policy-1'
        @($inventory.items.id) | Should -Contain 'template-policy-1'
        @($inventory.items.id) | Should -Not -Contain 'endpoint-security-policy'
        @($inventory.items.id) | Should -Not -Contain 'baseline-policy'
        @($inventory.items.id) | Should -Not -Contain 'future-policy'
        @($inventory.requestContext.admittedTemplateFamilies) | Should -Contain 'none'
        @($inventory.requestContext.admittedTemplateFamilies) | Should -Contain 'deviceConfigurationPolicies'

        $settings = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/intune-core/configurationPolicySettings/batch-0001.json') -Raw | ConvertFrom-Json
        $settings.apiVersion | Should -Be 'beta'
        [bool]$settings.isBeta | Should -BeTrue
        [bool]$settings.requestContext.paging | Should -BeTrue
        $settings.requestContext.responseShape | Should -Be 'one-wrapper-per-policy'
        @($settings.items).Count | Should -Be 2
        $settingsPolicy = @($settings.items | Where-Object { $_.policyId -eq 'settings-policy-1' })[0]
        [int]$settingsPolicy.settingCount | Should -Be 2
        @($settingsPolicy.settings).Count | Should -Be 2
        $settingsPolicy.settings[0].settingInstance.settingDefinitionId | Should -Be 'def-1'

        $classic = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/intune-core/deviceConfigurations/batch-0001.json') -Raw | ConvertFrom-Json
        $classic.apiVersion | Should -Be 'v1.0'
        [bool]$classic.isBeta | Should -BeFalse
        $classic.items[0].'@odata.type' | Should -Be '#microsoft.graph.windows10CustomConfiguration'
        @($classic.items[0].omaSettings).Count | Should -Be 1
    }

    It 'normalizes modern and classic assignment targets filters sources and intent' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage3') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        $modernSnapshot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/intune-core/configurationPolicyAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        $modernSnapshot.apiVersion | Should -Be 'beta'
        $modern = @($modernSnapshot.items | Where-Object { $_.parentId -eq 'settings-policy-1' })[0].relationships[0]
        $modern.targetId | Should -Be 'group-1'
        $modern.targetIdentityDomain | Should -Be 'entra.group'
        $modern.assignmentFilterId | Should -Be 'filter-1'
        $modern.assignmentFilterType | Should -Be 'include'
        $modern.assignmentFilterIdentityDomain | Should -Be 'intune.assignment-filter'
        $modern.source | Should -Be 'direct'

        $classicSnapshot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/intune-core/deviceConfigurationAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        $classicSnapshot.apiVersion | Should -Be 'beta'
        [bool]$classicSnapshot.isBeta | Should -BeTrue
        $classic = $classicSnapshot.items[0].relationships[0]
        $classic.targetId | Should -Be 'directory-object-1'
        $classic.targetIdentityDomain | Should -Be 'entra.directory-object'
        $classic.assignmentFilterType | Should -Be 'exclude'
        $classic.source | Should -Be 'policySets'
        $classic.sourceId | Should -Be 'policy-set-1'
        $classic.intent | Should -Be 'apply'
    }

    It 'preserves zero-item and resume behavior without calling configuration status telemetry' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            if ($Endpoint -match 'status|deviceStatus|userStatus|settingState|report') { throw ('Operational telemetry endpoint must not be called: {0}' -f $Endpoint) }
            return @()
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            throw ('Stage2 detail must not call Graph when accepted inventory is empty: {0}' -f $Endpoint)
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            throw ('Stage2 settings must not call Graph when configurationPolicies inventory is empty: {0}' -f $Endpoint)
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            throw ('Stage3 must not call Graph when configuration inventory is empty: {0}' -f $Endpoint)
        }

        $initial = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $initial.status | Should -Be 'Completed'

        foreach ($identity in @(
            @{ Stage = 'stage1'; Family = 'configurationPolicies' },
            @{ Stage = 'stage1'; Family = 'deviceConfigurations' },
            @{ Stage = 'stage2'; Family = 'configurationPolicies' },
            @{ Stage = 'stage2'; Family = 'configurationPolicySettings' },
            @{ Stage = 'stage2'; Family = 'deviceConfigurations' },
            @{ Stage = 'stage3'; Family = 'configurationPolicyAssignments' },
            @{ Stage = 'stage3'; Family = 'deviceConfigurationAssignments' }
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
