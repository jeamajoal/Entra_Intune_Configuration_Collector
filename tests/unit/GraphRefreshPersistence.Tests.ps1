BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Refreshable Graph authentication persistence boundary' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-graph-auth-persistence-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts provider-only Graph execution and persists only non-secret authentication facts' {
        $secretSentinel = 'manifest-secret-token-must-not-appear'
        $provider = {
            param([bool]$ForceRefresh)
            $null = $ForceRefresh
            'manifest-secret-token-must-not-appear'
        }

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            return @()
        }

        $result = Start-CollectorRun -GraphTokenProvider $provider -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps')
        $manifestRaw = Get-Content -LiteralPath $result.manifestPath -Raw
        $manifest = $manifestRaw | ConvertFrom-Json

        if ([bool]$manifest.parameters.graphTokenSupplied) {
            throw 'Expected provider-only run to persist graphTokenSupplied=false.'
        }
        if (-not [bool]$manifest.parameters.graphTokenProviderSupplied) {
            throw 'Expected provider-only run to persist graphTokenProviderSupplied=true.'
        }
        if ($manifestRaw -match [regex]::Escape($secretSentinel)) {
            throw 'Run manifest persisted Graph token/provider secret material.'
        }
        if ($manifestRaw -match 'Collector.GraphAuthState') {
            throw 'Run manifest persisted the live Graph authentication-state type.'
        }
        if ($result.status -ne 'Completed') {
            throw ('Expected provider-only mocked run to complete; actual: {0}' -f $result.status)
        }
    }
}
