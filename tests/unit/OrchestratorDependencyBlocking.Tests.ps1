[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester mock scriptblocks mirror production stage signatures even when a scenario does not inspect every bound parameter.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Collector orchestrator dependency blocking' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-dependency-blocking-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'keeps the original Stage1 provider failure primary and continues independent sections' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $sectionKey = @($Sections) -join ','
            switch ($sectionKey) {
                'entra-apps' {
                    return @([pscustomobject]@{
                        stage = 'stage1'; section = 'entra-apps'; family = 'applications'; batchCount = 1
                        succeededBatches = 1; failedBatches = 0; skippedBatches = 0; itemCount = 1; errors = @()
                    })
                }
                'onprem-ad-gpo' {
                    return @([pscustomobject]@{
                        stage = 'stage1'; section = 'onprem-ad-gpo'; family = 'domains'; batchCount = 1
                        succeededBatches = 0; failedBatches = 1; skippedBatches = 0; itemCount = 0
                        errors = @('simulated Stage1 AD provider failure')
                    })
                }
                default { throw ('Unexpected Stage1 section set: {0}' -f $sectionKey) }
            }
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $sectionKey = @($Sections) -join ','
            if ($sectionKey -ne 'entra-apps') {
                throw ('Blocked Stage2 section was invoked: {0}' -f $sectionKey)
            }
            return @([pscustomobject]@{
                stage = 'stage2'; section = 'entra-apps'; family = 'applications'; batchCount = 1
                succeededBatches = 1; failedBatches = 0; skippedBatches = 0; itemCount = 1; errors = @()
            })
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            $sectionKey = @($Sections) -join ','
            if ($sectionKey -ne 'entra-apps') {
                throw ('Blocked Stage3 section was invoked: {0}' -f $sectionKey)
            }
            return @([pscustomobject]@{
                stage = 'stage3'; section = 'entra-apps'; family = 'groupMembers'; batchCount = 1
                succeededBatches = 1; failedBatches = 0; skippedBatches = 0; itemCount = 1; errors = @()
            })
        }

        $result = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('All') -Sections @('entra-apps', 'onprem-ad-gpo')

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 1 -Exactly -ParameterFilter { @($Sections) -join ',' -eq 'onprem-ad-gpo' }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -Times 0 -Exactly -ParameterFilter { @($Sections) -contains 'onprem-ad-gpo' }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 0 -Exactly -ParameterFilter { @($Sections) -contains 'onprem-ad-gpo' }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -Times 1 -Exactly -ParameterFilter { @($Sections) -join ',' -eq 'entra-apps' }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 1 -Exactly -ParameterFilter { @($Sections) -join ',' -eq 'entra-apps' }

        if ([string]$result.status -ne 'CompletedWithErrors') {
            throw ('Expected CompletedWithErrors after durable Stage1 provider failure; actual {0}.' -f [string]$result.status)
        }
        if (@($result.failures).Count -ne 1 -or [string]$result.failures[0].error -ne 'simulated Stage1 AD provider failure') {
            throw 'Expected the original Stage1 provider failure to remain the only returned failure.'
        }
        if ([string]$result.failures[0].stage -ne 'stage1' -or [string]$result.failures[0].section -ne 'onprem-ad-gpo' -or [string]$result.failures[0].family -ne 'domains') {
            throw 'Expected the returned failure to retain Stage1/onprem-ad-gpo/domains attribution.'
        }

        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw | ConvertFrom-Json
        $latestInvocation = @($manifest.invocations)[-1]
        if ([string]$latestInvocation.status -ne 'CompletedWithErrors') {
            throw ('Expected durable invocation status CompletedWithErrors; actual {0}.' -f [string]$latestInvocation.status)
        }
        if (@($latestInvocation.failures).Count -ne 1 -or [string]$latestInvocation.failures[0].error -ne 'simulated Stage1 AD provider failure') {
            throw 'Expected manifest invocation to preserve the original Stage1 provider failure without a downstream inventory-first replacement.'
        }
    }

    It 'blocks a Stage2-failed section from Stage3 while another standard section continues' {
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            if ((@($Sections) -join ',') -ne 'entra-apps,entra-pim') {
                throw ('Unexpected Stage1 section set: {0}' -f (@($Sections) -join ','))
            }
            return @(
                [pscustomobject]@{
                    stage = 'stage1'; section = 'entra-apps'; family = 'applications'; batchCount = 1
                    succeededBatches = 1; failedBatches = 0; skippedBatches = 0; itemCount = 1; errors = @()
                },
                [pscustomobject]@{
                    stage = 'stage1'; section = 'entra-pim'; family = 'roleDefinitions'; batchCount = 1
                    succeededBatches = 1; failedBatches = 0; skippedBatches = 0; itemCount = 1; errors = @()
                }
            )
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            if ((@($Sections) -join ',') -ne 'entra-apps,entra-pim') {
                throw ('Unexpected Stage2 section set: {0}' -f (@($Sections) -join ','))
            }
            return @(
                [pscustomobject]@{
                    stage = 'stage2'; section = 'entra-apps'; family = 'applications'; batchCount = 1
                    succeededBatches = 0; failedBatches = 1; skippedBatches = 0; itemCount = 0
                    errors = @('simulated Stage2 application detail failure')
                },
                [pscustomobject]@{
                    stage = 'stage2'; section = 'entra-pim'; family = 'roleDefinitions'; batchCount = 1
                    succeededBatches = 1; failedBatches = 0; skippedBatches = 0; itemCount = 1; errors = @()
                }
            )
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            param(
                [hashtable]$Context,
                [string[]]$Sections
            )

            if ((@($Sections) -join ',') -ne 'entra-pim') {
                throw ('Expected only entra-pim to remain eligible for Stage3; actual {0}.' -f (@($Sections) -join ','))
            }
            return @([pscustomobject]@{
                stage = 'stage3'; section = 'entra-pim'; family = 'roleAssignmentEdges'; batchCount = 1
                succeededBatches = 1; failedBatches = 0; skippedBatches = 0; itemCount = 1; errors = @()
            })
        }

        $result = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('All') -Sections @('entra-apps', 'entra-pim')

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 1 -Exactly -ParameterFilter { @($Sections) -join ',' -eq 'entra-pim' }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 0 -Exactly -ParameterFilter { @($Sections) -contains 'entra-apps' }

        if ([string]$result.status -ne 'CompletedWithErrors') {
            throw ('Expected CompletedWithErrors after Stage2 failure; actual {0}.' -f [string]$result.status)
        }
        if (@($result.failures).Count -ne 1 -or [string]$result.failures[0].error -ne 'simulated Stage2 application detail failure') {
            throw 'Expected the original Stage2 failure to remain the only returned failure.'
        }
    }
}
