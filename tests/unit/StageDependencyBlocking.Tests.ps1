[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester mock scriptblocks mirror production command signatures while individual scenarios inspect only relevant parameters.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop

    function Get-TestStageResult {
        param(
            [Parameter(Mandatory = $true)][string]$Stage,
            [Parameter(Mandatory = $true)][string]$Section,
            [Parameter(Mandatory = $true)][string]$Family,
            [int]$FailedBatches = 0,
            [string[]]$Errors = @()
        )

        return [pscustomobject]@{
            stage = $Stage
            section = $Section
            family = $Family
            batchCount = 1
            succeededBatches = if ($FailedBatches -gt 0) { 0 } else { 1 }
            failedBatches = $FailedBatches
            skippedBatches = 0
            itemCount = if ($FailedBatches -gt 0) { 0 } else { 1 }
            errors = @($Errors)
        }
    }
}

Describe 'Invocation-local dependent stage blocking' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage-blocking-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'preserves the initiating Stage1 failure and does not invoke dependent on-prem stages' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            return @(
                Get-TestStageResult -Stage 'stage1' -Section 'onprem-ad-gpo' -Family 'domains'
                Get-TestStageResult -Stage 'stage1' -Section 'onprem-ad-gpo' -Family 'gpos' -FailedBatches 1 -Errors @('The supplied AD credential could not read the target domain.')
            )
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            throw 'Stage2 inventory-first enforcement failed. This downstream error must not replace the Stage1 provider failure.'
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            throw 'Stage3 must not execute for a section blocked by Stage1.'
        }

        $result = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('All') -Sections @('onprem-ad-gpo')

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 1 -Exactly
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -Times 0 -Exactly
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 0 -Exactly

        if ($result.status -ne 'CompletedWithErrors') {
            throw ('Expected CompletedWithErrors after preserved Stage1 failure; actual: {0}' -f $result.status)
        }
        if (@($result.stageResults).Count -ne 2) {
            throw ('Expected both successful and failed Stage1 family results to remain durable; actual count: {0}' -f @($result.stageResults).Count)
        }
        if (@($result.failures).Count -ne 1 -or [string]$result.failures[0].error -ne 'The supplied AD credential could not read the target domain.') {
            throw 'Expected the original Stage1 provider/authentication error to remain the terminal returned failure evidence.'
        }

        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw | ConvertFrom-Json
        $matchingFailure = @($manifest.failures | Where-Object {
            $_.stage -eq 'stage1' -and $_.section -eq 'onprem-ad-gpo' -and $_.family -eq 'gpos' -and $_.error -eq 'The supplied AD credential could not read the target domain.'
        })
        if ($matchingFailure.Count -ne 1) {
            throw 'Expected the initiating Stage1 failure to remain durable in the manifest.'
        }
    }

    It 'continues independent sections after Stage1 blocks one standard section' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            return @(
                Get-TestStageResult -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -FailedBatches 1 -Errors @('Application inventory provider failure.')
                Get-TestStageResult -Stage 'stage1' -Section 'entra-pim' -Family 'roleAssignmentScheduleInstances'
            )
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            if ((@($Sections) -join ',') -ne 'entra-pim') {
                throw ('Expected only entra-pim to remain runnable in Stage2; actual: {0}' -f (@($Sections) -join ','))
            }
            return @(Get-TestStageResult -Stage 'stage2' -Section 'entra-pim' -Family 'roleAssignmentScheduleInstances')
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            if ((@($Sections) -join ',') -ne 'entra-pim') {
                throw ('Expected only entra-pim to remain runnable in Stage3; actual: {0}' -f (@($Sections) -join ','))
            }
            return @(Get-TestStageResult -Stage 'stage3' -Section 'entra-pim' -Family 'pimRelationshipEdges')
        }

        $result = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('All') -Sections @('entra-apps', 'entra-pim')

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -Times 1 -Exactly -ParameterFilter {
            (@($Sections) -join ',') -eq 'entra-pim'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 1 -Exactly -ParameterFilter {
            (@($Sections) -join ',') -eq 'entra-pim'
        }
        if ($result.status -ne 'CompletedWithErrors') {
            throw ('Expected independent section continuation with retained upstream failure; actual: {0}' -f $result.status)
        }
    }

    It 'blocks only the failed Stage2 section from Stage3' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            return @(
                Get-TestStageResult -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
                Get-TestStageResult -Stage 'stage1' -Section 'entra-pim' -Family 'roleAssignmentScheduleInstances'
            )
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            if ((@($Sections) -join ',') -ne 'entra-apps,entra-pim') {
                throw ('Expected both sections to enter Stage2; actual: {0}' -f (@($Sections) -join ','))
            }
            return @(
                Get-TestStageResult -Stage 'stage2' -Section 'entra-apps' -Family 'applicationDetails' -FailedBatches 1 -Errors @('Application detail provider failure.')
                Get-TestStageResult -Stage 'stage2' -Section 'entra-pim' -Family 'roleAssignmentScheduleInstances'
            )
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            if ((@($Sections) -join ',') -ne 'entra-pim') {
                throw ('Expected Stage2 failure to block only entra-apps from Stage3; actual: {0}' -f (@($Sections) -join ','))
            }
            return @(Get-TestStageResult -Stage 'stage3' -Section 'entra-pim' -Family 'pimRelationshipEdges')
        }

        $result = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('All') -Sections @('entra-apps', 'entra-pim')

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 1 -Exactly -ParameterFilter {
            (@($Sections) -join ',') -eq 'entra-pim'
        }
        if (@($result.failures | Where-Object { $_.stage -eq 'stage2' -and $_.section -eq 'entra-apps' }).Count -ne 1) {
            throw 'Expected the Stage2 failure to remain returned failure evidence while only its section is blocked downstream.'
        }
    }

    It 'retains Stage2-only inventory-first fail-closed behavior' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            throw 'Stage1 must not execute during Stage2-only invocation.'
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            throw 'Stage2 inventory-first enforcement failed. Missing or mismatched Stage1 artifact for section entra-apps, family applications.'
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            throw 'Stage3 must not execute after the Stage2-only inventory-first failure.'
        }

        $threw = $false
        try {
            Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage2') -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Stage2 inventory-first enforcement failed') {
                throw ('Expected the existing Stage2-only fail-closed error; actual: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected Stage2-only invocation against missing prior evidence to fail closed.'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -Times 1 -Exactly
    }
}