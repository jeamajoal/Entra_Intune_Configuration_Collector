Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Observation.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

function Get-CollectorObservationPlanDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Observation
    )

    if (-not (Test-CollectorObservationDescriptor -Observation $Observation)) {
        throw 'Bounded observation plan requires a valid observation descriptor.'
    }

    return New-CollectorObservationDescriptor `
        -RequestedStartUtc $Observation.requested.startUtc `
        -RequestedEndUtc $Observation.requested.endUtc `
        -EventTimeProperty $Observation.eventTimeProperty
}

function Initialize-CollectorBoundedCheckpointPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Batches,

        [Parameter(Mandatory = $true)]
        [int]$BatchSize,

        [Parameter(Mandatory = $true)]
        [object]$Observation,

        [switch]$Resume
    )

    $currentObservation = Get-CollectorObservationPlanDescriptor -Observation $Observation
    if (@($Batches).Count -lt 1) {
        throw ('Bounded observation plan for {0}/{1}/{2} requires at least one planned batch. Represent a legitimate zero-result observation with one explicit empty batch so terminal evidence can be persisted.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
    }

    $hasExistingPlan = $Checkpoint.PSObject.Properties.Match('plan').Count -gt 0 -and $null -ne $Checkpoint.plan

    if ($Resume -and $hasExistingPlan) {
        $existingPlan = $Checkpoint.plan
        $hasExistingObservation = $existingPlan.PSObject.Properties.Match('observation').Count -gt 0 -and $null -ne $existingPlan.observation
        if ($hasExistingObservation) {
            if (-not (Test-CollectorObservationDescriptor -Observation $existingPlan.observation)) {
                throw ('Resume observation metadata is invalid for {0}/{1}/{2}; stale bounded evidence will not be reused.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
            }
            if ([string]$existingPlan.observation.planIdentity -cne [string]$currentObservation.planIdentity) {
                throw ('Resume observation-window mismatch for {0}/{1}/{2}. Requested UTC window or event-time identity changed; stale bounded evidence will not be reused.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
            }
        }
        else {
            $priorSucceeded = @($Checkpoint.batches | Where-Object { $_.status -eq 'Succeeded' }).Count
            if ($priorSucceeded -gt 0) {
                throw ('Resume checkpoint for {0}/{1}/{2} contains successful batches but no bounded-observation identity. Start the family without -Resume so evidence from an unknown window is not reused.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
            }
        }
    }

    $Checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $Checkpoint -Batches $Batches -BatchSize $BatchSize -Resume:$Resume
    if ($Checkpoint.plan.PSObject.Properties.Match('observation').Count -eq 0) {
        $Checkpoint.plan | Add-Member -MemberType NoteProperty -Name observation -Value $currentObservation
    }
    else {
        $Checkpoint.plan.observation = $currentObservation
    }

    return $Checkpoint
}

function Test-CollectorBoundedSnapshotAgainstPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot,

        [Parameter(Mandatory = $true)]
        [object]$PlanObservation
    )

    if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $Snapshot)) {
        return $false
    }
    if (
        $Snapshot.PSObject.Properties.Match('observation').Count -eq 0 -or
        $Snapshot.PSObject.Properties.Match('evidenceState').Count -eq 0
    ) {
        return $false
    }
    if (-not (Test-CollectorBoundedEvidenceContract -Observation $Snapshot.observation -EvidenceState $Snapshot.evidenceState)) {
        return $false
    }
    if ([string]$Snapshot.observation.planIdentity -cne [string]$PlanObservation.planIdentity) {
        return $false
    }
    if ([string]$Snapshot.evidenceState.availability -eq 'failed' -or [string]$Snapshot.evidenceState.completeness -eq 'failed') {
        return $false
    }

    return $true
}

function Get-CollectorBoundedBatchExecutionDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [string]$BatchId,

        [switch]$Resume,

        [switch]$ReprocessFailedOnly
    )

    $decision = Get-CollectorBatchExecutionDecision -Checkpoint $Checkpoint -BatchId $BatchId -Resume:$Resume -ReprocessFailedOnly:$ReprocessFailedOnly
    if ([bool]$decision.ShouldProcess) {
        return $decision
    }

    if (
        $Checkpoint.PSObject.Properties.Match('plan').Count -eq 0 -or
        $null -eq $Checkpoint.plan -or
        $Checkpoint.plan.PSObject.Properties.Match('observation').Count -eq 0 -or
        -not (Test-CollectorObservationDescriptor -Observation $Checkpoint.plan.observation)
    ) {
        throw ('Bounded checkpoint plan metadata is missing or invalid for {0}/{1}/{2}.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
    }

    $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $Checkpoint -BatchId $BatchId
    if ($null -eq $existingBatch -or [string]::IsNullOrWhiteSpace([string]$existingBatch.artifactPath)) {
        return [pscustomobject]@{
            ShouldProcess = $true
            MarkMissing = $false
            Reason = 'BoundedArtifactUnavailable'
        }
    }

    $snapshot = $null
    try {
        $snapshot = Get-Content -LiteralPath $existingBatch.artifactPath -Raw | ConvertFrom-Json
    }
    catch {
        $snapshot = $null
    }

    if (-not (Test-CollectorBoundedSnapshotAgainstPlan -Snapshot $snapshot -PlanObservation $Checkpoint.plan.observation)) {
        return [pscustomobject]@{
            ShouldProcess = $true
            MarkMissing = $false
            Reason = 'BoundedSnapshotPlanMismatch'
        }
    }

    return $decision
}

function Complete-CollectorBoundedCheckpointPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint
    )

    if (
        $Checkpoint.PSObject.Properties.Match('plan').Count -eq 0 -or
        $null -eq $Checkpoint.plan -or
        $Checkpoint.plan.PSObject.Properties.Match('observation').Count -eq 0 -or
        -not (Test-CollectorObservationDescriptor -Observation $Checkpoint.plan.observation)
    ) {
        throw ('Bounded checkpoint plan metadata is missing or invalid for {0}/{1}/{2}.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
    }

    if (@($Checkpoint.plan.batches).Count -lt 1) {
        $Checkpoint.plan.completed = $false
        return $Checkpoint
    }

    $Checkpoint = Complete-CollectorCheckpointPlan -Checkpoint $Checkpoint
    if (-not [bool]$Checkpoint.plan.completed) {
        return $Checkpoint
    }

    foreach ($plannedBatch in @($Checkpoint.plan.batches)) {
        $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $Checkpoint -BatchId ([string]$plannedBatch.batchId)
        if ($null -eq $existingBatch -or [string]$existingBatch.status -ne 'Succeeded' -or [string]::IsNullOrWhiteSpace([string]$existingBatch.artifactPath)) {
            $Checkpoint.plan.completed = $false
            return $Checkpoint
        }

        $snapshot = $null
        try {
            $snapshot = Get-Content -LiteralPath $existingBatch.artifactPath -Raw | ConvertFrom-Json
        }
        catch {
            $snapshot = $null
        }

        if (-not (Test-CollectorBoundedSnapshotAgainstPlan -Snapshot $snapshot -PlanObservation $Checkpoint.plan.observation)) {
            $Checkpoint.plan.completed = $false
            return $Checkpoint
        }
    }

    return $Checkpoint
}

Export-ModuleMember -Function @(
    'Initialize-CollectorBoundedCheckpointPlan',
    'Complete-CollectorBoundedCheckpointPlan',
    'Test-CollectorBoundedSnapshotAgainstPlan',
    'Get-CollectorBoundedBatchExecutionDecision'
)
