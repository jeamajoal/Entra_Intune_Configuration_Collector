Set-StrictMode -Version Latest

$stage1ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1'
$stage2ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1'
$stage3ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1'

$script:CollectorIntuneSecurityTemplateFamilies = @(
    'endpointSecurityAntivirus',
    'endpointSecurityDiskEncryption',
    'endpointSecurityFirewall',
    'endpointSecurityEndpointDetectionAndResponse',
    'endpointSecurityAttackSurfaceReduction',
    'endpointSecurityAccountProtection',
    'endpointSecurityApplicationControl',
    'endpointSecurityEndpointPrivilegeManagement',
    'baseline'
)

$script:CollectorIntuneSecurityLegacyTemplateTypes = @(
    'securityBaseline',
    'advancedThreatProtectionSecurityBaseline',
    'securityTemplate',
    'microsoftEdgeSecurityBaseline',
    'microsoftOffice365ProPlusSecurityBaseline',
    'cloudPC'
)

function Get-CollectorIntuneSecurityModule {
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
        throw ('Intune security collection could not load module {0}.' -f $Name)
    }
    return $imported[0]
}

$script:CollectorIntuneSecurityStage1Module = Get-CollectorIntuneSecurityModule -Name 'Collector.Stage1.Inventory' -Path $stage1ModulePath
$script:CollectorIntuneSecurityStage2Module = Get-CollectorIntuneSecurityModule -Name 'Collector.Stage2.Details' -Path $stage2ModulePath
$script:CollectorIntuneSecurityStage3Module = Get-CollectorIntuneSecurityModule -Name 'Collector.Stage3.Relationships' -Path $stage3ModulePath

function Get-CollectorIntuneSecurityProperty {
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

function Test-CollectorIntuneSecurityPolicyAdmission {
    [CmdletBinding()]
    param([AllowNull()][object]$Policy)

    $templateReference = Get-CollectorIntuneSecurityProperty -InputObject $Policy -Name 'templateReference'
    $templateFamily = [string](Get-CollectorIntuneSecurityProperty -InputObject $templateReference -Name 'templateFamily')
    return $script:CollectorIntuneSecurityTemplateFamilies -ccontains $templateFamily
}

function Test-CollectorIntuneSecurityConfigurationTemplateAdmission {
    [CmdletBinding()]
    param([AllowNull()][object]$Template)

    $templateFamily = [string](Get-CollectorIntuneSecurityProperty -InputObject $Template -Name 'templateFamily')
    return $script:CollectorIntuneSecurityTemplateFamilies -ccontains $templateFamily
}

function Test-CollectorIntuneSecurityLegacyTemplateAdmission {
    [CmdletBinding()]
    param([AllowNull()][object]$Template)

    $odataType = [string](Get-CollectorIntuneSecurityProperty -InputObject $Template -Name '@odata.type')
    if ($odataType -ceq '#microsoft.graph.securityBaselineTemplate') {
        return $true
    }

    $templateType = [string](Get-CollectorIntuneSecurityProperty -InputObject $Template -Name 'templateType')
    return $script:CollectorIntuneSecurityLegacyTemplateTypes -ccontains $templateType
}

function ConvertTo-CollectorIntuneSecurityAssignment {
    [CmdletBinding()]
    param([AllowNull()][object]$Assignment)

    $assignmentId = [string](Get-CollectorIntuneSecurityProperty -InputObject $Assignment -Name 'id')
    $source = [string](Get-CollectorIntuneSecurityProperty -InputObject $Assignment -Name 'source')
    $sourceId = [string](Get-CollectorIntuneSecurityProperty -InputObject $Assignment -Name 'sourceId')
    $intent = [string](Get-CollectorIntuneSecurityProperty -InputObject $Assignment -Name 'intent')
    $target = Get-CollectorIntuneSecurityProperty -InputObject $Assignment -Name 'target'
    $odataType = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name '@odata.type')
    $groupId = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name 'groupId')
    $entraObjectId = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name 'entraObjectId')
    $organizationalUnitId = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name 'organizationalUnitId')
    $collectionId = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name 'collectionId')
    $targetType = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name 'targetType')
    $filterId = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterId')
    $filterType = [string](Get-CollectorIntuneSecurityProperty -InputObject $target -Name 'deviceAndAppManagementAssignmentFilterType')

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
        intent = if ([string]::IsNullOrWhiteSpace($intent)) { $null } else { $intent }
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

function Invoke-CollectorIntuneSecurityStage1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $securityFamilies = @($script:CollectorIntuneSecurityTemplateFamilies)
    $legacyTypes = @($script:CollectorIntuneSecurityLegacyTemplateTypes)
    $policyAdmission = ${function:Test-CollectorIntuneSecurityPolicyAdmission}
    $configurationTemplateAdmission = ${function:Test-CollectorIntuneSecurityConfigurationTemplateAdmission}
    $legacyTemplateAdmission = ${function:Test-CollectorIntuneSecurityLegacyTemplateAdmission}

    $modernPolicyRunner = {
        param($InnerContext, $InnerAdmission, $InnerFamilies)
        $endpoint = '/beta/deviceManagement/configurationPolicies'
        Invoke-CollectorStage1Family -Context $InnerContext -Section 'intune-core' -Family 'securityConfigurationPolicies' -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpoint) -ApiVersion 'beta' -IsBeta:$true -RequestContext @{ endpoint = $endpoint; method = 'GET'; admittedTemplateFamilies = @($InnerFamilies); telemetryExcluded = $true } -CollectScript {
            $items = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $endpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
            @($items | Where-Object { & $InnerAdmission $_ })
        }
    }
    $results = @($script:CollectorIntuneSecurityStage1Module.Invoke($modernPolicyRunner, [object[]]@($Context, $policyAdmission, $securityFamilies)))

    $modernTemplateRunner = {
        param($InnerContext, $InnerAdmission, $InnerFamilies)
        $endpoint = '/beta/deviceManagement/configurationPolicyTemplates'
        Invoke-CollectorStage1Family -Context $InnerContext -Section 'intune-core' -Family 'securityConfigurationPolicyTemplates' -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpoint) -ApiVersion 'beta' -IsBeta:$true -RequestContext @{ endpoint = $endpoint; method = 'GET'; admittedTemplateFamilies = @($InnerFamilies); telemetryExcluded = $true } -CollectScript {
            $items = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $endpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
            @($items | Where-Object { & $InnerAdmission $_ })
        }
    }
    $results += @($script:CollectorIntuneSecurityStage1Module.Invoke($modernTemplateRunner, [object[]]@($Context, $configurationTemplateAdmission, $securityFamilies)))

    $legacyTemplateRunner = {
        param($InnerContext, $InnerAdmission, $InnerTypes)
        $endpoint = '/beta/deviceManagement/templates'
        Invoke-CollectorStage1Family -Context $InnerContext -Section 'intune-core' -Family 'securityBaselineTemplates' -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpoint) -ApiVersion 'beta' -IsBeta:$true -RequestContext @{ endpoint = $endpoint; method = 'GET'; admittedOdataType = '#microsoft.graph.securityBaselineTemplate'; admittedTemplateTypes = @($InnerTypes); telemetryExcluded = $true } -CollectScript {
            $items = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $endpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
            @($items | Where-Object { & $InnerAdmission $_ })
        }
    }
    $results += @($script:CollectorIntuneSecurityStage1Module.Invoke($legacyTemplateRunner, [object[]]@($Context, $legacyTemplateAdmission, $legacyTypes)))

    $legacyIntentRunner = {
        param($InnerContext, $InnerTemplateAdmission, $InnerTypes)
        $templateEndpoint = '/beta/deviceManagement/templates'
        $intentEndpoint = '/beta/deviceManagement/intents'
        Invoke-CollectorStage1Family -Context $InnerContext -Section 'intune-core' -Family 'securityBaselineIntents' -SourceType 'Graph' -SourceName ('Graph {0}' -f $intentEndpoint) -ApiVersion 'beta' -IsBeta:$true -RequestContext @{ endpoint = $intentEndpoint; method = 'GET'; admittedByTemplateEndpoint = $templateEndpoint; admittedOdataType = '#microsoft.graph.securityBaselineTemplate'; admittedTemplateTypes = @($InnerTypes); preservesMigrationState = $true; telemetryExcluded = $true } -CollectScript {
            $templates = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $templateEndpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
            $templateIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($template in @($templates | Where-Object { & $InnerTemplateAdmission $_ })) {
                if ($template.PSObject.Properties.Match('id').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$template.id)) {
                    $templateIds.Add([string]$template.id) | Out-Null
                }
            }
            $intents = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $intentEndpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
            @($intents | Where-Object { $_.PSObject.Properties.Match('templateId').Count -gt 0 -and $templateIds.Contains([string]$_.templateId) })
        }
    }
    $results += @($script:CollectorIntuneSecurityStage1Module.Invoke($legacyIntentRunner, [object[]]@($Context, $legacyTemplateAdmission, $legacyTypes)))
    return @($results)
}

function Invoke-CollectorIntuneSecurityPagedSettingStage2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][string]$DependencyFamily,
        [Parameter(Mandatory = $true)][string]$EndpointTemplate,
        [Parameter(Mandatory = $true)][string]$IdentityProperty,
        [Parameter(Mandatory = $true)][string]$ResponseShape
    )

    $runner = {
        param($InnerContext, $InnerFamily, $InnerDependencyFamily, $InnerEndpointTemplate, $InnerIdentityProperty, $InnerResponseShape)

        $section = 'intune-core'
        Assert-CollectorInventoryFirstForStage2 -RunPath $InnerContext.RunPath -Section $section -Family $InnerDependencyFamily -RunId $InnerContext.RunId

        $checkpoint = Get-CollectorCheckpoint -RunPath $InnerContext.RunPath -RunId $InnerContext.RunId -Stage 'stage2' -Section $section -Family $InnerFamily
        $result = Get-CollectorFamilyResult -Stage 'stage2' -Section $section -Family $InnerFamily
        $inventoryItems = @(Get-CollectorSnapshotItems -RunPath $InnerContext.RunPath -Stage 'stage1' -Section $section -Family $InnerDependencyFamily -ExpectedRunId $InnerContext.RunId)
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

            if ($InnerContext.Resume -and $existingBatch -and [string]$existingBatch.status -eq 'Succeeded' -and -not [string]::IsNullOrWhiteSpace([string]$existingBatch.artifactPath) -and (Test-Path -LiteralPath $existingBatch.artifactPath -PathType Leaf) -and -not (Test-CollectorStage2ResumeArtifact -Context $InnerContext -Section $section -Family $InnerFamily -BatchId $batchId -CheckpointBatch $existingBatch -ExpectedItemCount $batchItems.Count)) {
                $attempts = [int]$existingBatch.attempts
                $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount $batchItems.Count -SuccessCount 0 -FailedCount $batchItems.Count -ArtifactPath $existingBatch.artifactPath -Error 'Previously successful Intune security settings artifact failed resume validation and will be reprocessed.'
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
                $itemId = Get-CollectorObjectId -Item $inventoryItem
                if (-not $itemId) {
                    $failedCount++
                    $message = ('Unable to resolve id from Stage1 {0} inventory item.' -f $InnerDependencyFamily)
                    $errors += $message
                    $errorItem = [ordered]@{ _collectorError = $message }
                    $errorItem[$InnerIdentityProperty] = $null
                    $details += [pscustomobject]$errorItem
                    continue
                }

                $endpoint = $InnerEndpointTemplate.Replace('{id}', $itemId)
                try {
                    $settings = @(Invoke-CollectorGraphCollection -GraphToken $InnerContext.GraphToken -Endpoint $endpoint -MaxRetries $InnerContext.MaxRetries -BaseBackoffSeconds $InnerContext.BaseBackoffSeconds -MaxBackoffSeconds $InnerContext.MaxBackoffSeconds -ThrottleMilliseconds $InnerContext.ThrottleMilliseconds)
                    $detail = [ordered]@{}
                    $detail[$InnerIdentityProperty] = $itemId
                    $detail.settingCount = $settings.Count
                    $detail.settings = @($settings)
                    $details += [pscustomobject]$detail
                }
                catch {
                    $failedCount++
                    $errors += $_.Exception.Message
                    $errorItem = [ordered]@{ _collectorError = $_.Exception.Message }
                    $errorItem[$InnerIdentityProperty] = $itemId
                    $details += [pscustomobject]$errorItem
                }
            }

            $status = if ($failedCount -eq 0) { 'Succeeded' } else { 'Failed' }
            try {
                $snapshot = New-CollectorProvenanceSnapshot -RunId $InnerContext.RunId -Stage 'stage2' -Section $section -Family $InnerFamily -BatchId $batchId -SourceType 'Graph' -SourceName ('Graph {0}' -f $InnerEndpointTemplate) -ApiVersion 'beta' -IsBeta:$true -RequestContext @{ endpointTemplate = $InnerEndpointTemplate; method = 'GET'; inventoryStage = 'stage1'; dependencyFamily = $InnerDependencyFamily; paging = $true; responseShape = $InnerResponseShape; telemetryExcluded = $true } -ItemCount $details.Count -Items $details
                $artifact = Write-CollectorSnapshotArtifact -RunPath $InnerContext.RunPath -Stage 'stage2' -Section $section -Family $InnerFamily -BatchNumber $batchNumber -Snapshot $snapshot
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

    return @($script:CollectorIntuneSecurityStage2Module.Invoke($runner, [object[]]@($Context, $Family, $DependencyFamily, $EndpointTemplate, $IdentityProperty, $ResponseShape)))
}

function Invoke-CollectorIntuneSecurityStage2 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'securityConfigurationPolicies' -EndpointTemplate '/beta/deviceManagement/configurationPolicies/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'securityConfigurationPolicyTemplates' -EndpointTemplate '/beta/deviceManagement/configurationPolicyTemplates/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'securityBaselineTemplates' -EndpointTemplate '/beta/deviceManagement/templates/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'intune-core' -Family 'securityBaselineIntents' -EndpointTemplate '/beta/deviceManagement/intents/{id}')
        )
    }

    $results = @($script:CollectorIntuneSecurityStage2Module.Invoke($runner, [object[]]@($Context)))
    $results += @(Invoke-CollectorIntuneSecurityPagedSettingStage2 -Context $Context -Family 'securityConfigurationPolicySettings' -DependencyFamily 'securityConfigurationPolicies' -EndpointTemplate '/beta/deviceManagement/configurationPolicies/{id}/settings' -IdentityProperty 'policyId' -ResponseShape 'one-wrapper-per-policy')
    $results += @(Invoke-CollectorIntuneSecurityPagedSettingStage2 -Context $Context -Family 'securityBaselineIntentSettings' -DependencyFamily 'securityBaselineIntents' -EndpointTemplate '/beta/deviceManagement/intents/{id}/settings' -IdentityProperty 'intentId' -ResponseShape 'one-wrapper-per-intent')
    return @($results)
}

function Invoke-CollectorIntuneSecurityStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $transform = {
        param($InnerAssignment)
        ConvertTo-CollectorIntuneSecurityAssignment -Assignment $InnerAssignment
    }
    $runner = {
        param($InnerContext, $InnerTransform)
        @(
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'intune-core' -Family 'securityConfigurationPolicyAssignments' -DependencyFamily 'securityConfigurationPolicies' -EndpointTemplate '/beta/deviceManagement/configurationPolicies/{id}/assignments' -RelationshipTransform $InnerTransform)
            Publish-CollectorStage3Result -Context $InnerContext -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'intune-core' -Family 'securityBaselineIntentAssignments' -DependencyFamily 'securityBaselineIntents' -EndpointTemplate '/beta/deviceManagement/intents/{id}/assignments' -RelationshipTransform $InnerTransform)
        )
    }
    return @($script:CollectorIntuneSecurityStage3Module.Invoke($runner, [object[]]@($Context, $transform)))
}

Export-ModuleMember -Function @(
    'Invoke-CollectorIntuneSecurityStage1',
    'Invoke-CollectorIntuneSecurityStage2',
    'Invoke-CollectorIntuneSecurityStage3'
)
