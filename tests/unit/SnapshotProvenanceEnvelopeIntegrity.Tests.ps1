BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

    function Get-TestProvenanceSnapshot {
        return New-CollectorProvenanceSnapshot -RunId 'snapshot-provenance-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'fixture' -ApiVersion 'n/a' -RequestContext @{ endpoint = '/v1.0/applications'; method = 'GET' } -ItemCount 1 -Items @([pscustomobject]@{ id = 'one' })
    }

    function Get-TestDecisionCheckpoint {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ArtifactPath
        )

        return [pscustomobject]@{
            batches = @([pscustomobject]@{
                batchId = '0001'
                status = 'Succeeded'
                attempts = 1
                itemCount = 1
                successCount = 1
                failedCount = 0
                artifactPath = $ArtifactPath
                error = $null
                updatedUtc = '2026-09-08T00:00:00.0000000Z'
            })
        }
    }

    function Write-TestMalformedProvenanceSnapshot {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ArtifactPath,

            [Parameter(Mandatory = $true)]
            [string]$PropertyName,

            [switch]$Omit,

            [AllowNull()]
            [object]$Value
        )

        $persisted = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        if ($Omit) {
            $persisted.PSObject.Properties.Remove($PropertyName)
        }
        else {
            $persisted.$PropertyName = $Value
        }

        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ArtifactPath -Encoding UTF8
    }

    function Save-TestLoaderCheckpoint {
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
            runId = 'snapshot-provenance-test'
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
                batches = @([pscustomobject]@{
                    batchId = '0001'
                    itemCount = 1
                    fingerprint = $fingerprint
                })
            }
            batches = @([pscustomobject]@{
                batchId = '0001'
                status = 'Succeeded'
                attempts = 1
                itemCount = 1
                successCount = 1
                failedCount = 0
                artifactPath = $ArtifactPath
                error = $null
                updatedUtc = '2026-09-08T00:00:00.0000000Z'
            })
        }

        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
    }

    function Get-TestStage1Context {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'snapshot-provenance-stage1'
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

Describe 'Persisted snapshot provenance envelope integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-provenance-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts the writer envelope after persistence and rejects schema-invalid provenance field types' {
        $valid = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $valid)) {
            throw 'Expected a persisted production-writer snapshot to satisfy the shared persisted-snapshot contract.'
        }
        if (-not ($valid.requestContext -is [pscustomobject]) -or -not ($valid.isBeta -is [bool])) {
            throw 'Expected JSON round-trip to produce object requestContext and Boolean isBeta runtime shapes.'
        }

        $invalidStringCases = @(
            [pscustomobject]@{ Label = 'null'; Value = $null },
            [pscustomobject]@{ Label = 'numeric'; Value = 1 },
            [pscustomobject]@{ Label = 'boolean'; Value = $true },
            [pscustomobject]@{ Label = 'object'; Value = ([pscustomobject]@{ value = 'bad' }) },
            [pscustomobject]@{ Label = 'array'; Value = [object[]]@('bad', 'worse') }
        )

        foreach ($propertyName in @('collectedUtc', 'sourceType', 'sourceName', 'apiVersion')) {
            $emptyString = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $emptyString.$propertyName = ''
            if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $emptyString)) {
                throw ('Expected schema-valid empty string provenance property [{0}] to remain accepted.' -f $propertyName)
            }

            foreach ($invalidCase in $invalidStringCases) {
                $invalid = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
                $invalid.$propertyName = $invalidCase.Value
                if (Test-CollectorSnapshotSchemaVersion -Snapshot $invalid) {
                    throw ('Expected provenance property [{0}] invalid case [{1}] to be rejected.' -f $propertyName, $invalidCase.Label)
                }
            }

            $missing = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $missing.PSObject.Properties.Remove($propertyName)
            if (Test-CollectorSnapshotSchemaVersion -Snapshot $missing) {
                throw ('Expected missing required provenance property [{0}] to be rejected.' -f $propertyName)
            }
        }

        $invalidIsBetaCases = @(
            [pscustomobject]@{ Label = 'null'; Value = $null },
            [pscustomobject]@{ Label = 'string'; Value = 'false' },
            [pscustomobject]@{ Label = 'zero'; Value = 0 },
            [pscustomobject]@{ Label = 'one'; Value = 1 },
            [pscustomobject]@{ Label = 'object'; Value = ([pscustomobject]@{ value = $false }) },
            [pscustomobject]@{ Label = 'array'; Value = [object[]]@($false, $true) }
        )
        foreach ($invalidCase in $invalidIsBetaCases) {
            $invalid = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $invalid.isBeta = $invalidCase.Value
            if (Test-CollectorSnapshotSchemaVersion -Snapshot $invalid) {
                throw ('Expected isBeta invalid case [{0}] to be rejected.' -f $invalidCase.Label)
            }
        }
        $missingIsBeta = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $missingIsBeta.PSObject.Properties.Remove('isBeta')
        if (Test-CollectorSnapshotSchemaVersion -Snapshot $missingIsBeta) {
            throw 'Expected missing isBeta to be rejected.'
        }

        $emptyContext = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $emptyContext.requestContext = [pscustomobject]@{}
        if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $emptyContext)) {
            throw 'Expected empty persisted JSON object requestContext to remain accepted.'
        }
        $invalidContextCases = @(
            [pscustomobject]@{ Label = 'null'; Value = $null },
            [pscustomobject]@{ Label = 'string'; Value = 'bad' },
            [pscustomobject]@{ Label = 'numeric'; Value = 1 },
            [pscustomobject]@{ Label = 'boolean'; Value = $true },
            [pscustomobject]@{ Label = 'array'; Value = [object[]]@('bad', 'worse') }
        )
        foreach ($invalidCase in $invalidContextCases) {
            $invalid = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $invalid.requestContext = $invalidCase.Value
            if (Test-CollectorSnapshotSchemaVersion -Snapshot $invalid) {
                throw ('Expected requestContext invalid case [{0}] to be rejected.' -f $invalidCase.Label)
            }
        }
        $missingContext = (Get-TestProvenanceSnapshot) | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $missingContext.PSObject.Properties.Remove('requestContext')
        if (Test-CollectorSnapshotSchemaVersion -Snapshot $missingContext) {
            throw 'Expected missing requestContext to be rejected.'
        }
    }

    It 'forces successful-resume reprocessing for malformed provenance envelopes while preserving valid reuse' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        $checkpoint = Get-TestDecisionCheckpoint -ArtifactPath $artifactPath
        $invalidCases = @(
            [pscustomobject]@{ Property = 'collectedUtc'; Value = 1 },
            [pscustomobject]@{ Property = 'sourceType'; Value = $true },
            [pscustomobject]@{ Property = 'sourceName'; Value = ([pscustomobject]@{ value = 'bad' }) },
            [pscustomobject]@{ Property = 'apiVersion'; Value = [object[]]@('v1.0', 'beta') },
            [pscustomobject]@{ Property = 'isBeta'; Value = 'false' },
            [pscustomobject]@{ Property = 'requestContext'; Value = [object[]]@('bad', 'worse') }
        )

        foreach ($invalidCase in $invalidCases) {
            Write-TestMalformedProvenanceSnapshot -ArtifactPath $artifactPath -PropertyName $invalidCase.Property -Value $invalidCase.Value
            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
            if (-not $decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -eq 'SucceededWithArtifact') {
                throw ('Expected malformed provenance property [{0}] to force reprocessing; Reason={1}.' -f $invalidCase.Property, $decision.Reason)
            }
        }

        $valid = Get-TestProvenanceSnapshot
        $valid | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        $validDecision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if ($validDecision.ShouldProcess -or $validDecision.MarkMissing -or [string]$validDecision.Reason -ne 'SucceededWithArtifact') {
            throw ('Expected valid persisted provenance envelope to remain reusable; Reason={0}.' -f $validDecision.Reason)
        }
    }

    It 'rejects malformed provenance from the shared downstream loader before returning items' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
        Write-TestMalformedProvenanceSnapshot -ArtifactPath $artifactPath -PropertyName 'requestContext' -Value ([object[]]@('bad', 'worse'))
        Save-TestLoaderCheckpoint -RunPath $script:testRoot -ArtifactPath $artifactPath

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'snapshot-provenance-test' | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected shared downstream loading to reject malformed persisted requestContext before returning items.'
        }
    }

    It 'reprocesses a real Stage1 success after persisted provenance corruption' {
        $context = Get-TestStage1Context -RunPath $script:testRoot
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'one' })
        }

        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $context.RunId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $beforeBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        if ([int]$beforeBatch.attempts -ne 1 -or [string]$beforeBatch.status -ne 'Succeeded') {
            throw 'Expected initial Stage1 applications batch to succeed on attempt 1.'
        }

        $artifactPath = [string]$beforeBatch.artifactPath
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        if (-not ($snapshot.isBeta -is [bool]) -or $snapshot.isBeta) {
            throw 'Expected initial v1.0 applications snapshot to persist Boolean false isBeta.'
        }

        $snapshot.isBeta = 'false'
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        $malformed = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        if (-not ($malformed.isBeta -is [string]) -or [string]$malformed.isBeta -ne 'false') {
            throw 'Focused fixture failed to persist the intended string isBeta corruption.'
        }

        $context.Resume = $true
        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $repairedCheckpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $context.RunId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $repairedBatch = Get-CollectorCheckpointBatch -Checkpoint $repairedCheckpoint -BatchId '0001'
        if ([int]$repairedBatch.attempts -ne 2 -or [string]$repairedBatch.status -ne 'Succeeded') {
            throw ('Expected malformed prior provenance to be reprocessed to attempts=2/Succeeded; attempts={0}; status={1}.' -f $repairedBatch.attempts, $repairedBatch.status)
        }

        $repairedSnapshot = Get-Content -LiteralPath $repairedBatch.artifactPath -Raw | ConvertFrom-Json
        if (-not ($repairedSnapshot.isBeta -is [bool]) -or $repairedSnapshot.isBeta) {
            throw 'Expected Stage1 reprocessing to restore Boolean false isBeta provenance.'
        }
        if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $repairedSnapshot)) {
            throw 'Expected repaired production snapshot to satisfy the shared persisted-snapshot contract.'
        }
    }
}
