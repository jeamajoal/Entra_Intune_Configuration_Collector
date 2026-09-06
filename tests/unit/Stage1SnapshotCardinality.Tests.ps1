BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Initialize-CardinalityFixture {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [object]$PlanItemCount,
            [Parameter(Mandatory = $true)] [object]$CheckpointItemCount,
            [Parameter(Mandatory = $true)] [object]$SnapshotItemCount,
            [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Items
        )

        $runId = 'cardinality-run'
        $section = 'entra-apps'
        $family = 'applications'
        $batchId = '0001'
        $artifactPath = [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath 'stage1/entra-apps/applications/batch-0001.json'))
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null

        $snapshot = [ordered]@{
            schemaVersion = '1.0'
            runId = $runId
            stage = 'stage1'
            section = $section
            family = $family
            batchId = $batchId
            collectedUtc = '2026-09-06T00:00:00.0000000Z'
            sourceType = 'Graph'
            sourceName = '/v1.0/applications'
            apiVersion = 'v1.0'
            isBeta = $false
            requestContext = @{}
            itemCount = $SnapshotItemCount
            items = @($Items)
        }
        $snapshot | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = $runId
            stage = 'stage1'
            section = $section
            family = $family
            updatedUtc = '2026-09-06T00:00:00.0000000Z'
            plan = [pscustomobject]@{
                planVersion = '1.0'
                batchSize = 100
                expectedBatchCount = 1
                sourceFingerprint = 'cardinality-test'
                completed = $true
                batches = @([pscustomobject]@{
                    batchId = $batchId
                    itemCount = $PlanItemCount
                    fingerprint = Get-CollectorSnapshotBatchFingerprint -Items @($Items)
                })
            }
            batches = @([pscustomobject]@{
                batchId = $batchId
                status = 'Succeeded'
                attempts = 1
                itemCount = $CheckpointItemCount
                successCount = $CheckpointItemCount
                failedCount = 0
                artifactPath = $artifactPath
                error = $null
                updatedUtc = '2026-09-06T00:00:00.0000000Z'
            })
        }

        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
    }

    function Assert-CardinalityFailure {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$ExpectedMessagePattern
        )

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $RunPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch $ExpectedMessagePattern) {
                throw ('Expected cardinality failure matching {0}; actual error: {1}' -f $ExpectedMessagePattern, $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw ('Expected snapshot cardinality validation to fail: {0}.' -f $ExpectedMessagePattern)
        }
    }
}

Describe 'Stage1 snapshot cardinality integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-cardinality-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects an identity-correct snapshot with fewer actual items than planned' {
        Initialize-CardinalityFixture -RunPath $script:testRoot -PlanItemCount 2 -CheckpointItemCount 2 -SnapshotItemCount 2 -Items @([pscustomobject]@{ id = 'one' })
        Assert-CardinalityFailure -RunPath $script:testRoot -ExpectedMessagePattern 'Snapshot cardinality mismatch'
    }

    It 'rejects an identity-correct snapshot with extra actual items' {
        Initialize-CardinalityFixture -RunPath $script:testRoot -PlanItemCount 1 -CheckpointItemCount 1 -SnapshotItemCount 1 -Items @([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' })
        Assert-CardinalityFailure -RunPath $script:testRoot -ExpectedMessagePattern 'Snapshot cardinality mismatch'
    }

    It 'rejects a snapshot-declared itemCount that disagrees with the plan' {
        Initialize-CardinalityFixture -RunPath $script:testRoot -PlanItemCount 1 -CheckpointItemCount 1 -SnapshotItemCount 2 -Items @([pscustomobject]@{ id = 'one' })
        Assert-CardinalityFailure -RunPath $script:testRoot -ExpectedMessagePattern 'Snapshot cardinality mismatch'
    }

    It 'rejects a checkpoint-batch itemCount that disagrees with the plan' {
        Initialize-CardinalityFixture -RunPath $script:testRoot -PlanItemCount 1 -CheckpointItemCount 2 -SnapshotItemCount 1 -Items @([pscustomobject]@{ id = 'one' })
        Assert-CardinalityFailure -RunPath $script:testRoot -ExpectedMessagePattern 'checkpoint itemCount=2'
    }

    It 'rejects a nonnumeric planned itemCount' {
        Initialize-CardinalityFixture -RunPath $script:testRoot -PlanItemCount 'not-a-count' -CheckpointItemCount 1 -SnapshotItemCount 1 -Items @([pscustomobject]@{ id = 'one' })
        Assert-CardinalityFailure -RunPath $script:testRoot -ExpectedMessagePattern 'plan has an invalid itemCount'
    }

    It 'preserves a legitimate zero-item planned snapshot' {
        Initialize-CardinalityFixture -RunPath $script:testRoot -PlanItemCount 0 -CheckpointItemCount 0 -SnapshotItemCount 0 -Items @()
        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications')
        if ($items.Count -ne 0) {
            throw ('Expected zero-item Stage1 snapshot to load successfully; actual count {0}.' -f $items.Count)
        }
    }

    It 'preserves a valid nonzero planned snapshot' {
        Initialize-CardinalityFixture -RunPath $script:testRoot -PlanItemCount 2 -CheckpointItemCount 2 -SnapshotItemCount 2 -Items @([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' })
        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications')
        $ids = @($items | ForEach-Object { [string]$_.id })
        if ($ids.Count -ne 2 -or $ids[0] -ne 'one' -or $ids[1] -ne 'two') {
            throw ('Expected valid snapshot items one,two; actual: {0}.' -f ($ids -join ','))
        }
    }
}
