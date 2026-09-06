BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestSnapshotLoaderFixture {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Stage,
            [Parameter(Mandatory = $true)][int]$PlannedItemCount,
            [Parameter(Mandatory = $true)][int]$CheckpointItemCount,
            [Parameter(Mandatory = $true)][int]$SnapshotItemCount,
            [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
            [int]$SuccessCount = $CheckpointItemCount,
            [int]$FailedCount = 0
        )

        $runId = 'stage3-loader-cardinality'
        $section = 'entra-apps'
        $family = if ($Stage -eq 'stage3') { 'servicePrincipalAppRoleAssignedTo' } else { 'applications' }

        $snapshot = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = $runId
            stage = $Stage
            section = $section
            family = $family
            batchId = '0001'
            collectedUtc = '2026-09-06T00:00:00.0000000Z'
            sourceType = 'Test'
            sourceName = 'snapshot-loader-fixture'
            apiVersion = 'n/a'
            isBeta = $false
            requestContext = @{}
            itemCount = $SnapshotItemCount
            items = $Items
        }

        $artifact = Write-CollectorSnapshotArtifact -RunPath $RunPath -Stage $Stage -Section $section -Family $family -BatchNumber 1 -Snapshot $snapshot
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage $Stage -Section $section -Family $family
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount $CheckpointItemCount -SuccessCount $SuccessCount -FailedCount $FailedCount -ArtifactPath $artifact.artifactPath -ErrorMessage $null
        $checkpoint.plan = [pscustomobject]@{
            planVersion = '1.0'
            batchSize = 100
            expectedBatchCount = 1
            sourceFingerprint = ('snapshot-loader-' + $Stage)
            completed = $true
            batches = @([pscustomobject]@{
                batchId = '0001'
                itemCount = $PlannedItemCount
                fingerprint = ('snapshot-loader-' + $Stage + '-0001')
            })
        }
        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null

        return [pscustomobject]@{
            RunId = $runId
            Section = $section
            Family = $family
        }
    }

    function Assert-TestSnapshotLoaderFailure {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Stage,
            [Parameter(Mandatory = $true)][string]$Section,
            [Parameter(Mandatory = $true)][string]$Family,
            [Parameter(Mandatory = $true)][string]$RunId,
            [Parameter(Mandatory = $true)][string]$Pattern
        )

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family -ExpectedRunId $RunId | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch $Pattern) {
                throw ('Expected snapshot-loader rejection matching {0}; actual error: {1}' -f $Pattern, $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw ('Expected snapshot loader to reject invalid {0} cardinality state.' -f $Stage)
        }
    }
}

Describe 'Stage3 snapshot loader output cardinality' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage3-loader-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'loads valid Stage3 relationship output when one planned source item emits two rows' {
        $fixture = Get-TestSnapshotLoaderFixture -RunPath $script:testRoot -Stage 'stage3' -PlannedItemCount 1 -CheckpointItemCount 2 -SnapshotItemCount 2 -Items @(
            [pscustomobject]@{ id = 'edge-1' },
            [pscustomobject]@{ id = 'edge-2' }
        )

        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage3' -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)
        if ($items.Count -ne 2 -or [string]$items[0].id -ne 'edge-1' -or [string]$items[1].id -ne 'edge-2') {
            throw ('Expected two Stage3 relationship rows; actual count: {0}.' -f $items.Count)
        }
    }

    It 'rejects Stage3 snapshot output cardinality that disagrees with its succeeded checkpoint' {
        $fixture = Get-TestSnapshotLoaderFixture -RunPath $script:testRoot -Stage 'stage3' -PlannedItemCount 1 -CheckpointItemCount 2 -SnapshotItemCount 1 -Items @(
            [pscustomobject]@{ id = 'edge-1' },
            [pscustomobject]@{ id = 'edge-2' }
        )

        Assert-TestSnapshotLoaderFailure -RunPath $script:testRoot -Stage 'stage3' -Section $fixture.Section -Family $fixture.Family -RunId $fixture.RunId -Pattern 'Snapshot cardinality mismatch'
    }

    It 'keeps Stage3 succeeded checkpoint success and failure count integrity enforced' {
        $fixture = Get-TestSnapshotLoaderFixture -RunPath $script:testRoot -Stage 'stage3' -PlannedItemCount 1 -CheckpointItemCount 2 -SnapshotItemCount 2 -SuccessCount 1 -FailedCount 0 -Items @(
            [pscustomobject]@{ id = 'edge-1' },
            [pscustomobject]@{ id = 'edge-2' }
        )

        Assert-TestSnapshotLoaderFailure -RunPath $script:testRoot -Stage 'stage3' -Section $fixture.Section -Family $fixture.Family -RunId $fixture.RunId -Pattern 'success/failure counts are inconsistent'
    }

    It 'preserves strict planned and persisted cardinality equality for Stage1 and Stage2' {
        foreach ($stage in @('stage1', 'stage2')) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-loader-' + $stage + '-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $fixture = Get-TestSnapshotLoaderFixture -RunPath $caseRoot -Stage $stage -PlannedItemCount 1 -CheckpointItemCount 2 -SnapshotItemCount 2 -Items @(
                    [pscustomobject]@{ id = 'item-1' },
                    [pscustomobject]@{ id = 'item-2' }
                )
                Assert-TestSnapshotLoaderFailure -RunPath $caseRoot -Stage $stage -Section $fixture.Section -Family $fixture.Family -RunId $fixture.RunId -Pattern 'planned itemCount=1; checkpoint itemCount=2'
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'keeps legitimate zero-item Stage3 output loadable' {
        $fixture = Get-TestSnapshotLoaderFixture -RunPath $script:testRoot -Stage 'stage3' -PlannedItemCount 0 -CheckpointItemCount 0 -SnapshotItemCount 0 -Items @()
        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage3' -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)
        if ($items.Count -ne 0) {
            throw ('Expected zero Stage3 rows; actual count: {0}.' -f $items.Count)
        }
    }
}
