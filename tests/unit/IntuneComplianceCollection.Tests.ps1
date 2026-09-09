BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Intune compliance offline collection' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-intune-compliance-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/deviceAppManagement/mobileApps' { return @() }
                '/beta/deviceManagement/deviceManagementScripts' { return @() }
                '/v1.0/deviceManagement/deviceCompliancePolicies' {
                    return @([pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'
                        id = 'compliance-1'
                        displayName = 'Windows compliance'
                        description = 'Reviewable compliance configuration'
                        version = 4
                    })
                }
                '/beta/deviceManagement/assignmentFilters' {
                    return @([pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.deviceAndAppManagementAssignmentFilter'
                        id = 'filter-1'
                        displayName = 'Corporate Windows'
                        platform = 'windows10AndLater'
                        rule = '(device.deviceOwnership -eq "Corporate")'
                    })
                }
                '/beta/deviceManagement/configurationPolicies' { return @() }
                '/v1.0/deviceManagement/deviceConfigurations' { return @() }
                default { throw ('Unexpected Intune Stage1 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/deviceManagement/deviceCompliancePolicies/compliance-1' {
                    return [pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'
                        id = 'compliance-1'
                        displayName = 'Windows compliance'
                        passwordRequired = $true
                        osMinimumVersion = '10.0.26100.0'
                    }
                }
                '/beta/deviceManagement/assignmentFilters/filter-1' {
                    return [pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.deviceAndAppManagementAssignmentFilter'
                        id = 'filter-1'
                        displayName = 'Corporate Windows'
                        platform = 'windows10AndLater'
                        rule = '(device.deviceOwnership -eq "Corporate")'
                    }
                }
                default { throw ('Unexpected Intune Stage2 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/beta/deviceManagement/deviceCompliancePolicies/compliance-1/assignments' {
                    return @(
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.deviceCompliancePolicyAssignment'
                            id = 'assignment-group'
                            source = 'direct'
                            sourceId = $null
                            target = [pscustomobject]@{
                                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                                groupId = 'group-1'
                                deviceAndAppManagementAssignmentFilterId = 'filter-1'
                                deviceAndAppManagementAssignmentFilterType = 'include'
                            }
                        },
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.deviceCompliancePolicyAssignment'
                            id = 'assignment-all-devices'
                            source = 'direct'
                            sourceId = $null
                            target = [pscustomobject]@{
                                '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget'
                                deviceAndAppManagementAssignmentFilterId = $null
                                deviceAndAppManagementAssignmentFilterType = 'none'
                            }
                        },
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.deviceCompliancePolicyAssignment'
                            id = 'assignment-directory-object'
                            source = 'policySets'
                            sourceId = 'policy-set-1'
                            target = [pscustomobject]@{
                                '@odata.type' = '#microsoft.graph.scopeTagGroupAssignmentTarget'
                                targetType = 'user'
                                entraObjectId = 'directory-object-1'
                                deviceAndAppManagementAssignmentFilterId = 'filter-1'
                                deviceAndAppManagementAssignmentFilterType = 'exclude'
                            }
                        }
                    )
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

    It 'collects policy, filter, and assignment configuration with truthful API provenance' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        foreach ($family in @('deviceCompliancePolicies', 'assignmentFilters')) {
            Test-Path -LiteralPath (Join-Path $result.runPath ('stage1/intune-core/{0}/batch-0001.json' -f $family)) -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $result.runPath ('stage2/intune-core/{0}/batch-0001.json' -f $family)) -PathType Leaf | Should -BeTrue
        }
        Test-Path -LiteralPath (Join-Path $result.runPath 'stage3/intune-core/deviceCompliancePolicyAssignments/batch-0001.json') -PathType Leaf | Should -BeTrue

        $policyInventory = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-core/deviceCompliancePolicies/batch-0001.json') -Raw | ConvertFrom-Json
        $policyInventory.apiVersion | Should -Be 'v1.0'
        [bool]$policyInventory.isBeta | Should -BeFalse
        [string]$policyInventory.items[0].'@odata.type' | Should -Be '#microsoft.graph.windows10CompliancePolicy'

        $filterInventory = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-core/assignmentFilters/batch-0001.json') -Raw | ConvertFrom-Json
        $filterInventory.apiVersion | Should -Be 'beta'
        [bool]$filterInventory.isBeta | Should -BeTrue
        [string]$filterInventory.items[0].rule | Should -Match 'deviceOwnership'

        $policyDetail = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/intune-core/deviceCompliancePolicies/batch-0001.json') -Raw | ConvertFrom-Json
        [bool]$policyDetail.items[0].passwordRequired | Should -BeTrue
        [string]$policyDetail.items[0].osMinimumVersion | Should -Be '10.0.26100.0'

        $assignmentSnapshot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/intune-core/deviceCompliancePolicyAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        $assignmentSnapshot.apiVersion | Should -Be 'beta'
        [bool]$assignmentSnapshot.isBeta | Should -BeTrue
        $rows = @($assignmentSnapshot.items[0].relationships)

        $group = @($rows | Where-Object { $_.assignmentId -eq 'assignment-group' })[0]
        $group.targetId | Should -Be 'group-1'
        $group.targetIdentityDomain | Should -Be 'entra.group'
        $group.assignmentFilterId | Should -Be 'filter-1'
        $group.assignmentFilterType | Should -Be 'include'
        $group.assignmentFilterIdentityDomain | Should -Be 'intune.assignment-filter'

        $allDevices = @($rows | Where-Object { $_.assignmentId -eq 'assignment-all-devices' })[0]
        $allDevices.targetId | Should -Be 'microsoft.graph.allDevicesAssignmentTarget'
        $allDevices.targetIdentityDomain | Should -Be 'intune.assignment-target'

        $directoryObject = @($rows | Where-Object { $_.assignmentId -eq 'assignment-directory-object' })[0]
        $directoryObject.targetId | Should -Be 'directory-object-1'
        $directoryObject.targetIdentityDomain | Should -Be 'entra.directory-object'
        $directoryObject.source | Should -Be 'policySets'
        $directoryObject.sourceId | Should -Be 'policy-set-1'
        $directoryObject.assignmentFilterType | Should -Be 'exclude'
    }

    It 'emits compliance catalog dependency and relationship semantics' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0

        Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop
        $catalogResult = Collector.Storage.Catalog\Export-CollectorKnowledgeCatalog -RunPath $result.runPath -ExpectedRunId $result.runId
        $catalog = Get-Content -LiteralPath $catalogResult.catalogPath -Raw | ConvertFrom-Json

        @($catalog.dependencies | Where-Object { $_.consumer.section -eq 'intune-core' -and $_.consumer.family -eq 'deviceCompliancePolicies' -and $_.consumer.stage -eq 'stage2' }).Count | Should -Be 1
        @($catalog.dependencies | Where-Object { $_.consumer.section -eq 'intune-core' -and $_.consumer.family -eq 'assignmentFilters' -and $_.consumer.stage -eq 'stage2' }).Count | Should -Be 1
        @($catalog.dependencies | Where-Object { $_.consumer.section -eq 'intune-core' -and $_.consumer.family -eq 'deviceCompliancePolicyAssignments' -and $_.consumer.stage -eq 'stage3' }).Count | Should -Be 1

        $relationship = @($catalog.relationships | Where-Object { $_.section -eq 'intune-core' -and $_.family -eq 'deviceCompliancePolicyAssignments' })[0]
        $relationship.relationshipType | Should -Be 'assignment'
        @($relationship.sourceIdentityDomains) | Should -Contain 'intune.device-compliance-policy'
        @($relationship.targetIdentityDomains) | Should -Contain 'entra.group'
        @($relationship.targetIdentityDomains) | Should -Contain 'entra.directory-object'
        @($relationship.targetIdentityDomains) | Should -Contain 'intune.assignment-filter'
        @($relationship.targetIdentityDomains) | Should -Contain 'intune.assignment-target'
    }

    It 'preserves zero-item and resume semantics without calling status telemetry endpoints' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            if ($Endpoint -match 'status|deviceStatus|userStatus|settingState') {
                throw ('Operational status endpoint must not be called: {0}' -f $Endpoint)
            }
            return @()
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            throw ('Stage2 must not call Graph when Intune inventory is empty: {0}' -f $Endpoint)
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            throw ('Stage3 must not call Graph when Intune inventory is empty: {0}' -f $Endpoint)
        }

        $initial = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-core') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $initial.status | Should -Be 'Completed'

        foreach ($family in @('deviceCompliancePolicies', 'assignmentFilters')) {
            $stage1 = Get-Content -LiteralPath (Join-Path $initial.runPath ('stage1/intune-core/{0}/batch-0001.json' -f $family)) -Raw | ConvertFrom-Json
            [int]$stage1.itemCount | Should -Be 0
            @($stage1.items).Count | Should -Be 0

            $stage2 = Get-Content -LiteralPath (Join-Path $initial.runPath ('stage2/intune-core/{0}/batch-0001.json' -f $family)) -Raw | ConvertFrom-Json
            [int]$stage2.itemCount | Should -Be 0
        }

        $stage3 = Get-Content -LiteralPath (Join-Path $initial.runPath 'stage3/intune-core/deviceCompliancePolicyAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        [int]$stage3.itemCount | Should -Be 0

        $resumed = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-core') -Resume -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $resumed.runId | Should -Be $initial.runId
        $resumed.status | Should -Be 'Completed'
    }
}
