Set-StrictMode -Version Latest

$stage1ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1'
$stage2ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1'
$stage3ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1'
$configurationModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage.IntuneConfiguration.psm1'
$securityModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage.IntuneSecurity.psm1'

function Get-CollectorIntuneComplianceModule {
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
        throw ('Intune compliance collection could not load module {0}.' -f $Name)
    }
    return $imported[0]
}

$script:CollectorIntuneComplianceStage1Module = Get-CollectorIntuneComplianceModule -Name 'Collector.Stage1.Inventory' -Path $stage1ModulePath
$script:CollectorIntuneComplianceStage2Module = Get-CollectorIntuneComplianceModule -Name 'Collector.Stage2.Details' -Path $stage2ModulePath
$script:CollectorIntuneComplianceStage3Module = Get-CollectorIntuneComplianceModule -Name 'Collector.Stage3.Relationships' -Path $stage3ModulePath
Import-Module -Name $configurationModulePath -Force -ErrorAction Stop
Import-Module -Name $securityModulePath -Force -ErrorAction Stop

function Get-CollectorIntuneComplianceProperty {
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

function ConvertTo-CollectorDeviceCompliancePolicyAssignment {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Assignment
    )

    $assignmentId = [string](Get-CollectorIntuneComplianceProperty -InputObject $Assignment -Name 'id')
    $source = [string](Get-CollectorIntuneComplianceProperty -InputObject $Assignment -Name 'source')
    $sourceId = [string](Get-CollectorIntuneComplianceProperty -InputObject $Assignment -Name 'sourceId')
    $target = Get-CollectorIntuneComplianceProperty -InputObject $Assignment -Name 'target'
    $odataType = [string](Get-CollectorIntuneComplianceProperty -InputObject $target -Name '@odata.type')
    $groupId = [string](Get-CollectorIntuneComplianceProperty -InputObject $target -Name 'groupId')
    $entraObjectId = [string](Get-CollectorIntuneComplianceProperty -InputObject $target -Name 'entraObjectId')
    $organizationalUnitId = [string](Get-CollectorIntuneComplianceProperty -InputObject $target -Name 'organizationalUnitId')
    $targetType = [string](Get-CollectorIntuneComplianceProperty -InputObject $target -Name 'targetType')
    $filterId = [string](Get-CollectorIntuneComplianceProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterId')
    $filterType = [string](Get-CollectorIntuneComplianceProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterType')

    $targetId = $null
    $targetIdentityDomain = 'intune.assignment-target'

    if (-not [string]::IsNullOrWhiteSpace($groupId)) {
        $targetId = $groupId
        $targetIdentityDomain = 'entra.group'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($entraObjectId)) {
        $targetId = $entraObjectId
        $targetIdentityDomain = 'entra.directory-object'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($organizationalUnitId)) {
        $targetId = $organizationalUnitId
    }
    elseif (-not [string]::IsNullOrWhiteSpace($odataType)) {
        $targetId = $odataType.TrimStart('#')
    }

    [pscustomobject][ordered]@{
        assignmentId = if ([string]::IsNullOrWhiteSpace($assignmentId)) { $null } else { $assignmentId }
        source = if ([string]::IsNullOrWhiteSpace($source)) { $null } else { $source }
        sourceId = if ([string]::IsNullOrWhiteSpace($sourceId)) { $null } else { $sourceId }
        targetOdataType = if ([string]::IsNullOrWhiteSpace($odataType)) { $null } else { $odataType }
        targetType = if ([string]::IsNullOrWhiteSpace($targetType)) { $null } else { $targetType }
        targetId = $targetId
        targetIdentityDomain = $targetIdentityDomain
        assignmentFilterId = if ([string]::IsNullOrWhiteSpace($filterId)) { $null } else { $filterId }
        assignmentFilterType = if ([string]::IsNullOrWhiteSpace($filterType)) { $null } else { $filterType }
        assignmentFilterIdentityDomain = if ([string]::IsNullOrWhiteSpace($filterId)) { $null } else { 'intune.assignment-filter' }
    }
}

function Invoke-CollectorIntuneComplianceStage1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceCompliancePolicies' -Endpoint '/v1.0/deviceManagement/deviceCompliancePolicies'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'intune-core' -Family 'assignmentFilters' -Endpoint '/beta/deviceManagement/assignmentFilters'
        )
    }
    $results = @($script:CollectorIntuneComplianceStage1Module.Invoke($runner, [object[]]@($Context)))
    $results += @(Invoke-CollectorIntuneConfigurationStage1 -Context $Context)
    $results += @(Invoke-CollectorIntuneSecurityStage1 -Context $Context)
    return @($results)
}

function Invoke-CollectorIntuneComplianceStage2 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceCompliancePolicies' -EndpointTemplate '/v1.0/deviceManagement/deviceCompliancePolicies/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'assignmentFilters' -EndpointTemplate '/beta/deviceManagement/assignmentFilters/{id}')
        )
    }
    $results = @($script:CollectorIntuneComplianceStage2Module.Invoke($runner, [object[]]@($Context)))
    $results += @(Invoke-CollectorIntuneConfigurationStage2 -Context $Context)
    $results += @(Invoke-CollectorIntuneSecurityStage2 -Context $Context)
    return @($results)
}

function Invoke-CollectorIntuneComplianceStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $assignmentTransform = {
        param($InnerAssignment)
        ConvertTo-CollectorDeviceCompliancePolicyAssignment -Assignment $InnerAssignment
    }

    $runner = {
        param($InnerContext, $InnerTransform)
        return Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceCompliancePolicyAssignments' -DependencyFamily 'deviceCompliancePolicies' -EndpointTemplate '/beta/deviceManagement/deviceCompliancePolicies/{id}/assignments' -RelationshipTransform $InnerTransform)
    }
    $results = @($script:CollectorIntuneComplianceStage3Module.Invoke($runner, [object[]]@($Context, $assignmentTransform)))
    $results += @(Invoke-CollectorIntuneConfigurationStage3 -Context $Context)
    $results += @(Invoke-CollectorIntuneSecurityStage3 -Context $Context)
    return @($results)
}

Export-ModuleMember -Function @(
    'Invoke-CollectorIntuneComplianceStage1',
    'Invoke-CollectorIntuneComplianceStage2',
    'Invoke-CollectorIntuneComplianceStage3'
)
