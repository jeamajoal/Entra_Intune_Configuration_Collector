BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestPlanCompletedFixture {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        $runId = 'plan-completed-type'
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

    function Set-TestPlanCompletedValue {
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
            $checkpoint.plan.PSObject.Properties.Remove('completed')
        }
        else {
            $checkpoint.plan.completed = $Value
        }
        $checkpoint | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    }
}

Describe 'Checkpoint plan completed persisted type contract' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-plan-completed-type-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts actual Boolean true for otherwise valid Stage1 persisted evidence' {
        $fixture = Get-TestPlanCompletedFixture -RunPath $script:testRoot

        if (-not (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)) {
            throw 'Expected readiness to accept actual Boolean true plan completion.'
        }

        $items = @(Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage $fixture.Stage -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId)
        if ($items.Count -ne 1 -or [string]$items[0].id -ne 'one') {
            throw 'Expected snapshot loading to accept actual Boolean true plan completion.'
        }
    }

    It 'rejects actual Boolean false in readiness and snapshot loading' {
        $fixture = Get-TestPlanCompletedFixture -RunPath $script:testRoot
        Set-TestPlanCompletedValue -CheckpointPath $fixture.CheckpointPath -Value $false

        if (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId) {
            throw 'Expected readiness to reject actual Boolean false plan completion.'
        }

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage $fixture.Stage -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId | Out-Null
        }
        catch {
            $threw = $_.Exception.Message -like 'Snapshot loading requires a completed checkpoint plan*'
        }
        if (-not $threw) {
            throw 'Expected snapshot loading to reject actual Boolean false plan completion.'
        }
    }

    It 'rejects string true and string false in readiness and snapshot loading' {
        foreach ($value in @('true', 'false')) {
            $caseRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-plan-completed-string-' + $value + '-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            try {
                $fixture = Get-TestPlanCompletedFixture -RunPath $caseRoot
                Set-TestPlanCompletedValue -CheckpointPath $fixture.CheckpointPath -Value $value

                if (Test-CollectorInventoryArtifacts -RunPath $caseRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId) {
                    throw ('Expected readiness to reject string [{0}] plan completion.' -f $value)
                }

                $threw = $false
                try {
                    Get-CollectorSnapshotItems -RunPath $caseRoot -Stage $fixture.Stage -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId | Out-Null
                }
                catch {
                    $threw = $_.Exception.Message -like 'Snapshot loading requires a completed checkpoint plan*'
                }
                if (-not $threw) {
                    throw ('Expected snapshot loading to reject string [{0}] plan completion.' -f $value)
                }
            }
            finally {
                if (Test-Path -LiteralPath $caseRoot) {
                    Remove-Item -LiteralPath $caseRoot -Recurse -Force
                }
            }
        }
    }

    It 'rejects a missing completed property without throwing from readiness' {
        $fixture = Get-TestPlanCompletedFixture -RunPath $script:testRoot
        Set-TestPlanCompletedValue -CheckpointPath $fixture.CheckpointPath -Value $null -RemoveProperty

        if (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId) {
            throw 'Expected readiness to reject a missing completed property.'
        }

        $threw = $false
        try {
            Get-CollectorSnapshotItems -RunPath $script:testRoot -Stage $fixture.Stage -Section $fixture.Section -Family $fixture.Family -ExpectedRunId $fixture.RunId | Out-Null
        }
        catch {
            $threw = $_.Exception.Message -like 'Snapshot loading requires a completed checkpoint plan*'
        }
        if (-not $threw) {
            throw 'Expected snapshot loading to reject a missing completed property.'
        }
    }
}
