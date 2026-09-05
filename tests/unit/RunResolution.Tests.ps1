BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Resume run target validation' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-run-resolution-test-' + [Guid]::NewGuid().ToString('N'))

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith { @() }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith { @() }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'does not create a missing OutputRoot when resume has nothing to select' {
        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo') -Resume | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'no prior run artifacts') {
                throw ('Expected no-prior-run rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected resume without an existing OutputRoot to fail.'
        }
        if (Test-Path -LiteralPath $script:testRoot) {
            throw 'Resume must not create OutputRoot when no prior run exists.'
        }
    }

    It 'does not mutate an unrelated directory when no valid prior run exists' {
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $unrelatedPath = Join-Path -Path $script:testRoot -ChildPath 'unrelated'
        New-Item -Path $unrelatedPath -ItemType Directory -Force | Out-Null
        'sentinel' | Set-Content -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'keep.txt') -Encoding UTF8

        $threw = $false
        try {
            Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo') -Resume | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected resume with only an unrelated directory to fail.'
        }
        if (Test-Path -LiteralPath (Join-Path -Path $script:testRoot -ChildPath 'current-run.json')) {
            throw 'Failed resume must not create current-run.json.'
        }
        if (Test-Path -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'manifest')) {
            throw 'Failed resume must not create a manifest directory inside an unrelated directory.'
        }
        if (Test-Path -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'checkpoints')) {
            throw 'Failed resume must not create a checkpoints directory inside an unrelated directory.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'keep.txt'))) {
            throw 'Expected unrelated directory contents to remain intact.'
        }
    }

    It 'ignores an invalid marker target and newer unrelated directory when a valid prior run exists' {
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $first = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')

        $unrelatedPath = Join-Path -Path $script:testRoot -ChildPath 'unrelated'
        New-Item -Path $unrelatedPath -ItemType Directory -Force | Out-Null
        'sentinel' | Set-Content -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'keep.txt') -Encoding UTF8

        [pscustomobject]@{ runId = 'unrelated'; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') } |
            ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path -Path $script:testRoot -ChildPath 'current-run.json') -Encoding UTF8

        $resumed = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume

        if ([string]$resumed.runId -ne [string]$first.runId) {
            throw ('Expected fallback to valid prior run {0}; actual {1}.' -f $first.runId, $resumed.runId)
        }
        if (Test-Path -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'manifest')) {
            throw 'Resume fallback must not initialize manifest state inside the unrelated directory.'
        }
        if (Test-Path -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'checkpoints')) {
            throw 'Resume fallback must not initialize checkpoint state inside the unrelated directory.'
        }

        $marker = Get-Content -LiteralPath (Join-Path -Path $script:testRoot -ChildPath 'current-run.json') -Raw | ConvertFrom-Json
        if ([string]$marker.runId -ne [string]$first.runId) {
            throw 'Expected current-run.json to be repaired to the selected valid prior run.'
        }
    }

    It 'skips a readable manifest that has no runId property' {
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $first = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')

        $unrelatedPath = Join-Path -Path $script:testRoot -ChildPath 'unrelated'
        $unrelatedManifestPath = Join-Path -Path $unrelatedPath -ChildPath 'manifest\run-manifest.json'
        New-Item -Path (Split-Path -Path $unrelatedManifestPath -Parent) -ItemType Directory -Force | Out-Null
        '{}' | Set-Content -LiteralPath $unrelatedManifestPath -Encoding UTF8

        [pscustomobject]@{ runId = 'unrelated'; updatedUtc = (Get-Date).ToUniversalTime().ToString('o') } |
            ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path -Path $script:testRoot -ChildPath 'current-run.json') -Encoding UTF8

        $resumed = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume

        if ([string]$resumed.runId -ne [string]$first.runId) {
            throw 'Expected readable manifest without runId to be rejected while fallback selects the valid run.'
        }
        if (Test-Path -LiteralPath (Join-Path -Path $unrelatedPath -ChildPath 'checkpoints')) {
            throw 'Invalid readable manifest candidate must not receive checkpoint state.'
        }
        $unrelatedManifest = Get-Content -LiteralPath $unrelatedManifestPath -Raw | ConvertFrom-Json
        if ($unrelatedManifest.PSObject.Properties.Match('runId').Count -ne 0) {
            throw 'Invalid readable manifest must remain untouched.'
        }
    }
}
