[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester mock scriptblocks intentionally mirror production stage command signatures.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Write-TestSummaryCheckpoint {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][object[]]$Batches,
            [string]$Stage = 'stage1',
            [string]$Section = 'entra-apps',
            [string]$Family = 'applications'
        )

        $runId = ([System.IO.DirectoryInfo]$RunPath).Name
        $checkpointPath = Get-CollectorCheckpointPath -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family
        New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null

        [pscustomobject]@{
            schemaVersion = '1.0'
            runId = $runId
            stage = $Stage
            section = $Section
            family = $Family
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            plan = $null
            batches = @($Batches)
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        return $checkpointPath
    }

    function Get-TestSummaryBatch {
        param(
            [object]$Status = 'Succeeded',
            [object]$ItemCount = 1,
            [string]$BatchId = '0001'
        )

        return [pscustomobject]@{
            batchId = $BatchId
            status = $Status
            attempts = 1
            itemCount = $ItemCount
            successCount = 0
            failedCount = 0
            artifactPath = $null
            error = $null
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}

Describe 'Checkpoint summary consumed batch integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-summary-batch-integrity-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'run-summary-batch'
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'preserves valid status buckets and legitimate zero-item summary behavior' {
        $batches = @(
            (Get-TestSummaryBatch -BatchId '0001' -Status 'Succeeded' -ItemCount 3),
            (Get-TestSummaryBatch -BatchId '0002' -Status 'Failed' -ItemCount 2),
            (Get-TestSummaryBatch -BatchId '0003' -Status 'Missing' -ItemCount 1),
            (Get-TestSummaryBatch -BatchId '0004' -Status 'InProgress' -ItemCount 0)
        )
        Write-TestSummaryCheckpoint -RunPath $script:runPath -Batches $batches | Out-Null

        $summary = @(Get-CollectorCheckpointSummary -RunPath $script:runPath)
        if ($summary.Count -ne 1) {
            throw ('Expected one summary row; found {0}.' -f $summary.Count)
        }

        $row = $summary[0]
        if (
            $row.batchCount -ne 4 -or
            $row.succeededBatches -ne 1 -or
            $row.failedBatches -ne 1 -or
            $row.missingBatches -ne 1 -or
            $row.inProgressBatches -ne 1 -or
            $row.itemCount -ne 6
        ) {
            throw ('Expected valid summary counts 4/1/1/1/1/6; actual {0}/{1}/{2}/{3}/{4}/{5}.' -f $row.batchCount, $row.succeededBatches, $row.failedBatches, $row.missingBatches, $row.inProgressBatches, $row.itemCount)
        }
    }

    It 'rejects schema-invalid persisted batch status instead of emitting a false summary row' {
        $invalidStatuses = @(
            'Bogus',
            'succeeded',
            '',
            $true,
            $null
        )

        foreach ($invalidStatus in $invalidStatuses) {
            $batch = Get-TestSummaryBatch -Status $invalidStatus -ItemCount 1
            Write-TestSummaryCheckpoint -RunPath $script:runPath -Batches @($batch) | Out-Null

            $threw = $false
            try {
                Get-CollectorCheckpointSummary -RunPath $script:runPath | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'invalid.*status') {
                    throw ('Expected invalid-status summary rejection; actual error: {0}' -f $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected schema-invalid status [{0}] to be rejected.' -f [string]$invalidStatus)
            }
        }

        $missingStatusBatch = Get-TestSummaryBatch -Status 'Succeeded' -ItemCount 1
        $missingStatusBatch.PSObject.Properties.Remove('status')
        Write-TestSummaryCheckpoint -RunPath $script:runPath -Batches @($missingStatusBatch) | Out-Null

        $missingThrew = $false
        try {
            Get-CollectorCheckpointSummary -RunPath $script:runPath | Out-Null
        }
        catch {
            $missingThrew = $true
            if ($_.Exception.Message -notmatch '(missing status|invalid persisted status)') {
                throw ('Expected missing-status summary rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }
        if (-not $missingThrew) {
            throw 'Expected missing persisted batch status to be rejected.'
        }
    }

    It 'rejects schema-invalid persisted itemCount instead of coercing it into the summary' {
        $invalidValues = @(
            '3',
            $true,
            [pscustomobject]@{ value = 3 },
            [double]1.5,
            [double]::Parse('1.0000000000000002', [System.Globalization.CultureInfo]::InvariantCulture),
            -1,
            ([long][int]::MaxValue + 1),
            $null
        )

        foreach ($invalidValue in $invalidValues) {
            $batch = Get-TestSummaryBatch -Status 'Succeeded' -ItemCount $invalidValue
            Write-TestSummaryCheckpoint -RunPath $script:runPath -Batches @($batch) | Out-Null

            $threw = $false
            try {
                Get-CollectorCheckpointSummary -RunPath $script:runPath | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'invalid itemCount') {
                    throw ('Expected strict itemCount summary rejection; actual error: {0}' -f $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected schema-invalid itemCount [{0}] to be rejected.' -f [string]$invalidValue)
            }
        }

        $missingItemCountBatch = Get-TestSummaryBatch -Status 'Succeeded' -ItemCount 1
        $missingItemCountBatch.PSObject.Properties.Remove('itemCount')
        Write-TestSummaryCheckpoint -RunPath $script:runPath -Batches @($missingItemCountBatch) | Out-Null

        $missingThrew = $false
        try {
            Get-CollectorCheckpointSummary -RunPath $script:runPath | Out-Null
        }
        catch {
            $missingThrew = $true
            if ($_.Exception.Message -notmatch 'invalid itemCount') {
                throw ('Expected missing itemCount summary rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }
        if (-not $missingThrew) {
            throw 'Expected missing persisted batch itemCount to be rejected.'
        }
    }

    It 'persists terminal Failed manifest state when final summary batch validation fails' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $batch = [pscustomobject]@{
                batchId = '0001'
                status = 'Bogus'
                attempts = 1
                itemCount = 1
                successCount = 0
                failedCount = 0
                artifactPath = $null
                error = $null
                updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            }
            Write-TestSummaryCheckpoint -RunPath $Context.RunPath -Batches @($batch) -Stage 'stage1' -Section 'onprem-ad-gpo' -Family 'domains' | Out-Null
            return @()
        }

        $caughtMessage = $null
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo') | Out-Null
        }
        catch {
            $caughtMessage = $_.Exception.Message
        }

        if ($caughtMessage -notmatch 'invalid.*status') {
            throw ('Expected final summary validation error to escape; actual: {0}' -f $caughtMessage)
        }

        $runDirectory = Get-ChildItem -LiteralPath $script:testRoot -Directory | Where-Object { $_.Name -ne 'run-summary-batch' } | Select-Object -First 1
        if (-not $runDirectory) {
            throw 'Expected failed invocation to retain its run directory.'
        }

        $manifestPath = Join-Path -Path $runDirectory.FullName -ChildPath 'manifest/run-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $latestInvocation = @($manifest.invocations)[-1]

        if ([string]$manifest.status -ne 'Failed' -or [string]$latestInvocation.status -ne 'Failed') {
            throw ('Expected terminal Failed status; manifest={0}, invocation={1}.' -f $manifest.status, $latestInvocation.status)
        }
        if (@($manifest.checkpointSummary).Count -ne 0) {
            throw 'Schema-invalid checkpoint state must not contribute a checkpoint summary row after failure.'
        }
        if (@($latestInvocation.failures | Where-Object { [string]$_.error -match 'invalid.*status' }).Count -lt 1) {
            throw 'Expected checkpoint-summary validation failure evidence in the invocation manifest.'
        }
    }
}
