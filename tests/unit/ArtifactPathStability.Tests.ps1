$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

Describe 'Artifact path stability' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-artifact-path-test-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'output/run-one'
        $script:otherWorkingDirectory = Join-Path -Path $script:testRoot -ChildPath 'different-working-directory'
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
        New-Item -Path $script:otherWorkingDirectory -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'writes new artifact references as canonical absolute paths' {
        $snapshot = [pscustomobject]@{ itemCount = 0; items = @() }
        $artifact = Write-CollectorSnapshotArtifact -RunPath $script:runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchNumber 1 -Snapshot $snapshot

        if (-not [System.IO.Path]::IsPathRooted([string]$artifact.artifactPath)) {
            throw ('Expected a rooted artifactPath; actual: ' + [string]$artifact.artifactPath)
        }

        if (-not (Test-Path -LiteralPath $artifact.artifactPath)) {
            throw 'Expected canonical artifact path to point to the written snapshot.'
        }
    }

    It 'recognizes and migrates a legacy relative artifact reference from another working directory' {
        $artifactDirectory = Join-Path -Path $script:runPath -ChildPath 'stage1/entra-apps/applications'
        New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
        $canonicalArtifactPath = [System.IO.Path]::GetFullPath((Join-Path -Path $artifactDirectory -ChildPath 'batch-0001.json'))
        '{"items":[]}' | Set-Content -LiteralPath $canonicalArtifactPath -Encoding UTF8

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-one' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $legacyRelativePath = './output/run-one/stage1/entra-apps/applications/batch-0001.json'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 0 -SuccessCount 0 -FailedCount 0 -ArtifactPath $legacyRelativePath -ErrorMessage $null
        $checkpointPath = Save-CollectorCheckpoint -RunPath $script:runPath -Checkpoint $checkpoint

        Push-Location -LiteralPath $script:otherWorkingDirectory
        try {
            $loaded = Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-one' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            $loadedBatch = Get-CollectorCheckpointBatch -Checkpoint $loaded -BatchId '0001'

            if ([string]$loadedBatch.artifactPath -ne $canonicalArtifactPath) {
                throw ('Expected legacy reference to normalize to canonical run artifact path. Actual: ' + [string]$loadedBatch.artifactPath)
            }

            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $loaded -BatchId '0001' -Resume -ReprocessFailedOnly
            if ($decision.ShouldProcess -or $decision.MarkMissing) {
                throw 'Expected valid legacy artifact to remain recognized during resume from another working directory.'
            }

            if (-not (Test-CollectorInventoryArtifacts -RunPath $script:runPath -Section 'entra-apps' -Family 'applications')) {
                throw 'Expected inventory readiness to use the canonical run artifact location.'
            }

            Save-CollectorCheckpoint -RunPath $script:runPath -Checkpoint $loaded | Out-Null
        }
        finally {
            Pop-Location
        }

        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        if (-not [System.IO.Path]::IsPathRooted([string]@($persisted.batches)[0].artifactPath)) {
            throw 'Expected next checkpoint save to migrate legacy relative artifactPath to rooted canonical form.'
        }
    }

    It 'still detects a genuinely missing canonical artifact' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-one' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath './legacy/batch-0001.json' -ErrorMessage $null
        Save-CollectorCheckpoint -RunPath $script:runPath -Checkpoint $checkpoint | Out-Null

        $loaded = Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-one' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $decision = Get-CollectorBatchExecutionDecision -Checkpoint $loaded -BatchId '0001' -Resume -ReprocessFailedOnly

        if (-not $decision.ShouldProcess -or -not $decision.MarkMissing) {
            throw 'Expected a missing canonical artifact to remain detectable after path normalization.'
        }

        if (Test-CollectorInventoryArtifacts -RunPath $script:runPath -Section 'entra-apps' -Family 'applications') {
            throw 'Expected inventory readiness to reject the genuinely missing canonical artifact.'
        }
    }
}
