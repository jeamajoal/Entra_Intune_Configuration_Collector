BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestStage2ResumeContext {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'stage2-resume-integrity'
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

    function Get-TestStage2ArtifactPath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Section,

            [Parameter(Mandatory = $true)]
            [string]$Family
        )

        return [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath ('stage2/{0}/{1}/batch-0001.json' -f $Section, $Family)))
    }

    function Get-TestStage2Batch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Section,

            [Parameter(Mandatory = $true)]
            [string]$Family
        )

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId 'stage2-resume-integrity' -Stage 'stage2' -Section $Section -Family $Family
        return Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
    }

    function Assert-TestGraphStage2Repair {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [object[]]$Results
        )

        $applications = @($Results | Where-Object { $_.family -eq 'applications' })
        if ($applications.Count -ne 1 -or [int]$applications[0].succeededBatches -ne 1 -or [int]$applications[0].skippedBatches -ne 0 -or [int]$applications[0].failedBatches -ne 0) {
            throw 'Expected only the invalid applications Stage2 batch to be reprocessed successfully.'
        }

        foreach ($family in @('servicePrincipals', 'groups', 'applicationCredentials', 'servicePrincipalCredentials')) {
            $familyResult = @($Results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid sibling Stage2 family {0} to remain skipped.' -f $family)
            }

            $siblingBatch = Get-TestStage2Batch -RunPath $RunPath -Section 'entra-apps' -Family $family
            if ([string]$siblingBatch.status -ne 'Succeeded' -or [int]$siblingBatch.attempts -ne 1) {
                throw ('Expected sibling Stage2 family {0} to remain on attempt 1.' -f $family)
            }
        }

        $applicationBatch = Get-TestStage2Batch -RunPath $RunPath -Section 'entra-apps' -Family 'applications'
        if ([string]$applicationBatch.status -ne 'Succeeded' -or [int]$applicationBatch.attempts -ne 2 -or [int]$applicationBatch.itemCount -ne 1 -or [int]$applicationBatch.successCount -ne 1 -or [int]$applicationBatch.failedCount -ne 0) {
            throw 'Expected repaired applications Stage2 batch to be a second-attempt successful one-item batch.'
        }

        $snapshot = Get-Content -LiteralPath (Get-TestStage2ArtifactPath -RunPath $RunPath -Section 'entra-apps' -Family 'applications') -Raw | ConvertFrom-Json
        if ([string]$snapshot.runId -ne 'stage2-resume-integrity' -or [string]$snapshot.stage -ne 'stage2' -or [string]$snapshot.section -ne 'entra-apps' -or [string]$snapshot.family -ne 'applications' -or [string]$snapshot.batchId -ne '0001' -or [int]$snapshot.itemCount -ne 1 -or @($snapshot.items).Count -ne 1) {
            throw 'Expected applications Stage2 snapshot to be repaired with current identity and cardinality.'
        }
    }
}

Describe 'Stage2 Graph resume artifact integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage2-graph-resume-integrity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestStage2ResumeContext -RunPath $script:testRoot

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'source-item' })
        }
        Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps') | Out-Null

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            [pscustomobject]@{
                id = 'source-item'
                keyCredentials = @()
                passwordCredentials = @()
            }
        }
        Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps') | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'reprocesses and repairs a malformed prior successful Graph Stage2 snapshot while valid siblings remain skipped' {
        $artifactPath = Get-TestStage2ArtifactPath -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        '{not-json' | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage2Repair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses and repairs an identity-mismatched prior successful Graph Stage2 snapshot' {
        $artifactPath = Get-TestStage2ArtifactPath -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        $snapshot.runId = 'other-run'
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage2Repair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses and repairs a cardinality-invalid prior successful Graph Stage2 snapshot' {
        $artifactPath = Get-TestStage2ArtifactPath -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        $snapshot.itemCount = 2
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage2Repair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses a prior successful Graph Stage2 batch whose checkpoint success cardinality is inconsistent' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'stage2-resume-integrity' -Stage 'stage2' -Section 'entra-apps' -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        $batch.successCount = 0
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage2Repair -RunPath $script:testRoot -Results $results
    }

    It 'keeps valid prior successful Graph Stage2 artifacts skipped without incrementing attempts' {
        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps'))

        foreach ($family in @('applications', 'servicePrincipals', 'groups', 'applicationCredentials', 'servicePrincipalCredentials')) {
            $familyResult = @($results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid prior successful Stage2 family {0} to remain skipped.' -f $family)
            }

            $batch = Get-TestStage2Batch -RunPath $script:testRoot -Section 'entra-apps' -Family $family
            if ([string]$batch.status -ne 'Succeeded' -or [int]$batch.attempts -ne 1) {
                throw ('Expected valid prior successful Stage2 family {0} attempts to remain unchanged.' -f $family)
            }
        }
    }
}

Describe 'Stage2 on-prem resume artifact integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage2-onprem-resume-integrity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestStage2ResumeContext -RunPath $script:testRoot

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorOnPremInventoryFamily -MockWith {
            @([pscustomobject]@{
                name = 'source-item'
                distinguishedName = 'CN=source-item,DC=example,DC=com'
                domain = 'example.com'
            })
        }
        Invoke-CollectorStage1 -Context $script:context -Sections @('onprem-ad-gpo') | Out-Null

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorOnPremDetailFamily -MockWith {
            [pscustomobject]@{
                name = 'source-item'
                distinguishedName = 'CN=source-item,DC=example,DC=com'
                domain = 'example.com'
            }
        }
        Invoke-CollectorStage2 -Context $script:context -Sections @('onprem-ad-gpo') | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'reprocesses and repairs a malformed prior successful on-prem Stage2 snapshot while valid siblings remain skipped' {
        $artifactPath = Get-TestStage2ArtifactPath -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family 'domains'
        '{not-json' | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('onprem-ad-gpo'))

        $domains = @($results | Where-Object { $_.family -eq 'domains' })
        if ($domains.Count -ne 1 -or [int]$domains[0].succeededBatches -ne 1 -or [int]$domains[0].skippedBatches -ne 0 -or [int]$domains[0].failedBatches -ne 0) {
            throw 'Expected the invalid domains Stage2 batch to be reprocessed successfully.'
        }

        $domainsBatch = Get-TestStage2Batch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family 'domains'
        if ([string]$domainsBatch.status -ne 'Succeeded' -or [int]$domainsBatch.attempts -ne 2 -or [int]$domainsBatch.itemCount -ne 1 -or [int]$domainsBatch.successCount -ne 1 -or [int]$domainsBatch.failedCount -ne 0) {
            throw 'Expected repaired domains Stage2 batch to be a second-attempt successful one-item batch.'
        }

        foreach ($family in @('organizationalUnits', 'groups', 'gpos')) {
            $familyResult = @($results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid on-prem sibling Stage2 family {0} to remain skipped.' -f $family)
            }

            $siblingBatch = Get-TestStage2Batch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family $family
            if ([string]$siblingBatch.status -ne 'Succeeded' -or [int]$siblingBatch.attempts -ne 1) {
                throw ('Expected valid on-prem sibling Stage2 family {0} to remain on attempt 1.' -f $family)
            }
        }

        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        if ([string]$snapshot.runId -ne 'stage2-resume-integrity' -or [string]$snapshot.stage -ne 'stage2' -or [string]$snapshot.section -ne 'onprem-ad-gpo' -or [string]$snapshot.family -ne 'domains' -or [string]$snapshot.batchId -ne '0001' -or [int]$snapshot.itemCount -ne 1 -or @($snapshot.items).Count -ne 1) {
            throw 'Expected domains Stage2 snapshot to be repaired with current identity and cardinality.'
        }
    }
}
