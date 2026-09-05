$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop

Describe 'Graph token section dependency' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-token-dependency-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            @()
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'allows an on-prem-only run without GraphToken and records that no token was supplied' {
        $result = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')

        if ($result.status -ne 'Completed') {
            throw ('Expected on-prem-only run to complete; actual ' + [string]$result.status + '.')
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 1 -Exactly -Scope It -ParameterFilter {
            @($Sections) -join ',' -eq 'onprem-ad-gpo'
        }

        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw | ConvertFrom-Json
        if ([bool]$manifest.parameters.graphTokenSupplied) {
            throw 'Expected on-prem-only manifest to record graphTokenSupplied=false.'
        }
        if (@($manifest.parameters.sections) -join ',' -ne 'onprem-ad-gpo') {
            throw 'Expected manifest to preserve the on-prem-only section selection.'
        }
    }

    It 'rejects a Graph-backed section without GraphToken before stage execution' {
        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'GraphToken is required') {
                throw
            }
        }

        if (-not $threw) {
            throw 'Expected Graph-backed execution without a token to fail.'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 0 -Exactly -Scope It
    }

    It 'rejects mixed on-prem and Graph selection without GraphToken' {
        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo', 'intune-core') | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'GraphToken is required') {
                throw
            }
        }

        if (-not $threw) {
            throw 'Expected mixed Graph/on-prem execution without a token to fail.'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 0 -Exactly -Scope It
    }

    It 'preserves Graph-backed execution when a token is supplied' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-pim')

        if ($result.status -ne 'Completed') {
            throw ('Expected Graph-backed run with token to complete; actual ' + [string]$result.status + '.')
        }
        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw | ConvertFrom-Json
        if (-not [bool]$manifest.parameters.graphTokenSupplied) {
            throw 'Expected Graph-backed manifest to record graphTokenSupplied=true.'
        }
    }
}
