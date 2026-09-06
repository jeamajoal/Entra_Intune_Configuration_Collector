BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestStage1FingerprintContext {
        param([Parameter(Mandatory = $true)][string]$RunPath)

        return @{
            RunPath = $RunPath
            RunId = 'stage1-fingerprint-integrity'
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

    function Get-TestStage1FingerprintArtifactPath {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family
        )

        return [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath ('stage1/entra-apps/{0}/batch-0001.json' -f $Family)))
    }

    function Set-TestStage1FingerprintSubstitution {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This test helper mutates only a temporary canonical snapshot fixture.')]
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family
        )

        $artifactPath = Get-TestStage1FingerprintArtifactPath -RunPath $RunPath -Family $Family
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        $snapshot.itemCount = 1
        $snapshot.items = @([pscustomobject]@{ id = 'substituted-item'; displayName = 'substituted-item' })
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
    }

    function Assert-TestStage1FingerprintLoadFailure {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family
        )

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $RunPath -Stage 'stage1' -Section 'entra-apps' -Family $Family -ExpectedRunId 'stage1-fingerprint-integrity' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Snapshot fingerprint mismatch') {
                throw ('Expected Stage1 snapshot fingerprint rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected Stage1 snapshot loading to reject same-cardinality substituted items.'
        }
    }
}

Describe 'Stage1 snapshot fingerprint integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage1-fingerprint-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestStage1FingerprintContext -RunPath $script:testRoot

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'current-item'; displayName = 'current-item' })
        }

        Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps') | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'reprocesses same-cardinality substituted Stage1 content during resume while valid siblings stay skipped' {
        Set-TestStage1FingerprintSubstitution -RunPath $script:testRoot -Family 'applications'

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps'))

        $applications = @($results | Where-Object { $_.family -eq 'applications' })
        if ($applications.Count -ne 1 -or [int]$applications[0].succeededBatches -ne 1 -or [int]$applications[0].skippedBatches -ne 0 -or [int]$applications[0].failedBatches -ne 0) {
            throw 'Expected same-cardinality substituted applications content to be reprocessed successfully.'
        }

        foreach ($family in @('servicePrincipals', 'groups')) {
            $familyResult = @($results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid sibling {0} Stage1 batch to remain skipped.' -f $family)
            }
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'stage1-fingerprint-integrity' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        if ([string]$batch.status -ne 'Succeeded' -or [int]$batch.attempts -ne 2 -or [int]$batch.successCount -ne 1 -or [int]$batch.failedCount -ne 0) {
            throw 'Expected repaired applications batch to be a second-attempt successful batch.'
        }

        $snapshot = Get-Content -LiteralPath (Get-TestStage1FingerprintArtifactPath -RunPath $script:testRoot -Family 'applications') -Raw | ConvertFrom-Json
        if (@($snapshot.items).Count -ne 1 -or [string]$snapshot.items[0].id -ne 'current-item') {
            throw 'Expected Stage1 resume repair to restore the current source item.'
        }
    }

    It 'rejects same-cardinality substituted Stage1 content during generic snapshot loading' {
        Set-TestStage1FingerprintSubstitution -RunPath $script:testRoot -Family 'applications'
        Assert-TestStage1FingerprintLoadFailure -RunPath $script:testRoot -Family 'applications'
    }

    It 'blocks direct Stage2 from consuming same-cardinality substituted Stage1 content' {
        Set-TestStage1FingerprintSubstitution -RunPath $script:testRoot -Family 'applications'

        $threw = $false
        try {
            Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Snapshot fingerprint mismatch') {
                throw ('Expected direct Stage2 fingerprint rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected direct Stage2 execution to reject substituted Stage1 content.'
        }
    }

    It 'blocks direct Stage3 from consuming same-cardinality substituted Stage1 content' {
        Set-TestStage1FingerprintSubstitution -RunPath $script:testRoot -Family 'servicePrincipals'

        $threw = $false
        try {
            Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Snapshot fingerprint mismatch') {
                throw ('Expected direct Stage3 fingerprint rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected direct Stage3 execution to reject substituted Stage1 content.'
        }
    }

    It 'keeps valid and legitimate zero-item Stage1 snapshots loadable' {
        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'stage1-fingerprint-integrity')
        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'current-item') {
            throw 'Expected valid Stage1 snapshot fingerprint to remain loadable.'
        }

        $emptyRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage1-fingerprint-empty-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $emptyRoot -ItemType Directory -Force | Out-Null
        try {
            Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith { @() }
            $emptyContext = Get-TestStage1FingerprintContext -RunPath $emptyRoot
            Invoke-CollectorStage1 -Context $emptyContext -Sections @('entra-apps') | Out-Null

            $emptyItems = @(Get-CollectorSnapshotItems -RunPath $emptyRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'stage1-fingerprint-integrity')
            if ($emptyItems.Count -ne 0) {
                throw ('Expected legitimate zero-item Stage1 snapshot to remain loadable; actual count: {0}' -f $emptyItems.Count)
            }
        }
        finally {
            if (Test-Path -LiteralPath $emptyRoot) {
                Remove-Item -LiteralPath $emptyRoot -Recurse -Force
            }
        }
    }
}