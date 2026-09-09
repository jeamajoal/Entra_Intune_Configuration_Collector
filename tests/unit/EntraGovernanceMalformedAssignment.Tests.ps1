BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Entra governance malformed assignment checkpointing' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-governance-malformed-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/directory/administrativeUnits' { return @() }
                '/v1.0/directoryRoles' { return @() }
                '/v1.0/roleManagement/directory/roleDefinitions' {
                    return @([pscustomobject]@{ id = 'role-def-1'; displayName = 'Helpdesk Administrator'; templateId = 'template-role-1' })
                }
                '/v1.0/roleManagement/directory/roleAssignments' {
                    return @(
                        [pscustomobject]@{ id = 'assign-valid'; principalId = 'user-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/'; appScopeId = $null },
                        [pscustomobject]@{ id = 'assign-invalid'; principalId = $null; roleDefinitionId = 'role-def-1'; directoryScopeId = '/'; appScopeId = $null }
                    )
                }
                default { throw ('Unexpected governance Stage1 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/roleManagement/directory/roleDefinitions/role-def-1' {
                    return [pscustomobject]@{ id = 'role-def-1'; displayName = 'Helpdesk Administrator'; templateId = 'template-role-1'; rolePermissions = @() }
                }
                '/v1.0/roleManagement/directory/roleAssignments/assign-valid' {
                    return [pscustomobject]@{ id = 'assign-valid'; principalId = 'user-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/'; appScopeId = $null }
                }
                '/v1.0/roleManagement/directory/roleAssignments/assign-invalid' {
                    return [pscustomobject]@{ id = 'assign-invalid'; principalId = $null; roleDefinitionId = 'role-def-1'; directoryScopeId = '/'; appScopeId = $null }
                }
                default { throw ('Unexpected governance Stage2 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            throw 'Administrative-unit Stage3 Graph collection should not run for an empty administrative-unit inventory.'
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'records conversion failure in a retryable Stage3 checkpoint without discarding valid assignments' {
        $initial = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-governance') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $initial.status | Should -Be 'CompletedWithErrors'

        $checkpointPath = Join-Path -Path $initial.runPath -ChildPath 'checkpoints/stage3/entra-governance/activeRoleAssignmentEdges.json'
        Test-Path -LiteralPath $checkpointPath -PathType Leaf | Should -BeTrue
        $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        @($checkpoint.batches).Count | Should -Be 1
        $checkpoint.batches[0].status | Should -Be 'Failed'
        [int]$checkpoint.batches[0].attempts | Should -Be 1
        [int]$checkpoint.batches[0].successCount | Should -Be 1
        [int]$checkpoint.batches[0].failedCount | Should -Be 1

        $snapshotPath = Join-Path -Path $initial.runPath -ChildPath 'stage3/entra-governance/activeRoleAssignmentEdges/batch-0001.json'
        $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
        @($snapshot.items | Where-Object { $_.assignmentId -eq 'assign-valid' -and $_.principalId -eq 'user-1' }).Count | Should -Be 1
        @($snapshot.items | Where-Object { $_.assignmentId -eq 'assign-invalid' -and $_._collectorError }).Count | Should -Be 1

        $resumed = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-governance') -Resume -ReprocessFailedOnly -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $resumed.runId | Should -Be $initial.runId
        $resumed.status | Should -Be 'CompletedWithErrors'

        $checkpointAfterResume = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        [int]$checkpointAfterResume.batches[0].attempts | Should -Be 2
        $checkpointAfterResume.batches[0].status | Should -Be 'Failed'
    }
}
