Set-StrictMode -Version Latest

$stage1ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1'
$stage2ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1'
$stage3ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1'

function Get-CollectorIntuneConfigurationModule {
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
        throw ('Intune configuration collection could not load module {0}.' -f $Name)
    }
    return $imported[0]
}

$script:CollectorIntuneConfigurationStage1Module = Get-CollectorIntuneConfigurationModule -Name 'Collector.Stage1.Inventory' -Path $stage1ModulePath
$script:CollectorIntuneConfigurationStage2Module = Get-CollectorIntuneConfigurationModule -Name 'Collector.Stage2.Details' -Path $stage2ModulePath
$script:CollectorIntuneConfigurationStage3Module = Get-CollectorIntuneConfigurationModule -Name 'Collector.Stage3.Relationships' -Path $stage3ModulePath

function Get-CollectorIntuneConfigurationProperty {
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

function Test-CollectorIntuneConfigurationPolicyAdmission {
    [CmdletBinding()]
    param([AllowNull()][object]$Policy)

    $templateReference = Get-CollectorIntuneConfigurationProperty -InputObject $Policy -Name 'templateReference'
    $templateFamily = [string](Get-CollectorIntuneConfigurationProperty -InputObject $templateReference -Name 'templateFamily')
    return @('none', 'deviceConfigurationPolicies') -ccontains $templateFamily
}

function ConvertTo-CollectorIntuneConfigurationAssignment {
    [CmdletBinding()]
    param([AllowNull()][object]$Assignment)

    $assignmentId = [string](Get-CollectorIntuneConfigurationProperty -InputObject $Assignment -Name 'id')
    $source = [string](Get-CollectorIntuneConfigurationProperty -InputObject $Assignment -Name 'source')
    $sourceId = [string](Get-CollectorIntuneConfigurationProperty -InputObject $Assignment -Name 'sourceId')
    $intent = [string](Get-CollectorIntuneConfigurationProperty -InputObject $Assignment -Name 'intent')
    $target = Get-CollectorIntuneConfigurationProperty -InputObject $Assignment -Name 'target'
    $odataType = [string](Get-CollectorIntuneConfigurationProperty -InputObject $target -Name '@odata.type')
    $groupId = [string](Get-CollectorIntuneConfigurationProperty -InputObject $target -Name 'groupId')
    $entraObjectId = [string](Get-CollectorIntuneConfigurationProperty -InputObject $target -Name 'entraObjectId')
    $organizationalUnitId = [string](Get-CollectorIntuneConfigurationProperty -InputObject $target -Name 'organizationalUnitId')
    $targetType = [string](Get-CollectorIntuneConfigurationProperty -InputObject $target -Name 'targetType')
    $filterId = [string](Get-CollectorIntuneConfigurationProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterId')
    $filterType = [string](Get-CollectorIntuneConfigurationProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterType')

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

    return [pscustomobject][ordered]@{
        assignmentId = if ([string]::IsNullOrWhiteSpace($assignmentId)) { $null } else { $assignmentId }
        source = if ([string]::IsNullOrWhiteSpace($source)) { $null } else { $source }
        sourceId = if ([string]::IsNullOrWhiteSpace($sourceId)) { $null } else { $sourceId }
        intent = if ([string]::IsNullOrWhiteSpace($intent)) { $null } else { $intent }
        targetOdataType = if ([string]::IsNullOrWhiteSpace($odataType)) { $null } else { $odataType }
        targetType = if ([string]::IsNullOrWhiteSpace($targetType)) { $null } else { $targetType }
        targetId = $targetId
        targetIdentityDomain = $targetIdentityDomain
        assignmentFilterId = if ([string]::IsNullOrWhiteSpace($filterId)) { $null } else { $filterId }
        assignmentFilterType = if ([string]::IsNullOrWhiteSpace($filterType)) { $null } else { $filterType }
        assignmentFilterIdentityDomain = if ([string]::IsNullOrWhiteSpace($filterId)) { $null } else { 'intune.assignment-filter' }
    }
}

function Invoke-CollectorIntuneConfigurationStage1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $policyRunner = {
        param($InnerContext)
        $admissionTest = $args[0]
        $endpoint = '/beta/deviceManagement/configurationPolicies'
        $requestContext = @{
            endpoint = $endpoint
            method = 'GET'
            admittedTemplateFamilies = @('none', 'deviceConfigurationPolicies')
            excludedTemplateFamiliesOwnedByOtherSlices = @('endpointSecurity*', 'baseline', 'enrollmentConfiguration', 'deviceConfigurationScripts', 'windowsOsRecoveryPolicies', 'companyPortal', 'appQuietTime', 'unknownFutureValue')
        }
        Invoke-CollectorStage1Family -Context $InnerContext -Section 'intune-core' -Family 'configurationPolicies' -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpoint) -ApiVersion 'beta' -IsBeta:$true -RequestContext $requestContext -CollectScript {
            $policies = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $endpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
            @($policies | Where-Object { & $admissionTest $_ })
        }
    }

    $results = @($script:CollectorIntuneConfigurationStage1Module.Invoke($policyRunner, [object[]]@($Context, ${function:Test-CollectorIntuneConfigurationPolicyAdmission})))
    $classicRunner = {
        param($InnerContext)
        Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceConfigurations' -Endpoint '/v1.0/deviceManagement/deviceConfigurations'
    }
    $results += @($script:CollectorIntuneConfigurationStage1Module.Invoke($classicRunner, [object[]]@($Context)))
    return @($results)
}

function Invoke-CollectorIntuneConfigurationSettingsStage2 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)

        $section = 'intune-core'
        $family = 'configurationPolicySettings'
        $dependencyFamily = 'configurationPolicies'
        $endpointTemplate = '/beta/deviceManagement/configurationPolicies/{id}/settings'
        Assert-CollectorInventoryFirstForStage2 -RunPath $InnerContext.RunPath -Section $section -Family $dependencyFamily -RunId $InnerContext.RunId

        $checkpoint = Get-CollectorCheckpoint -RunPath $InnerContext.RunPath -RunId $InnerContext.RunId -Stage 'stage2' -Section $section -Family $family
        $result = Get-CollectorFamilyResult -Stage 'stage2' -Section $section -Family $family
        $inventoryItems = @(Get-CollectorSnapshotItems -RunPath $InnerContext.RunPath -Stage 'stage1' -Section $section -Family $dependencyFamily -ExpectedRunId $InnerContext.RunId)
        $batches = Split-CollectorItems -Items $inventoryItems -BatchSize $InnerContext.BatchSize
        if ($batches.Count -eq 0) { $batches = @(@()) }

        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize $InnerContext.BatchSize -Resume:$InnerContext.Resume
        Save-CollectorCheckpoint -RunPath $InnerContext.RunPath -Checkpoint $checkpoint | Out-Null
        $result.batchCount = $batches.Count
        $batchNumber = 0

        foreach ($batch in $batches) {
            $batchNumber++
            $batchId = '{0:D4}' -f $batchNumber
            $batchItems = @($batch)
            $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId

            if ($InnerContext.Resume -and $existingBatch -and [string]$existingBatch.status -eq 'Succeeded' -and -not [string]::IsNullOrWhiteSpace([string]$existingBatch.artifactPath) -and (Test-Path -LiteralPath $existingBatch.artifactPath -PathType Leaf) -and -not (Test-CollectorStage2ResumeArtifact -Context $InnerContext -Section $section -Family $family -BatchId $batchId -CheckpointBatch $existingBatch -ExpectedItemCount $batchItems.Count)) {
                $attempts = [int]$existingBatch.attempts
                $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount $batchItems.Count -SuccessCount 0 -FailedCount $batchItems.Count -ArtifactPath $existingBatch.artifactPath -Error 'Previously successful Stage2 settings artifact failed resume validation and will be reprocessed.'
                Save-CollectorCheckpoint -RunPath $InnerContext.RunPath -Checkpoint $checkpoint | Out-Null
            }

            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId $batchId -Resume:$InnerContext.Resume -ReprocessFailedOnly:$InnerContext.ReprocessFailedOnly
            if ($decision.MarkMissing) {
                $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
                $attempts = if ($existingBatch) { [int]$existingBatch.attempts } else { 0 }
                $itemCount = if ($existingBatch) { [int]$existingBatch.itemCount } else { 0 }
                $artifactPath = if ($existingBatch) { $existingBatch.artifactPath } else { $null }
                $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Missing' -Attempts $attempts -ItemCount $itemCount -SuccessCount 0 -FailedCount $itemCount -ArtifactPath $artifactPath -Error 'Artifact path from previous success is missing.'
                Save-CollectorCheckpoint -RunPath $InnerContext.RunPath -Checkpoint $checkpoint | Out-Null
            }
            if (-not $decision.ShouldProcess) {
                $result.skippedBatches++
                $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
                if ($existingBatch) { $result.itemCount += [int]$existingBatch.itemCount }
                continue
            }

            $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
            $attempts = if ($existingBatch) { [int]$existingBatch.attempts + 1 } else { 1 }
            $existingArtifactPath = if ($existingBatch) { $existingBatch.artifactPath } else { $null }
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'InProgress' -Attempts $attempts -ItemCount $batchItems.Count -SuccessCount 0 -FailedCount 0 -ArtifactPath $existingArtifactPath -Error $null
            Save-CollectorCheckpoint -RunPath $InnerContext.RunPath -Checkpoint $checkpoint | Out-Null

            $details = @()
            $failedCount = 0
            $errors = @()
            foreach ($inventoryItem in $batchItems) {
                $policyId = Get-CollectorObjectId -Item $inventoryItem
                if (-not $policyId) {
                    $failedCount++
                    $errors += 'Unable to resolve policy id from Stage1 configurationPolicies inventory item.'
                    $details += [pscustomobject]@{ policyId = $null; _collectorError = 'Unable to resolve policy id from Stage1 configurationPolicies inventory item.' }
                    continue
                }
                $endpoint = $endpointTemplate.Replace('{id}', $policyId)
                try {
                    $settings = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $endpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
                    $details += [pscustomobject][ordered]@{ policyId = $policyId; settingCount = $settings.Count; settings = @($settings) }
                }
                catch {
                    $failedCount++
                    $errors += $_.Exception.Message
                    $details += [pscustomobject]@{ policyId = $policyId; _collectorError = $_.Exception.Message }
                }
            }

            $status = if ($failedCount -eq 0) { 'Succeeded' } else { 'Failed' }
            try {
                $snapshot = New-CollectorProvenanceSnapshot -RunId $InnerContext.RunId -Stage 'stage2' -Section $section -Family $family -BatchId $batchId -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpointTemplate) -ApiVersion 'beta' -IsBeta:$true -RequestContext @{ endpointTemplate = $endpointTemplate; method = 'GET'; inventoryStage = 'stage1'; dependencyFamily = $dependencyFamily; paging = $true; responseShape = 'one-wrapper-per-policy' } -ItemCount $details.Count -Items $details
                $artifact = Write-CollectorSnapshotArtifact -RunPath $InnerContext.RunPath -Stage 'stage2' -Section $section -Family $family -BatchNumber $batchNumber -Snapshot $snapshot
                $successCount = [Math]::Max(0, $details.Count - $failedCount)
                $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status $status -Attempts $attempts -ItemCount $details.Count -SuccessCount $successCount -FailedCount $failedCount -ArtifactPath $artifact.artifactPath -Error (($errors -join '; ').Trim())
                Save-CollectorCheckpoint -RunPath $InnerContext.RunPath -Checkpoint $checkpoint | Out-Null
                if ($status -eq 'Succeeded') { $result.succeededBatches++ } else { $result.failedBatches++; $result.errors += $errors }
                $result.itemCount += $details.Count
            }
            catch {
                $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount $details.Count -SuccessCount 0 -FailedCount ([Math]::Max(1, $failedCount)) -ArtifactPath $existingArtifactPath -Error $_.Exception.Message
                Save-CollectorCheckpoint -RunPath $InnerContext.RunPath -Checkpoint $checkpoint | Out-Null
                $result.failedBatches++
                $result.itemCount += $details.Count
                $result.errors += $_.Exception.Message
            }
        }

        $checkpoint = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint
        Save-CollectorCheckpoint -RunPath $InnerContext.RunPath -Checkpoint $checkpoint | Out-Null
        return Publish-CollectorStage2Result -Context $InnerContext -Result $result
    }

    return @($script:CollectorIntuneConfigurationStage2Module.Invoke($runner, [object[]]@($Context)))
}

function Invoke-CollectorIntuneConfigurationStage2 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'configurationPolicies' -EndpointTemplate '/beta/deviceManagement/configurationPolicies/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceConfigurations' -EndpointTemplate '/v1.0/deviceManagement/deviceConfigurations/{id}')
        )
    }
    $results = @($script:CollectorIntuneConfigurationStage2Module.Invoke($runner, [object[]]@($Context)))
    $results += @(Invoke-CollectorIntuneConfigurationSettingsStage2 -Context $Context)
    return @($results)
}

function Invoke-CollectorIntuneConfigurationStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $transform = {
        param($InnerAssignment)
        ConvertTo-CollectorIntuneConfigurationAssignment -Assignment $InnerAssignment
    }
    $runner = {
        param($InnerContext, $InnerTransform)
        @(
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'intune-core' -Family 'configurationPolicyAssignments' -DependencyFamily 'configurationPolicies' -EndpointTemplate '/beta/deviceManagement/configurationPolicies/{id}/assignments' -RelationshipTransform $InnerTransform)
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'intune-core' -Family 'deviceConfigurationAssignments' -DependencyFamily 'deviceConfigurations' -EndpointTemplate '/beta/deviceManagement/deviceConfigurations/{id}/assignments' -RelationshipTransform $InnerTransform)
        )
    }
    return @($script:CollectorIntuneConfigurationStage3Module.Invoke($runner, [object[]]@($Context, $transform)))
}

Export-ModuleMember -Function @(
    'Invoke-CollectorIntuneConfigurationStage1',
    'Invoke-CollectorIntuneConfigurationStage2',
    'Invoke-CollectorIntuneConfigurationStage3'
)
