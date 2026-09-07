BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
}

Describe 'Persisted snapshot schema-version integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-schema-version-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        $script:invalidCases = @(
            [pscustomobject]@{ Omit = $true; Value = 'placeholder'; Label = 'missing' },
            [pscustomobject]@{ Omit = $false; Value = $null; Label = 'null' },
            [pscustomobject]@{ Omit = $false; Value = ''; Label = 'empty string' },
            [pscustomobject]@{ Omit = $false; Value = 1; Label = 'numeric' },
            [pscustomobject]@{ Omit = $false; Value = ([pscustomobject]@{ value = '1.0' }); Label = 'object' },
            [pscustomobject]@{ Omit = $false; Value = '999.0'; Label = 'unsupported string' }
        )
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts only the current string snapshot schema version' {
        $valid = New-CollectorProvenanceSnapshot -RunId 'snapshot-schema-version-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'fixture' -ApiVersion 'n/a' -ItemCount 1 -Items @([pscustomobject]@{ id = 'one' })
        if ([string]$valid.schemaVersion -ne '1.0') {
            throw ('Expected the production snapshot writer to default schemaVersion to 1.0; actual: {0}.' -f [string]$valid.schemaVersion)
        }

        $persistedValid = $valid | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $persistedValid)) {
            throw 'Expected persisted current snapshot schemaVersion 1.0 to be accepted.'
        }

        foreach ($invalidCase in $script:invalidCases) {
            $snapshot = [pscustomobject][ordered]@{
                schemaVersion = $invalidCase.Value
                runId = 'snapshot-schema-version-test'
                stage = 'stage1'
                section = 'entra-apps'
                family = 'applications'
                batchId = '0001'
                itemCount = 1
                items = @([pscustomobject]@{ id = 'one' })
            }
            if ($invalidCase.Omit) {
                $snapshot.PSObject.Properties.Remove('schemaVersion')
            }
            if (Test-CollectorSnapshotSchemaVersion -Snapshot $snapshot) {
                throw ('Expected invalid snapshot schemaVersion case to be rejected: {0}.' -f $invalidCase.Label)
            }
        }
    }

    It 'forces resume reprocessing for invalid snapshot versions while preserving valid reuse' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'batch-0001.json'
        $checkpoint = [pscustomobject]@{
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

        foreach ($invalidCase in $script:invalidCases) {
            $snapshot = [pscustomobject][ordered]@{
                schemaVersion = $invalidCase.Value
                runId = 'snapshot-schema-version-test'
                stage = 'stage1'
                section = 'entra-apps'
                family = 'applications'
                batchId = '0001'
                itemCount = 1
                items = @([pscustomobject]@{ id = 'one' })
            }
            if ($invalidCase.Omit) {
                $snapshot.PSObject.Properties.Remove('schemaVersion')
            }
            $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

            $decision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
            if (-not $decision.ShouldProcess -or $decision.MarkMissing -or [string]$decision.Reason -ne 'InvalidSnapshotSchemaVersion') {
                throw ('Expected invalid snapshot schemaVersion case [{0}] to force reprocessing; Reason={1}.' -f $invalidCase.Label, $decision.Reason)
            }
        }

        $valid = New-CollectorProvenanceSnapshot -RunId 'snapshot-schema-version-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'fixture' -ApiVersion 'n/a' -ItemCount 1 -Items @([pscustomobject]@{ id = 'one' })
        $valid | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        $validDecision = Get-CollectorBatchExecutionDecision -Checkpoint $checkpoint -BatchId '0001' -Resume
        if ($validDecision.ShouldProcess -or $validDecision.MarkMissing -or [string]$validDecision.Reason -ne 'SucceededWithArtifact') {
            throw ('Expected valid snapshot schemaVersion 1.0 to remain reusable; Reason={0}.' -f $validDecision.Reason)
        }
    }

    It 'rejects invalid persisted snapshot versions from the shared downstream loader' {
        foreach ($invalidCase in $script:invalidCases) {
            $snapshot = [pscustomobject][ordered]@{
                schemaVersion = $invalidCase.Value
                runId = 'snapshot-schema-version-test'
                stage = 'stage1'
                section = 'entra-apps'
                family = 'applications'
                batchId = '0001'
                itemCount = 1
                items = @([pscustomobject]@{ id = 'one' })
            }
            if ($invalidCase.Omit) {
                $snapshot.PSObject.Properties.Remove('schemaVersion')
            }

            $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
            New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
            $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

            $fingerprint = Get-CollectorSnapshotBatchFingerprint -Items @($snapshot.items)
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
                    batches = @([pscustomobject]@{ batchId = '0001'; itemCount = 1; fingerprint = $fingerprint })
                }
                batches = @([pscustomobject]@{ batchId = '0001'; status = 'Succeeded'; attempts = 1; itemCount = 1; successCount = 1; failedCount = 0; artifactPath = $artifactPath; error = $null; updatedUtc = '2026-09-07T00:00:00.0000000Z' })
            }
            Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

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
        }
    }

    It 'loads a valid current-version snapshot without changing existing item semantics' {
        $snapshot = New-CollectorProvenanceSnapshot -RunId 'snapshot-schema-version-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'fixture' -ApiVersion 'n/a' -ItemCount 1 -Items @([pscustomobject]@{ id = 'one' })
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $fingerprint = Get-CollectorSnapshotBatchFingerprint -Items @($snapshot.items)
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
                batches = @([pscustomobject]@{ batchId = '0001'; itemCount = 1; fingerprint = $fingerprint })
            }
            batches = @([pscustomobject]@{ batchId = '0001'; status = 'Succeeded'; attempts = 1; itemCount = 1; successCount = 1; failedCount = 0; artifactPath = $artifactPath; error = $null; updatedUtc = '2026-09-07T00:00:00.0000000Z' })
        }
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'snapshot-schema-version-test')
        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'one') {
            throw 'Expected valid current-version snapshot to return its original one-item payload.'
        }
    }
}
