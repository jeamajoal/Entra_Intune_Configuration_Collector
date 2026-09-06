BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestResumePlanCheckpoint {
        param(
            [Parameter(Mandatory = $true)]
            [object[]]$Batches,

            [int]$BatchSize = 100
        )

        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = 'resume-plan-numeric-integrity'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            updatedUtc = '2026-09-06T00:00:00.0000000Z'
            plan = $null
            batches = @()
        }

        return Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $Batches -BatchSize $BatchSize
    }

    function Copy-TestResumePlanCheckpoint {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$Checkpoint
        )

        return ($Checkpoint | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    }

    function Get-TestSingleItemBatchSet {
        return [object[]]@([object[]]@([pscustomobject]@{ id = 'one' }))
    }
}

Describe 'Resume checkpoint plan numeric integrity' {
    It 'rejects malformed persisted batchSize values with the bounded resume mismatch and does not normalize them' {
        $batches = Get-TestSingleItemBatchSet
        $baseline = Get-TestResumePlanCheckpoint -Batches $batches -BatchSize 100
        $cases = @(
            [pscustomobject]@{ Name = 'string numeric'; Remove = $false; Value = '100' },
            [pscustomobject]@{ Name = 'Boolean'; Remove = $false; Value = $true },
            [pscustomobject]@{ Name = 'fractional'; Remove = $false; Value = [double]100.4 },
            [pscustomobject]@{ Name = 'zero'; Remove = $false; Value = 0 },
            [pscustomobject]@{ Name = 'negative'; Remove = $false; Value = -100 },
            [pscustomobject]@{ Name = 'object'; Remove = $false; Value = [pscustomobject]@{ value = 100 } },
            [pscustomobject]@{ Name = 'out of range'; Remove = $false; Value = ([long][int]::MaxValue + 1) },
            [pscustomobject]@{ Name = 'null'; Remove = $false; Value = $null },
            [pscustomobject]@{ Name = 'missing'; Remove = $true; Value = $null }
        )

        foreach ($case in $cases) {
            $candidate = Copy-TestResumePlanCheckpoint -Checkpoint $baseline
            if ($case.Remove) {
                $candidate.plan.PSObject.Properties.Remove('batchSize')
            }
            else {
                $candidate.plan.PSObject.Properties['batchSize'].Value = $case.Value
            }

            $errorMessage = $null
            try {
                Initialize-CollectorCheckpointPlan -Checkpoint $candidate -Batches $batches -BatchSize 100 -Resume | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }

            if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch '^Resume plan mismatch') {
                throw ('Expected malformed batchSize case [{0}] to fail with bounded resume mismatch; actual: {1}' -f $case.Name, [string]$errorMessage)
            }

            if ($case.Remove) {
                if ($candidate.plan.PSObject.Properties.Match('batchSize').Count -ne 0) {
                    throw ('Expected rejected missing batchSize case [{0}] to remain unnormalized.' -f $case.Name)
                }
            }
            elseif ($candidate.plan.batchSize -is [int] -and [int]$candidate.plan.batchSize -eq 100) {
                throw ('Expected rejected batchSize case [{0}] not to be silently normalized to current plan value.' -f $case.Name)
            }
        }
    }

    It 'rejects malformed persisted expectedBatchCount values with the bounded resume mismatch and does not normalize them' {
        $batches = Get-TestSingleItemBatchSet
        $baseline = Get-TestResumePlanCheckpoint -Batches $batches -BatchSize 100
        $cases = @(
            [pscustomobject]@{ Name = 'string numeric'; Remove = $false; Value = '1' },
            [pscustomobject]@{ Name = 'Boolean'; Remove = $false; Value = $true },
            [pscustomobject]@{ Name = 'fractional'; Remove = $false; Value = [double]1.4 },
            [pscustomobject]@{ Name = 'zero'; Remove = $false; Value = 0 },
            [pscustomobject]@{ Name = 'negative'; Remove = $false; Value = -1 },
            [pscustomobject]@{ Name = 'object'; Remove = $false; Value = [pscustomobject]@{ value = 1 } },
            [pscustomobject]@{ Name = 'out of range'; Remove = $false; Value = ([long][int]::MaxValue + 1) },
            [pscustomobject]@{ Name = 'null'; Remove = $false; Value = $null },
            [pscustomobject]@{ Name = 'missing'; Remove = $true; Value = $null }
        )

        foreach ($case in $cases) {
            $candidate = Copy-TestResumePlanCheckpoint -Checkpoint $baseline
            if ($case.Remove) {
                $candidate.plan.PSObject.Properties.Remove('expectedBatchCount')
            }
            else {
                $candidate.plan.PSObject.Properties['expectedBatchCount'].Value = $case.Value
            }

            $errorMessage = $null
            try {
                Initialize-CollectorCheckpointPlan -Checkpoint $candidate -Batches $batches -BatchSize 100 -Resume | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }

            if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch '^Resume plan mismatch') {
                throw ('Expected malformed expectedBatchCount case [{0}] to fail with bounded resume mismatch; actual: {1}' -f $case.Name, [string]$errorMessage)
            }

            if ($case.Remove) {
                if ($candidate.plan.PSObject.Properties.Match('expectedBatchCount').Count -ne 0) {
                    throw ('Expected rejected missing expectedBatchCount case [{0}] to remain unnormalized.' -f $case.Name)
                }
            }
            elseif ($candidate.plan.expectedBatchCount -is [int] -and [int]$candidate.plan.expectedBatchCount -eq 1) {
                throw ('Expected rejected expectedBatchCount case [{0}] not to be silently normalized to current plan value.' -f $case.Name)
            }
        }
    }

    It 'accepts supported integral numeric runtime forms that match the current plan' {
        $batches = Get-TestSingleItemBatchSet
        $baseline = Get-TestResumePlanCheckpoint -Batches $batches -BatchSize 100
        $typeCases = @(
            [pscustomobject]@{ BatchSize = [int]100; ExpectedBatchCount = [int]1 },
            [pscustomobject]@{ BatchSize = [long]100; ExpectedBatchCount = [long]1 },
            [pscustomobject]@{ BatchSize = [double]100.0; ExpectedBatchCount = [double]1.0 },
            [pscustomobject]@{ BatchSize = [decimal]100.0; ExpectedBatchCount = [decimal]1.0 }
        )

        foreach ($typeCase in $typeCases) {
            $candidate = Copy-TestResumePlanCheckpoint -Checkpoint $baseline
            $candidate.plan.batchSize = $typeCase.BatchSize
            $candidate.plan.expectedBatchCount = $typeCase.ExpectedBatchCount

            $resumed = Initialize-CollectorCheckpointPlan -Checkpoint $candidate -Batches $batches -BatchSize 100 -Resume
            if ([int]$resumed.plan.batchSize -ne 100 -or [int]$resumed.plan.expectedBatchCount -ne 1) {
                throw 'Expected supported integral numeric forms to remain resume-compatible.'
            }
        }
    }

    It 'preserves existing planVersion and sourceFingerprint mismatch behavior' {
        $batches = Get-TestSingleItemBatchSet
        $baseline = Get-TestResumePlanCheckpoint -Batches $batches -BatchSize 100

        foreach ($propertyName in @('planVersion', 'sourceFingerprint')) {
            $candidate = Copy-TestResumePlanCheckpoint -Checkpoint $baseline
            $candidate.plan.PSObject.Properties[$propertyName].Value = 'different'

            $errorMessage = $null
            try {
                Initialize-CollectorCheckpointPlan -Checkpoint $candidate -Batches $batches -BatchSize 100 -Resume | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }

            if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch '^Resume plan mismatch') {
                throw ('Expected {0} mismatch to retain bounded resume mismatch behavior.' -f $propertyName)
            }
        }
    }

    It 'preserves legitimate zero-item planning as one positive expected batch' {
        $zeroBatches = New-Object 'object[]' 1
        $zeroBatches[0] = [object[]]@()

        $baseline = Get-TestResumePlanCheckpoint -Batches $zeroBatches -BatchSize 100
        if ([int]$baseline.plan.expectedBatchCount -ne 1 -or [int]$baseline.plan.batches[0].itemCount -ne 0) {
            throw 'Expected zero-item input to persist one planned empty batch.'
        }

        $resumed = Initialize-CollectorCheckpointPlan -Checkpoint (Copy-TestResumePlanCheckpoint -Checkpoint $baseline) -Batches $zeroBatches -BatchSize 100 -Resume
        if ([int]$resumed.plan.expectedBatchCount -ne 1 -or [int]$resumed.plan.batches[0].itemCount -ne 0) {
            throw 'Expected legitimate zero-item plan to remain resume-compatible.'
        }
    }
}
