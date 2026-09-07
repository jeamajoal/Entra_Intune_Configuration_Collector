BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestItemCountContext {
        param([Parameter(Mandatory = $true)][string]$RunPath)

        return @{
            RunPath = $RunPath
            RunId = 'persisted-itemcount-type'
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

    function Get-TestItemCountDecisionCheckpoint {
        param(
            [Parameter(Mandatory = $true)][string]$ArtifactPath,
            [object]$ItemCount = 1,
            [object]$SuccessCount = 1,
            [object]$FailedCount = 0
        )

        return [pscustomobject]@{
            schemaVersion = '1.0'
            runId = 'persisted-itemcount-type'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            plan = $null
            batches = @([pscustomobject]@{
                batchId = '0001'
                status = 'Succeeded'
                attempts = 1
                itemCount = $ItemCount
                successCount = $SuccessCount
                failedCount = $FailedCount
                artifactPath = $ArtifactPath
                error = $null
            })
        }
    }

    function Write-TestRawSnapshot {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$ItemCountJson
        )

        $json = '{"itemCount":' + $ItemCountJson + ',"items":[{"id":"seed-1"}]}'
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    }

    function Invoke-TestStage1Seed {
        param([Parameter(Mandatory = $true)][string]$RunPath)

        $context = Get-TestItemCountContext -RunPath $RunPath
        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
        return $context
    }

    function Get-TestStage1Checkpoint {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family
        )

        return Get-CollectorCheckpoint -RunPath $RunPath -RunId 'persisted-itemcount-type' -Stage 'stage1' -Section 'entra-apps' -Family $Family
    }
}

Describe 'Persisted plan and snapshot itemCount type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-persisted-itemcount-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'seed-1'; displayName = 'seed-1' })
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts only supported integral nonnegative in-range runtime itemCount values' {
        $validValues = @(
            [int]1,
            [long]1,
            [double]1.0,
            [decimal]1.0,
            [int]0
        )
        foreach ($value in $validValues) {
            $holder = [pscustomobject]@{ itemCount = $value }
            $parsed = Get-CollectorBatchCountValue -Batch $holder -PropertyName 'itemCount'
            if ($null -eq $parsed -or $parsed -ne [int]$value) {
                throw ('Expected supported itemCount value [{0}] ({1}) to remain valid.' -f $value, $value.GetType().FullName)
            }
        }

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
        foreach ($value in $invalidValues) {
            $holder = [pscustomobject]@{ itemCount = $value }
            if ($null -ne (Get-CollectorBatchCountValue -Batch $holder -PropertyName 'itemCount')) {
                throw ('Expected schema-invalid itemCount value [{0}] to be rejected.' -f [string]$value)
            }
        }

        $missing = [pscustomobject]@{}
        if ($null -ne (Get-CollectorBatchCountValue -Batch $missing -PropertyName 'itemCount')) {
            throw 'Expected missing itemCount to be rejected.'
        }
    }

    It 'reprocesses artifact-present succeeded state whose persisted snapshot itemCount is schema-invalid' {
        $invalidJsonValues = @(
            '"1"',
            'true',
            '{"value":1}',
            '1.5',
            '1.0000000000000002',
            '-1',
            '2147483648',
            'null'
        )

        foreach ($itemCountJson in $invalidJsonValues) {
            Write-TestRawSnapshot -Path $script:artifactPath -ItemCountJson $itemCountJson
            $checkpoint = Get-TestItemCountDecisionCheckpoint -ArtifactPath $script:artifactPath
            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume

            if (-not $decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -ne 'InvalidSnapshotItemCount') {
                throw ('Expected persisted snapshot itemCount JSON [{0}] to force reprocessing; Reason={1}.' -f $itemCountJson, $decision.Reason)
            }
        }

        Set-Content -LiteralPath $script:artifactPath -Value '{"items":[{"id":"seed-1"}]}' -Encoding UTF8
        $missingDecision = Get-CollectorBatchExecutionDecision -Checkpoint (Get-TestItemCountDecisionCheckpoint -ArtifactPath $script:artifactPath) -BatchId '0001' -Resume
        if (-not $missingDecision.ShouldProcess -or [string]$missingDecision.Reason -ne 'InvalidSnapshotItemCount') {
            throw 'Expected missing persisted snapshot itemCount to force reprocessing.'
        }
    }

    It 'keeps valid numeric and legitimate zero-item persisted snapshot counts skippable' {
        $validCases = @(
            [pscustomobject]@{ Json = '1'; Count = 1 },
            [pscustomobject]@{ Json = '1.0'; Count = 1 },
            [pscustomobject]@{ Json = '0'; Count = 0 }
        )

        foreach ($case in $validCases) {
            $itemsJson = if ($case.Count -eq 0) { '[]' } else { '[{"id":"seed-1"}]' }
            Set-Content -LiteralPath $script:artifactPath -Value ('{"itemCount":' + $case.Json + ',"items":' + $itemsJson + '}') -Encoding UTF8
            $checkpoint = Get-TestItemCountDecisionCheckpoint -ArtifactPath $script:artifactPath -ItemCount $case.Count -SuccessCount $case.Count -FailedCount 0
            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume

            if ($decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -ne 'SucceededWithArtifact') {
                throw ('Expected valid persisted snapshot itemCount [{0}] to remain skippable; Reason={1}.' -f $case.Json, $decision.Reason)
            }
        }
    }

    It 'marks missing artifacts only when succeeded terminal counts are safe to consume' {
        $missingPath = Join-Path -Path $script:testRoot -ChildPath 'does-not-exist.json'

        $validCheckpoint = Get-TestItemCountDecisionCheckpoint -ArtifactPath $missingPath -ItemCount 1 -SuccessCount 1 -FailedCount 0
        $validDecision = Get-CollectorBatchExecutionDecision -Checkpoint $validCheckpoint -BatchId '0001' -Resume
        if (-not $validDecision.ShouldProcess -or -not $validDecision.MarkMissing -or [string]$validDecision.Reason -ne 'MissingArtifact') {
            throw ('Expected valid-count missing artifact to retain MissingArtifact behavior; ShouldProcess={0}; MarkMissing={1}; Reason={2}.' -f $validDecision.ShouldProcess, $validDecision.MarkMissing, $validDecision.Reason)
        }

        $malformedCheckpoint = Get-TestItemCountDecisionCheckpoint -ArtifactPath $missingPath -ItemCount ([pscustomobject]@{ value = 1 }) -SuccessCount 1 -FailedCount 0
        $malformedDecision = Get-CollectorBatchExecutionDecision -Checkpoint $malformedCheckpoint -BatchId '0001' -Resume
        if (-not $malformedDecision.ShouldProcess -or $malformedDecision.MarkMissing -or [string]$malformedDecision.Reason -ne 'MissingArtifactInvalidCounts') {
            throw ('Expected malformed-count missing artifact to bypass unsafe MarkMissing handling; ShouldProcess={0}; MarkMissing={1}; Reason={2}.' -f $malformedDecision.ShouldProcess, $malformedDecision.MarkMissing, $malformedDecision.Reason)
        }
    }

    It 'rejects schema-invalid persisted plan batch itemCount during generic snapshot loading' {
        Invoke-TestStage1Seed -RunPath $script:testRoot | Out-Null
        $checkpoint = Get-TestStage1Checkpoint -RunPath $script:testRoot -Family 'applications'
        $checkpoint.plan.batches[0].itemCount = '1'
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'persisted-itemcount-type' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'plan has an invalid itemCount') {
                throw ('Expected strict plan itemCount rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected generic snapshot loading to reject schema-invalid persisted plan itemCount.'
        }
    }

    It 'rejects schema-invalid persisted snapshot itemCount during generic snapshot loading' {
        Invoke-TestStage1Seed -RunPath $script:testRoot | Out-Null
        $checkpoint = Get-TestStage1Checkpoint -RunPath $script:testRoot -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        $snapshot = Get-Content -LiteralPath $batch.artifactPath -Raw | ConvertFrom-Json
        $snapshot.itemCount = '1'
        $snapshot | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $batch.artifactPath -Encoding UTF8

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'persisted-itemcount-type' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'snapshot artifact has an invalid itemCount') {
                throw ('Expected strict snapshot itemCount rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected generic snapshot loading to reject schema-invalid persisted snapshot itemCount.'
        }
    }

    It 'reprocesses schema-invalid Stage1 snapshot itemCount while valid neighboring families remain skipped' {
        $context = Get-TestItemCountContext -RunPath $script:testRoot
        $initialResults = @(Invoke-CollectorStage1 -Context $context -Sections @('entra-apps'))
        if ($initialResults.Count -ne 3) {
            throw 'Expected initial Stage1 execution to produce all three entra-apps family results.'
        }

        $checkpoint = Get-TestStage1Checkpoint -RunPath $script:testRoot -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        $snapshot = Get-Content -LiteralPath $batch.artifactPath -Raw | ConvertFrom-Json
        $snapshot.itemCount = '1'
        $snapshot | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $batch.artifactPath -Encoding UTF8

        $context.Resume = $true
        $resumeResults = @(Invoke-CollectorStage1 -Context $context -Sections @('entra-apps'))
        $applications = $resumeResults | Where-Object { $_.family -eq 'applications' } | Select-Object -First 1
        $servicePrincipals = $resumeResults | Where-Object { $_.family -eq 'servicePrincipals' } | Select-Object -First 1
        $groups = $resumeResults | Where-Object { $_.family -eq 'groups' } | Select-Object -First 1

        if ($applications.succeededBatches -ne 1 -or $applications.skippedBatches -ne 0) {
            throw ('Expected malformed applications snapshot to be reprocessed; succeeded={0}; skipped={1}.' -f $applications.succeededBatches, $applications.skippedBatches)
        }
        if ($servicePrincipals.skippedBatches -ne 1 -or $groups.skippedBatches -ne 1) {
            throw ('Expected valid neighboring families to remain skipped; servicePrincipals={0}; groups={1}.' -f $servicePrincipals.skippedBatches, $groups.skippedBatches)
        }

        $repairedCheckpoint = Get-TestStage1Checkpoint -RunPath $script:testRoot -Family 'applications'
        $repairedBatch = Get-CollectorCheckpointBatch -Checkpoint $repairedCheckpoint -BatchId '0001'
        $repairedSnapshot = Get-Content -LiteralPath $repairedBatch.artifactPath -Raw | ConvertFrom-Json
        if ($repairedSnapshot.itemCount -is [string] -or [int]$repairedSnapshot.itemCount -ne 1 -or -not [bool]$repairedCheckpoint.plan.completed) {
            throw 'Expected Stage1 reprocessing to restore numeric snapshot itemCount and completed plan state.'
        }
    }

    It 'reprocesses a missing Stage1 artifact with malformed persisted itemCount without unsafe casting' {
        $context = Get-TestItemCountContext -RunPath $script:testRoot
        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $checkpoint = Get-TestStage1Checkpoint -RunPath $script:testRoot -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        $artifactPath = [string]$batch.artifactPath
        Remove-Item -LiteralPath $artifactPath -Force
        $batch.itemCount = [pscustomobject]@{ value = 1 }
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        $context.Resume = $true
        $resumeResults = @(Invoke-CollectorStage1 -Context $context -Sections @('entra-apps'))
        $applications = $resumeResults | Where-Object { $_.family -eq 'applications' } | Select-Object -First 1
        $servicePrincipals = $resumeResults | Where-Object { $_.family -eq 'servicePrincipals' } | Select-Object -First 1
        $groups = $resumeResults | Where-Object { $_.family -eq 'groups' } | Select-Object -First 1

        if ($applications.succeededBatches -ne 1 -or $applications.skippedBatches -ne 0) {
            throw ('Expected malformed-count missing applications artifact to reprocess successfully; succeeded={0}; skipped={1}.' -f $applications.succeededBatches, $applications.skippedBatches)
        }
        if ($servicePrincipals.skippedBatches -ne 1 -or $groups.skippedBatches -ne 1) {
            throw ('Expected valid neighboring families to remain skipped; servicePrincipals={0}; groups={1}.' -f $servicePrincipals.skippedBatches, $groups.skippedBatches)
        }

        $repairedCheckpoint = Get-TestStage1Checkpoint -RunPath $script:testRoot -Family 'applications'
        $repairedBatch = Get-CollectorCheckpointBatch -Checkpoint $repairedCheckpoint -BatchId '0001'
        if ($repairedBatch.itemCount -isnot [int] -or [int]$repairedBatch.itemCount -ne 1 -or -not (Test-Path -LiteralPath $repairedBatch.artifactPath -PathType Leaf) -or -not [bool]$repairedCheckpoint.plan.completed) {
            throw 'Expected Stage1 reprocessing to replace malformed missing-artifact state with valid numeric counts, artifact, and completed plan.'
        }
    }
}
