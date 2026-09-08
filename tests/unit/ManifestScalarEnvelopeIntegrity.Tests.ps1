BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop

    function Invoke-TestManifestSeed {
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
}

Describe 'Persisted manifest scalar envelope integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-manifest-scalar-' + [Guid]::NewGuid().ToString('N'))

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith { @() }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith { @() }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'preserves valid current resume and intentional legacy 1.0 history migration across persisted timestamp materialization' {
        $currentRoot = Join-Path -Path $script:testRoot -ChildPath 'current'
        $current = Invoke-TestManifestSeed -OutputRoot $currentRoot
        $currentResumed = Start-CollectorRun -OutputRoot $currentRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
        $currentManifest = Get-Content -LiteralPath $currentResumed.manifestPath -Raw | ConvertFrom-Json

        if ([string]$currentResumed.runId -ne [string]$current.runId -or @($currentManifest.invocations).Count -ne 2) {
            throw 'Expected valid schema 1.1 persisted manifest to remain resumable with cumulative invocation history.'
        }

        $legacyRoot = Join-Path -Path $script:testRoot -ChildPath 'legacy'
        $legacy = Invoke-TestManifestSeed -OutputRoot $legacyRoot
        $legacyManifest = Get-Content -LiteralPath $legacy.manifestPath -Raw | ConvertFrom-Json
        $legacyManifest.schemaVersion = '1.0'
        $legacyManifest.PSObject.Properties.Remove('invocations')
        Write-TestManifestDocument -ManifestPath $legacy.manifestPath -Manifest $legacyManifest

        $legacyResumed = Start-CollectorRun -OutputRoot $legacyRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
        $upgraded = Get-Content -LiteralPath $legacyResumed.manifestPath -Raw | ConvertFrom-Json

        if ([string]$legacyResumed.runId -ne [string]$legacy.runId) {
            throw 'Expected valid schema 1.0 persisted manifest to retain the same run identity after resume.'
        }
        if ([string]$upgraded.schemaVersion -ne '1.1' -or @($upgraded.invocations).Count -ne 2) {
            throw 'Expected valid schema 1.0 persisted manifest to migrate to schema 1.1 with historical plus resumed invocations.'
        }
    }

    It 'rejects malformed top-level scalar envelopes for both current and legacy manifests without rewriting durable evidence' {
        $invalidCases = @(
            [pscustomobject]@{ property = 'startedUtc'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'startedUtc'; label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ property = 'startedUtc'; label = 'array'; omit = $false; value = [object[]]@('2026-09-08T00:00:00.0000000Z') },
            [pscustomobject]@{ property = 'startedUtc'; label = 'object'; omit = $false; value = ([pscustomobject]@{ value = '2026-09-08T00:00:00.0000000Z' }) },
            [pscustomobject]@{ property = 'startedUtc'; label = 'number'; omit = $false; value = 1 },
            [pscustomobject]@{ property = 'startedUtc'; label = 'boolean'; omit = $false; value = $true },
            [pscustomobject]@{ property = 'completedUtc'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'completedUtc'; label = 'array'; omit = $false; value = [object[]]@('2026-09-08T00:01:00.0000000Z') },
            [pscustomobject]@{ property = 'completedUtc'; label = 'object'; omit = $false; value = ([pscustomobject]@{ value = '2026-09-08T00:01:00.0000000Z' }) },
            [pscustomobject]@{ property = 'completedUtc'; label = 'number'; omit = $false; value = 1 },
            [pscustomobject]@{ property = 'completedUtc'; label = 'boolean'; omit = $false; value = $false },
            [pscustomobject]@{ property = 'status'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'status'; label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ property = 'status'; label = 'array'; omit = $false; value = [object[]]@('Completed') },
            [pscustomobject]@{ property = 'status'; label = 'object'; omit = $false; value = ([pscustomobject]@{ value = 'Completed' }) },
            [pscustomobject]@{ property = 'status'; label = 'number'; omit = $false; value = 1 },
            [pscustomobject]@{ property = 'status'; label = 'boolean'; omit = $false; value = $true },
            [pscustomobject]@{ property = 'status'; label = 'unsupported'; omit = $false; value = 'Succeeded' },
            [pscustomobject]@{ property = 'parameters'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'parameters'; label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ property = 'parameters'; label = 'array'; omit = $false; value = [object[]]@([pscustomobject]@{ sections = @('onprem-ad-gpo') }) },
            [pscustomobject]@{ property = 'parameters'; label = 'string'; omit = $false; value = 'bad' },
            [pscustomobject]@{ property = 'parameters'; label = 'number'; omit = $false; value = 1 },
            [pscustomobject]@{ property = 'parameters'; label = 'boolean'; omit = $false; value = $true }
        )

        foreach ($schemaVersion in @('1.0', '1.1')) {
            foreach ($invalidCase in $invalidCases) {
                $caseRoot = Join-Path -Path $script:testRoot -ChildPath ('top-' + $schemaVersion.Replace('.', '-') + '-' + $invalidCase.property + '-' + $invalidCase.label)
                $run = Invoke-TestManifestSeed -OutputRoot $caseRoot
                $manifest = Get-Content -LiteralPath $run.manifestPath -Raw | ConvertFrom-Json
                $manifest.schemaVersion = $schemaVersion
                if ($schemaVersion -eq '1.0') {
                    $manifest.PSObject.Properties.Remove('invocations')
                }

                if ($invalidCase.omit) {
                    $manifest.PSObject.Properties.Remove($invalidCase.property)
                }
                else {
                    $manifest.($invalidCase.property) = $invalidCase.value
                }

                Write-TestManifestDocument -ManifestPath $run.manifestPath -Manifest $manifest
                $before = Get-Content -LiteralPath $run.manifestPath -Raw

                $threw = $false
                try {
                    Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume | Out-Null
                }
                catch {
                    $threw = $true
                }

                if (-not $threw) {
                    throw ('Expected schema {0} top-level property [{1}] invalid [{2}] envelope to make the run ineligible for resume.' -f $schemaVersion, $invalidCase.property, $invalidCase.label)
                }

                $after = Get-Content -LiteralPath $run.manifestPath -Raw
                if ($after -ne $before) {
                    throw ('Expected rejected schema {0} top-level property [{1}] invalid [{2}] envelope to remain byte-for-byte unchanged.' -f $schemaVersion, $invalidCase.property, $invalidCase.label)
                }
            }
        }
    }

    It 'rejects malformed existing invocation scalar envelopes without appending or rewriting history' {
        $invalidCases = @(
            [pscustomobject]@{ property = 'startedUtc'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'startedUtc'; label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ property = 'startedUtc'; label = 'array'; omit = $false; value = [object[]]@('2026-09-08T00:00:00.0000000Z') },
            [pscustomobject]@{ property = 'startedUtc'; label = 'object'; omit = $false; value = ([pscustomobject]@{ value = '2026-09-08T00:00:00.0000000Z' }) },
            [pscustomobject]@{ property = 'completedUtc'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'completedUtc'; label = 'array'; omit = $false; value = [object[]]@('2026-09-08T00:01:00.0000000Z') },
            [pscustomobject]@{ property = 'completedUtc'; label = 'object'; omit = $false; value = ([pscustomobject]@{ value = '2026-09-08T00:01:00.0000000Z' }) },
            [pscustomobject]@{ property = 'status'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'status'; label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ property = 'status'; label = 'array'; omit = $false; value = [object[]]@('Completed') },
            [pscustomobject]@{ property = 'status'; label = 'unsupported'; omit = $false; value = 'Succeeded' },
            [pscustomobject]@{ property = 'parameters'; label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ property = 'parameters'; label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ property = 'parameters'; label = 'array'; omit = $false; value = [object[]]@([pscustomobject]@{ sections = @('onprem-ad-gpo') }) },
            [pscustomobject]@{ property = 'parameters'; label = 'string'; omit = $false; value = 'bad' }
        )

        foreach ($invalidCase in $invalidCases) {
            $caseRoot = Join-Path -Path $script:testRoot -ChildPath ('nested-' + $invalidCase.property + '-' + $invalidCase.label)
            $run = Invoke-TestManifestSeed -OutputRoot $caseRoot
            $manifest = Get-Content -LiteralPath $run.manifestPath -Raw | ConvertFrom-Json
            $invocation = @($manifest.invocations)[0]

            if ($invalidCase.omit) {
                $invocation.PSObject.Properties.Remove($invalidCase.property)
            }
            else {
                $invocation.($invalidCase.property) = $invalidCase.value
            }

            Write-TestManifestDocument -ManifestPath $run.manifestPath -Manifest $manifest
            $before = Get-Content -LiteralPath $run.manifestPath -Raw

            $threw = $false
            try {
                Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume | Out-Null
            }
            catch {
                $threw = $true
            }

            if (-not $threw) {
                throw ('Expected existing invocation property [{0}] invalid [{1}] envelope to make the run ineligible for resume.' -f $invalidCase.property, $invalidCase.label)
            }

            $after = Get-Content -LiteralPath $run.manifestPath -Raw
            if ($after -ne $before) {
                throw ('Expected rejected existing invocation property [{0}] invalid [{1}] envelope to remain byte-for-byte unchanged.' -f $invalidCase.property, $invalidCase.label)
            }
        }
    }
}
