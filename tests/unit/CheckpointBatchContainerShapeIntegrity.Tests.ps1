BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

    function Get-TestPlanBatch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$BatchId,

            [int]$ItemCount = 0,

            [string]$Fingerprint = 'fixture-fingerprint'
        )

        return [pscustomobject]@{
            batchId = $BatchId
            itemCount = $ItemCount
            fingerprint = $Fingerprint
        }
    }

    function Get-TestRecordedBatch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$BatchId,

            [string]$Status = 'Failed',

            [int]$ItemCount = 0,

            [int]$SuccessCount = 0,

            [int]$FailedCount = 0,

            [string]$ArtifactPath
        )

        return [pscustomobject]@{
            batchId = $BatchId
            status = $Status
            attempts = 0
            itemCount = $ItemCount
            successCount = $SuccessCount
            failedCount = $FailedCount
            artifactPath = $ArtifactPath
            error = $null
            updatedUtc = '2026-09-08T00:00:00.0000000Z'
        }
    }

    function Write-TestCheckpointDocument {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$PlanBatches,

            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$RecordedBatches,

            [string]$RunId = 'checkpoint-container-shape-test',

            [bool]$Completed = $false
        )

        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = $RunId
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            updatedUtc = '2026-09-08T00:00:00.0000000Z'
            plan = [pscustomobject]@{
                planVersion = '1.0'
                batchSize = 100
                expectedBatchCount = $PlanBatches.Count
                sourceFingerprint = 'fixture-source'
                completed = $Completed
                batches = [object[]]@($PlanBatches)
            }
            batches = [object[]]@($RecordedBatches)
        }

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $RunPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null
        $checkpoint | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
        return $checkpointPath
    }

    function Set-TestCheckpointContainerShape {
        param(
            [Parameter(Mandatory = $true)]
            [string]$CheckpointPath,

            [Parameter(Mandatory = $true)]
            [ValidateSet('plan', 'recorded')]
            [string]$Target,

            [Parameter(Mandatory = $true)]
            [ValidateSet('object', 'string', 'number', 'boolean')]
            [string]$Shape
        )

        $persisted = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        $currentArray = if ($Target -eq 'plan') { @($persisted.plan.batches) } else { @($persisted.batches) }
        if ($currentArray.Count -ne 1) {
            throw ('Expected one persisted batch before scalar-shape mutation; target={0}; count={1}.' -f $Target, $currentArray.Count)
        }

        $replacement = switch ($Shape) {
            'object' { $currentArray[0] }
            'string' { 'scalar-batches' }
            'number' { 1 }
            'boolean' { $true }
        }

        if ($Target -eq 'plan') {
            $persisted.plan.batches = $replacement
        }
        else {
            $persisted.batches = $replacement
        }

        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    }

    function Write-TestCompletedStage1Fixture {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [string]$RunId = 'checkpoint-container-shape-test'
        )

        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        $snapshot = New-CollectorProvenanceSnapshot -RunId $RunId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'fixture' -ApiVersion 'n/a' -ItemCount 1 -Items $items
        $artifact = Write-CollectorSnapshotArtifact -RunPath $RunPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchNumber 1 -Snapshot $snapshot
        $fingerprint = Get-CollectorSnapshotBatchFingerprint -Items $items

        $planBatch = Get-TestPlanBatch -BatchId '0001' -ItemCount 1 -Fingerprint $fingerprint
        $recordedBatch = Get-TestRecordedBatch -BatchId '0001' -Status 'Succeeded' -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifact.artifactPath
        $checkpointPath = Write-TestCheckpointDocument -RunPath $RunPath -PlanBatches ([object[]]@($planBatch)) -RecordedBatches ([object[]]@($recordedBatch)) -RunId $RunId -Completed $true

        return [pscustomobject]@{
            RunId = $RunId
            CheckpointPath = $checkpointPath
            ArtifactPath = $artifact.artifactPath
        }
    }

    function Get-TestStage1Context {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'checkpoint-container-shape-stage1'
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
}

Describe 'Persisted checkpoint batch container shape integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-container-shape-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts persisted array containers and rejects non-null scalar planned and recorded containers' {
        foreach ($count in @(0, 1, 2)) {
            $planBatches = @()
            $recordedBatches = @()
            for ($ordinal = 1; $ordinal -le $count; $ordinal++) {
                $batchId = '{0:D4}' -f $ordinal
                $planBatches += Get-TestPlanBatch -BatchId $batchId
                $recordedBatches += Get-TestRecordedBatch -BatchId $batchId
            }

            $checkpointPath = Write-TestCheckpointDocument -RunPath $script:testRoot -PlanBatches ([object[]]@($planBatches)) -RecordedBatches ([object[]]@($recordedBatches))
            $loaded = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'checkpoint-container-shape-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            if (-not ($loaded.plan.batches -is [System.Array]) -or -not ($loaded.batches -is [System.Array])) {
                throw ('Expected valid persisted batch containers to remain arrays for count={0}.' -f $count)
            }
            if (@($loaded.plan.batches).Count -ne $count -or @($loaded.batches).Count -ne $count) {
                throw ('Expected valid persisted batch container count={0}; planned={1}; recorded={2}.' -f $count, @($loaded.plan.batches).Count, @($loaded.batches).Count)
            }
        }

        foreach ($target in @('plan', 'recorded')) {
            foreach ($shape in @('object', 'string', 'number', 'boolean')) {
                $checkpointPath = Write-TestCheckpointDocument -RunPath $script:testRoot -PlanBatches ([object[]]@(Get-TestPlanBatch -BatchId '0001')) -RecordedBatches ([object[]]@(Get-TestRecordedBatch -BatchId '0001'))
                Set-TestCheckpointContainerShape -CheckpointPath $checkpointPath -Target $target -Shape $shape

                $threw = $false
                try {
                    Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'checkpoint-container-shape-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
                }
                catch {
                    $threw = $true
                    if ($_.Exception.Message -notmatch 'batch.*container|batches.*array') {
                        throw ('Expected batch-container shape rejection for target={0}, shape={1}; actual error: {2}' -f $target, $shape, $_.Exception.Message)
                    }
                }

                if (-not $threw) {
                    throw ('Expected scalar persisted batch container to fail closed; target={0}; shape={1}.' -f $target, $shape)
                }
            }
        }
    }

    It 'preserves the existing missing and null top-level batches migration to an empty array' {
        foreach ($shape in @('missing', 'null')) {
            $checkpointPath = Write-TestCheckpointDocument -RunPath $script:testRoot -PlanBatches ([object[]]@()) -RecordedBatches ([object[]]@())
            $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            if ($shape -eq 'missing') {
                $persisted.PSObject.Properties.Remove('batches')
            }
            else {
                $persisted.batches = $null
            }
            $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

            $loaded = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'checkpoint-container-shape-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            if (-not ($loaded.batches -is [System.Array]) -or @($loaded.batches).Count -ne 0) {
                throw ('Expected existing top-level {0} batches compatibility path to normalize to an empty array.' -f $shape)
            }
        }
    }

    It 'fails Stage1 readiness and downstream loading when either one-batch array wrapper is removed' {
        foreach ($target in @('plan', 'recorded')) {
            $fixture = Write-TestCompletedStage1Fixture -RunPath $script:testRoot
            Set-TestCheckpointContainerShape -CheckpointPath $fixture.CheckpointPath -Target $target -Shape 'object'

            if (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications' -ExpectedRunId $fixture.RunId) {
                throw ('Expected Stage1 readiness to reject scalar {0} batch container.' -f $target)
            }

            $threw = $false
            try {
                Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId $fixture.RunId | Out-Null
            }
            catch {
                $threw = $true
            }
            if (-not $threw) {
                throw ('Expected downstream snapshot loading to reject scalar {0} batch container.' -f $target)
            }
        }
    }

    It 'fails closed on real Stage1 resume when a successful recorded batches array wrapper is removed' {
        $context = Get-TestStage1Context -RunPath $script:testRoot
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'one' })
        }

        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        Set-TestCheckpointContainerShape -CheckpointPath $checkpointPath -Target 'recorded' -Shape 'object'

        $context.Resume = $true
        $threw = $false
        try {
            Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'batch.*container|batches.*array') {
                throw ('Expected real Stage1 resume batch-container rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected real Stage1 resume to fail closed rather than skip prior success from a scalar recorded batches container.'
        }

        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        if ($persisted.batches -is [System.Array]) {
            throw 'Expected fail-closed resume to leave malformed persisted evidence unmodified.'
        }
    }
}
