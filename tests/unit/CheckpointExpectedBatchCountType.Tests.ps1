BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestExpectedBatchCountFixture {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        $runId = 'expected-batch-count-type'
        $stage = 'stage1'
        $section = 'entra-apps'
        $family = 'applications'
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage $stage -Section $section -Family $family
        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        $batches = Split-CollectorItems -Items $items -BatchSize 100
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100

        $snapshot = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = $runId
            stage = $stage
            section = $section
            family = $family
            batchId = '0001'
            collectedUtc = '2026-09-06T00:00:00.0000000Z'
            sourceType = 'Graph'
            sourceName = '/v1.0/applications'
            apiVersion = 'v1.0'
            isBeta = $false
            requestContext = [pscustomobject]@{}
            itemCount = 1
            items = @([pscustomobject]@{ id = 'one' })
        }
        $artifact = Write-CollectorSnapshotArtifact -RunPath $RunPath -Stage $stage -Section $section -Family $family -BatchNumber 1 -Snapshot $snapshot
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifact.artifactPath -ErrorMessage $null
        $checkpoint.plan.completed = $true
        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null

        return [pscustomobject]@{
            RunId = $runId
            Stage = $stage
            Section = $section
            Family = $family
            CheckpointPath = (Join-Path -Path $RunPath -ChildPath 'checkpoints/stage1/entra-apps/applications.json')
        }
    }

    function Set-TestExpectedBatchCountValue {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This test helper mutates only temporary checkpoint fixture files.')]
        param(
            [Parameter(Mandatory = $true)]
            [string]$CheckpointPath,

            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$Value,

            [switch]$RemoveProperty
        )

        $checkpoint = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        if ($RemoveProperty) {
            $checkpoint.plan.PSObject.Properties.Remove('expectedBatchCount')
        }
        else {
            $checkpoint.plan.expectedBatchCount = $Value
        }
        $checkpoint | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    }

    function Assert-TestExpectedBatchCountRejected {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [object]$Fixture,

            [Parameter(Mandatory = $true)]
            [string]$CaseName
        )

        $readinessThrew = $false
        $isReady = $null
        try {
            $isReady = Test-CollectorInventoryArtifacts -RunPath $RunPath -Section $Fixture.Section -Family $Fixture.Family -ExpectedRunId $Fixture.RunId
        }
        catch {
            $readinessThrew = $true
        }
        if ($readinessThrew -or $isReady) {
            throw ('Expected readiness to fail closed without throwing for invalid expectedBatchCount case [{0}].' -f $CaseName)
        }

        $loaderRejected = $false
        try {
            Get-CollectorSnapshotItems -RunPath $RunPath -Stage $Fixture.Stage -Section $Fixture.Section -Family $Fixture.Family -ExpectedRunId $Fixture.RunId | Out-Null
        }
        catch {
            $loaderRejected = $_.Exception.Message -like 'Snapshot checkpoint plan is incomplete or inconsistent*'
        }
        if (-not $loaderRejected) {
            throw ('Expected snapshot loading to reject invalid expectedBatchCount case [{0}] with the bounded plan-consistency error.' -f $CaseName)
        }
    }
}

Describe 'Checkpoint expectedBatchCount persisted numeric contract' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-expected-batch-count-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts persisted numeric integral forms that match the completed plan' {
        foreach ($value in @([int]1, [long]1, [double]1.0, [decimal]1.0)) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-expected-batch-count-valid-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $fixture = Get-TestExpectedBatchCountFixture -RunPath $caseRoot
                Set-TestExpectedBatchCountValue -CheckpointPath $fixture.CheckpointPath -Value $value

                if (-not (Test-CollectorInventoryArtifacts -RunPath $caseRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)) {
                    throw ('Expected readiness to accept persisted numeric integral expectedBatchCount value [{0}] of type [{1}].' -f $value, $value.GetType().FullName)
                }

                $items = @(Get-CollectorSnapshotItems -RunPath $caseRoot -Stage $fixture.Stage -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)
                if ($items.Count -ne 1 -or [string]$items[0].id -ne 'one') {
                    throw 'Expected snapshot loading to accept valid persisted numeric integral expectedBatchCount.'
                }
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'rejects a missing expectedBatchCount without readiness throwing' {
        $fixture = Get-TestExpectedBatchCountFixture -RunPath $script:testRoot
        Set-TestExpectedBatchCountValue -CheckpointPath $fixture.CheckpointPath -Value $null -RemoveProperty

        Assert-TestExpectedBatchCountRejected -RunPath $script:testRoot -Fixture $fixture -CaseName 'missing'
    }

    It 'rejects schema-invalid string and malformed expectedBatchCount values' {
        $invalidCases = @(
            [pscustomobject]@{ Name = 'numeric-string'; Value = '1' },
            [pscustomobject]@{ Name = 'text-string'; Value = 'abc' },
            [pscustomobject]@{ Name = 'object'; Value = [pscustomobject]@{ bad = $true } }
        )

        foreach ($invalidCase in $invalidCases) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-expected-batch-count-invalid-shape-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $fixture = Get-TestExpectedBatchCountFixture -RunPath $caseRoot
                Set-TestExpectedBatchCountValue -CheckpointPath $fixture.CheckpointPath -Value $invalidCase.Value
                Assert-TestExpectedBatchCountRejected -RunPath $caseRoot -Fixture $fixture -CaseName $invalidCase.Name
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'rejects fractional nonpositive and out-of-range numeric expectedBatchCount values' {
        $invalidCases = @(
            [pscustomobject]@{ Name = 'fractional'; Value = [double]1.5 },
            [pscustomobject]@{ Name = 'zero'; Value = [int]0 },
            [pscustomobject]@{ Name = 'negative'; Value = [int]-1 },
            [pscustomobject]@{ Name = 'out-of-range'; Value = ([long][int]::MaxValue + 1) }
        )

        foreach ($invalidCase in $invalidCases) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-expected-batch-count-invalid-number-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $fixture = Get-TestExpectedBatchCountFixture -RunPath $caseRoot
                Set-TestExpectedBatchCountValue -CheckpointPath $fixture.CheckpointPath -Value $invalidCase.Value
                Assert-TestExpectedBatchCountRejected -RunPath $caseRoot -Fixture $fixture -CaseName $invalidCase.Name
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }
}
