Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Provider.Graph.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Provider.OnPrem.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

function New-CollectorFamilyResult {
    param(
        [string]$Stage,
        [string]$Section,
        [string]$Family
    )

    [pscustomobject]@{
        stage = $Stage
        section = $Section
        family = $Family
        batchCount = 0
        succeededBatches = 0
        failedBatches = 0
        skippedBatches = 0
        itemCount = 0
        errors = @()
    }
}

function Get-CollectorObjectId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Item
    )

    foreach ($propertyName in @('id', 'Id', 'objectId', 'ObjectId', 'distinguishedName', 'DistinguishedName', 'name', 'Name')) {
        if ($Item.PSObject.Properties.Match($propertyName).Count -gt 0) {
            $value = $Item.$propertyName
            if ($null -ne $value -and [string]$value -ne '') {
                return [string]$value
            }
        }
    }

    return $null
}

function Assert-CollectorInventoryFirstForStage2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    if (-not (Test-CollectorInventoryArtifacts -RunPath $RunPath -Section $Section -Family $Family)) {
        throw ('Stage2 inventory-first enforcement failed. Missing Stage1 artifact for section {0}, family {1}.' -f $Section, $Family)
    }
}

function Invoke-CollectorStage2GraphFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$EndpointTemplate
    )

    Assert-CollectorInventoryFirstForStage2 -RunPath $Context.RunPath -Section $Section -Family $Family

    $stageName = 'stage2'
    $checkpoint = Get-CollectorCheckpoint -RunPath $Context.RunPath -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family
    $result = New-CollectorFamilyResult -Stage $stageName -Section $Section -Family $Family

    $inventoryItems = @(Get-CollectorSnapshotItems -RunPath $Context.RunPath -Stage 'stage1' -Section $Section -Family $Family)
    $batches = Split-CollectorItems -Items $inventoryItems -BatchSize $Context.BatchSize

    if ($batches.Count -eq 0) {
        $batches = @(@())
    }

    $result.batchCount = $batches.Count
    $batchNumber = 0

    foreach ($batch in $batches) {
        $batchNumber++
        $batchId = '{0:D4}' -f $batchNumber
        $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId $batchId -Resume:$Context.Resume -ReprocessFailedOnly:$Context.ReprocessFailedOnly

        if ($decision.MarkMissing) {
            $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
            $attempts = if ($existingBatch) { [int]$existingBatch.attempts } else { 0 }
            $itemCount = if ($existingBatch) { [int]$existingBatch.itemCount } else { 0 }
            $existingArtifactPath = if ($existingBatch) { $existingBatch.artifactPath } else { $null }
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Missing' -Attempts $attempts -ItemCount $itemCount -SuccessCount 0 -FailedCount $itemCount -ArtifactPath $existingArtifactPath -Error 'Artifact path from previous success is missing.'
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null
        }

        if (-not $decision.ShouldProcess) {
            $result.skippedBatches++
            $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
            if ($existingBatch) {
                $result.itemCount += [int]$existingBatch.itemCount
            }
            continue
        }

        $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
        $attempts = if ($existingBatch) { [int]$existingBatch.attempts + 1 } else { 1 }
        $existingArtifactPath = if ($existingBatch) { $existingBatch.artifactPath } else { $null }
        $batchItems = @($batch)

        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'InProgress' -Attempts $attempts -ItemCount $batchItems.Count -SuccessCount 0 -FailedCount 0 -ArtifactPath $existingArtifactPath -Error $null
        Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

        $details = @()
        $failedCount = 0
        $errors = @()

        foreach ($inventoryItem in $batchItems) {
            $objectId = Get-CollectorObjectId -Item $inventoryItem
            if (-not $objectId) {
                $failedCount++
                $errors += 'Unable to resolve object id from Stage1 inventory item.'
                $details += [pscustomobject]@{ _collectorError = 'Unable to resolve object id from Stage1 inventory item.' }
                continue
            }

            $endpoint = $EndpointTemplate.Replace('{id}', $objectId)
            try {
                $detail = Invoke-CollectorGraphRequest -GraphToken $Context.GraphToken -Endpoint $endpoint -MaxRetries $Context.MaxRetries -BaseBackoffSeconds $Context.BaseBackoffSeconds -MaxBackoffSeconds $Context.MaxBackoffSeconds -ThrottleMilliseconds $Context.ThrottleMilliseconds
                $details += $detail
            }
            catch {
                $failedCount++
                $errors += $_.Exception.Message
                $details += [pscustomobject]@{
                    id = $objectId
                    _collectorError = $_.Exception.Message
                }
            }
        }

        $isBeta = $EndpointTemplate.StartsWith('/beta')
        $apiVersion = if ($isBeta) { 'beta' } else { 'v1.0' }
        $status = if ($failedCount -eq 0) { 'Succeeded' } else { 'Failed' }

        try {
            $snapshot = New-CollectorProvenanceSnapshot -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family -BatchId $batchId -SourceType 'Graph' -SourceName ('Graph {0}' -f $EndpointTemplate) -ApiVersion $apiVersion -IsBeta:$isBeta -RequestContext @{ endpointTemplate = $EndpointTemplate; method = 'GET'; inventoryStage = 'stage1' } -ItemCount $details.Count -Items $details
            $artifact = Write-CollectorSnapshotArtifact -RunPath $Context.RunPath -Stage $stageName -Section $Section -Family $Family -BatchNumber $batchNumber -Snapshot $snapshot

            $successCount = [Math]::Max(0, $details.Count - $failedCount)
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status $status -Attempts $attempts -ItemCount $details.Count -SuccessCount $successCount -FailedCount $failedCount -ArtifactPath $artifact.artifactPath -Error (($errors -join '; ').Trim())
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

            if ($status -eq 'Succeeded') {
                $result.succeededBatches++
            }
            else {
                $result.failedBatches++
                $result.errors += $errors
            }

            $result.itemCount += $details.Count
        }
        catch {
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount $details.Count -SuccessCount 0 -FailedCount ([Math]::Max(1, $failedCount)) -ArtifactPath $existingArtifactPath -Error $_.Exception.Message
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

            $result.failedBatches++
            $result.itemCount += $details.Count
            $result.errors += $_.Exception.Message
        }
    }

    return $result
}

function Invoke-CollectorStage2OnPremFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [ValidateSet('domains', 'organizationalUnits', 'groups', 'gpos')]
        [string]$Family
    )

    Assert-CollectorInventoryFirstForStage2 -RunPath $Context.RunPath -Section $Section -Family $Family

    $stageName = 'stage2'
    $provenanceProfile = Get-CollectorOnPremProvenanceProfile -Phase 'Details' -Family $Family
    $requestContext = @{
        cmdletFamily = $Family
        cmdletNames = @($provenanceProfile.CmdletNames)
        inventoryStage = 'stage1'
        domainContextFromInventory = $true
    }

    $checkpoint = Get-CollectorCheckpoint -RunPath $Context.RunPath -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family
    $result = New-CollectorFamilyResult -Stage $stageName -Section $Section -Family $Family

    $inventoryItems = @(Get-CollectorSnapshotItems -RunPath $Context.RunPath -Stage 'stage1' -Section $Section -Family $Family)
    $batches = Split-CollectorItems -Items $inventoryItems -BatchSize $Context.BatchSize

    if ($batches.Count -eq 0) {
        $batches = @(@())
    }

    $result.batchCount = $batches.Count
    $batchNumber = 0

    foreach ($batch in $batches) {
        $batchNumber++
        $batchId = '{0:D4}' -f $batchNumber
        $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId $batchId -Resume:$Context.Resume -ReprocessFailedOnly:$Context.ReprocessFailedOnly

        if ($decision.MarkMissing) {
            $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
            $attempts = if ($existingBatch) { [int]$existingBatch.attempts } else { 0 }
            $itemCount = if ($existingBatch) { [int]$existingBatch.itemCount } else { 0 }
            $existingArtifactPath = if ($existingBatch) { $existingBatch.artifactPath } else { $null }
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Missing' -Attempts $attempts -ItemCount $itemCount -SuccessCount 0 -FailedCount $itemCount -ArtifactPath $existingArtifactPath -Error 'Artifact path from previous success is missing.'
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null
        }

        if (-not $decision.ShouldProcess) {
            $result.skippedBatches++
            $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
            if ($existingBatch) {
                $result.itemCount += [int]$existingBatch.itemCount
            }
            continue
        }

        $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
        $attempts = if ($existingBatch) { [int]$existingBatch.attempts + 1 } else { 1 }
        $existingArtifactPath = if ($existingBatch) { $existingBatch.artifactPath } else { $null }
        $batchItems = @($batch)

        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'InProgress' -Attempts $attempts -ItemCount $batchItems.Count -SuccessCount 0 -FailedCount 0 -ArtifactPath $existingArtifactPath -Error $null
        Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

        $details = @()
        $failedCount = 0
        $errors = @()

        foreach ($inventoryItem in $batchItems) {
            try {
                $detail = Invoke-CollectorOnPremDetailFamily -Family $Family -InventoryItem $inventoryItem
                $details += $detail
            }
            catch {
                $failedCount++
                $errors += $_.Exception.Message
                $details += [pscustomobject]@{ _collectorError = $_.Exception.Message }
            }
        }

        $status = if ($failedCount -eq 0) { 'Succeeded' } else { 'Failed' }

        try {
            $snapshot = New-CollectorProvenanceSnapshot -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family -BatchId $batchId -SourceType 'OnPrem' -SourceName $provenanceProfile.SourceName -ApiVersion 'n/a' -RequestContext $requestContext -ItemCount $details.Count -Items $details
            $artifact = Write-CollectorSnapshotArtifact -RunPath $Context.RunPath -Stage $stageName -Section $Section -Family $Family -BatchNumber $batchNumber -Snapshot $snapshot

            $successCount = [Math]::Max(0, $details.Count - $failedCount)
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status $status -Attempts $attempts -ItemCount $details.Count -SuccessCount $successCount -FailedCount $failedCount -ArtifactPath $artifact.artifactPath -Error (($errors -join '; ').Trim())
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

            if ($status -eq 'Succeeded') {
                $result.succeededBatches++
            }
            else {
                $result.failedBatches++
                $result.errors += $errors
            }

            $result.itemCount += $details.Count
        }
        catch {
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount $details.Count -SuccessCount 0 -FailedCount ([Math]::Max(1, $failedCount)) -ArtifactPath $existingArtifactPath -Error $_.Exception.Message
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

            $result.failedBatches++
            $result.itemCount += $details.Count
            $result.errors += $_.Exception.Message
        }
    }

    return $result
}

function Invoke-CollectorStage2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [string[]]$Sections
    )

    $results = @()

    foreach ($section in $Sections) {
        switch ($section) {
            'entra-apps' {
                $results += Invoke-CollectorStage2GraphFamily -Context $Context -Section $section -Family 'applications' -EndpointTemplate '/v1.0/applications/{id}'
                $results += Invoke-CollectorStage2GraphFamily -Context $Context -Section $section -Family 'servicePrincipals' -EndpointTemplate '/v1.0/servicePrincipals/{id}'
                $results += Invoke-CollectorStage2GraphFamily -Context $Context -Section $section -Family 'groups' -EndpointTemplate '/v1.0/groups/{id}'
            }

            'entra-pim' {
                $results += Invoke-CollectorStage2GraphFamily -Context $Context -Section $section -Family 'roleAssignmentScheduleInstances' -EndpointTemplate '/v1.0/roleManagement/directory/roleAssignmentScheduleInstances/{id}'
                $results += Invoke-CollectorStage2GraphFamily -Context $Context -Section $section -Family 'roleEligibilityScheduleInstances' -EndpointTemplate '/v1.0/roleManagement/directory/roleEligibilityScheduleInstances/{id}'
            }

            'intune-core' {
                $results += Invoke-CollectorStage2GraphFamily -Context $Context -Section $section -Family 'mobileApps' -EndpointTemplate '/v1.0/deviceAppManagement/mobileApps/{id}'
                $results += Invoke-CollectorStage2GraphFamily -Context $Context -Section $section -Family 'deviceManagementScripts' -EndpointTemplate '/beta/deviceManagement/deviceManagementScripts/{id}'
            }

            'onprem-ad-gpo' {
                $results += Invoke-CollectorStage2OnPremFamily -Context $Context -Section $section -Family 'domains'
                $results += Invoke-CollectorStage2OnPremFamily -Context $Context -Section $section -Family 'organizationalUnits'
                $results += Invoke-CollectorStage2OnPremFamily -Context $Context -Section $section -Family 'groups'
                $results += Invoke-CollectorStage2OnPremFamily -Context $Context -Section $section -Family 'gpos'
            }

            default {
                throw ('Unsupported section for Stage2 detail collection: {0}' -f $section)
            }
        }
    }

    return $results
}

Export-ModuleMember -Function @(
    'Invoke-CollectorStage2',
    'Assert-CollectorInventoryFirstForStage2'
)
