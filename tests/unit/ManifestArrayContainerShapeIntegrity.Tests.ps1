BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop

    function New-TestManifestRun {
        param(
            [Parameter(Mandatory = $true)]
            [string]$OutputRoot
        )

        return Start-CollectorRun -OutputRoot $OutputRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')
    }

    function Write-TestManifestDocument {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ManifestPath,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$Manifest
        )

        $Manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    }

    function New-TestInvocationRecord {
        return [pscustomobject]@{
            startedUtc = '2026-09-08T00:00:00.0000000Z'
            completedUtc = '2026-09-08T00:00:01.0000000Z'
            status = 'Completed'
            parameters = [pscustomobject]@{ sections = @('onprem-ad-gpo') }
            stageResults = @()
            failures = @()
        }
    }
}

Describe 'Persisted manifest array container shape integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-manifest-container-' + [Guid]::NewGuid().ToString('N'))

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith { @() }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith { @() }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects present non-array top-level manifest history containers without rewriting the manifest' {
        $invalidValues = @(
            [pscustomobject]@{ label = 'object'; value = ([pscustomobject]@{ bad = $true }) },
            [pscustomobject]@{ label = 'string'; value = 'bad' },
            [pscustomobject]@{ label = 'number'; value = 1 },
            [pscustomobject]@{ label = 'boolean'; value = $true }
        )

        foreach ($propertyName in @('stageResults', 'checkpointSummary', 'failures', 'invocations')) {
            foreach ($invalidValue in $invalidValues) {
                $caseRoot = Join-Path -Path $script:testRoot -ChildPath ($propertyName + '-' + $invalidValue.label)
                $run = New-TestManifestRun -OutputRoot $caseRoot
                $manifestPath = Join-Path -Path $run.runPath -ChildPath 'manifest\run-manifest.json'
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $manifest.$propertyName = $invalidValue.value
                Write-TestManifestDocument -ManifestPath $manifestPath -Manifest $manifest
                $before = Get-Content -LiteralPath $manifestPath -Raw

                $threw = $false
                try {
                    Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume | Out-Null
                }
                catch {
                    $threw = $true
                }

                if (-not $threw) {
                    throw ('Expected top-level manifest property [{0}] invalid [{1}] container to make the run ineligible for resume.' -f $propertyName, $invalidValue.label)
                }

                $after = Get-Content -LiteralPath $manifestPath -Raw
                if ($after -ne $before) {
                    throw ('Expected rejected top-level manifest property [{0}] invalid [{1}] container to remain byte-for-byte unchanged.' -f $propertyName, $invalidValue.label)
                }
            }
        }
    }

    It 'accepts valid array cardinalities and preserves intentional missing or null top-level legacy migration' {
        foreach ($count in @(0, 1, 2)) {
            $caseRoot = Join-Path -Path $script:testRoot -ChildPath ('valid-' + $count)
            $run = New-TestManifestRun -OutputRoot $caseRoot
            $manifestPath = Join-Path -Path $run.runPath -ChildPath 'manifest\run-manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

            $genericEntries = @()
            $failureEntries = @()
            $invocationEntries = @()
            for ($index = 0; $index -lt $count; $index++) {
                $genericEntries += [pscustomobject]@{ id = ('entry-{0}' -f $index) }
                $failureEntries += [pscustomobject]@{ stage = 'Stage1'; section = 'onprem-ad-gpo'; family = 'test'; error = ('error-{0}' -f $index) }
                $invocationEntries += New-TestInvocationRecord
            }

            $manifest.stageResults = [object[]]@($genericEntries)
            $manifest.checkpointSummary = [object[]]@($genericEntries)
            $manifest.failures = [object[]]@($failureEntries)
            $manifest.invocations = [object[]]@($invocationEntries)
            Write-TestManifestDocument -ManifestPath $manifestPath -Manifest $manifest

            $resumed = Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
            if ([string]$resumed.runId -ne [string]$run.runId) {
                throw ('Expected valid array cardinality [{0}] manifest to remain resumable.' -f $count)
            }
        }

        foreach ($propertyName in @('stageResults', 'checkpointSummary', 'failures', 'invocations')) {
            foreach ($legacyState in @('missing', 'null')) {
                $caseRoot = Join-Path -Path $script:testRoot -ChildPath ('legacy-' + $propertyName + '-' + $legacyState)
                $run = New-TestManifestRun -OutputRoot $caseRoot
                $manifestPath = Join-Path -Path $run.runPath -ChildPath 'manifest\run-manifest.json'
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

                if ($legacyState -eq 'missing') {
                    $manifest.PSObject.Properties.Remove($propertyName)
                }
                else {
                    $manifest.$propertyName = $null
                }
                Write-TestManifestDocument -ManifestPath $manifestPath -Manifest $manifest

                $resumed = Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
                if ([string]$resumed.runId -ne [string]$run.runId) {
                    throw ('Expected legacy top-level manifest property [{0}] state [{1}] to remain resumable.' -f $propertyName, $legacyState)
                }

                $persisted = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                if ($persisted.PSObject.Properties.Match($propertyName).Count -eq 0 -or -not ($persisted.$propertyName -is [System.Array])) {
                    throw ('Expected legacy top-level manifest property [{0}] state [{1}] to migrate back to an array.' -f $propertyName, $legacyState)
                }
            }
        }
    }

    It 'rejects malformed nested invocation history arrays before adding or persisting another invocation' {
        $nestedCases = @(
            [pscustomobject]@{ label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ label = 'object'; omit = $false; value = ([pscustomobject]@{ bad = $true }) },
            [pscustomobject]@{ label = 'string'; omit = $false; value = 'bad' },
            [pscustomobject]@{ label = 'number'; omit = $false; value = 1 },
            [pscustomobject]@{ label = 'boolean'; omit = $false; value = $true }
        )

        foreach ($propertyName in @('stageResults', 'failures')) {
            foreach ($nestedCase in $nestedCases) {
                $caseRoot = Join-Path -Path $script:testRoot -ChildPath ('nested-' + $propertyName + '-' + $nestedCase.label)
                $run = New-TestManifestRun -OutputRoot $caseRoot
                $manifestPath = Join-Path -Path $run.runPath -ChildPath 'manifest\run-manifest.json'
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $invocation = @($manifest.invocations)[0]

                if ($nestedCase.omit) {
                    $invocation.PSObject.Properties.Remove($propertyName)
                }
                else {
                    $invocation.$propertyName = $nestedCase.value
                }
                Write-TestManifestDocument -ManifestPath $manifestPath -Manifest $manifest
                $before = Get-Content -LiteralPath $manifestPath -Raw

                $threw = $false
                try {
                    Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume | Out-Null
                }
                catch {
                    $threw = $true
                }

                if (-not $threw) {
                    throw ('Expected nested invocation property [{0}] invalid [{1}] container to make the run ineligible for resume.' -f $propertyName, $nestedCase.label)
                }

                $after = Get-Content -LiteralPath $manifestPath -Raw
                if ($after -ne $before) {
                    throw ('Expected rejected nested invocation property [{0}] invalid [{1}] container to remain byte-for-byte unchanged.' -f $propertyName, $nestedCase.label)
                }
            }
        }
    }
}
