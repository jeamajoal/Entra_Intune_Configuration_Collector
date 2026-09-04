Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Provider.Graph.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Provider.OnPrem.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

function New-CollectorFamilyResult {
    param([string]$Stage,[string]$Section,[string]$Family)
    [pscustomobject]@{stage=$Stage;section=$Section;family=$Family;batchCount=0;succeededBatches=0;failedBatches=0;skippedBatches=0;itemCount=0;errors=@()}
}

function Publish-CollectorStage3Result {
    param([Parameter(Mandatory=$true)][hashtable]$Context,[Parameter(Mandatory=$true)][pscustomobject]$Result)
    if($Context.ContainsKey('ResultSink') -and $Context.ResultSink){& $Context.ResultSink $Result}
    return $Result
}

function Get-CollectorObjectId {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][pscustomobject]$Item)
    foreach($propertyName in @('id','Id','objectId','ObjectId','distinguishedName','DistinguishedName','name','Name')){
        if($Item.PSObject.Properties.Match($propertyName).Count -gt 0){$value=$Item.$propertyName;if($null -ne $value -and [string]$value -ne ''){return [string]$value}}
    }
    return $null
}

function Get-CollectorNestedValue {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][pscustomobject]$Item,[Parameter(Mandatory=$true)][string[]]$DirectProperties,[string]$NestedParent,[string]$NestedProperty)
    foreach($propertyName in $DirectProperties){if($Item.PSObject.Properties.Match($propertyName).Count -gt 0 -and $Item.$propertyName){return [string]$Item.$propertyName}}
    if($NestedParent -and $NestedProperty -and $Item.PSObject.Properties.Match($NestedParent).Count -gt 0 -and $Item.$NestedParent){$nestedObject=$Item.$NestedParent;if($nestedObject.PSObject.Properties.Match($NestedProperty).Count -gt 0 -and $nestedObject.$NestedProperty){return [string]$nestedObject.$NestedProperty}}
    return $null
}

function Assert-CollectorInventoryFirstForStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RunPath,[Parameter(Mandatory=$true)][string]$Section,[Parameter(Mandatory=$true)][string[]]$Families)
    foreach($family in $Families){
        if(-not(Test-CollectorInventoryArtifacts -RunPath $RunPath -Section $Section -Family $family)){
            $message='Stage3 inventory-first enforcement failed. Missing Stage1 artifact for section {0}, family {1}.' -f $Section,$family
            $exception=[System.InvalidOperationException]::new($message)
            $exception.Data['CollectorStage']='stage3';$exception.Data['CollectorSection']=$Section;$exception.Data['CollectorFamily']=$family
            throw $exception
        }
    }
}

function Invoke-CollectorStage3BatchLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,[Parameter(Mandatory=$true)][string]$Section,[Parameter(Mandatory=$true)][string]$Family,
        [Parameter(Mandatory=$true)][object[]]$Batches,[Parameter(Mandatory=$true)][string]$SourceType,[Parameter(Mandatory=$true)][string]$SourceName,
        [Parameter(Mandatory=$true)][string]$ApiVersion,[bool]$IsBeta=$false,[hashtable]$RequestContext=@{},[Parameter(Mandatory=$true)][scriptblock]$BatchCollector
    )
    $stageName='stage3';$checkpoint=Get-CollectorCheckpoint -RunPath $Context.RunPath -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family;$result=New-CollectorFamilyResult -Stage $stageName -Section $Section -Family $Family
    if($Batches.Count -eq 0){$Batches=@(@())}
    $checkpoint=Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $Batches -BatchSize $Context.BatchSize -Resume:$Context.Resume;Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null
    $result.batchCount=$Batches.Count;$batchNumber=0
    foreach($batch in $Batches){
        $batchNumber++;$batchId='{0:D4}' -f $batchNumber;$decision=Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId $batchId -Resume:$Context.Resume -ReprocessFailedOnly:$Context.ReprocessFailedOnly
        if($decision.MarkMissing){$existingBatch=Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId;$attempts=if($existingBatch){[int]$existingBatch.attempts}else{0};$itemCount=if($existingBatch){[int]$existingBatch.itemCount}else{0};$existingArtifactPath=if($existingBatch){$existingBatch.artifactPath}else{$null};$checkpoint=Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Missing' -Attempts $attempts -ItemCount $itemCount -SuccessCount 0 -FailedCount $itemCount -ArtifactPath $existingArtifactPath -Error 'Artifact path from previous success is missing.';Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null}
        if(-not $decision.ShouldProcess){$result.skippedBatches++;$existingBatch=Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId;if($existingBatch){$result.itemCount += [int]$existingBatch.itemCount};continue}
        $existingBatch=Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId;$attempts=if($existingBatch){[int]$existingBatch.attempts+1}else{1};$existingArtifactPath=if($existingBatch){$existingBatch.artifactPath}else{$null};$batchItems=@($batch)
        $checkpoint=Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'InProgress' -Attempts $attempts -ItemCount $batchItems.Count -SuccessCount 0 -FailedCount 0 -ArtifactPath $existingArtifactPath -Error $null;Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null
        $collectedItems=@();$failedCount=0;$errors=@()
        try{
            $batchOutcome=& $BatchCollector $batchItems
            if($batchOutcome -and $batchOutcome.PSObject.Properties.Match('Items').Count -gt 0){$collectedItems=@($batchOutcome.Items)}else{$collectedItems=@($batchOutcome)}
            $hasExplicitFailedCount=$false
            if($batchOutcome -and $batchOutcome.PSObject.Properties.Match('FailedCount').Count -gt 0){$hasExplicitFailedCount=$true;$failedCount=[int]$batchOutcome.FailedCount}
            if($batchOutcome -and $batchOutcome.PSObject.Properties.Match('Errors').Count -gt 0 -and $batchOutcome.Errors){$errors += @($batchOutcome.Errors)}
            if(-not $hasExplicitFailedCount){foreach($item in $collectedItems){if($item -and $item.PSObject.Properties.Match('_collectorError').Count -gt 0 -and $item._collectorError){$failedCount++;$errors += [string]$item._collectorError}}}
        }catch{$collectedItems=@([pscustomobject]@{_collectorError=$_.Exception.Message});$failedCount=1;$errors=@($_.Exception.Message)}
        $status=if($failedCount -eq 0){'Succeeded'}else{'Failed'}
        try{
            $snapshot=New-CollectorProvenanceSnapshot -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family -BatchId $batchId -SourceType $SourceType -SourceName $SourceName -ApiVersion $ApiVersion -IsBeta:$IsBeta -RequestContext $RequestContext -ItemCount $collectedItems.Count -Items $collectedItems
            $artifact=Write-CollectorSnapshotArtifact -RunPath $Context.RunPath -Stage $stageName -Section $Section -Family $Family -BatchNumber $batchNumber -Snapshot $snapshot;$successCount=[Math]::Max(0,$collectedItems.Count-$failedCount)
            $checkpoint=Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status $status -Attempts $attempts -ItemCount $collectedItems.Count -SuccessCount $successCount -FailedCount $failedCount -ArtifactPath $artifact.artifactPath -Error (($errors -join '; ').Trim());Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null
            if($status -eq 'Succeeded'){$result.succeededBatches++}else{$result.failedBatches++;$result.errors += $errors};$result.itemCount += $collectedItems.Count
        }catch{$checkpoint=Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount $collectedItems.Count -SuccessCount 0 -FailedCount ([Math]::Max(1,$failedCount)) -ArtifactPath $existingArtifactPath -Error $_.Exception.Message;Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null;$result.failedBatches++;$result.itemCount += $collectedItems.Count;$result.errors += $_.Exception.Message}
    }
    $checkpoint=Complete-CollectorCheckpointPlan -Checkpoint $checkpoint;Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null
    return $result
}

function Invoke-CollectorStage3GraphPerObjectFamily {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable]$Context,[Parameter(Mandatory=$true)][string]$Section,[Parameter(Mandatory=$true)][string]$Family,[Parameter(Mandatory=$true)][string]$DependencyFamily,[Parameter(Mandatory=$true)][string]$EndpointTemplate)
    Assert-CollectorInventoryFirstForStage3 -RunPath $Context.RunPath -Section $Section -Families @($DependencyFamily)
    $inventoryItems=@(Get-CollectorSnapshotItems -RunPath $Context.RunPath -Stage 'stage1' -Section $Section -Family $DependencyFamily);$batches=Split-CollectorItems -Items $inventoryItems -BatchSize $Context.BatchSize;$isBeta=$EndpointTemplate.StartsWith('/beta');$apiVersion=if($isBeta){'beta'}else{'v1.0'}
    Invoke-CollectorStage3BatchLoop -Context $Context -Section $Section -Family $Family -Batches $batches -SourceType 'Graph' -SourceName ('Graph {0}' -f $EndpointTemplate) -ApiVersion $apiVersion -IsBeta:$isBeta -RequestContext @{endpointTemplate=$EndpointTemplate;method='GET';dependencyFamily=$DependencyFamily} -BatchCollector {
        param([object[]]$batchItems);$items=@();$failedCount=0;$errors=@()
        foreach($inventoryItem in $batchItems){$objectId=Get-CollectorObjectId -Item $inventoryItem;if(-not $objectId){$failedCount++;$errors+='Unable to resolve object id from Stage1 inventory item.';$items += [pscustomobject]@{_collectorError='Unable to resolve object id from Stage1 inventory item.'};continue};$endpoint=$EndpointTemplate.Replace('{id}',$objectId);try{$relationships=Invoke-CollectorGraphCollection -GraphToken $Context.GraphToken -Endpoint $endpoint -MaxRetries $Context.MaxRetries -BaseBackoffSeconds $Context.BaseBackoffSeconds -MaxBackoffSeconds $Context.MaxBackoffSeconds -ThrottleMilliseconds $Context.ThrottleMilliseconds;$items += [pscustomobject]@{parentId=$objectId;relationshipCount=@($relationships).Count;relationships=@($relationships)}}catch{$failedCount++;$errors += $_.Exception.Message;$items += [pscustomobject]@{parentId=$objectId;_collectorError=$_.Exception.Message}}}
        [pscustomobject]@{Items=$items;FailedCount=$failedCount;Errors=$errors}
    }
}

function Invoke-CollectorStage3DelegatedGrantFamily {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable]$Context,[Parameter(Mandatory=$true)][string]$Section)
    Assert-CollectorInventoryFirstForStage3 -RunPath $Context.RunPath -Section $Section -Families @('servicePrincipals')
    $grants=@();$seedError=$null;try{$grants=@(Invoke-CollectorGraphCollection -GraphToken $Context.GraphToken -Endpoint '/v1.0/oauth2PermissionGrants' -MaxRetries $Context.MaxRetries -BaseBackoffSeconds $Context.BaseBackoffSeconds -MaxBackoffSeconds $Context.MaxBackoffSeconds -ThrottleMilliseconds $Context.ThrottleMilliseconds)}catch{$seedError=$_.Exception.Message;$grants=@([pscustomobject]@{_collectorError=$seedError})}
    $batches=Split-CollectorItems -Items $grants -BatchSize $Context.BatchSize
    Invoke-CollectorStage3BatchLoop -Context $Context -Section $Section -Family 'delegatedGrants' -Batches $batches -SourceType 'Graph' -SourceName 'Graph /v1.0/oauth2PermissionGrants' -ApiVersion 'v1.0' -IsBeta:$false -RequestContext @{endpoint='/v1.0/oauth2PermissionGrants';method='GET';dependencyFamily='servicePrincipals'} -BatchCollector {param([object[]]$batchItems);$failedCount=0;$errors=@();if($seedError){$failedCount=$batchItems.Count;$errors += $seedError};[pscustomobject]@{Items=@($batchItems);FailedCount=$failedCount;Errors=$errors}}
}

function Convert-CollectorPimScheduleToEdge {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][pscustomobject]$Item,[Parameter(Mandatory=$true)][ValidateSet('active','eligible')][string]$ScheduleType)
    [pscustomobject]@{scheduleType=$ScheduleType;scheduleId=Get-CollectorNestedValue -Item $Item -DirectProperties @('id','Id');principalId=Get-CollectorNestedValue -Item $Item -DirectProperties @('principalId') -NestedParent 'principal' -NestedProperty 'id';roleDefinitionId=Get-CollectorNestedValue -Item $Item -DirectProperties @('roleDefinitionId') -NestedParent 'roleDefinition' -NestedProperty 'id';directoryScopeId=Get-CollectorNestedValue -Item $Item -DirectProperties @('directoryScopeId') -NestedParent 'directoryScope' -NestedProperty 'id';appScopeId=Get-CollectorNestedValue -Item $Item -DirectProperties @('appScopeId') -NestedParent 'appScope' -NestedProperty 'id'}
}

function Invoke-CollectorStage3PimScheduleEdges {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable]$Context,[Parameter(Mandatory=$true)][string]$Section)
    Assert-CollectorInventoryFirstForStage3 -RunPath $Context.RunPath -Section $Section -Families @('roleAssignmentScheduleInstances','roleEligibilityScheduleInstances')
    $assignmentSchedules=@(Get-CollectorSnapshotItems -RunPath $Context.RunPath -Stage 'stage1' -Section $Section -Family 'roleAssignmentScheduleInstances');$eligibilitySchedules=@(Get-CollectorSnapshotItems -RunPath $Context.RunPath -Stage 'stage1' -Section $Section -Family 'roleEligibilityScheduleInstances');$edges=@()
    foreach($assignment in $assignmentSchedules){$edges += Convert-CollectorPimScheduleToEdge -Item $assignment -ScheduleType 'active'};foreach($eligibility in $eligibilitySchedules){$edges += Convert-CollectorPimScheduleToEdge -Item $eligibility -ScheduleType 'eligible'}
    $batches=Split-CollectorItems -Items $edges -BatchSize $Context.BatchSize
    Invoke-CollectorStage3BatchLoop -Context $Context -Section $Section -Family 'pimScheduleEdges' -Batches $batches -SourceType 'Derived' -SourceName 'Derived PIM schedule edges from Stage1 inventory' -ApiVersion 'v1.0' -IsBeta:$false -RequestContext @{dependencyFamilies=@('roleAssignmentScheduleInstances','roleEligibilityScheduleInstances');transform='schedule-instance-to-edge'} -BatchCollector {param([object[]]$batchItems);[pscustomobject]@{Items=@($batchItems);FailedCount=0;Errors=@()}}
}

function Invoke-CollectorStage3OnPremFamily {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable]$Context,[Parameter(Mandatory=$true)][string]$Section,[Parameter(Mandatory=$true)][ValidateSet('domainRootAcl','ouAcl','gpoPermissions','groupMembersOnPrem')][string]$Family,[Parameter(Mandatory=$true)][ValidateSet('domains','organizationalUnits','gpos','groups')][string]$DependencyFamily)
    Assert-CollectorInventoryFirstForStage3 -RunPath $Context.RunPath -Section $Section -Families @($DependencyFamily)
    $inventoryItems=@(Get-CollectorSnapshotItems -RunPath $Context.RunPath -Stage 'stage1' -Section $Section -Family $DependencyFamily);$batches=Split-CollectorItems -Items $inventoryItems -BatchSize $Context.BatchSize;$provenanceProfile=Get-CollectorOnPremProvenanceProfile -Phase 'Relationships' -Family $Family;$requestContext=@{dependencyFamily=$DependencyFamily;cmdletFamily=$Family;cmdletNames=@($provenanceProfile.CmdletNames);domainContextFromInventory=$true}
    Invoke-CollectorStage3BatchLoop -Context $Context -Section $Section -Family $Family -Batches $batches -SourceType 'OnPrem' -SourceName $provenanceProfile.SourceName -ApiVersion 'n/a' -RequestContext $requestContext -BatchCollector {param([object[]]$batchItems);$relationships=@(Invoke-CollectorOnPremRelationshipFamily -Family $Family -InventoryItems $batchItems);$errors=@();$failedCount=0;foreach($relationship in $relationships){if($relationship -and $relationship.PSObject.Properties.Match('_collectorError').Count -gt 0 -and $relationship._collectorError){$failedCount++;$errors += [string]$relationship._collectorError}};[pscustomobject]@{Items=$relationships;FailedCount=$failedCount;Errors=$errors}}
}

function Invoke-CollectorStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable]$Context,[Parameter(Mandatory=$true)][string[]]$Sections)
    $results=@()
    foreach($section in $Sections){
        switch($section){
            'entra-apps' {
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $Context -Section $section -Family 'servicePrincipalAppRoleAssignedTo' -DependencyFamily 'servicePrincipals' -EndpointTemplate '/v1.0/servicePrincipals/{id}/appRoleAssignedTo')
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $Context -Section $section -Family 'groupMembers' -DependencyFamily 'groups' -EndpointTemplate '/v1.0/groups/{id}/members')
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3DelegatedGrantFamily -Context $Context -Section $section)
            }
            'entra-pim' {$results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3PimScheduleEdges -Context $Context -Section $section)}
            'intune-core' {
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $Context -Section $section -Family 'mobileAppAssignments' -DependencyFamily 'mobileApps' -EndpointTemplate '/v1.0/deviceAppManagement/mobileApps/{id}/assignments')
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3GraphPerObjectFamily -Context $Context -Section $section -Family 'deviceManagementScriptAssignments' -DependencyFamily 'deviceManagementScripts' -EndpointTemplate '/beta/deviceManagement/deviceManagementScripts/{id}/assignments')
            }
            'onprem-ad-gpo' {
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3OnPremFamily -Context $Context -Section $section -Family 'domainRootAcl' -DependencyFamily 'domains')
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3OnPremFamily -Context $Context -Section $section -Family 'ouAcl' -DependencyFamily 'organizationalUnits')
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3OnPremFamily -Context $Context -Section $section -Family 'gpoPermissions' -DependencyFamily 'gpos')
                $results += Publish-CollectorStage3Result -Context $Context -Result (Invoke-CollectorStage3OnPremFamily -Context $Context -Section $section -Family 'groupMembersOnPrem' -DependencyFamily 'groups')
            }
            default {throw ('Unsupported section for Stage3 relationship collection: {0}' -f $section)}
        }
    }
    return $results
}

Export-ModuleMember -Function @('Invoke-CollectorStage3','Assert-CollectorInventoryFirstForStage3')
