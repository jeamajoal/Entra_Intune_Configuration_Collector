[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester mock scriptblocks intentionally mirror production stage command signatures.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
}

Describe 'Checkpoint summary identity integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-summary-test-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'run-summary'
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'summarizes a valid checkpoint using canonical path identity' {
        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null

        $checkpoint = [pscustomobject]@{
            schemaVersion = '1.0'
            runId = 'run-summary'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            plan = $null
            batches = @(
                [pscustomobject]@{ batchId = '0001'; status = 'Succeeded'; attempts = 1; itemCount = 3; successCount = 3; failedCount = 0; artifactPath = $null; error = $null },
                [pscustomobject]@{ batchId = '0002'; status = 'Failed'; attempts = 1; itemCount = 2; successCount = 1; failedCount = 1; artifactPath = $null; error = 'failure' }
            )
        }
        $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        $summary = @(Get-CollectorCheckpointSummary -RunPath $script:runPath)
        if ($summary.Count -ne 1) {
            throw ('Expected one checkpoint summary row; found {0}.' -f $summary.Count)
        }
        if ($summary[0].stage -ne 'stage1' -or $summary[0].section -ne 'entra-apps' -or $summary[0].family -ne 'applications') {
            throw 'Expected checkpoint summary identity to match the canonical checkpoint path.'
        }
        if ($summary[0].batchCount -ne 2 -or $summary[0].succeededBatches -ne 1 -or $summary[0].failedBatches -ne 1 -or $summary[0].itemCount -ne 5) {
            throw 'Expected checkpoint summary counts to preserve valid existing behavior.'
        }
    }

    It 'rejects persisted checkpoint identity that conflicts with its canonical summary path' {
        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null

        $mismatches = @(
            [pscustomobject]@{ Property = 'runId'; Value = 'other-run' },
            [pscustomobject]@{ Property = 'stage'; Value = 'stage2' },
            [pscustomobject]@{ Property = 'section'; Value = 'intune-core' },
            [pscustomobject]@{ Property = 'family'; Value = 'groups' }
        )

        foreach ($mismatch in $mismatches) {
            $checkpoint = [pscustomobject]@{
                schemaVersion = '1.0'
                runId = 'run-summary'
                stage = 'stage1'
                section = 'entra-apps'
                family = 'applications'
                updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                plan = $null
                batches = @()
            }
            $checkpoint.($mismatch.Property) = $mismatch.Value
            $checkpoint | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

            $threw = $false
            try {
                Get-CollectorCheckpointSummary -RunPath $script:runPath | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'Checkpoint identity mismatch' -or $_.Exception.Message -notmatch $mismatch.Property) {
                    throw ('Expected summary identity rejection for {0}; actual error: {1}' -f $mismatch.Property, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected checkpoint summary to reject mismatched {0}.' -f $mismatch.Property)
            }
        }
    }
}

Describe 'Collector terminal state when checkpoint summary fails' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-summary-terminal-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'persists Failed terminal state when final checkpoint summary JSON is malformed' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $checkpointPath = Get-CollectorCheckpointPath -RunPath $Context.RunPath -Stage 'stage1' -Section 'onprem-ad-gpo' -Family 'domains'
            New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $checkpointPath -Value '{malformed-json' -Encoding UTF8
            return @()
        }

        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo') | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected malformed final checkpoint summary state to fail the invocation.'
        }

        $runDirectory = Get-ChildItem -LiteralPath $script:testRoot -Directory | Select-Object -First 1
        if (-not $runDirectory) {
            throw 'Expected failed invocation to retain its run directory.'
        }
        $manifestPath = Join-Path -Path $runDirectory.FullName -ChildPath 'manifest/run-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $latestInvocation = @($manifest.invocations)[-1]

        if ([string]$manifest.status -ne 'Failed' -or [string]$latestInvocation.status -ne 'Failed') {
            throw ('Expected terminal Failed status; manifest={0}, invocation={1}.' -f $manifest.status, $latestInvocation.status)
        }
        if ([string]::IsNullOrWhiteSpace([string]$manifest.completedUtc) -or [string]::IsNullOrWhiteSpace([string]$latestInvocation.completedUtc)) {
            throw 'Expected failed manifest and invocation to record completion timestamps.'
        }
        if (@($latestInvocation.failures).Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$latestInvocation.failures[-1].error)) {
            throw 'Expected malformed summary failure evidence to be retained in the invocation manifest.'
        }
        if (@($manifest.checkpointSummary).Count -ne 0) {
            throw 'Malformed checkpoint state must not contribute a checkpoint summary row.'
        }
    }

    It 'does not mask an earlier stage failure when best-effort checkpoint summary refresh also fails' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $checkpointPath = Get-CollectorCheckpointPath -RunPath $Context.RunPath -Stage 'stage1' -Section 'onprem-ad-gpo' -Family 'domains'
            New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $checkpointPath -Value '{malformed-json' -Encoding UTF8
            throw 'original stage failure'
        }

        $caughtMessage = $null
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo') | Out-Null
        }
        catch {
            $caughtMessage = $_.Exception.Message
        }

        if ($caughtMessage -notmatch 'original stage failure') {
            throw ('Expected original stage failure to escape unchanged; actual error: {0}' -f $caughtMessage)
        }

        $runDirectory = Get-ChildItem -LiteralPath $script:testRoot -Directory | Select-Object -First 1
        $manifestPath = Join-Path -Path $runDirectory.FullName -ChildPath 'manifest/run-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $latestInvocation = @($manifest.invocations)[-1]

        if ([string]$manifest.status -ne 'Failed' -or [string]$latestInvocation.status -ne 'Failed') {
            throw 'Expected original stage failure plus summary refresh failure to persist terminal Failed state.'
        }
        if (@($latestInvocation.failures | Where-Object { [string]$_.error -match 'original stage failure' }).Count -lt 1) {
            throw 'Expected original stage failure evidence to remain in the persisted invocation.'
        }
    }
}
