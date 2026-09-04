$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop

Describe 'Run manifest history across resume' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-manifest-history-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            @(
                [pscustomobject]@{
                    stage = 'stage1'
                    section = 'entra-apps'
                    family = 'applications'
                    batchCount = 1
                    succeededBatches = 0
                    failedBatches = 1
                    skippedBatches = 0
                    itemCount = 1
                    errors = @('first invocation failure')
                }
            )
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            @(
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
                }
            )
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'keeps original run evidence and records each resumed invocation separately' {
        $first = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps')
        $firstManifest = Get-Content -LiteralPath $first.manifestPath -Raw | ConvertFrom-Json
        $originalStartedUtc = [string]$firstManifest.startedUtc

        if ([string]$first.status -ne 'CompletedWithErrors') {
            throw ('Expected first invocation status CompletedWithErrors; actual ' + [string]$first.status)
        }
        if (@($firstManifest.invocations).Count -ne 1 -or @($firstManifest.failures).Count -ne 1) {
            throw 'Expected first manifest to contain one invocation and one failure.'
        }

        $second = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('entra-apps') -Resume
        $manifest = Get-Content -LiteralPath $second.manifestPath -Raw | ConvertFrom-Json

        if ([string]$second.runId -ne [string]$first.runId) {
            throw 'Expected resume to reuse the same runId.'
        }
        if ([string]$manifest.startedUtc -ne $originalStartedUtc) {
            throw 'Expected original run startedUtc to remain unchanged after resume.'
        }
        if ([string]$manifest.schemaVersion -ne '1.1') {
            throw ('Expected manifest schemaVersion 1.1; actual ' + [string]$manifest.schemaVersion)
        }
        if (@($manifest.invocations).Count -ne 2) {
            throw ('Expected two invocation records; actual ' + @($manifest.invocations).Count)
        }
        if (@($manifest.stageResults).Count -ne 2) {
            throw ('Expected cumulative stageResults to retain both invocations; actual ' + @($manifest.stageResults).Count)
        }
        if (@($manifest.failures).Count -ne 1 -or [string]@($manifest.failures)[0].error -ne 'first invocation failure') {
            throw 'Expected prior failure evidence to remain in cumulative manifest failures.'
        }

        $firstInvocation = @($manifest.invocations)[0]
        $secondInvocation = @($manifest.invocations)[1]
        if ((@($firstInvocation.parameters.stages) -join ',') -ne 'Stage1' -or [string]$firstInvocation.status -ne 'CompletedWithErrors') {
            throw 'Expected first invocation parameters/status to remain recoverable.'
        }
        if (@($firstInvocation.failures).Count -ne 1) {
            throw 'Expected first invocation failure history to remain recoverable.'
        }
        if ((@($secondInvocation.parameters.stages) -join ',') -ne 'Stage3' -or [string]$secondInvocation.status -ne 'Completed') {
            throw 'Expected second invocation to record current Stage3 parameters and successful status.'
        }
        if (@($secondInvocation.failures).Count -ne 0) {
            throw 'Expected successful resumed invocation to have no invocation-local failures.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$firstInvocation.completedUtc) -or [string]::IsNullOrWhiteSpace([string]$secondInvocation.completedUtc)) {
            throw 'Expected every completed invocation to retain its completion timestamp.'
        }
        if ((@($manifest.parameters.stages) -join ',') -ne 'Stage3' -or -not [bool]$manifest.parameters.resume) {
            throw 'Expected top-level parameters to represent the latest invocation for compatibility.'
        }
        if ([string]$manifest.status -ne 'Completed') {
            throw ('Expected top-level status to represent latest invocation; actual ' + [string]$manifest.status)
        }
        if (@($second.stageResults).Count -ne 1 -or @($second.failures).Count -ne 0) {
            throw 'Expected Start-CollectorRun return data to remain invocation-local after resume.'
        }
    }

    It 'upgrades a legacy manifest into invocation history instead of discarding it' {
        $first = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps')
        $legacy = Get-Content -LiteralPath $first.manifestPath -Raw | ConvertFrom-Json
        $legacy.PSObject.Properties.Remove('invocations')
        $legacy.schemaVersion = '1.0'
        $legacy | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $first.manifestPath -Encoding UTF8

        Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('entra-apps') -Resume | Out-Null
        $upgraded = Get-Content -LiteralPath $first.manifestPath -Raw | ConvertFrom-Json

        if ([string]$upgraded.schemaVersion -ne '1.1' -or @($upgraded.invocations).Count -ne 2) {
            throw 'Expected legacy manifest to upgrade to schema 1.1 with historical plus resumed invocation records.'
        }
        if (@($upgraded.invocations)[0].failures.Count -ne 1 -or [string]@($upgraded.invocations)[0].failures[0].error -ne 'first invocation failure') {
            throw 'Expected legacy failure evidence to be retained in synthesized historical invocation.'
        }
    }
}
