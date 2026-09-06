BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestStage1ResumeContext {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'stage1-resume-integrity'
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

    function Get-TestStage1ArtifactPath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Family
        )

        return [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath ('stage1/entra-apps/{0}/batch-0001.json' -f $Family)))
    }

    function Get-TestStage1Batch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Family
        )

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId 'stage1-resume-integrity' -Stage 'stage1' -Section 'entra-apps' -Family $Family
        return Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
    }

    function Assert-TestResumeRepair {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [object[]]$Results
        )

        $applications = @($Results | Where-Object { $_.family -eq 'applications' })
        $servicePrincipals = @($Results | Where-Object { $_.family -eq 'servicePrincipals' })
        $groups = @($Results | Where-Object { $_.family -eq 'groups' })

        if ($applications.Count -ne 1 -or [int]$applications[0].succeededBatches -ne 1 -or [int]$applications[0].skippedBatches -ne 0 -or [int]$applications[0].failedBatches -ne 0) {
            throw 'Expected only the corrupted applications family batch to be reprocessed successfully.'
        }
        foreach ($sibling in @($servicePrincipals, $groups)) {
            if ($sibling.Count -ne 1 -or [int]$sibling[0].succeededBatches -ne 0 -or [int]$sibling[0].skippedBatches -ne 1 -or [int]$sibling[0].failedBatches -ne 0) {
                throw 'Expected valid sibling Stage1 family batches to remain skipped during repair.'
            }
        }

        $applicationBatch = Get-TestStage1Batch -RunPath $RunPath -Family 'applications'
        if ([string]$applicationBatch.status -ne 'Succeeded' -or [int]$applicationBatch.attempts -ne 2 -or [int]$applicationBatch.itemCount -ne 1 -or [int]$applicationBatch.successCount -ne 1 -or [int]$applicationBatch.failedCount -ne 0) {
            throw 'Expected the repaired applications checkpoint batch to be a second-attempt successful one-item batch.'
        }

        foreach ($family in @('servicePrincipals', 'groups')) {
            $siblingBatch = Get-TestStage1Batch -RunPath $RunPath -Family $family
            if ([string]$siblingBatch.status -ne 'Succeeded' -or [int]$siblingBatch.attempts -ne 1) {
                throw ('Expected sibling {0} batch to remain on its original successful attempt.' -f $family)
            }
        }

        $snapshot = Get-Content -LiteralPath (Get-TestStage1ArtifactPath -RunPath $RunPath -Family 'applications') -Raw | ConvertFrom-Json
        if ([string]$snapshot.runId -ne 'stage1-resume-integrity' -or [string]$snapshot.stage -ne 'stage1' -or [string]$snapshot.section -ne 'entra-apps' -or [string]$snapshot.family -ne 'applications' -or [string]$snapshot.batchId -ne '0001' -or [int]$snapshot.itemCount -ne 1 -or @($snapshot.items).Count -ne 1) {
            throw 'Expected the applications snapshot to be repaired with current identity and cardinality.'
        }
    }
}

Describe 'Stage1 resume artifact integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage1-resume-integrity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestStage1ResumeContext -RunPath $script:testRoot

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'current-item' })
        }

        Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps') | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'reprocesses and repairs a malformed prior successful Stage1 snapshot while valid siblings remain skipped' {
        $artifactPath = Get-TestStage1ArtifactPath -RunPath $script:testRoot -Family 'applications'
        '{not-json' | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps'))

        Assert-TestResumeRepair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses and repairs an identity-mismatched prior successful Stage1 snapshot' {
        $artifactPath = Get-TestStage1ArtifactPath -RunPath $script:testRoot -Family 'applications'
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        $snapshot.runId = 'other-run'
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps'))

        Assert-TestResumeRepair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses and repairs a cardinality-invalid prior successful Stage1 snapshot' {
        $artifactPath = Get-TestStage1ArtifactPath -RunPath $script:testRoot -Family 'applications'
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        $snapshot.itemCount = 2
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps'))

        Assert-TestResumeRepair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses a prior successful Stage1 batch whose checkpoint success cardinality is inconsistent' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'stage1-resume-integrity' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        $batch.successCount = 0
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps'))

        Assert-TestResumeRepair -RunPath $script:testRoot -Results $results
    }

    It 'keeps valid prior successful Stage1 artifacts skipped without incrementing attempts' {
        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps'))

        foreach ($family in @('applications', 'servicePrincipals', 'groups')) {
            $familyResult = @($results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid prior successful {0} batch to remain skipped.' -f $family)
            }

            $batch = Get-TestStage1Batch -RunPath $script:testRoot -Family $family
            if ([string]$batch.status -ne 'Succeeded' -or [int]$batch.attempts -ne 1) {
                throw ('Expected valid prior successful {0} batch attempts to remain unchanged.' -f $family)
            }
        }
    }
}
