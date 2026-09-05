[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester mock scriptblocks intentionally mirror the production stage command signatures even when an individual scenario only inspects one of the bound parameters.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
}

Describe 'Collector orchestrator selectors' {
    It 'resolves All to Stage1 Stage2 Stage3 in execution order' {
        $resolved = Resolve-CollectorStages -Stages @('All')
        $expected = @('Stage1', 'Stage2', 'Stage3')
        if (@($resolved).Count -ne $expected.Count -or (@($resolved) -join ',') -ne ($expected -join ',')) {
            throw ('Expected resolved stages in canonical order: ' + ($expected -join ',') + '; actual: ' + (@($resolved) -join ','))
        }
    }

    It 'resolves explicit stage selection in canonical execution order' {
        $resolved = Resolve-CollectorStages -Stages @('Stage3', 'Stage1')
        $expected = @('Stage1', 'Stage3')
        if (@($resolved).Count -ne $expected.Count -or (@($resolved) -join ',') -ne ($expected -join ',')) {
            throw ('Expected resolved stages in canonical order: ' + ($expected -join ',') + '; actual: ' + (@($resolved) -join ','))
        }
    }

    It 'resolves all sections when not specified' {
        $resolved = Resolve-CollectorSections
        $expected = @('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo')
        if (@($resolved).Count -ne $expected.Count -or (@($resolved) -join ',') -ne ($expected -join ',')) {
            throw ('Expected resolved sections in canonical order: ' + ($expected -join ',') + '; actual: ' + (@($resolved) -join ','))
        }
    }

    It 'resolves section-only selection in canonical order' {
        $resolved = Resolve-CollectorSections -Sections @('onprem-ad-gpo', 'entra-apps')
        $expected = @('entra-apps', 'onprem-ad-gpo')
        if (@($resolved).Count -ne $expected.Count -or (@($resolved) -join ',') -ne ($expected -join ',')) {
            throw ('Expected resolved sections in canonical order: ' + ($expected -join ',') + '; actual: ' + (@($resolved) -join ','))
        }
    }
}

Describe 'Collector orchestrator execution flow' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-orchestrator-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -Path $script:testRoot) {
            Remove-Item -Path $script:testRoot -Recurse -Force
        }
    }

    It 'rejects a mixed valid and invalid stage selection before creating run state' {
        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1', 'Stgae3') -Sections @('onprem-ad-gpo') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Unsupported stage selection' -or $_.Exception.Message -notmatch 'Stgae3') {
                throw ('Expected explicit invalid-stage rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected mixed valid/invalid stage selection to fail.'
        }

        $markerPath = Join-Path -Path $script:testRoot -ChildPath 'current-run.json'
        if (Test-Path -LiteralPath $markerPath) {
            throw 'Invalid stage selection must fail before current-run.json is created.'
        }
    }

    It 'rejects a mixed valid and invalid section selection before creating run state' {
        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo', 'onprem-ad-gop') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Unsupported section selection' -or $_.Exception.Message -notmatch 'onprem-ad-gop') {
                throw ('Expected explicit invalid-section rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected mixed valid/invalid section selection to fail.'
        }

        $markerPath = Join-Path -Path $script:testRoot -ChildPath 'current-run.json'
        if (Test-Path -LiteralPath $markerPath) {
            throw 'Invalid section selection must fail before current-run.json is created.'
        }
    }

    It 'executes only the selected stage and forwards section-only selection in canonical order' {
        $script:capturedStage3Sections = @()

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            throw 'Stage1 should not be invoked for Stage3-only execution.'
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            throw 'Stage2 should not be invoked for Stage3-only execution.'
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $script:capturedStage3Sections = @($Sections)
            return @(
                [pscustomobject]@{
                    stage = 'stage3'
                    section = 'entra-apps'
                    family = 'groupMembers'
                    batchCount = 1
                    succeededBatches = 1
                    failedBatches = 0
                    skippedBatches = 0
                    itemCount = 1
                    errors = @()
                },
                [pscustomobject]@{
                    stage = 'stage3'
                    section = 'onprem-ad-gpo'
                    family = 'groupMembersOnPrem'
                    batchCount = 1
                    succeededBatches = 1
                    failedBatches = 0
                    skippedBatches = 0
                    itemCount = 1
                    errors = @()
                }
            )
        }

        $result = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo', 'entra-apps')

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 0 -Exactly
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -Times 0 -Exactly
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 1 -Exactly -ParameterFilter {
            @($Sections) -join ',' -eq 'entra-apps,onprem-ad-gpo'
        }

        if (@($result.stageResults).Count -ne 2) {
            throw ('Expected 2 stage results but found ' + @($result.stageResults).Count + '.')
        }

        if ($result.status -ne 'Completed') {
            throw ('Expected run status Completed but found ' + [string]$result.status + '.')
        }
    }

    It 'records manifest checkpoint and snapshot artifacts for executed stage section family output' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            throw 'Stage2 should not be invoked for Stage1-only execution.'
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            throw 'Stage3 should not be invoked for Stage1-only execution.'
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $snapshot = New-CollectorProvenanceSnapshot -RunId $Context.RunId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Graph' -SourceName 'Graph /v1.0/applications' -ApiVersion 'v1.0' -IsBeta:$false -RequestContext @{ endpoint = '/v1.0/applications'; method = 'GET' } -ItemCount 1 -Items @(@{ id = 'app-1' })
            $artifact = Write-CollectorSnapshotArtifact -RunPath $Context.RunPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchNumber 1 -Snapshot $snapshot

            $checkpoint = Get-CollectorCheckpoint -RunPath $Context.RunPath -RunId $Context.RunId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifact.artifactPath -Error $null
            Save-CollectorCheckpoint -RunPath $Context.RunPath -Checkpoint $checkpoint | Out-Null

            return @(
                [pscustomobject]@{
                    stage = 'stage1'
                    section = 'entra-apps'
                    family = 'applications'
                    batchCount = 1
                    succeededBatches = 1
                    failedBatches = 0
                    skippedBatches = 0
                    itemCount = 1
                    errors = @()
                }
            )
        }

        $result = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps')

        if (-not (Test-Path -Path $result.manifestPath)) {
            throw ('Expected manifest path to exist: ' + [string]$result.manifestPath)
        }

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $result.runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        if (-not (Test-Path -Path $checkpointPath)) {
            throw ('Expected checkpoint path to exist: ' + [string]$checkpointPath)
        }

        $checkpointDocument = Get-Content -Path $checkpointPath -Raw | ConvertFrom-Json
        if (@($checkpointDocument.batches).Count -ne 1) {
            throw ('Expected 1 checkpoint batch but found ' + @($checkpointDocument.batches).Count + '.')
        }

        $snapshotPath = [string]$checkpointDocument.batches[0].artifactPath
        if ([string]::IsNullOrWhiteSpace($snapshotPath)) {
            throw 'Expected checkpoint batch artifactPath to be populated.'
        }

        if (-not (Test-Path -Path $snapshotPath)) {
            throw ('Expected snapshot path to exist: ' + $snapshotPath)
        }

        $summaryMatches = @($result.checkpointSummary | Where-Object {
            $_.stage -eq 'stage1' -and $_.section -eq 'entra-apps' -and $_.family -eq 'applications'
        })
        if ($summaryMatches.Count -ne 1) {
            throw ('Expected 1 checkpoint summary match but found ' + $summaryMatches.Count + '.')
        }
    }
}
