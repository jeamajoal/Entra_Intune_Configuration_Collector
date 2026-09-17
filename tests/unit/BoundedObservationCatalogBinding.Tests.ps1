BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Observation.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.BoundedObservations.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop
}

Describe 'Bounded observation catalog plan binding' {
    BeforeEach {
        $script:root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-bounded-catalog-' + [Guid]::NewGuid().ToString('N'))
        $script:runId = 'bounded-catalog-run'
        $script:runPath = Join-Path -Path $script:root -ChildPath $script:runId
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:root) {
            Remove-Item -LiteralPath $script:root -Recurse -Force
        }
    }

    It 'rejects a valid snapshot whose observation window no longer matches the checkpoint plan' {
        $observation = New-CollectorObservationDescriptor `
            -RequestedStartUtc '2026-09-16T00:00:00Z' `
            -RequestedEndUtc '2026-09-17T00:00:00Z' `
            -EventTimeProperty 'createdDateTime'
        $state = New-CollectorEvidenceState -Availability 'available' -Completeness 'complete'
        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        $batches = Split-CollectorItems -Items $items -BatchSize 100

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:runPath -RunId $script:runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Initialize-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100 -Observation $observation
        $snapshot = New-CollectorProvenanceSnapshot `
            -RunId $script:runId `
            -Stage 'stage1' `
            -Section 'entra-apps' `
            -Family 'applications' `
            -BatchId '0001' `
            -SourceType 'Test' `
            -SourceName 'bounded-catalog-binding' `
            -ApiVersion 'test-v1' `
            -RequestContext @{} `
            -Observation $observation `
            -EvidenceState $state `
            -ItemCount 1 `
            -Items $items
        $artifact = Write-CollectorSnapshotArtifact -RunPath $script:runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchNumber 1 -Snapshot $snapshot
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status Succeeded -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifact.artifactPath
        $checkpoint = Complete-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint
        Save-CollectorCheckpoint -RunPath $script:runPath -Checkpoint $checkpoint | Out-Null

        $completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $parameters = [pscustomobject]@{}
        $manifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = $script:runId
            startedUtc = $completedUtc
            completedUtc = $completedUtc
            status = 'Completed'
            parameters = $parameters
            stageResults = @()
            checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $script:runPath)
            failures = @()
            invocations = @([pscustomobject]@{
                startedUtc = $completedUtc
                completedUtc = $completedUtc
                status = 'Completed'
                parameters = $parameters
                stageResults = @()
                failures = @()
            })
        }
        Save-CollectorManifest -RunPath $script:runPath -Manifest $manifest | Out-Null
        Export-CollectorKnowledgeCatalog -RunPath $script:runPath -ExpectedRunId $script:runId | Out-Null

        $persistedSnapshot = Get-Content -LiteralPath $artifact.artifactPath -Raw | ConvertFrom-Json
        $persistedSnapshot.observation = New-CollectorObservationDescriptor `
            -RequestedStartUtc '2026-09-16T01:00:00Z' `
            -RequestedEndUtc '2026-09-17T01:00:00Z' `
            -EventTimeProperty 'createdDateTime'
        [System.IO.File]::WriteAllText($artifact.artifactPath, ($persistedSnapshot | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))

        { Export-CollectorKnowledgeCatalog -RunPath $script:runPath -ExpectedRunId $script:runId | Out-Null } | Should -Throw '*Bounded observation plan identity mismatch*'
    }
}
