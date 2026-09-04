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

function Invoke-CollectorStage1Family {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$SourceType,

        [Parameter(Mandatory = $true)]
        [string]$SourceName,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion,

        [bool]$IsBeta = $false,

        [hashtable]$RequestContext = @{},

        [Parameter(Mandatory = $true)]
        [scriptblock]$CollectScript
    )

    $stageName = 'stage1'
    $result = New-CollectorFamilyResult -Stage $stageName -Section $Section -Family $Family
    $checkpoint = Get-CollectorCheckpoint -RunPath $Context.RunPath -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family

    try {
        $collectedItems = @(& $CollectScript)
    }
    catch {
        $batchId = '0001'
        $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
        $attempts = if ($existingBatch) { [int]$existingBatch.attempts + 1 } else { 1 }

        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount 0 -SuccessCount 0 -FailedCount 0 -Error $_.Exception.Message
        Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

        $result.batchCount = 1
        $result.failedBatches = 1
        $result.errors += $_.Exception.Message
        return $result
    }

    if ($null -eq $collectedItems) {
        $collectedItems = @()
    }

    $batches = Split-CollectorItems -Items $collectedItems -BatchSize $Context.BatchSize
    if ($batches.Count -eq 0) {
        $batches = @(@())
    }

    # Persist the expected work identity before any batch state is mutated. This
    # makes an interruption before a later batch is reached visibly incomplete.
    $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize $Context.BatchSize -Resume:$Context.Resume
    Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

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
        $batchItemCount = $batchItems.Count

        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'InProgress' -Attempts $attempts -ItemCount $batchItemCount -SuccessCount 0 -FailedCount 0 -ArtifactPath $existingArtifactPath -Error $null
        Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

        try {
            $snapshot = New-CollectorProvenanceSnapshot -RunId $Context.RunId -Stage $stageName -Section $Section -Family $Family -BatchId $batchId -SourceType $SourceType -SourceName $SourceName -ApiVersion $ApiVersion -IsBeta:$IsBeta -RequestContext $RequestContext -ItemCount $batchItemCount -Items $batchItems

            $artifact = Write-CollectorSnapshotArtifact -RunPath $Context.RunPath -Stage $stageName -Section $Section -Family $Family -BatchNumber $batchNumber -Snapshot $snapshot

            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Succeeded' -Attempts $attempts -ItemCount $batchItemCount -SuccessCount $batchItemCount -FailedCount 0 -ArtifactPath $artifact.artifactPath -Error $null
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

            $result.succeededBatches++
            $result.itemCount += $batchItemCount
        }
        catch {
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Failed' -Attempts $attempts -ItemCount $batchItemCount -SuccessCount 0 -FailedCount $batchItemCount -ArtifactPath $existingArtifactPath -Error $_.Exception.Message
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

            $result.failedBatches++
            $result.itemCount += $batchItemCount
            $result.errors += $_.Exception.Message
        }
    }

    $checkpoint = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint
    Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

    return $result
}

function Invoke-CollectorGraphInventoryFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )

    $isBeta = $Endpoint.StartsWith('/beta')
    $apiVersion = if ($isBeta) { 'beta' } else { 'v1.0' }

    Invoke-CollectorStage1Family -Context $Context -Section $Section -Family $Family -SourceType 'Graph' -SourceName ('Graph {0}' -f $Endpoint) -ApiVersion $apiVersion -IsBeta:$isBeta -RequestContext @{ endpoint = $Endpoint; method = 'GET' } -CollectScript {
        Invoke-CollectorGraphCollection -GraphToken $Context.GraphToken -Endpoint $Endpoint -MaxRetries $Context.MaxRetries -BaseBackoffSeconds $Context.BaseBackoffSeconds -MaxBackoffSeconds $Context.MaxBackoffSeconds -ThrottleMilliseconds $Context.ThrottleMilliseconds
    }
}

function Invoke-CollectorStage1OnPremInventoryFamily {
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

    $provenanceProfile = Get-CollectorOnPremProvenanceProfile -Phase 'Inventory' -Family $Family
    $requestContext = @{
        cmdletFamily = $Family
        cmdletNames = @($provenanceProfile.CmdletNames)
        inventoryScope = 'forestDomains'
    }

    Invoke-CollectorStage1Family -Context $Context -Section $Section -Family $Family -SourceType 'OnPrem' -SourceName $provenanceProfile.SourceName -ApiVersion 'n/a' -RequestContext $requestContext -CollectScript {
        Invoke-CollectorOnPremInventoryFamily -Family $Family
    }
}

function Invoke-CollectorStage1 {
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
                $results += Invoke-CollectorGraphInventoryFamily -Context $Context -Section $section -Family 'applications' -Endpoint '/v1.0/applications'
                $results += Invoke-CollectorGraphInventoryFamily -Context $Context -Section $section -Family 'servicePrincipals' -Endpoint '/v1.0/servicePrincipals'
                $results += Invoke-CollectorGraphInventoryFamily -Context $Context -Section $section -Family 'groups' -Endpoint '/v1.0/groups'
            }

            'entra-pim' {
                $results += Invoke-CollectorGraphInventoryFamily -Context $Context -Section $section -Family 'roleAssignmentScheduleInstances' -Endpoint '/v1.0/roleManagement/directory/roleAssignmentScheduleInstances'
                $results += Invoke-CollectorGraphInventoryFamily -Context $Context -Section $section -Family 'roleEligibilityScheduleInstances' -Endpoint '/v1.0/roleManagement/directory/roleEligibilityScheduleInstances'
            }

            'intune-core' {
                $results += Invoke-CollectorGraphInventoryFamily -Context $Context -Section $section -Family 'mobileApps' -Endpoint '/v1.0/deviceAppManagement/mobileApps'
                $results += Invoke-CollectorGraphInventoryFamily -Context $Context -Section $section -Family 'deviceManagementScripts' -Endpoint '/beta/deviceManagement/deviceManagementScripts'
            }

            'onprem-ad-gpo' {
                $results += Invoke-CollectorStage1OnPremInventoryFamily -Context $Context -Section $section -Family 'domains'
                $results += Invoke-CollectorStage1OnPremInventoryFamily -Context $Context -Section $section -Family 'organizationalUnits'
                $results += Invoke-CollectorStage1OnPremInventoryFamily -Context $Context -Section $section -Family 'groups'
                $results += Invoke-CollectorStage1OnPremInventoryFamily -Context $Context -Section $section -Family 'gpos'
            }

            default {
                throw ('Unsupported section for Stage1 inventory: {0}' -f $section)
            }
        }
    }

    return $results
}

Export-ModuleMember -Function Invoke-CollectorStage1
