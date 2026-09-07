BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

    function Get-TestIdentitySnapshot {
        param(
            [AllowNull()][object]$RunId = '123',
            [AllowNull()][object]$Stage = 'stage1',
            [AllowNull()][object]$Section = 'entra-apps',
            [AllowNull()][object]$Family = 'applications',
            [AllowNull()][object]$BatchId = '0001'
        )

        return [pscustomobject][ordered]@{
            schemaVersion = '1.0'
            runId = $RunId
            stage = $Stage
            section = $Section
            family = $Family
            batchId = $BatchId
            collectedUtc = '2026-09-07T00:00:00.0000000Z'
            sourceType = 'Test'
            sourceName = 'fixture'
            apiVersion = 'n/a'
            isBeta = $false
            requestContext = @{}
            itemCount = 1
            items = @([pscustomobject]@{ id = 'one' })
        }
    }

    function Save-TestIdentityLoaderFixture {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][object]$Snapshot
        )

        $artifactPath = Join-Path -Path $RunPath -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
        $Snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $fingerprint = Get-CollectorSnapshotBatchFingerprint -Items @($Snapshot.items)
        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = '123'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            updatedUtc = '2026-09-07T00:00:00.0000000Z'
            plan = [pscustomobject]@{
                planVersion = '1.0'
                batchSize = 100
                expectedBatchCount = 1
                sourceFingerprint = 'fixture'
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
                artifactPath = $artifactPath
                error = $null
                updatedUtc = '2026-09-07T00:00:00.0000000Z'
            })
        }

        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
        return $artifactPath
    }
}

Describe 'Persisted snapshot identity type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-identity-type-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'requires every persisted snapshot identity property to be a non-empty string' {
        $identityNames = @('runId', 'stage', 'section', 'family', 'batchId')
        $invalidCases = @(
            [pscustomobject]@{ Label = 'missing'; Value = 'placeholder'; Omit = $true },
            [pscustomobject]@{ Label = 'null'; Value = $null; Omit = $false },
            [pscustomobject]@{ Label = 'empty'; Value = ''; Omit = $false },
            [pscustomobject]@{ Label = 'numeric'; Value = 123; Omit = $false },
            [pscustomobject]@{ Label = 'boolean'; Value = $true; Omit = $false },
            [pscustomobject]@{ Label = 'object'; Value = ([pscustomobject]@{ value = '123' }); Omit = $false },
            [pscustomobject]@{ Label = 'array'; Value = @('123'); Omit = $false }
        )

        foreach ($identityName in $identityNames) {
            foreach ($case in $invalidCases) {
                $snapshot = Get-TestIdentitySnapshot
                if ($case.Omit) {
                    $snapshot.PSObject.Properties.Remove($identityName)
                }
                else {
                    $snapshot.$identityName = $case.Value
                }

                if (Test-CollectorSnapshotSchemaVersion -Snapshot $snapshot) {
                    throw ('Expected identity [{0}] case [{1}] to fail the persisted snapshot contract.' -f $identityName, $case.Label)
                }
            }
        }
    }

    It 'forces reprocessing instead of skipping a coercible numeric runId prior success' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        $checkpoint = [pscustomobject]@{
            batches = @([pscustomobject]@{
                batchId = '0001'
                status = 'Succeeded'
                attempts = 1
                itemCount = 1
                successCount = 1
                failedCount = 0
                artifactPath = $artifactPath
                error = $null
                updatedUtc = '2026-09-07T00:00:00.0000000Z'
            })
        }

        $invalidSnapshot = Get-TestIdentitySnapshot -RunId 123
        $invalidSnapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $invalidDecision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if (-not $invalidDecision.ShouldProcess -or $invalidDecision.MarkMissing) {
            throw ('Expected schema-invalid numeric snapshot runId to force reprocessing; Reason={0}.' -f $invalidDecision.Reason)
        }

        $validSnapshot = Get-TestIdentitySnapshot -RunId '123'
        $validSnapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $validDecision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if ($validDecision.ShouldProcess -or $validDecision.MarkMissing -or [string]$validDecision.Reason -ne 'SucceededWithArtifact') {
            throw ('Expected matching string snapshot identities to remain reusable; Reason={0}.' -f $validDecision.Reason)
        }
    }

    It 'fails closed in the downstream loader for numeric runId 123 instead of coercing it to logical run string 123' {
        $invalidSnapshot = Get-TestIdentitySnapshot -RunId 123
        $artifactPath = Save-TestIdentityLoaderFixture -RunPath $script:testRoot -Snapshot $invalidSnapshot

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId '123' | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected downstream loading to reject numeric persisted snapshot runId 123 for logical run string 123.'
        }

        $validSnapshot = Get-TestIdentitySnapshot -RunId '123'
        $validSnapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId '123')
        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'one') {
            throw 'Expected matching non-empty string snapshot identities to preserve downstream item loading.'
        }
    }

    It 'leaves established exact string mismatch rejection intact' {
        $snapshot = Get-TestIdentitySnapshot -RunId 'different-run'
        Save-TestIdentityLoaderFixture -RunPath $script:testRoot -Snapshot $snapshot | Out-Null

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId '123' | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected an ordinary string runId mismatch to remain rejected by downstream loading.'
        }
    }
}
