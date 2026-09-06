BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestArtifactPath {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$Section,
            [Parameter(Mandatory = $true)] [string]$Family,
            [Parameter(Mandatory = $true)] [string]$BatchId
        )

        return [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath (Join-Path -Path 'stage1' -ChildPath (Join-Path -Path $Section -ChildPath (Join-Path -Path $Family -ChildPath ('batch-{0}.json' -f $BatchId))))))
    }

    function Write-TestStage1Snapshot {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$Section,
            [Parameter(Mandatory = $true)] [string]$Family,
            [Parameter(Mandatory = $true)] [string]$BatchId,
            [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Items,
            [hashtable]$IdentityOverrides = @{}
        )

        $artifactPath = Get-TestArtifactPath -RunPath $RunPath -Section $Section -Family $Family -BatchId $BatchId
        $artifactDirectory = Split-Path -Path $artifactPath -Parent
        New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null

        $snapshot = [ordered]@{
            schemaVersion = '1.0'
            runId = ([System.IO.DirectoryInfo]([System.IO.Path]::GetFullPath($RunPath))).Name
            stage = 'stage1'
            section = $Section
            family = $Family
            batchId = $BatchId
            collectedUtc = '2026-09-06T00:00:00.0000000Z'
            sourceType = 'Graph'
            sourceName = '/v1.0/test'
            apiVersion = 'v1.0'
            isBeta = $false
            requestContext = @{}
            itemCount = @($Items).Count
            items = @($Items)
        }

        foreach ($identityName in $IdentityOverrides.Keys) {
            $snapshot[$identityName] = $IdentityOverrides[$identityName]
        }

        $snapshot | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        return $artifactPath
    }

    function Save-TestStage1Checkpoint {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$Section,
            [Parameter(Mandatory = $true)] [string]$Family,
            [Parameter(Mandatory = $true)] [string[]]$BatchIds
        )

        $runId = ([System.IO.DirectoryInfo]([System.IO.Path]::GetFullPath($RunPath))).Name
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage 'stage1' -Section $Section -Family $Family
        $checkpoint.batches = @()

        $planBatches = @()
        foreach ($batchId in $BatchIds) {
            $artifactPath = Get-TestArtifactPath -RunPath $RunPath -Section $Section -Family $Family -BatchId $batchId
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifactPath -ErrorMessage $null

            $fixtureFingerprint = 'test-' + $batchId
            if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
                try {
                    $artifactSnapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
                    if ($null -ne $artifactSnapshot -and $artifactSnapshot.PSObject.Properties.Match('items').Count -gt 0) {
                        $fixtureFingerprint = Get-CollectorSnapshotBatchFingerprint -Items @($artifactSnapshot.items)
                    }
                }
                catch {
                    $artifactSnapshot = $null
                    # Malformed fixtures intentionally fail before fingerprint validation.
                }
            }

            $planBatches += [pscustomobject]@{
                batchId = $batchId
                itemCount = 1
                fingerprint = $fixtureFingerprint
            }
        }

        $checkpoint.plan = [pscustomobject]@{
            planVersion = '1.0'
            batchSize = 100
            expectedBatchCount = @($BatchIds).Count
            sourceFingerprint = 'test-source'
            completed = $true
            batches = @($planBatches)
        }

        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
    }
}

Describe 'Checkpoint-bound Stage1 snapshot loading' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage1-binding-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'bound-run'
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
        $script:section = 'entra-apps'
        $script:family = 'applications'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'loads only checkpoint-planned batches and ignores an unreferenced extra snapshot' {
        Write-TestStage1Snapshot -RunPath $script:runPath -Section $script:section -Family $script:family -BatchId '0001' -Items @([pscustomobject]@{ id = 'planned' }) | Out-Null
        Write-TestStage1Snapshot -RunPath $script:runPath -Section $script:section -Family $script:family -BatchId '9999' -Items @([pscustomobject]@{ id = 'stale-extra' }) | Out-Null
        Save-TestStage1Checkpoint -RunPath $script:runPath -Section $script:section -Family $script:family -BatchIds @('0001')

        $items = @(Get-CollectorSnapshotItems -RunPath $script:runPath -Stage 'stage1' -Section $script:section -Family $script:family)

        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'planned') {
            throw ('Expected only the checkpoint-owned item; actual ids: {0}.' -f ((@($items | ForEach-Object { [string]$_.id })) -join ','))
        }
    }

    It 'rejects every persisted snapshot identity mismatch before returning items' {
        Save-TestStage1Checkpoint -RunPath $script:runPath -Section $script:section -Family $script:family -BatchIds @('0001')

        $mismatches = @(
            @{ Name = 'runId'; Value = 'other-run' },
            @{ Name = 'stage'; Value = 'stage2' },
            @{ Name = 'section'; Value = 'intune-core' },
            @{ Name = 'family'; Value = 'groups' },
            @{ Name = 'batchId'; Value = '9999' }
        )

        foreach ($mismatch in $mismatches) {
            $overrides = @{}
            $overrides[$mismatch.Name] = $mismatch.Value
            Write-TestStage1Snapshot -RunPath $script:runPath -Section $script:section -Family $script:family -BatchId '0001' -Items @([pscustomobject]@{ id = 'must-not-load' }) -IdentityOverrides $overrides | Out-Null

            $threw = $false
            try {
                Get-CollectorSnapshotItems -RunPath $script:runPath -Stage 'stage1' -Section $script:section -Family $script:family | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'Snapshot identity mismatch' -or $_.Exception.Message -notmatch [regex]::Escape([string]$mismatch.Name)) {
                    throw ('Expected {0} identity rejection; actual error: {1}' -f $mismatch.Name, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected snapshot identity mismatch for {0} to fail closed.' -f $mismatch.Name)
            }
        }
    }

    It 'fails closed when an expected planned snapshot is missing' {
        Save-TestStage1Checkpoint -RunPath $script:runPath -Section $script:section -Family $script:family -BatchIds @('0001')

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:runPath -Stage 'stage1' -Section $script:section -Family $script:family | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Expected snapshot artifact is missing') {
                throw ('Expected missing-snapshot rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected a missing checkpoint-owned snapshot to fail closed.'
        }
    }

    It 'fails closed when an expected planned snapshot contains malformed JSON' {
        $artifactPath = Get-TestArtifactPath -RunPath $script:runPath -Section $script:section -Family $script:family -BatchId '0001'
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
        '{not-json' | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        Save-TestStage1Checkpoint -RunPath $script:runPath -Section $script:section -Family $script:family -BatchIds @('0001')

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:runPath -Stage 'stage1' -Section $script:section -Family $script:family | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Expected snapshot artifact is unreadable') {
                throw ('Expected malformed-snapshot rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected a malformed checkpoint-owned snapshot to fail closed.'
        }
    }

    It 'loads every valid planned batch exactly once in checkpoint plan order' {
        Write-TestStage1Snapshot -RunPath $script:runPath -Section $script:section -Family $script:family -BatchId '0001' -Items @([pscustomobject]@{ id = 'one' }) | Out-Null
        Write-TestStage1Snapshot -RunPath $script:runPath -Section $script:section -Family $script:family -BatchId '0002' -Items @([pscustomobject]@{ id = 'two' }) | Out-Null
        Save-TestStage1Checkpoint -RunPath $script:runPath -Section $script:section -Family $script:family -BatchIds @('0001', '0002')

        $items = @(Get-CollectorSnapshotItems -RunPath $script:runPath -Stage 'stage1' -Section $script:section -Family $script:family)
        $ids = @($items | ForEach-Object { [string]$_.id })

        if ($ids.Count -ne 2 -or $ids[0] -ne 'one' -or $ids[1] -ne 'two') {
            throw ('Expected planned multi-batch items one,two exactly once; actual: {0}.' -f ($ids -join ','))
        }
    }
}
