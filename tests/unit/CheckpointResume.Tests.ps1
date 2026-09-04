$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

Describe 'Checkpoint resume behavior' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -Path $script:testRoot) {
            Remove-Item -Path $script:testRoot -Recurse -Force
        }
    }

    It 'skips succeeded batch when artifact exists during resume failed-only mode' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        '{}' | Set-Content -Path $artifactPath -Encoding UTF8

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'run-a' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 10 -SuccessCount 10 -FailedCount 0 -ArtifactPath $artifactPath -Error $null

        $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume -ReprocessFailedOnly

        if ($decision.ShouldProcess) {
            throw 'Expected ShouldProcess to be false for succeeded batch with existing artifact during failed-only resume.'
        }

        if ($decision.MarkMissing) {
            throw 'Expected MarkMissing to be false for succeeded batch with existing artifact during failed-only resume.'
        }
    }

    It 'reruns succeeded batch when artifact is missing during resume failed-only mode' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001-missing.json'

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'run-b' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 10 -SuccessCount 10 -FailedCount 0 -ArtifactPath $artifactPath -Error $null

        $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume -ReprocessFailedOnly

        if (-not $decision.ShouldProcess) {
            throw 'Expected ShouldProcess to be true for succeeded batch with missing artifact during failed-only resume.'
        }

        if (-not $decision.MarkMissing) {
            throw 'Expected MarkMissing to be true for succeeded batch with missing artifact during failed-only resume.'
        }
    }

    It 'reruns failed batch during resume failed-only mode' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'run-c' -Stage 'stage2' -Section 'intune-core' -Family 'mobileApps'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0002' -Status 'Failed' -Attempts 2 -ItemCount 5 -SuccessCount 3 -FailedCount 2 -ArtifactPath $null -Error 'sample failure'

        $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0002' -Resume -ReprocessFailedOnly

        if (-not $decision.ShouldProcess) {
            throw 'Expected ShouldProcess to be true for failed batch during failed-only resume.'
        }

        if ($decision.MarkMissing) {
            throw 'Expected MarkMissing to be false for failed batch during failed-only resume.'
        }
    }
}
