[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester mock scriptblocks intentionally mirror production stage command signatures.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
}

Describe 'Checkpoint summary review regressions' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-review-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'clears a stale prior checkpoint summary when a resumed refresh cannot validate current checkpoint state' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )
            return @()
        }

        $initial = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')
        $manifest = Get-Content -LiteralPath $initial.manifestPath -Raw | ConvertFrom-Json
        $manifest.checkpointSummary = @(
            [pscustomobject]@{
                stage = 'stage1'
                section = 'onprem-ad-gpo'
                family = 'domains'
                batchCount = 1
                succeededBatches = 1
                failedBatches = 0
                missingBatches = 0
                inProgressBatches = 0
                itemCount = 99
            }
        )
        $manifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $initial.manifestPath -Encoding UTF8

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $initial.runPath -Stage 'stage1' -Section 'onprem-ad-gpo' -Family 'domains'
        New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $checkpointPath -Value '{malformed-json' -Encoding UTF8

        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo') -Resume | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected invalid persisted checkpoint state to fail the resumed invocation.'
        }

        $failedManifest = Get-Content -LiteralPath $initial.manifestPath -Raw | ConvertFrom-Json
        if ([string]$failedManifest.status -ne 'Failed') {
            throw ('Expected resumed manifest status Failed; actual: {0}.' -f $failedManifest.status)
        }
        if (@($failedManifest.checkpointSummary).Count -ne 0) {
            throw 'Expected stale checkpointSummary entries to be cleared when current checkpoint state cannot be validated.'
        }
    }

    It 'does not append a completed partial stage result again when final summary generation fails' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $stageResult = [pscustomobject]@{
                stage = 'stage2'
                section = 'onprem-ad-gpo'
                family = 'domains'
                batchCount = 1
                succeededBatches = 1
                failedBatches = 0
                skippedBatches = 0
                itemCount = 1
                errors = @()
            }
            $Context.PartialStageResults.Add($stageResult) | Out-Null

            $checkpointPath = Get-CollectorCheckpointPath -RunPath $Context.RunPath -Stage 'stage2' -Section 'onprem-ad-gpo' -Family 'domains'
            New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $checkpointPath -Value '{malformed-json' -Encoding UTF8

            return @($stageResult)
        }

        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage2') -Sections @('onprem-ad-gpo') | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected malformed checkpoint state to fail final summary generation.'
        }

        $runDirectory = Get-ChildItem -LiteralPath $script:testRoot -Directory | Select-Object -First 1
        $manifestPath = Join-Path -Path $runDirectory.FullName -ChildPath 'manifest/run-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $latestInvocation = @($manifest.invocations)[-1]

        if (@($manifest.stageResults).Count -ne 1) {
            throw ('Expected one persisted manifest stage result; found {0}.' -f @($manifest.stageResults).Count)
        }
        if (@($latestInvocation.stageResults).Count -ne 1) {
            throw ('Expected one persisted invocation stage result; found {0}.' -f @($latestInvocation.stageResults).Count)
        }
        if ([string]$manifest.stageResults[0].stage -ne 'stage2' -or [string]$manifest.stageResults[0].family -ne 'domains') {
            throw 'Expected the single persisted stage result to remain the completed Stage2 result.'
        }
    }
}
