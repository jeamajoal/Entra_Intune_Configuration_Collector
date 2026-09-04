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

    It 'uses ErrorMessage as the canonical parameter while preserving the serialized error field' {
        $command = Get-Command -Name Set-CollectorCheckpointBatch -ErrorAction Stop
        if (-not $command.Parameters.ContainsKey('ErrorMessage')) {
            throw 'Expected Set-CollectorCheckpointBatch to expose canonical ErrorMessage parameter.'
        }

        if ($command.Parameters.ContainsKey('Error')) {
            throw 'Set-CollectorCheckpointBatch must not define a canonical parameter named Error because $Error is a PowerShell automatic variable.'
        }

        if (-not (@($command.Parameters['ErrorMessage'].Aliases) -contains 'Error')) {
            throw 'Expected temporary Error alias to preserve compatibility with existing callers.'
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'run-error-contract' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Failed' -Attempts 1 -ItemCount 1 -SuccessCount 0 -FailedCount 1 -ArtifactPath $null -ErrorMessage 'canonical error text'

        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        if ([string]$batch.error -ne 'canonical error text') {
            throw ('Expected serialized/object error field to retain canonical error text; actual: ' + [string]$batch.error)
        }
    }

    It 'preserves the Error alias for existing caller compatibility' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'run-error-alias' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Failed' -Attempts 1 -ItemCount 1 -SuccessCount 0 -FailedCount 1 -ArtifactPath $null -Error 'alias error text'

        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        if ([string]$batch.error -ne 'alias error text') {
            throw ('Expected Error alias to bind to ErrorMessage and preserve error field; actual: ' + [string]$batch.error)
        }
    }

    It 'skips succeeded batch when artifact exists during resume failed-only mode' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        '{}' | Set-Content -Path $artifactPath -Encoding UTF8

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'run-a' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 10 -SuccessCount 10 -FailedCount 0 -ArtifactPath $artifactPath -ErrorMessage $null

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
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 10 -SuccessCount 10 -FailedCount 0 -ArtifactPath $artifactPath -ErrorMessage $null

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
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0002' -Status 'Failed' -Attempts 2 -ItemCount 5 -SuccessCount 3 -FailedCount 2 -ArtifactPath $null -ErrorMessage 'sample failure'

        $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0002' -Resume -ReprocessFailedOnly

        if (-not $decision.ShouldProcess) {
            throw 'Expected ShouldProcess to be true for failed batch during failed-only resume.'
        }

        if ($decision.MarkMissing) {
            throw 'Expected MarkMissing to be false for failed batch during failed-only resume.'
        }
    }
}
