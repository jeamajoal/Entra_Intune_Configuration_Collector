BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

    function New-TestSnapshotItemsDocument {
        param(
            [Parameter(Mandatory = $true)]
            [object[]]$Items,

            [string]$RunId = 'snapshot-items-array-test',
            [string]$Stage = 'stage1',
            [string]$Section = 'entra-apps',
            [string]$Family = 'applications',
            [string]$BatchId = '0001'
        )

        return New-CollectorProvenanceSnapshot -RunId $RunId -Stage $Stage -Section $Section -Family $Family -BatchId $BatchId -SourceType 'Test' -SourceName 'fixture' -ApiVersion 'n/a' -ItemCount $Items.Count -Items $Items
    }

    function Get-TestDecisionCheckpoint {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ArtifactPath
        )

        return [pscustomobject]@{
            batches = @(
                [pscustomobject]@{
                    batchId = '0001'
                    status = 'Succeeded'
                    attempts = 1
                    itemCount = 1
                    successCount = 1
                    failedCount = 0
                    artifactPath = $ArtifactPath
                    error = $null
                    updatedUtc = '2026-09-08T00:00:00.0000000Z'
                }
            )
        }
    }

    function Write-TestInvalidItemsShape {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ArtifactPath,

            [Parameter(Mandatory = $true)]
            [ValidateSet('missing', 'null', 'object', 'string', 'number', 'boolean')]
            [string]$Shape
        )

        $snapshot = New-TestSnapshotItemsDocument -Items ([object[]]@([pscustomobject]@{ id = 'one' }))
        $persisted = $snapshot | ConvertTo-Json -Depth 30 | ConvertFrom-Json

        switch ($Shape) {
            'missing' { $persisted.PSObject.Properties.Remove('items') }
            'null' { $persisted.items = $null }
            'object' { $persisted.items = [pscustomobject]@{ id = 'one' } }
            'string' { $persisted.items = 'one' }
            'number' { $persisted.items = 1 }
            'boolean' { $persisted.items = $true }
        }

        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ArtifactPath -Encoding UTF8
    }

    function Save-TestCompletedStage1Checkpoint {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$ArtifactPath
        )

        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        $fingerprint = Get-CollectorSnapshotBatchFingerprint -Items $items
        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = 'snapshot-items-array-test'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            updatedUtc = '2026-09-08T00:00:00.0000000Z'
            plan = [pscustomobject]@{
                planVersion = '1.0'
                batchSize = 100
                expectedBatchCount = 1
                sourceFingerprint = 'fixture-source'
                completed = $true
                batches = @(
                    [pscustomobject]@{
                        batchId = '0001'
                        itemCount = 1
                        fingerprint = $fingerprint
                    }
                )
            }
            batches = @(
                [pscustomobject]@{
                    batchId = '0001'
                    status = 'Succeeded'
                    attempts = 1
                    itemCount = 1
                    successCount = 1
                    failedCount = 0
                    artifactPath = $ArtifactPath
                    error = $null
                    updatedUtc = '2026-09-08T00:00:00.0000000Z'
                }
            )
        }

        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
    }

    function New-TestStage1Context {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'snapshot-items-array-stage1'
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

Describe 'Persisted snapshot items array integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-items-array-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts persisted JSON arrays and rejects missing, null, and scalar items shapes' {
        $validItemSets = @(
            [pscustomobject]@{ Label = 'empty'; Items = [object[]]@() },
            [pscustomobject]@{ Label = 'one-item'; Items = [object[]]@([pscustomobject]@{ id = 'one' }) },
            [pscustomobject]@{ Label = 'multi-item'; Items = [object[]]@([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' }) }
        )

        foreach ($validCase in $validItemSets) {
            $persisted = (New-TestSnapshotItemsDocument -Items $validCase.Items) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            if (-not ($persisted.items -is [System.Array])) {
                throw ('Expected persisted valid case [{0}] to retain an array runtime shape; actual type: {1}.' -f $validCase.Label, $(if ($null -eq $persisted.items) { '<null>' } else { $persisted.items.GetType().FullName }))
            }
            if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $persisted)) {
                throw ('Expected persisted valid items array case [{0}] to satisfy the shared snapshot predicate.' -f $validCase.Label)
            }
        }

        foreach ($shape in @('missing', 'null', 'object', 'string', 'number', 'boolean')) {
            $artifactPath = Join-Path -Path $script:testRoot -ChildPath ('invalid-' + $shape + '.json')
            Write-TestInvalidItemsShape -ArtifactPath $artifactPath -Shape $shape
            $persisted = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json

            if (Test-CollectorSnapshotSchemaVersion -Snapshot $persisted) {
                throw ('Expected persisted invalid items shape [{0}] to fail the shared snapshot predicate.' -f $shape)
            }
        }
    }

    It 'forces successful-resume reprocessing when persisted items is not an actual array' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        $checkpoint = Get-TestDecisionCheckpoint -ArtifactPath $artifactPath

        foreach ($shape in @('missing', 'null', 'object', 'string', 'number', 'boolean')) {
            Write-TestInvalidItemsShape -ArtifactPath $artifactPath -Shape $shape
            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume

            if (-not $decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -eq 'SucceededWithArtifact') {
                throw ('Expected invalid persisted items shape [{0}] to force reprocessing; ShouldProcess={1}; MarkMissing={2}; Reason={3}.' -f $shape, $decision.ShouldProcess, $decision.MarkMissing, $decision.Reason)
            }
        }

        $valid = New-TestSnapshotItemsDocument -Items ([object[]]@([pscustomobject]@{ id = 'one' }))
        $valid | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        $validDecision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if ($validDecision.ShouldProcess -or $validDecision.MarkMissing -or [string]$validDecision.Reason -ne 'SucceededWithArtifact') {
            throw ('Expected a valid one-item persisted array to remain reusable; Reason={0}.' -f $validDecision.Reason)
        }
    }

    It 'rejects a scalar one-item payload from the shared downstream loader' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
        Write-TestInvalidItemsShape -ArtifactPath $artifactPath -Shape 'object'
        Save-TestCompletedStage1Checkpoint -RunPath $script:testRoot -ArtifactPath $artifactPath

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'snapshot-items-array-test' | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected the shared downstream loader to reject a scalar one-item payload rather than normalize it into an array.'
        }
    }

    It 'reprocesses a real Stage1 success after its one-item array wrapper is removed' {
        $context = New-TestStage1Context -RunPath $script:testRoot
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'one' })
        }

        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $context.RunId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $beforeBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        if ([int]$beforeBatch.attempts -ne 1) {
            throw ('Expected initial Stage1 success attempts=1; actual={0}.' -f $beforeBatch.attempts)
        }

        $artifactPath = [string]$beforeBatch.artifactPath
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        if (-not ($snapshot.items -is [System.Array]) -or @($snapshot.items).Count -ne 1) {
            throw 'Expected initial production Stage1 artifact to persist one item inside an array.'
        }

        $snapshot.items = $snapshot.items[0]
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        $malformed = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        if ($malformed.items -is [System.Array] -or [string]$malformed.items.id -ne 'one' -or [int]$malformed.itemCount -ne 1) {
            throw 'Focused fixture failed to persist the intended scalar one-item payload while preserving itemCount.'
        }

        $context.Resume = $true
        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $repairedCheckpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $context.RunId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $repairedBatch = Get-CollectorCheckpointBatch -Checkpoint $repairedCheckpoint -BatchId '0001'
        if ([int]$repairedBatch.attempts -ne 2 -or [string]$repairedBatch.status -ne 'Succeeded') {
            throw ('Expected malformed prior success to be reprocessed to attempts=2/Succeeded; attempts={0}; status={1}.' -f $repairedBatch.attempts, $repairedBatch.status)
        }

        $repairedSnapshot = Get-Content -LiteralPath $repairedBatch.artifactPath -Raw | ConvertFrom-Json
        if (-not ($repairedSnapshot.items -is [System.Array]) -or @($repairedSnapshot.items).Count -ne 1 -or [string]$repairedSnapshot.items[0].id -ne 'one') {
            throw 'Expected Stage1 reprocessing to rewrite the artifact with a valid one-item items array.'
        }

        if (-not [bool]$repairedCheckpoint.plan.completed) {
            throw 'Expected Stage1 plan to be complete after repairing the malformed prior success.'
        }

        if (-not (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
            throw 'Expected Stage1 checkpoint to remain persisted after repair.'
        }
    }
}
