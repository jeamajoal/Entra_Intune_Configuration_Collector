BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestCompletionCheckpoint {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [string]$Stage = 'stage1',

            [object]$PlannedItemCount = 1,

            [object]$BatchItemCount = 1,

            [object]$SuccessCount = 1,

            [object]$FailedCount = 0,

            [string]$Status = 'Succeeded',

            [switch]$OmitArtifact,

            [switch]$OmitRecordedBatch
        )

        $artifactPath = Join-Path -Path $RunPath -ChildPath ('{0}-batch-0001.json' -f $Stage)
        if (-not $OmitArtifact) {
            '{}' | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        }

        $recordedBatches = @()
        if (-not $OmitRecordedBatch) {
            $recordedBatches = @([pscustomobject]@{
                batchId = '0001'
                status = $Status
                attempts = 1
                itemCount = $BatchItemCount
                successCount = $SuccessCount
                failedCount = $FailedCount
                artifactPath = $artifactPath
                error = $null
                updatedUtc = '2026-09-06T00:00:00.0000000Z'
            })
        }

        return [pscustomobject]@{
            schemaVersion = '1.0'
            runId = 'completion-count-integrity'
            stage = $Stage
            section = 'entra-apps'
            family = 'applications'
            updatedUtc = '2026-09-06T00:00:00.0000000Z'
            plan = [pscustomobject]@{
                planVersion = '1.0'
                batchSize = 100
                expectedBatchCount = 1
                sourceFingerprint = 'completion-count-integrity'
                completed = $false
                batches = @([pscustomobject]@{
                    batchId = '0001'
                    itemCount = $PlannedItemCount
                    fingerprint = 'not-used-by-completion'
                })
            }
            batches = @($recordedBatches)
        }
    }
}

Describe 'Checkpoint plan completion count integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-completion-count-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'marks a valid nonzero succeeded batch complete' {
        $checkpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot
        $completed = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint

        if ($completed.plan.completed -ne $true) {
            throw 'Expected valid nonzero succeeded batch evidence to complete the plan.'
        }
    }

    It 'accepts supported integral numeric runtime types for terminal counts' {
        foreach ($numericValue in @([int]2, [long]2, [double]2.0, [decimal]2.0)) {
            $checkpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot -BatchItemCount 2 -SuccessCount 2
            $batch = $checkpoint.batches[0]
            $batch.itemCount = $numericValue
            $batch.successCount = $numericValue
            $batch.failedCount = if ($numericValue -is [decimal]) { [decimal]0 } elseif ($numericValue -is [double]) { [double]0 } elseif ($numericValue -is [long]) { [long]0 } else { [int]0 }

            $completed = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint
            if ($completed.plan.completed -ne $true) {
                throw ('Expected supported integral count type {0} to remain completable.' -f $numericValue.GetType().FullName)
            }
        }
    }

    It 'keeps contradictory succeeded batch counts incomplete' {
        $checkpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot -BatchItemCount 1 -SuccessCount 0 -FailedCount 1
        $completed = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint

        if ($completed.plan.completed -ne $false) {
            throw 'Expected contradictory succeeded batch counts to leave the plan incomplete.'
        }
    }

    It 'fails closed without throwing for missing malformed fractional string Boolean negative and out-of-range counts' {
        $cases = @(
            [pscustomobject]@{ Name = 'missing itemCount'; Property = 'itemCount'; Remove = $true; Value = $null },
            [pscustomobject]@{ Name = 'string successCount'; Property = 'successCount'; Remove = $false; Value = '1' },
            [pscustomobject]@{ Name = 'Boolean failedCount'; Property = 'failedCount'; Remove = $false; Value = $false },
            [pscustomobject]@{ Name = 'fractional itemCount'; Property = 'itemCount'; Remove = $false; Value = [double]1.5 },
            [pscustomobject]@{ Name = 'negative successCount'; Property = 'successCount'; Remove = $false; Value = -1 },
            [pscustomobject]@{ Name = 'object failedCount'; Property = 'failedCount'; Remove = $false; Value = [pscustomobject]@{ value = 0 } },
            [pscustomobject]@{ Name = 'out-of-range itemCount'; Property = 'itemCount'; Remove = $false; Value = ([long][int]::MaxValue + 1) }
        )

        foreach ($case in $cases) {
            $checkpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot
            $batch = $checkpoint.batches[0]
            if ($case.Remove) {
                $batch.PSObject.Properties.Remove([string]$case.Property)
            }
            else {
                $batch.PSObject.Properties[[string]$case.Property].Value = $case.Value
            }

            try {
                $completed = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint
            }
            catch {
                throw ('Expected [{0}] to fail closed without throwing; actual error: {1}' -f $case.Name, $_.Exception.Message)
            }

            if ($completed.plan.completed -ne $false) {
                throw ('Expected [{0}] to leave the plan incomplete.' -f $case.Name)
            }
        }
    }

    It 'preserves legitimate zero-item successful completion' {
        $checkpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot -PlannedItemCount 0 -BatchItemCount 0 -SuccessCount 0 -FailedCount 0
        $completed = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint

        if ($completed.plan.completed -ne $true) {
            throw 'Expected legitimate zero-item succeeded evidence to complete the plan.'
        }
    }

    It 'does not impose Stage3 source-plan versus output cardinality equality' {
        $checkpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot -Stage 'stage3' -PlannedItemCount 1 -BatchItemCount 2 -SuccessCount 2 -FailedCount 0
        $completed = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint

        if ($completed.plan.completed -ne $true) {
            throw 'Expected Stage3 output cardinality 2 to complete despite source-plan itemCount 1 when terminal output counts are truthful.'
        }
    }

    It 'preserves existing incomplete behavior for non-succeeded missing-artifact missing-batch and batch-count mismatch states' {
        $failedCheckpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot -Status 'Failed'
        if ((Complete-CollectorCheckpointPlan -Checkpoint $failedCheckpoint).plan.completed -ne $false) {
            throw 'Expected Failed batch status to remain incomplete.'
        }

        $missingArtifactCheckpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot -OmitArtifact
        if ((Complete-CollectorCheckpointPlan -Checkpoint $missingArtifactCheckpoint).plan.completed -ne $false) {
            throw 'Expected missing artifact to remain incomplete.'
        }

        $missingBatchCheckpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot -OmitRecordedBatch
        if ((Complete-CollectorCheckpointPlan -Checkpoint $missingBatchCheckpoint).plan.completed -ne $false) {
            throw 'Expected missing recorded batch to remain incomplete.'
        }

        $extraBatchCheckpoint = Get-TestCompletionCheckpoint -RunPath $script:testRoot
        $extraBatchCheckpoint.batches += [pscustomobject]@{
            batchId = '9999'
            status = 'Succeeded'
            attempts = 1
            itemCount = 0
            successCount = 0
            failedCount = 0
            artifactPath = $extraBatchCheckpoint.batches[0].artifactPath
            error = $null
            updatedUtc = '2026-09-06T00:00:00.0000000Z'
        }
        if ((Complete-CollectorCheckpointPlan -Checkpoint $extraBatchCheckpoint).plan.completed -ne $false) {
            throw 'Expected recorded batch-count mismatch to remain incomplete.'
        }
    }
}
