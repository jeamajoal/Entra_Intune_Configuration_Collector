param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Initialize-TestSucceededCheckpoint {
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

Describe 'Persisted artifactPath type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-artifactpath-type-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'run-artifactpath'
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects a non-string persisted artifactPath even when the canonical snapshot exists' {
        $checkpointPath = Initialize-TestSucceededCheckpoint -RunPath $script:runPath
        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        @($persisted.batches)[0].artifactPath = [pscustomobject]@{ path = 'legacy' }
        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        { Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-artifactpath' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' } | Should -Throw '*invalid persisted artifactPath*'

        if (Test-CollectorInventoryArtifacts -RunPath $script:runPath -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'run-artifactpath') {
            throw 'Expected Stage1 readiness to fail closed for a schema-invalid persisted artifactPath.'
        }
    }

    It 'keeps legacy relative string artifact paths compatible and canonicalizes them' {
        $checkpointPath = Initialize-TestSucceededCheckpoint -RunPath $script:runPath
        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        @($persisted.batches)[0].artifactPath = './legacy/batch-0001.json'
        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        $loaded = Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-artifactpath' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $loadedPath = [string]@($loaded.batches)[0].artifactPath
        $expectedPath = [System.IO.Path]::GetFullPath((Join-Path -Path $script:runPath -ChildPath 'stage1/entra-apps/applications/batch-0001.json'))
        if ($loadedPath -ne $expectedPath) {
            throw ('Expected legacy string artifactPath to canonicalize. Actual: ' + $loadedPath)
        }
    }

    It 'accepts null or omitted artifactPath for unfinished persisted batches' {
        foreach ($mode in @('null', 'omitted')) {
            $runPath = Join-Path -Path $script:testRoot -ChildPath ('run-' + $mode)
            New-Item -Path $runPath -ItemType Directory -Force | Out-Null
            $runId = ([System.IO.DirectoryInfo]$runPath).Name
            $checkpoint = Get-CollectorCheckpoint -RunPath $runPath -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'InProgress' -Attempts 1 -ItemCount 0 -SuccessCount 0 -FailedCount 0 -ArtifactPath $null -ErrorMessage $null
            $checkpointPath = Save-CollectorCheckpoint -RunPath $runPath -Checkpoint $checkpoint

            if ($mode -eq 'omitted') {
                $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
                @($persisted.batches)[0].PSObject.Properties.Remove('artifactPath')
                $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
            }

            $loaded = Get-CollectorCheckpoint -RunPath $runPath -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            if (@($loaded.batches).Count -ne 1) {
                throw ('Expected persisted batch to load for artifactPath mode ' + $mode)
            }
        }
    }
}
