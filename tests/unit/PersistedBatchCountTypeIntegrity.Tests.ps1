BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestBatchCountContext {
        param([Parameter(Mandatory = $true)][string]$RunPath)

        return @{
            RunPath = $RunPath
            RunId = 'persisted-batch-count-type'
            GraphToken = 'test-token'
            BatchSize = 100
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $false
            ReprocessFailedOnly = $false
        }
    }

    function Get-TestSucceededBatch {
        param(
            [object]$ItemCount = 1,
            [object]$SuccessCount = 1,
            [object]$FailedCount = 0,
            [Parameter(Mandatory = $true)][string]$ArtifactPath
        )

        return [pscustomobject]@{
            batchId = '0001'
            status = 'Succeeded'
            attempts = 1
            itemCount = $ItemCount
            successCount = $SuccessCount
            failedCount = $FailedCount
            artifactPath = $ArtifactPath
            error = $null
        }
    }

    function Get-TestDecisionCheckpoint {
        param([Parameter(Mandatory = $true)][object]$Batch)

        return [pscustomobject]@{
            schemaVersion = '1.0'
            runId = 'persisted-batch-count-type'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            plan = $null
            batches = @($Batch)
        }
    }

    function Save-TestCountMutation {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family,
            [Parameter(Mandatory = $true)][scriptblock]$Mutation
        )

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId 'persisted-batch-count-type' -Stage 'stage1' -Section 'entra-apps' -Family $Family
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        & $Mutation $batch
        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
    }
}

Describe 'Persisted succeeded batch count type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-persisted-count-type-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        Set-Content -LiteralPath $script:artifactPath -Value '{}' -Encoding UTF8
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'reprocesses succeeded state with schema-invalid terminal count types instead of skipping it' {
        $invalidValues = @(
            '1',
            $true,
            [pscustomobject]@{ value = 1 },
            [double]1.5,
            [double]::Parse('1.0000000000000002', [System.Globalization.CultureInfo]::InvariantCulture),
            [double]::NaN,
            [double]::PositiveInfinity,
            -1,
            ([long][int]::MaxValue + 1),
            $null
        )

        foreach ($invalidValue in $invalidValues) {
            foreach ($propertyName in @('itemCount', 'successCount', 'failedCount')) {
                $itemCount = 1
                $successCount = 1
                $failedCount = 0
                switch ($propertyName) {
                    'itemCount' { $itemCount = $invalidValue }
                    'successCount' { $successCount = $invalidValue }
                    'failedCount' { $failedCount = $invalidValue }
                }

                $batch = Get-TestSucceededBatch -ItemCount $itemCount -SuccessCount $successCount -FailedCount $failedCount -ArtifactPath $script:artifactPath
                $checkpoint = Get-TestDecisionCheckpoint -Batch $batch
                $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume

                if (-not $decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -ne 'InvalidSucceededCounts') {
                    throw ('Expected invalid {0} value [{1}] to force reprocessing; ShouldProcess={2}; MarkMissing={3}; Reason={4}' -f $propertyName, [string]$invalidValue, $decision.ShouldProcess, $decision.MarkMissing, $decision.Reason)
                }
            }
        }
    }

    It 'reprocesses succeeded state when a required terminal count property is missing' {
        foreach ($propertyName in @('itemCount', 'successCount', 'failedCount')) {
            $batch = Get-TestSucceededBatch -ArtifactPath $script:artifactPath
            $batch.PSObject.Properties.Remove($propertyName)
            $decision = Get-CollectorBatchExecutionDecision -Checkpoint (Get-TestDecisionCheckpoint -Batch $batch) -BatchId '0001' -Resume

            if (-not $decision.ShouldProcess -or [string]$decision.Reason -ne 'InvalidSucceededCounts') {
                throw ('Expected missing {0} to force reprocessing.' -f $propertyName)
            }
        }
    }

    It 'keeps supported integral numeric runtime forms and legitimate zero-item state skippable' {
        $validCases = @(
            [pscustomobject]@{ ItemCount = [int]1; SuccessCount = [int]1; FailedCount = [int]0 },
            [pscustomobject]@{ ItemCount = [long]1; SuccessCount = [long]1; FailedCount = [long]0 },
            [pscustomobject]@{ ItemCount = [double]1.0; SuccessCount = [double]1.0; FailedCount = [double]0.0 },
            [pscustomobject]@{ ItemCount = [decimal]1.0; SuccessCount = [decimal]1.0; FailedCount = [decimal]0.0 },
            [pscustomobject]@{ ItemCount = [int]0; SuccessCount = [int]0; FailedCount = [int]0 }
        )

        foreach ($validCase in $validCases) {
            $batch = Get-TestSucceededBatch -ItemCount $validCase.ItemCount -SuccessCount $validCase.SuccessCount -FailedCount $validCase.FailedCount -ArtifactPath $script:artifactPath
            $decision = Get-CollectorBatchExecutionDecision -Checkpoint (Get-TestDecisionCheckpoint -Batch $batch) -BatchId '0001' -Resume

            if ($decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -ne 'SucceededWithArtifact') {
                throw ('Expected valid numeric terminal counts to remain skippable; Reason={0}' -f $decision.Reason)
            }
        }
    }

    It 'rejects numeric-string and near-integer Double checkpoint counts during generic snapshot loading' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'seed-1'; displayName = 'seed-1' })
        }

        $cases = @(
            { param($batch) $batch.itemCount = '1' },
            { param($batch) $batch.successCount = '1' },
            { param($batch) $batch.failedCount = '0' },
            { param($batch) $batch.itemCount = [double]::Parse('1.0000000000000002', [System.Globalization.CultureInfo]::InvariantCulture) }
        )

        foreach ($mutation in $cases) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-persisted-count-load-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $context = Get-TestBatchCountContext -RunPath $caseRoot
                Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
                Save-TestCountMutation -RunPath $caseRoot -Family 'applications' -Mutation $mutation

                $threw = $false
                try {
                    Get-CollectorSnapshotItems -RunPath $caseRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'persisted-batch-count-type' | Out-Null
                }
                catch {
                    $threw = $true
                    if ($_.Exception.Message -notmatch 'success/failure counts') {
                        throw ('Expected strict terminal-count rejection; actual error: {0}' -f $_.Exception.Message)
                    }
                }

                if (-not $threw) {
                    throw 'Expected generic snapshot loading to reject schema-invalid terminal count types.'
                }
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'reprocesses a schema-invalid Stage1 succeeded batch while valid neighboring families remain skipped' {
        $context = Get-TestBatchCountContext -RunPath $script:testRoot
        $script:collectionCalls = 0
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            $script:collectionCalls++
            @([pscustomobject]@{ id = 'seed-1'; displayName = 'seed-1' })
        }

        $initialResults = @(Invoke-CollectorStage1 -Context $context -Sections @('entra-apps'))
        if ($initialResults.Count -ne 3 -or $script:collectionCalls -ne 3) {
            throw 'Expected initial Stage1 execution to collect all three entra-apps families.'
        }

        Save-TestCountMutation -RunPath $script:testRoot -Family 'applications' -Mutation {
            param($batch)
            $batch.itemCount = '1'
            $batch.successCount = '1'
            $batch.failedCount = '0'
        }

        $context.Resume = $true
        $resumeResults = @(Invoke-CollectorStage1 -Context $context -Sections @('entra-apps'))
        $applications = $resumeResults | Where-Object { $_.family -eq 'applications' } | Select-Object -First 1
        $servicePrincipals = $resumeResults | Where-Object { $_.family -eq 'servicePrincipals' } | Select-Object -First 1
        $groups = $resumeResults | Where-Object { $_.family -eq 'groups' } | Select-Object -First 1

        if ($script:collectionCalls -ne 6) {
            throw ('Stage1 collects source inventory before deciding per-batch reuse; expected six total collection calls across two runs, found {0}.' -f $script:collectionCalls)
        }
        if ($applications.succeededBatches -ne 1 -or $applications.skippedBatches -ne 0) {
            throw ('Expected malformed applications batch to be reprocessed successfully; succeeded={0}; skipped={1}.' -f $applications.succeededBatches, $applications.skippedBatches)
        }
        if ($servicePrincipals.skippedBatches -ne 1 -or $groups.skippedBatches -ne 1) {
            throw ('Expected valid neighboring families to remain skipped; servicePrincipals={0}; groups={1}.' -f $servicePrincipals.skippedBatches, $groups.skippedBatches)
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'persisted-batch-count-type' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        if ($batch.itemCount -is [string] -or $batch.successCount -is [string] -or $batch.failedCount -is [string] -or -not [bool]$checkpoint.plan.completed) {
            throw 'Expected Stage1 reprocessing to replace malformed string counts with valid numeric state and restore plan completion.'
        }
    }
}
