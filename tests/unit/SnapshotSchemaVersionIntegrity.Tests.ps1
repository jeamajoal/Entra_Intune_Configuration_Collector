BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop

    function New-TestSnapshotSchemaVersionFixture {
        param(
            [AllowNull()]
            [object]$SchemaVersion,

            [switch]$OmitSchemaVersion
        )

        $snapshot = [pscustomobject][ordered]@{
            schemaVersion = $SchemaVersion
            runId = 'snapshot-schema-version-test'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            batchId = '0001'
            collectedUtc = '2026-09-07T00:00:00.0000000Z'
            sourceType = 'Test'
            sourceName = 'snapshot-schema-version-fixture'
            apiVersion = 'n/a'
            isBeta = $false
            requestContext = [pscustomobject]@{}
            itemCount = 1
            items = @([pscustomobject]@{ id = 'one' })
        }

        if ($OmitSchemaVersion) {
            $snapshot.PSObject.Properties.Remove('schemaVersion')
        }

        return $snapshot
    }

    function Get-TestInvalidSnapshotVersions {
        return @(
            [pscustomobject]@{ Omit = $true; Value = 'placeholder'; Label = 'missing' },
            [pscustomobject]@{ Omit = $false; Value = $null; Label = 'null' },
            [pscustomobject]@{ Omit = $false; Value = ''; Label = 'empty string' },
            [pscustomobject]@{ Omit = $false; Value = 1; Label = 'numeric' },
            [pscustomobject]@{ Omit = $false; Value = ([pscustomobject]@{ value = '1.0' }); Label = 'object' },
            [pscustomobject]@{ Omit = $false; Value = '999.0'; Label = 'unsupported string' }
        )
    }

    function New-TestResumeDecisionCheckpoint {
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
                    updatedUtc = '2026-09-07T00:00:00.0000000Z'
                }
            )
        }
    }

    function Save-TestLoaderFixture {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$Snapshot
        )

        $artifactPath = Join-Path -Path $RunPath -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
        $Snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $fingerprint = Get-CollectorSnapshotBatchFingerprint -Items @($Snapshot.items)
        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = 'snapshot-schema-version-test'
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
                    artifactPath = $artifactPath
                    error = $null
                    updatedUtc = '2026-09-07T00:00:00.0000000Z'
                }
            )
        }

        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
        return $artifactPath
    }
}

Describe 'Persisted snapshot schema-version integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-schema-version-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts only the current string snapshot schema version' {
        $valid = New-TestSnapshotSchemaVersionFixture -SchemaVersion '1.0'
        if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $valid)) {
            throw 'Expected current snapshot schemaVersion 1.0 to be accepted.'
        }

        foreach ($invalidCase in Get-TestInvalidSnapshotVersions) {
            $snapshot = New-TestSnapshotSchemaVersionFixture -SchemaVersion $invalidCase.Value -OmitSchemaVersion:$invalidCase.Omit
            if (Test-CollectorSnapshotSchemaVersion -Snapshot $snapshot) {
                throw ('Expected invalid snapshot schemaVersion case to be rejected: {0}.' -f $invalidCase.Label)
            }
        }
    }

    It 'forces resume reprocessing for otherwise-valid successful artifacts with invalid snapshot versions' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        $checkpoint = New-TestResumeDecisionCheckpoint -ArtifactPath $artifactPath

        foreach ($invalidCase in Get-TestInvalidSnapshotVersions) {
            $snapshot = New-TestSnapshotSchemaVersionFixture -SchemaVersion $invalidCase.Value -OmitSchemaVersion:$invalidCase.Omit
            $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
            if (-not $decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -ne 'InvalidSnapshotSchemaVersion') {
                throw ('Expected invalid snapshot schemaVersion case [{0}] to force reprocessing; Reason={1}.' -f $invalidCase.Label, $decision.Reason)
            }
        }

        $valid = New-TestSnapshotSchemaVersionFixture -SchemaVersion '1.0'
        $valid | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        $validDecision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if ($validDecision.ShouldProcess -or $validDecision.MarkMissing -or [string]$validDecision.Reason -ne 'SucceededWithArtifact') {
            throw ('Expected valid snapshot schemaVersion 1.0 to remain reusable; Reason={0}.' -f $validDecision.Reason)
        }
    }

    It 'rejects invalid persisted snapshot versions from the shared downstream loader' {
        foreach ($invalidCase in Get-TestInvalidSnapshotVersions) {
            $snapshot = New-TestSnapshotSchemaVersionFixture -SchemaVersion $invalidCase.Value -OmitSchemaVersion:$invalidCase.Omit
            $artifactPath = Save-TestLoaderFixture -RunPath $script:testRoot -Snapshot $snapshot

            $threw = $false
            try {
                Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'snapshot-schema-version-test' | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'schemaVersion') {
                    throw ('Expected schemaVersion rejection for case [{0}]; actual error: {1}' -f $invalidCase.Label, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected invalid persisted snapshot schemaVersion case to fail closed: {0}.' -f $invalidCase.Label)
            }

            Remove-Item -LiteralPath $artifactPath -Force
        }
    }

    It 'loads a valid current-version snapshot without changing existing item semantics' {
        $snapshot = New-TestSnapshotSchemaVersionFixture -SchemaVersion '1.0'
        Save-TestLoaderFixture -RunPath $script:testRoot -Snapshot $snapshot | Out-Null

        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'snapshot-schema-version-test')
        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'one') {
            throw 'Expected valid current-version snapshot to return its original one-item payload.'
        }
    }
}
