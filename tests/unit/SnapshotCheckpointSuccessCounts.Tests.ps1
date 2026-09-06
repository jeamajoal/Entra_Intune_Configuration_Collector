BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestSnapshotCountContext {
        param([Parameter(Mandatory = $true)][string]$RunPath)

        return @{
            RunPath = $RunPath
            RunId = 'snapshot-count-integrity'
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

    function Get-TestStage1Batch {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family
        )

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId 'snapshot-count-integrity' -Stage 'stage1' -Section 'entra-apps' -Family $Family
        return [pscustomobject]@{
            Checkpoint = $checkpoint
            Batch = (Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001')
        }
    }

    function Save-TestStage1BatchMutation {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family,
            [Parameter(Mandatory = $true)][scriptblock]$Mutation
        )

        $state = Get-TestStage1Batch -RunPath $RunPath -Family $Family
        & $Mutation $state.Batch
        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $state.Checkpoint | Out-Null
    }

    function Assert-TestSnapshotLoadFailure {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$Family
        )

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $RunPath -Stage 'stage1' -Section 'entra-apps' -Family $Family -ExpectedRunId 'snapshot-count-integrity' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'success/failure counts') {
                throw ('Expected snapshot success/failure count rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected snapshot loading to reject inconsistent succeeded checkpoint counts.'
        }
    }
}

Describe 'Succeeded snapshot checkpoint count integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-count-integrity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestSnapshotCountContext -RunPath $script:testRoot

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'seed-1'; displayName = 'seed-1' })
        }

        Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps') | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects a succeeded snapshot checkpoint whose successCount does not equal itemCount' {
        Save-TestStage1BatchMutation -RunPath $script:testRoot -Family 'applications' -Mutation {
            param($batch)
            $batch.successCount = 0
        }

        Assert-TestSnapshotLoadFailure -RunPath $script:testRoot -Family 'applications'
    }

    It 'rejects a succeeded snapshot checkpoint whose failedCount is nonzero' {
        Save-TestStage1BatchMutation -RunPath $script:testRoot -Family 'applications' -Mutation {
            param($batch)
            $batch.failedCount = 1
        }

        Assert-TestSnapshotLoadFailure -RunPath $script:testRoot -Family 'applications'
    }

    It 'fails closed for missing malformed or negative succeeded success/failure counts' {
        $cases = @(
            { param($batch) $batch.PSObject.Properties.Remove('successCount') },
            { param($batch) $batch.successCount = 'not-an-int' },
            { param($batch) $batch.failedCount = -1 }
        )

        foreach ($mutation in $cases) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-count-case-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $caseContext = Get-TestSnapshotCountContext -RunPath $caseRoot
                Invoke-CollectorStage1 -Context $caseContext -Sections @('entra-apps') | Out-Null
                Save-TestStage1BatchMutation -RunPath $caseRoot -Family 'applications' -Mutation $mutation
                Assert-TestSnapshotLoadFailure -RunPath $caseRoot -Family 'applications'
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'blocks direct Stage2 from consuming inconsistent succeeded Stage1 state' {
        Save-TestStage1BatchMutation -RunPath $script:testRoot -Family 'applications' -Mutation {
            param($batch)
            $batch.successCount = 0
        }

        $threw = $false
        try {
            Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'success/failure counts') {
                throw ('Expected direct Stage2 snapshot-count rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected direct Stage2 execution to reject inconsistent Stage1 succeeded checkpoint counts.'
        }
    }

    It 'blocks direct Stage3 from consuming inconsistent succeeded Stage1 state' {
        Save-TestStage1BatchMutation -RunPath $script:testRoot -Family 'servicePrincipals' -Mutation {
            param($batch)
            $batch.failedCount = 1
        }

        $threw = $false
        try {
            Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'success/failure counts') {
                throw ('Expected direct Stage3 snapshot-count rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected direct Stage3 execution to reject inconsistent Stage1 succeeded checkpoint counts.'
        }
    }

    It 'keeps valid succeeded and legitimate zero-item Stage1 snapshots loadable' {
        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'snapshot-count-integrity')
        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'seed-1') {
            throw 'Expected valid succeeded Stage1 snapshot to remain loadable.'
        }

        $emptyRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-snapshot-count-empty-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $emptyRoot -ItemType Directory -Force | Out-Null
        try {
            Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith { @() }
            $emptyContext = Get-TestSnapshotCountContext -RunPath $emptyRoot
            Invoke-CollectorStage1 -Context $emptyContext -Sections @('entra-apps') | Out-Null
            $emptyItems = @(Get-CollectorSnapshotItems -RunPath $emptyRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -ExpectedRunId 'snapshot-count-integrity')
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
