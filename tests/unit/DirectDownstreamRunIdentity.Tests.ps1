BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Save-TestStage1IdentityFixture {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$RunId,
            [Parameter(Mandatory = $true)] [string]$Section,
            [Parameter(Mandatory = $true)] [string]$Family
        )

        $snapshot = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = $RunId
            stage = 'stage1'
            section = $Section
            family = $Family
            batchId = '0001'
            collectedUtc = '2026-09-06T00:00:00.0000000Z'
            sourceType = 'Graph'
            sourceName = '/v1.0/test'
            apiVersion = 'v1.0'
            isBeta = $false
            requestContext = @{}
            itemCount = 1
            items = @([pscustomobject]@{ id = 'seed-1' })
        }

        $artifact = Write-CollectorSnapshotArtifact -RunPath $RunPath -Stage 'stage1' -Section $Section -Family $Family -BatchNumber 1 -Snapshot $snapshot
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $RunId -Stage 'stage1' -Section $Section -Family $Family
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifact.artifactPath -ErrorMessage $null
        $checkpoint.plan = [pscustomobject]@{
            planVersion = '1.0'
            batchSize = 100
            expectedBatchCount = 1
            sourceFingerprint = 'direct-run-identity-source'
            completed = $true
            batches = @([pscustomobject]@{
                batchId = '0001'
                itemCount = 1
                fingerprint = 'direct-run-identity-batch'
            })
        }
        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
    }

    function Get-TestDirectContext {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$RunId
        )

        return @{
            RunPath = $RunPath
            RunId = $RunId
            GraphToken = 'test-token'
            BatchSize = 100
            Resume = $false
            ReprocessFailedOnly = $false
            MaxRetries = 1
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
        }
    }
}

Describe 'Direct downstream Stage1 run identity binding' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-direct-runid-folder-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects stale Stage1 inventory during direct Stage2 execution without a manifest' {
        Save-TestStage1IdentityFixture -RunPath $script:testRoot -RunId 'stale-run' -Section 'entra-apps' -Family 'applications'
        $context = Get-TestDirectContext -RunPath $script:testRoot -RunId 'current-run'

        $threw = $false
        try {
            Invoke-CollectorStage2 -Context $context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Stage2 inventory-first enforcement failed' -or $_.Exception.Message -notmatch 'mismatched Stage1 artifact') {
                throw ('Expected Stage2 stale-run readiness rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected direct Stage2 execution to reject Stage1 inventory from a different logical run.'
        }
    }

    It 'rejects stale Stage1 inventory during direct Stage3 execution without a manifest' {
        Save-TestStage1IdentityFixture -RunPath $script:testRoot -RunId 'stale-run' -Section 'entra-apps' -Family 'servicePrincipals'
        $context = Get-TestDirectContext -RunPath $script:testRoot -RunId 'current-run'

        $threw = $false
        try {
            Invoke-CollectorStage3 -Context $context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Stage3 inventory-first enforcement failed' -or $_.Exception.Message -notmatch 'mismatched Stage1 artifact') {
                throw ('Expected Stage3 stale-run readiness rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected direct Stage3 execution to reject Stage1 inventory from a different logical run.'
        }
    }

    It 'binds storage readiness and loading to the expected run identity' {
        Save-TestStage1IdentityFixture -RunPath $script:testRoot -RunId 'logical-run' -Section 'entra-apps' -Family 'applications'

        if (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'other-run') {
            throw 'Expected readiness to reject a different expected run identity.'
        }

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'other-run' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Snapshot loading run identity mismatch') {
                throw ('Expected loader run-identity rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected loader to reject a different expected run identity.'
        }
    }

    It 'accepts matching logical run identity when the RunPath leaf is unrelated' {
        Save-TestStage1IdentityFixture -RunPath $script:testRoot -RunId 'logical-run' -Section 'entra-apps' -Family 'applications'

        if (-not (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'logical-run')) {
            throw 'Expected matching logical run identity to pass readiness independently of the RunPath leaf.'
        }

        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'logical-run')
        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'seed-1') {
            throw ('Expected matching logical-run Stage1 item seed-1; actual count/ids: {0}/{1}.' -f $items.Count, ((@($items | ForEach-Object { [string]$_.id })) -join ','))
        }
    }
}
