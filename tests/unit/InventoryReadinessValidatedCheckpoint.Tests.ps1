param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Initialize-TestReadyStage1Checkpoint {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        $runId = ([System.IO.DirectoryInfo]$RunPath).Name
        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        $batches = Split-CollectorItems -Items $items -BatchSize 100

        $snapshot = [pscustomobject]@{
            runId = $runId
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            batchId = '0001'
            itemCount = 1
            items = $items
        }
        $artifact = Write-CollectorSnapshotArtifact -RunPath $RunPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchNumber 1 -Snapshot $snapshot

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifact.artifactPath -ErrorMessage $null
        $checkpoint = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint
        return Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint
    }
}

Describe 'Stage1 readiness validated checkpoint binding' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-readiness-checkpoint-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'run-readiness'
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts a valid completed Stage1 checkpoint through the shared loader boundary' {
        Initialize-TestReadyStage1Checkpoint -RunPath $script:runPath | Out-Null

        if (-not (Test-CollectorInventoryArtifacts -RunPath $script:runPath -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'run-readiness')) {
            throw 'Expected valid Stage1 checkpoint state to remain ready.'
        }
    }

    It 'rejects readiness when the shared checkpoint loader rejects persisted attempts' {
        $checkpointPath = Initialize-TestReadyStage1Checkpoint -RunPath $script:runPath
        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        @($persisted.batches)[0].attempts = '1'
        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        if (Test-CollectorInventoryArtifacts -RunPath $script:runPath -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'run-readiness') {
            throw 'Expected readiness to fail closed when persisted attempts violates the shared checkpoint loader contract.'
        }
    }
}
