BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.BoundedObservations.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Observation.psm1') -Force -ErrorAction Stop
}

Describe 'Bounded observation resume safety' {
    BeforeEach {
        $script:root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-bounded-resume-' + [Guid]::NewGuid().ToString('N'))
        $script:runId = 'bounded-resume-run'
        $script:runPath = Join-Path -Path $script:root -ChildPath $script:runId
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
        $script:observation = New-CollectorObservationDescriptor -RequestedStartUtc '2026-09-16T00:00:00Z' -RequestedEndUtc '2026-09-17T00:00:00Z' -EventTimeProperty 'createdDateTime'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:root) {
            Remove-Item -LiteralPath $script:root -Recurse -Force
        }
    }

    It 'rejects a zero-batch bounded plan so a terminal evidence artifact is required' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:runPath -RunId $script:runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        { Initialize-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint -Batches @() -BatchSize 100 -Observation $script:observation | Out-Null } | Should -Throw '*requires at least one planned batch*'
    }

    It 'reprocesses a successful artifact whose bounded observation differs from the checkpoint plan' {
        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        $batches = Split-CollectorItems -Items $items -BatchSize 100
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:runPath -RunId $script:runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Initialize-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100 -Observation $script:observation

        $staleObservation = New-CollectorObservationDescriptor -RequestedStartUtc '2026-09-15T00:00:00Z' -RequestedEndUtc '2026-09-16T00:00:00Z' -EventTimeProperty 'createdDateTime'
        $state = New-CollectorEvidenceState -Availability 'available' -Completeness 'complete'
        $snapshot = New-CollectorProvenanceSnapshot -RunId $script:runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'bounded-resume' -ApiVersion 'test-v1' -RequestContext @{} -Observation $staleObservation -EvidenceState $state -ItemCount 1 -Items $items
        $artifact = Write-CollectorSnapshotArtifact -RunPath $script:runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchNumber 1 -Snapshot $snapshot
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status Succeeded -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifact.artifactPath

        $genericDecision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if ([bool]$genericDecision.ShouldProcess) {
            throw 'Fixture expected the generic resume decision to skip an internally valid snapshot.'
        }

        $boundedDecision = Get-CollectorBoundedBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if (-not [bool]$boundedDecision.ShouldProcess -or [string]$boundedDecision.Reason -ne 'BoundedSnapshotPlanMismatch') {
            throw ('Expected bounded resume to reprocess stale observation evidence; actual reason: {0}' -f [string]$boundedDecision.Reason)
        }
    }
}
