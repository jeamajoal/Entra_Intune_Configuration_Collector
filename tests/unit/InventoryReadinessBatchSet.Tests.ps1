BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestReadinessFixture {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [switch]$ZeroItem
        )

        $runId = 'readiness-batch-set'
        $section = 'entra-apps'
        $family = 'applications'
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage 'stage1' -Section $section -Family $family

        $batches = if ($ZeroItem) {
            [object[]]@([object[]]@())
        }
        else {
            [object[]]@(
                [object[]]@([pscustomobject]@{ id = 'one' }),
                [object[]]@([pscustomobject]@{ id = 'two' })
            )
        }

        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 1
        foreach ($plannedBatch in @($checkpoint.plan.batches)) {
            $batchId = [string]$plannedBatch.batchId
            $artifactPath = [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath ('stage1/entra-apps/applications/batch-{0}.json' -f $batchId)))
            New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
            '{}' | Set-Content -LiteralPath $artifactPath -Encoding UTF8

            $itemCount = [int]$plannedBatch.itemCount
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Succeeded' -Attempts 1 -ItemCount $itemCount -SuccessCount $itemCount -FailedCount 0 -ArtifactPath $artifactPath -ErrorMessage $null
        }

        $checkpoint.plan.completed = $true
        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null

        return [pscustomobject]@{
            Checkpoint = $checkpoint
            RunId = $runId
            Section = $section
            Family = $family
        }
    }
}

Describe 'Stage1 inventory readiness exact batch-set integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-readiness-batch-set-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts a valid exact multi-batch Stage1 plan and recorded batch set' {
        $fixture = Get-TestReadinessFixture -RunPath $script:testRoot
        if (-not (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)) {
            throw 'Expected exact two-batch Stage1 readiness to succeed.'
        }
    }

    It 'rejects a recorded succeeded batch that substitutes an unplanned batch id even when its canonical artifact exists' {
        $fixture = Get-TestReadinessFixture -RunPath $script:testRoot
        $checkpoint = $fixture.Checkpoint
        $replacementPath = [System.IO.Path]::GetFullPath((Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications/batch-9999.json'))
        '{}' | Set-Content -LiteralPath $replacementPath -Encoding UTF8
        $checkpoint.batches[1].batchId = '9999'
        $checkpoint.batches[1].artifactPath = $replacementPath
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        if (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId) {
            throw 'Expected readiness to reject a recorded batch set that substitutes unplanned batch 9999 for planned batch 0002.'
        }
    }

    It 'rejects duplicate or empty planned batch ids' {
        foreach ($plannedBatchId in @('0001', '')) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-readiness-planned-id-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $fixture = Get-TestReadinessFixture -RunPath $caseRoot
                $checkpoint = $fixture.Checkpoint
                $checkpoint.plan.batches[1].batchId = $plannedBatchId
                Save-CollectorCheckpoint -RunPath $caseRoot -Checkpoint $checkpoint | Out-Null

                if (Test-CollectorInventoryArtifacts -RunPath $caseRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId) {
                    throw ('Expected readiness to reject invalid planned batch id value [{0}].' -f $plannedBatchId)
                }
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'rejects duplicate or empty recorded checkpoint batch ids' {
        foreach ($recordedBatchId in @('0001', '')) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-readiness-recorded-id-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $fixture = Get-TestReadinessFixture -RunPath $caseRoot
                $checkpoint = $fixture.Checkpoint
                $checkpoint.batches[1].batchId = $recordedBatchId
                if ([string]::IsNullOrWhiteSpace($recordedBatchId)) {
                    $emptyArtifactPath = [System.IO.Path]::GetFullPath((Join-Path -Path $caseRoot -ChildPath 'stage1/entra-apps/applications/batch-.json'))
                    '{}' | Set-Content -LiteralPath $emptyArtifactPath -Encoding UTF8
                }
                Save-CollectorCheckpoint -RunPath $caseRoot -Checkpoint $checkpoint | Out-Null

                if (Test-CollectorInventoryArtifacts -RunPath $caseRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId) {
                    throw ('Expected readiness to reject invalid recorded batch id value [{0}].' -f $recordedBatchId)
                }
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'keeps the legitimate one-batch zero-item Stage1 readiness contract valid' {
        $fixture = Get-TestReadinessFixture -RunPath $script:testRoot -ZeroItem
        if (-not (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)) {
            throw 'Expected legitimate zero-item Stage1 readiness to succeed.'
        }
    }
}
