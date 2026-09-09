Set-StrictMode -Version Latest

$stage1ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1'
$stage2ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1'
$stage3ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1'

function Get-CollectorIntuneEnrollmentModule {
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
        throw ('Intune enrollment collection could not load module {0}.' -f $Name)
    }
    return $imported[0]
}

$script:CollectorIntuneEnrollmentStage1Module = Get-CollectorIntuneEnrollmentModule -Name 'Collector.Stage1.Inventory' -Path $stage1ModulePath
$script:CollectorIntuneEnrollmentStage2Module = Get-CollectorIntuneEnrollmentModule -Name 'Collector.Stage2.Details' -Path $stage2ModulePath
$script:CollectorIntuneEnrollmentStage3Module = Get-CollectorIntuneEnrollmentModule -Name 'Collector.Stage3.Relationships' -Path $stage3ModulePath

function Get-CollectorIntuneEnrollmentProperty {
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

function ConvertTo-CollectorIntuneEnrollmentAssignment {
    [CmdletBinding()]
    param([AllowNull()][object]$Assignment)

    $assignmentId = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $Assignment -Name 'id')
    $source = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $Assignment -Name 'source')
    $sourceId = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $Assignment -Name 'sourceId')
    $target = Get-CollectorIntuneEnrollmentProperty -InputObject $Assignment -Name 'target'
    $odataType = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name '@odata.type')
    $groupId = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name 'groupId')
    $entraObjectId = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name 'entraObjectId')
    $organizationalUnitId = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name 'organizationalUnitId')
    $collectionId = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name 'collectionId')
    $targetType = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name 'targetType')
    $filterId = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterId')
    $filterType = [string](Get-CollectorIntuneEnrollmentProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterType')

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
    elseif (-not [string]::IsNullOrWhiteSpace($collectionId)) {
        $targetId = $collectionId
    }
    elseif (-not [string]::IsNullOrWhiteSpace($odataType)) {
        $targetId = $odataType.TrimStart('#')
    }

    return [pscustomobject][ordered]@{
        assignmentId = if ([string]::IsNullOrWhiteSpace($assignmentId)) { $null } else { $assignmentId }
        source = if ([string]::IsNullOrWhiteSpace($source)) { $null } else { $source }
        sourceId = if ([string]::IsNullOrWhiteSpace($sourceId)) { $null } else { $sourceId }
        targetOdataType = if ([string]::IsNullOrWhiteSpace($odataType)) { $null } else { $odataType }
        targetType = if ([string]::IsNullOrWhiteSpace($targetType)) { $null } else { $targetType }
        targetId = $targetId
        targetIdentityDomain = $targetIdentityDomain
        collectionId = if ([string]::IsNullOrWhiteSpace($collectionId)) { $null } else { $collectionId }
        assignmentFilterId = if ([string]::IsNullOrWhiteSpace($filterId)) { $null } else { $filterId }
        assignmentFilterType = if ([string]::IsNullOrWhiteSpace($filterType)) { $null } else { $filterType }
        assignmentFilterIdentityDomain = if ([string]::IsNullOrWhiteSpace($filterId)) { $null } else { 'intune.assignment-filter' }
    }
}

function Invoke-CollectorIntuneEnrollmentStage1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceEnrollmentConfigurations' -Endpoint '/v1.0/deviceManagement/deviceEnrollmentConfigurations'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'intune-core' -Family 'windowsAutopilotDeploymentProfiles' -Endpoint '/beta/deviceManagement/windowsAutopilotDeploymentProfiles'
        )
    }
    return @($script:CollectorIntuneEnrollmentStage1Module.Invoke($runner, [object[]]@($Context)))
}

function Invoke-CollectorIntuneEnrollmentStage2 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceEnrollmentConfigurations' -EndpointTemplate '/v1.0/deviceManagement/deviceEnrollmentConfigurations/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'windowsAutopilotDeploymentProfiles' -EndpointTemplate '/beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}')
        )
    }
    return @($script:CollectorIntuneEnrollmentStage2Module.Invoke($runner, [object[]]@($Context)))
}

function Invoke-CollectorIntuneEnrollmentStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $transform = {
        param($InnerAssignment)
        ConvertTo-CollectorIntuneEnrollmentAssignment -Assignment $InnerAssignment
    }
    $runner = {
        param($InnerContext, $InnerTransform)
        @(
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceEnrollmentConfigurationAssignments' -DependencyFamily 'deviceEnrollmentConfigurations' -EndpointTemplate '/v1.0/deviceManagement/deviceEnrollmentConfigurations/{id}/assignments' -RelationshipTransform $InnerTransform)
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'intune-core' -Family 'windowsAutopilotDeploymentProfileAssignments' -DependencyFamily 'windowsAutopilotDeploymentProfiles' -EndpointTemplate '/beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assignments' -RelationshipTransform $InnerTransform)
        )
    }
    return @($script:CollectorIntuneEnrollmentStage3Module.Invoke($runner, [object[]]@($Context, $transform)))
}

Export-ModuleMember -Function @(
    'Invoke-CollectorIntuneEnrollmentStage1',
    'Invoke-CollectorIntuneEnrollmentStage2',
    'Invoke-CollectorIntuneEnrollmentStage3'
)
