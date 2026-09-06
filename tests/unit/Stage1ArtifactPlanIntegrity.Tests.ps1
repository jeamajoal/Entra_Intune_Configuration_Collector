BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Save-TestCorruptCheckpoint {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string[]]$PlannedBatchIds,
            [Parameter(Mandatory = $true)] [string[]]$RecordedBatchIds,
            [string]$RunId = 'logical-run'
        )

        $planBatches = @($PlannedBatchIds | ForEach-Object {
            [pscustomobject]@{
                batchId = [string]$_
                itemCount = 1
                fingerprint = 'plan-' + [string]$_
            }
        })

        $recordedBatches = @($RecordedBatchIds | ForEach-Object {
            [pscustomobject]@{
                batchId = [string]$_
                status = 'Succeeded'
                attempts = 1
                itemCount = 1
                successCount = 1
                failedCount = 0
                artifactPath = Join-Path -Path $RunPath -ChildPath ('stage1/entra-apps/applications/batch-{0}.json' -f [string]$_)
                error = $null
                updatedUtc = '2026-09-06T00:00:00.0000000Z'
            }
        })

        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = $RunId
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            updatedUtc = '2026-09-06T00:00:00.0000000Z'
            plan = [pscustomobject]@{
                planVersion = '1.0'
                batchSize = 100
                expectedBatchCount = @($PlannedBatchIds).Count
                sourceFingerprint = 'test-source'
                completed = $true
                batches = @($planBatches)
            }
            batches = @($recordedBatches)
        }

        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
    }
}

Describe 'Stage1 checkpoint plan identity set validation' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage1-plan-integrity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects duplicate planned batch identities before loading any artifact' {
        Save-TestCorruptCheckpoint -RunPath $script:testRoot -PlannedBatchIds @('0001', '0001') -RecordedBatchIds @('0001', '0002')

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'duplicate batch identity') {
                throw ('Expected duplicate planned-batch rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected duplicate planned batch identities to fail closed.'
        }
    }

    It 'rejects a recorded batch identity set that differs from the completed plan' {
        Save-TestCorruptCheckpoint -RunPath $script:testRoot -PlannedBatchIds @('0001', '0002') -RecordedBatchIds @('0001', '0003')

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'planned and recorded batch identities do not match') {
                throw ('Expected planned/recorded batch-set rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected mismatched planned and recorded batch sets to fail closed.'
        }
    }

    It 'rejects checkpoint run identity that disagrees with a persisted manifest' {
        Save-TestCorruptCheckpoint -RunPath $script:testRoot -PlannedBatchIds @('0001') -RecordedBatchIds @('0001') -RunId 'checkpoint-run'
        $manifestDirectory = Join-Path -Path $script:testRoot -ChildPath 'manifest'
        New-Item -Path $manifestDirectory -ItemType Directory -Force | Out-Null
        [pscustomobject]@{ runId = 'manifest-run' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path -Path $manifestDirectory -ChildPath 'run-manifest.json') -Encoding UTF8

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'does not match the persisted manifest') {
                throw ('Expected manifest/checkpoint run identity rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected checkpoint/manifest run identity mismatch to fail closed.'
        }
    }
}
