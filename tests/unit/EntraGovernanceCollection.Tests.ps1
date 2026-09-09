BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Entra governance offline collection' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-governance-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/directory/administrativeUnits' {
                    return @([pscustomobject]@{ id = 'au-1'; displayName = 'Tier 1 Admin Boundary'; description = 'Scoped administration' })
                }
                '/v1.0/roleManagement/directory/roleDefinitions' {
                    return @([pscustomobject]@{ id = 'role-def-1'; displayName = 'Helpdesk Administrator'; isBuiltIn = $true; templateId = 'template-role-1' })
                }
                '/v1.0/roleManagement/directory/roleAssignments' {
                    return @(
                        [pscustomobject]@{ id = 'assign-tenant'; principalId = 'user-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/'; appScopeId = $null },
                        [pscustomobject]@{ id = 'assign-au'; principalId = 'group-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/administrativeUnits/au-1'; appScopeId = $null },
                        [pscustomobject]@{ id = 'assign-app'; principalId = 'sp-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/app-object-1'; appScopeId = $null }
                    )
                }
                default { throw ('Unexpected governance Stage1 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/directory/administrativeUnits/au-1' {
                    return [pscustomobject]@{ id = 'au-1'; displayName = 'Tier 1 Admin Boundary'; description = 'Scoped administration'; membershipType = $null }
                }
                '/v1.0/roleManagement/directory/roleDefinitions/role-def-1' {
                    return [pscustomobject]@{ id = 'role-def-1'; displayName = 'Helpdesk Administrator'; description = 'Helpdesk role'; isBuiltIn = $true; templateId = 'template-role-1'; rolePermissions = @() }
                }
                '/v1.0/roleManagement/directory/roleAssignments/assign-tenant' {
                    return [pscustomobject]@{ id = 'assign-tenant'; principalId = 'user-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/'; appScopeId = $null }
                }
                '/v1.0/roleManagement/directory/roleAssignments/assign-au' {
                    return [pscustomobject]@{ id = 'assign-au'; principalId = 'group-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/administrativeUnits/au-1'; appScopeId = $null }
                }
                '/v1.0/roleManagement/directory/roleAssignments/assign-app' {
                    return [pscustomobject]@{ id = 'assign-app'; principalId = 'sp-1'; roleDefinitionId = 'role-def-1'; directoryScopeId = '/app-object-1'; appScopeId = $null }
                }
                default { throw ('Unexpected governance Stage2 endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            switch ($Endpoint) {
                '/v1.0/directory/administrativeUnits/au-1/members' {
                    return @([pscustomobject]@{ id = 'group-1'; displayName = 'Scoped Operators'; '@odata.type' = '#microsoft.graph.group' })
                }
                '/v1.0/directory/administrativeUnits/au-1/scopedRoleMembers' {
                    return @([pscustomobject]@{
                        id = 'scoped-1'
                        administrativeUnitId = 'au-1'
                        roleId = 'directory-role-1'
                        roleMemberInfo = [pscustomobject]@{ id = 'user-1'; displayName = 'Operator One' }
                    })
                }
                default { throw ('Unexpected governance Stage3 endpoint: {0}' -f $Endpoint) }
            }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'keeps entra-governance opt-in while accepting it as a Graph-backed section' {
        $defaults = @(Resolve-CollectorSections)
        if ($defaults -contains 'entra-governance') {
            throw 'Entra governance must remain opt-in so the legacy default permission contract does not silently expand.'
        }

        $resolved = @(Resolve-CollectorSections -Sections @('entra-governance'))
        if ($resolved.Count -ne 1 -or [string]$resolved[0] -ne 'entra-governance') {
            throw 'Expected entra-governance to resolve as a supported section.'
        }

        { Start-CollectorRun -GraphToken '' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-governance') } | Should -Throw '*GraphToken is required*entra-governance*'
    }

    It 'collects administrative boundaries and active role governance with explicit scope domains' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-governance') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $result.status | Should -Be 'Completed'

        foreach ($family in @('administrativeUnits', 'roleDefinitions', 'roleAssignments')) {
            Test-Path -LiteralPath (Join-Path $result.runPath ('stage1/entra-governance/{0}/batch-0001.json' -f $family)) -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $result.runPath ('stage2/entra-governance/{0}/batch-0001.json' -f $family)) -PathType Leaf | Should -BeTrue
        }
        foreach ($family in @('administrativeUnitMembers', 'administrativeUnitScopedRoleMembers', 'activeRoleAssignmentEdges')) {
            Test-Path -LiteralPath (Join-Path $result.runPath ('stage3/entra-governance/{0}/batch-0001.json' -f $family)) -PathType Leaf | Should -BeTrue
        }

        $roleDetail = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/entra-governance/roleDefinitions/batch-0001.json') -Raw | ConvertFrom-Json
        $roleDetail.apiVersion | Should -Be 'v1.0'
        [bool]$roleDetail.isBeta | Should -BeFalse
        [string]$roleDetail.items[0].id | Should -Be 'role-def-1'

        $memberSnapshot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/entra-governance/administrativeUnitMembers/batch-0001.json') -Raw | ConvertFrom-Json
        [string]$memberSnapshot.items[0].parentId | Should -Be 'au-1'
        [string]$memberSnapshot.items[0].relationships[0].id | Should -Be 'group-1'

        $scopedSnapshot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/entra-governance/administrativeUnitScopedRoleMembers/batch-0001.json') -Raw | ConvertFrom-Json
        [string]$scopedSnapshot.items[0].relationships[0].roleId | Should -Be 'directory-role-1'
        [string]$scopedSnapshot.items[0].relationships[0].roleMemberInfo.id | Should -Be 'user-1'

        $edgeSnapshot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/entra-governance/activeRoleAssignmentEdges/batch-0001.json') -Raw | ConvertFrom-Json
        $edges = @($edgeSnapshot.items)
        $tenantEdge = @($edges | Where-Object { $_.assignmentId -eq 'assign-tenant' })[0]
        $tenantEdge.scopeType | Should -Be 'tenant'
        $tenantEdge.scopeIdentityDomain | Should -Be 'entra.tenant'
        $tenantEdge.roleDefinitionIdentityDomain | Should -Be 'entra.directory-role-definition'
        $tenantEdge.principalIdentityDomain | Should -Be 'entra.directory-object'

        $auEdge = @($edges | Where-Object { $_.assignmentId -eq 'assign-au' })[0]
        $auEdge.scopeType | Should -Be 'administrative-unit'
        $auEdge.scopeId | Should -Be 'au-1'
        $auEdge.scopeIdentityDomain | Should -Be 'entra.administrative-unit'

        $objectEdge = @($edges | Where-Object { $_.assignmentId -eq 'assign-app' })[0]
        $objectEdge.scopeType | Should -Be 'directory-object'
        $objectEdge.scopeId | Should -Be 'app-object-1'
        $objectEdge.scopeIdentityDomain | Should -Be 'entra.directory-object'

        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw | ConvertFrom-Json
        @($manifest.checkpointSummary | Where-Object { $_.section -eq 'entra-governance' }).Count | Should -Be 9
    }

    It 'emits governance catalog dependencies and relationship identity domains' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-governance') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0

        Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop
        $catalogResult = Collector.Storage.Catalog\Export-CollectorKnowledgeCatalog -RunPath $result.runPath -ExpectedRunId $result.runId
        $catalog = Get-Content -LiteralPath $catalogResult.catalogPath -Raw | ConvertFrom-Json

        @($catalog.artifacts | Where-Object { $_.section -eq 'entra-governance' }).Count | Should -Be 9
        @($catalog.dependencies | Where-Object { $_.consumer.section -eq 'entra-governance' }).Count | Should -Be 6
        @($catalog.relationships | Where-Object { $_.section -eq 'entra-governance' }).Count | Should -Be 3

        $activeRelationship = @($catalog.relationships | Where-Object { $_.section -eq 'entra-governance' -and $_.family -eq 'activeRoleAssignmentEdges' })[0]
        $activeRelationship.relationshipType | Should -Be 'role-governance'
        @($activeRelationship.targetIdentityDomains) | Should -Contain 'entra.directory-role-definition'
        @($activeRelationship.targetIdentityDomains) | Should -Contain 'entra.administrative-unit'
        @($activeRelationship.targetIdentityDomains) | Should -Contain 'entra.tenant'
    }

    It 'preserves zero-item and resume behavior without inventing governance relationships' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith { @() }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith { throw 'Stage2 must not call Graph when governance inventory is empty.' }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith { throw 'Stage3 must not call Graph when administrative-unit inventory is empty.' }

        $initial = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-governance') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $initial.status | Should -Be 'Completed'

        foreach ($family in @('administrativeUnits', 'roleDefinitions', 'roleAssignments')) {
            $snapshot = Get-Content -LiteralPath (Join-Path $initial.runPath ('stage1/entra-governance/{0}/batch-0001.json' -f $family)) -Raw | ConvertFrom-Json
            [int]$snapshot.itemCount | Should -Be 0
            @($snapshot.items).Count | Should -Be 0
        }
        foreach ($family in @('administrativeUnitMembers', 'administrativeUnitScopedRoleMembers', 'activeRoleAssignmentEdges')) {
            $snapshot = Get-Content -LiteralPath (Join-Path $initial.runPath ('stage3/entra-governance/{0}/batch-0001.json' -f $family)) -Raw | ConvertFrom-Json
            [int]$snapshot.itemCount | Should -Be 0
        }
        Assert-MockCalled -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -Times 0 -Exactly
        Assert-MockCalled -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -Times 0 -Exactly

        $resumed = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-governance') -Resume -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $resumed.runId | Should -Be $initial.runId
        $resumed.status | Should -Be 'Completed'
    }

    It 'does not replace the existing PIM schedule representation' {
        $defaults = @(Resolve-CollectorSections)
        $defaults | Should -Contain 'entra-pim'
        $defaults | Should -Not -Contain 'entra-governance'

        $pimSource = Get-Content -LiteralPath (Join-Path $moduleRoot 'Collector.Stage1.Inventory.psm1') -Raw
        $pimSource | Should -Match 'roleAssignmentScheduleInstances'
        $pimSource | Should -Match 'roleEligibilityScheduleInstances'
        $pimSource | Should -Not -Match "entra-governance.*roleAssignmentScheduleInstances"
    }
}
