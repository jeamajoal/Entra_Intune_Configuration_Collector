Set-StrictMode -Version Latest

$stage1ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1'
$stage2ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1'
$stage3ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1'
$artifactModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1'

function Get-CollectorEntraGovernanceModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $loaded = @(Get-Module -Name $Name | Where-Object { $_.Path -and [System.IO.Path]::GetFullPath($_.Path) -eq $fullPath })
    if ($loaded.Count -gt 0) {
        return $loaded[0]
    }

    $imported = @(Import-Module -Name $fullPath -PassThru -ErrorAction Stop)
    if ($imported.Count -lt 1) {
        throw ('Entra governance collection could not load module {0}.' -f $Name)
    }
    return $imported[0]
}

$script:CollectorEntraGovernanceStage1Module = Get-CollectorEntraGovernanceModule -Name 'Collector.Stage1.Inventory' -Path $stage1ModulePath
$script:CollectorEntraGovernanceStage2Module = Get-CollectorEntraGovernanceModule -Name 'Collector.Stage2.Details' -Path $stage2ModulePath
$script:CollectorEntraGovernanceStage3Module = Get-CollectorEntraGovernanceModule -Name 'Collector.Stage3.Relationships' -Path $stage3ModulePath
$script:CollectorEntraGovernanceArtifactModule = Get-CollectorEntraGovernanceModule -Name 'Collector.Storage.Artifacts' -Path $artifactModulePath

function Get-CollectorEntraGovernanceProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject -or $InputObject.PSObject.Properties.Match($Name).Count -eq 0) {
        return $null
    }
    return $InputObject.$Name
}

function ConvertTo-CollectorActiveRoleAssignmentEdge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Assignment
    )

    $assignmentId = [string](Get-CollectorEntraGovernanceProperty -InputObject $Assignment -Name 'id')
    $principalId = [string](Get-CollectorEntraGovernanceProperty -InputObject $Assignment -Name 'principalId')
    $roleDefinitionId = [string](Get-CollectorEntraGovernanceProperty -InputObject $Assignment -Name 'roleDefinitionId')
    $directoryScopeId = [string](Get-CollectorEntraGovernanceProperty -InputObject $Assignment -Name 'directoryScopeId')
    $appScopeId = [string](Get-CollectorEntraGovernanceProperty -InputObject $Assignment -Name 'appScopeId')

    foreach ($required in @(
        @{ Name = 'id'; Value = $assignmentId },
        @{ Name = 'principalId'; Value = $principalId },
        @{ Name = 'roleDefinitionId'; Value = $roleDefinitionId }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
            throw ('Active role assignment edge derivation requires non-empty {0}.' -f $required.Name)
        }
    }

    $scopeType = $null
    $scopeId = $null
    $scopeIdentityDomain = $null

    if (-not [string]::IsNullOrWhiteSpace($appScopeId)) {
        $scopeType = 'app-scope'
        $scopeId = $appScopeId
        $scopeIdentityDomain = 'entra.app-scope'
    }
    elseif ($directoryScopeId -eq '/') {
        $scopeType = 'tenant'
        $scopeId = '/'
        $scopeIdentityDomain = 'entra.tenant'
    }
    elseif ($directoryScopeId -match '^/administrativeUnits/([^/]+)$') {
        $scopeType = 'administrative-unit'
        $scopeId = [string]$Matches[1]
        $scopeIdentityDomain = 'entra.administrative-unit'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($directoryScopeId) -and $directoryScopeId.StartsWith('/')) {
        $scopeType = 'directory-object'
        $scopeId = $directoryScopeId.TrimStart('/')
        $scopeIdentityDomain = 'entra.directory-object'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($directoryScopeId)) {
        $scopeType = 'directory-scope'
        $scopeId = $directoryScopeId
        $scopeIdentityDomain = 'entra.directory-scope'
    }
    else {
        throw ('Active role assignment {0} has neither directoryScopeId nor appScopeId.' -f $assignmentId)
    }

    return [pscustomobject][ordered]@{
        assignmentId = $assignmentId
        principalId = $principalId
        principalIdentityDomain = 'entra.directory-object'
        roleDefinitionId = $roleDefinitionId
        roleDefinitionIdentityDomain = 'entra.directory-role-definition'
        directoryScopeId = if ([string]::IsNullOrWhiteSpace($directoryScopeId)) { $null } else { $directoryScopeId }
        appScopeId = if ([string]::IsNullOrWhiteSpace($appScopeId)) { $null } else { $appScopeId }
        scopeType = $scopeType
        scopeId = $scopeId
        scopeIdentityDomain = $scopeIdentityDomain
    }
}

function Invoke-CollectorEntraGovernanceStage1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-governance' -Family 'administrativeUnits' -Endpoint '/v1.0/directory/administrativeUnits'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-governance' -Family 'directoryRoles' -Endpoint '/v1.0/directoryRoles'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-governance' -Family 'roleDefinitions' -Endpoint '/v1.0/roleManagement/directory/roleDefinitions'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-governance' -Family 'roleAssignments' -Endpoint '/v1.0/roleManagement/directory/roleAssignments'
        )
    }
    return @($script:CollectorEntraGovernanceStage1Module.Invoke($runner, [object[]]@($Context)))
}

function Invoke-CollectorEntraGovernanceStage2 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-governance' -Family 'administrativeUnits' -EndpointTemplate '/v1.0/directory/administrativeUnits/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-governance' -Family 'directoryRoles' -EndpointTemplate '/v1.0/directoryRoles/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-governance' -Family 'roleDefinitions' -EndpointTemplate '/v1.0/roleManagement/directory/roleDefinitions/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-governance' -Family 'roleAssignments' -EndpointTemplate '/v1.0/roleManagement/directory/roleAssignments/{id}')
        )
    }
    return @($script:CollectorEntraGovernanceStage2Module.Invoke($runner, [object[]]@($Context)))
}

function Invoke-CollectorEntraGovernanceStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $relationshipRunner = {
        param($InnerContext)
        @(
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'entra-governance' -Family 'administrativeUnitMembers' -DependencyFamily 'administrativeUnits' -EndpointTemplate '/v1.0/directory/administrativeUnits/{id}/members')
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'entra-governance' -Family 'administrativeUnitScopedRoleMembers' -DependencyFamily 'administrativeUnits' -EndpointTemplate '/v1.0/directory/administrativeUnits/{id}/scopedRoleMembers')
        )
    }
    $results = @($script:CollectorEntraGovernanceStage3Module.Invoke($relationshipRunner, [object[]]@($Context)))

    $readinessCheck = {
        param($InnerRunPath, $InnerRunId)
        Assert-CollectorInventoryFirstForStage3 -RunPath $InnerRunPath -Section 'entra-governance' -Families @('roleAssignments') -RunId $InnerRunId
    }
    $script:CollectorEntraGovernanceStage3Module.Invoke($readinessCheck, [object[]]@($Context.RunPath, $Context.RunId)) | Out-Null

    $inventoryReader = {
        param($InnerRunPath, $InnerRunId)
        return @(Get-CollectorSnapshotItems -RunPath $InnerRunPath -Stage 'stage1' -Section 'entra-governance' -Family 'roleAssignments' -ExpectedRunId $InnerRunId)
    }
    $assignments = @($script:CollectorEntraGovernanceArtifactModule.Invoke($inventoryReader, [object[]]@($Context.RunPath, $Context.RunId)))

    $batchCollector = {
        param([object[]]$batchItems)

        $items = @()
        $failedCount = 0
        $errors = @()
        foreach ($assignment in $batchItems) {
            try {
                if ($null -eq $assignment) {
                    throw 'Active role assignment edge derivation cannot process a null assignment.'
                }
                $items += ConvertTo-CollectorActiveRoleAssignmentEdge -Assignment $assignment
            }
            catch {
                $failedCount++
                $message = $_.Exception.Message
                $errors += $message
                $assignmentId = $null
                if ($null -ne $assignment -and $assignment.PSObject.Properties.Match('id').Count -gt 0) {
                    $assignmentId = [string]$assignment.id
                }
                $items += [pscustomobject]@{
                    assignmentId = $assignmentId
                    _collectorError = $message
                }
            }
        }

        [pscustomobject]@{
            Items = @($items)
            FailedCount = $failedCount
            Errors = @($errors)
        }
    }

    $edgeRunner = {
        param($InnerContext, $InnerAssignments, $InnerBatchCollector)
        $batches = Split-CollectorItems -Items @($InnerAssignments) -BatchSize $InnerContext.BatchSize
        $result = Invoke-CollectorStage3BatchLoop -Context $InnerContext -Section 'entra-governance' -Family 'activeRoleAssignmentEdges' -Batches $batches -SourceType 'Derived' -SourceName 'Derived active role assignment edges from Stage1 role assignment inventory' -ApiVersion 'v1.0' -IsBeta:$false -RequestContext @{ dependencyFamily = 'roleAssignments'; transform = 'role-assignment-to-edge' } -BatchCollector $InnerBatchCollector
        return Publish-CollectorStage3Result -Context $InnerContext -Result $result
    }
    $results += @($script:CollectorEntraGovernanceStage3Module.Invoke($edgeRunner, [object[]]@($Context, $assignments, $batchCollector)))

    return @($results)
}

Export-ModuleMember -Function @(
    'Invoke-CollectorEntraGovernanceStage1',
    'Invoke-CollectorEntraGovernanceStage2',
    'Invoke-CollectorEntraGovernanceStage3'
)
