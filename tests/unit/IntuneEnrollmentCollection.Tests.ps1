BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Intune enrollment section selection' {
    It 'keeps enrollment outside the legacy default section set' {
        $defaults = @(Resolve-CollectorSections)
        $defaults | Should -Be @('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo')
        $defaults | Should -Not -Contain 'intune-enrollment'
    }

    It 'resolves the opt-in enrollment section explicitly' {
        @(Resolve-CollectorSections -Sections @('intune-enrollment')) | Should -Be @('intune-enrollment')
    }
}

Describe 'Intune enrollment and onboarding collection' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-intune-enrollment-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/deviceManagement/deviceEnrollmentConfigurations' {
                    return @(
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.windows10EnrollmentCompletionPageConfiguration'
                            id = 'enrollment-config-1'
                            displayName = 'Windows Enrollment Status Page'
                            priority = 0
                            showInstallationProgress = $true
                            blockDeviceSetupRetryByUser = $true
                        },
                        [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.deviceEnrollmentPlatformRestrictionsConfiguration'
                            id = 'enrollment-config-2'
                            displayName = 'Platform restrictions'
                            priority = 1
                        }
                    )
                }
                '/beta/deviceManagement/windowsAutopilotDeploymentProfiles' {
                    return @([pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile'
                        id = 'autopilot-profile-1'
                        displayName = 'Corporate Windows Autopilot'
                        hardwareHashExtractionEnabled = $true
                        deviceNameTemplate = 'CORP-%RAND:5%'
                        preprovisioningAllowed = $true
                        roleScopeTagIds = @('0')
                        outOfBoxExperienceSetting = [pscustomobject]@{ privacySettingsHidden = $true; eulaHidden = $true; userType = 'standard' }
                        enrollmentStatusScreenSettings = [pscustomobject]@{ hideInstallationProgress = $false; installProgressTimeoutInMinutes = 60 }
                    })
                }
                default { throw ('Unexpected Intune enrollment Stage1 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/deviceManagement/deviceEnrollmentConfigurations/enrollment-config-1' {
                    return [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10EnrollmentCompletionPageConfiguration'; id = 'enrollment-config-1'; displayName = 'Windows Enrollment Status Page'; showInstallationProgress = $true; blockDeviceSetupRetryByUser = $true }
                }
                '/v1.0/deviceManagement/deviceEnrollmentConfigurations/enrollment-config-2' {
                    return [pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceEnrollmentPlatformRestrictionsConfiguration'; id = 'enrollment-config-2'; displayName = 'Platform restrictions'; priority = 1 }
                }
                '/beta/deviceManagement/windowsAutopilotDeploymentProfiles/autopilot-profile-1' {
                    return [pscustomobject]@{ '@odata.type' = '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile'; id = 'autopilot-profile-1'; displayName = 'Corporate Windows Autopilot'; hardwareHashExtractionEnabled = $true; deviceNameTemplate = 'CORP-%RAND:5%'; preprovisioningAllowed = $true; roleScopeTagIds = @('0') }
                }
                default { throw ('Unexpected Intune enrollment Stage2 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/deviceManagement/deviceEnrollmentConfigurations/enrollment-config-1/assignments' {
                    return @([pscustomobject]@{
                        id = 'enrollment-assignment-1'
                        source = 'direct'
                        target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'enrollment-group-1' }
                    })
                }
                '/v1.0/deviceManagement/deviceEnrollmentConfigurations/enrollment-config-2/assignments' { return @() }
                'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/autopilot-profile-1/assignments?$skiptoken=page2' {
                    return @([pscustomobject]@{
                        id = 'autopilot-assignment-page2'
                        source = 'direct'
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                            groupId = 'autopilot-group-2'
                        }
                    })
                }
                default { throw ('Unexpected Intune enrollment Stage3 collection endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            if ($Endpoint -ne '/beta/deviceManagement/windowsAutopilotDeploymentProfiles/autopilot-profile-1?$expand=assignments') {
                throw ('Unexpected Intune enrollment Stage3 object endpoint: {0}' -f $Endpoint)
            }

            return [pscustomobject]@{
                '@odata.type' = '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile'
                id = 'autopilot-profile-1'
                'assignments@odata.nextLink' = 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/autopilot-profile-1/assignments?$skiptoken=page2'
                assignments = @(
                    [pscustomobject]@{
                        id = 'autopilot-assignment-group'
                        source = 'direct'
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                            groupId = 'autopilot-group-1'
                            deviceAndAppManagementAssignmentFilterId = 'filter-1'
                            deviceAndAppManagementAssignmentFilterType = 'include'
                        }
                    },
                    [pscustomobject]@{
                        id = 'autopilot-assignment-collection'
                        source = 'direct'
                        target = [pscustomobject]@{
                            '@odata.type' = '#microsoft.graph.configurationManagerCollectionAssignmentTarget'
                            collectionId = 'autopilot-collection-7'
                        }
                    }
                )
            }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'persists v1 enrollment configurations and beta Autopilot deployment profile configuration' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2') -Sections @('intune-enrollment') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        $enrollment = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-enrollment/deviceEnrollmentConfigurations/batch-0001.json') -Raw | ConvertFrom-Json
        $enrollment.apiVersion | Should -Be 'v1.0'
        [bool]$enrollment.isBeta | Should -BeFalse
        @($enrollment.items).Count | Should -Be 2
        @($enrollment.items.'@odata.type') | Should -Contain '#microsoft.graph.windows10EnrollmentCompletionPageConfiguration'

        $autopilot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage1/intune-enrollment/windowsAutopilotDeploymentProfiles/batch-0001.json') -Raw | ConvertFrom-Json
        $autopilot.apiVersion | Should -Be 'beta'
        [bool]$autopilot.isBeta | Should -BeTrue
        @($autopilot.items).Count | Should -Be 1
        [bool]$autopilot.items[0].hardwareHashExtractionEnabled | Should -BeTrue
        $autopilot.items[0].deviceNameTemplate | Should -Be 'CORP-%RAND:5%'

        $autopilotDetail = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/intune-enrollment/windowsAutopilotDeploymentProfiles/batch-0001.json') -Raw | ConvertFrom-Json
        $autopilotDetail.items[0].id | Should -Be 'autopilot-profile-1'
        [bool]$autopilotDetail.items[0].hardwareHashExtractionEnabled | Should -BeTrue
    }

    It 'normalizes enrollment and expanded-profile Autopilot assignments with stable group filter and ConfigMgr identities' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage3') -Sections @('intune-enrollment') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        $enrollment = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/intune-enrollment/deviceEnrollmentConfigurationAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        $enrollmentRelationship = @($enrollment.items | Where-Object { $_.parentId -eq 'enrollment-config-1' })[0].relationships[0]
        $enrollmentRelationship.targetId | Should -Be 'enrollment-group-1'
        $enrollmentRelationship.targetIdentityDomain | Should -Be 'entra.group'

        $autopilot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/intune-enrollment/windowsAutopilotDeploymentProfileAssignments/batch-0001.json') -Raw | ConvertFrom-Json
        [int]$autopilot.items[0].relationshipCount | Should -Be 3
        $group = @($autopilot.items[0].relationships | Where-Object { $_.assignmentId -eq 'autopilot-assignment-group' })[0]
        $group.targetId | Should -Be 'autopilot-group-1'
        $group.targetIdentityDomain | Should -Be 'entra.group'
        $group.assignmentFilterId | Should -Be 'filter-1'
        $group.assignmentFilterType | Should -Be 'include'
        $group.assignmentFilterIdentityDomain | Should -Be 'intune.assignment-filter'

        $collection = @($autopilot.items[0].relationships | Where-Object { $_.assignmentId -eq 'autopilot-assignment-collection' })[0]
        $collection.targetId | Should -Be 'autopilot-collection-7'
        $collection.collectionId | Should -Be 'autopilot-collection-7'
        $collection.targetIdentityDomain | Should -Be 'intune.assignment-target'

        $continued = @($autopilot.items[0].relationships | Where-Object { $_.assignmentId -eq 'autopilot-assignment-page2' })[0]
        $continued.targetId | Should -Be 'autopilot-group-2'
        $continued.targetIdentityDomain | Should -Be 'entra.group'

        Assert-MockCalled -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphRequest -Times 1 -Exactly -Scope It -ParameterFilter {
            $Endpoint -eq '/beta/deviceManagement/windowsAutopilotDeploymentProfiles/autopilot-profile-1?$expand=assignments'
        }
        Assert-MockCalled -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -Times 1 -Exactly -Scope It -ParameterFilter {
            $Endpoint -eq 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/autopilot-profile-1/assignments?$skiptoken=page2'
        }
        Assert-MockCalled -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -Times 0 -Exactly -Scope It -ParameterFilter {
            $Endpoint -like '/beta/deviceManagement/windowsAutopilotDeploymentProfiles/*/assignments'
        }
    }

    It 'preserves zero-item and resume semantics without requesting device identity or operational enrollment surfaces' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            if ($Endpoint -match 'windowsAutopilotDeviceIdentit|importedWindowsAutopilot|assignedDevices|managedDevices|enrollmentEvent|hardwareHash|deviceStatus|deploymentStatus') {
                throw ('Device identity or operational enrollment endpoint must not be called: {0}' -f $Endpoint)
            }
            return @()
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            throw ('Stage2 must not call Graph when enrollment inventory is empty: {0}' -f $Endpoint)
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            throw ('Stage3 collection must not call Graph when enrollment inventory is empty: {0}' -f $Endpoint)
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            throw ('Stage3 object read must not call Graph when enrollment inventory is empty: {0}' -f $Endpoint)
        }

        $initial = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-enrollment') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $initial.status | Should -Be 'Completed'

        foreach ($identity in @(
            @{ Stage = 'stage1'; Family = 'deviceEnrollmentConfigurations' },
            @{ Stage = 'stage1'; Family = 'windowsAutopilotDeploymentProfiles' },
            @{ Stage = 'stage2'; Family = 'deviceEnrollmentConfigurations' },
            @{ Stage = 'stage2'; Family = 'windowsAutopilotDeploymentProfiles' },
            @{ Stage = 'stage3'; Family = 'deviceEnrollmentConfigurationAssignments' },
            @{ Stage = 'stage3'; Family = 'windowsAutopilotDeploymentProfileAssignments' }
        )) {
            $snapshot = Get-Content -LiteralPath (Join-Path $initial.runPath ('{0}/intune-enrollment/{1}/batch-0001.json' -f $identity.Stage, $identity.Family)) -Raw | ConvertFrom-Json
            [int]$snapshot.itemCount | Should -Be 0
            @($snapshot.items).Count | Should -Be 0
        }

        $resumed = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('intune-enrollment') -Resume -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $resumed.runId | Should -Be $initial.runId
        $resumed.status | Should -Be 'Completed'
    }
}
