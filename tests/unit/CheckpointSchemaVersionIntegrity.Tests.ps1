param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Initialize-TestReadyCheckpoint {
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

Describe 'Checkpoint schemaVersion integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-version-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects missing null empty non-string and unsupported persisted schema versions' {
        foreach ($mode in @('missing', 'null', 'empty', 'non-string', 'unsupported')) {
            $runPath = Join-Path -Path $script:testRoot -ChildPath ('run-' + $mode)
            New-Item -Path $runPath -ItemType Directory -Force | Out-Null
            $runId = ([System.IO.DirectoryInfo]$runPath).Name
            $checkpoint = Get-CollectorCheckpoint -RunPath $runPath -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            $checkpointPath = Save-CollectorCheckpoint -RunPath $runPath -Checkpoint $checkpoint
            $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json

            switch ($mode) {
                'missing' { $persisted.PSObject.Properties.Remove('schemaVersion') }
                'null' { $persisted.schemaVersion = $null }
                'empty' { $persisted.schemaVersion = '' }
                'non-string' { $persisted.schemaVersion = 1 }
                'unsupported' { $persisted.schemaVersion = '999.0' }
            }
            $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

            { Get-CollectorCheckpoint -RunPath $runPath -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' } | Should -Throw '*Unsupported checkpoint schemaVersion*'
        }
    }

    It 'accepts the current persisted schema version 1.0' {
        $runPath = Join-Path -Path $script:testRoot -ChildPath 'run-current'
        New-Item -Path $runPath -ItemType Directory -Force | Out-Null
        $checkpoint = Get-CollectorCheckpoint -RunPath $runPath -RunId 'run-current' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpointPath = Save-CollectorCheckpoint -RunPath $runPath -Checkpoint $checkpoint

        $loaded = Get-CollectorCheckpoint -RunPath $runPath -RunId 'run-current' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        if ($loaded.schemaVersion -ne '1.0' -or -not (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
            throw 'Expected a persisted checkpoint using schemaVersion 1.0 to remain loadable.'
        }
    }

    It 'makes Stage1 readiness fail closed for an unsupported checkpoint version' {
        $runPath = Join-Path -Path $script:testRoot -ChildPath 'run-readiness'
        New-Item -Path $runPath -ItemType Directory -Force | Out-Null
        $checkpointPath = Initialize-TestReadyCheckpoint -RunPath $runPath
        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        $persisted.schemaVersion = '999.0'
        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        if (Test-CollectorInventoryArtifacts -RunPath $runPath -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'run-readiness') {
            throw 'Expected Stage1 readiness to fail closed for an unsupported checkpoint schemaVersion.'
        }
    }
}
