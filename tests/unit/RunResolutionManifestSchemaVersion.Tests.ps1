BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop

    function Write-TestRunManifest {
        param(
            [Parameter(Mandatory = $true)][string]$OutputRoot,
            [Parameter(Mandatory = $true)][string]$RunId,
            [AllowNull()][object]$SchemaVersion,
            [switch]$OmitSchemaVersion
        )

        $runPath = Join-Path -Path $OutputRoot -ChildPath $RunId
        $manifestDirectory = Join-Path -Path $runPath -ChildPath 'manifest'
        New-Item -Path $manifestDirectory -ItemType Directory -Force | Out-Null

        $manifest = [pscustomobject][ordered]@{
            schemaVersion = $SchemaVersion
            runId = $RunId
            startedUtc = '2026-09-07T00:00:00.0000000Z'
            completedUtc = '2026-09-07T00:01:00.0000000Z'
            status = 'Completed'
            parameters = [pscustomobject]@{ sections = @('onprem-ad-gpo') }
            stageResults = @()
            checkpointSummary = @()
            failures = @()
            invocations = @()
        }
        if ($OmitSchemaVersion) {
            $manifest.PSObject.Properties.Remove('schemaVersion')
        }

        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path -Path $manifestDirectory -ChildPath 'run-manifest.json') -Encoding UTF8
        return $runPath
    }

    function Write-TestRunMarker {
        param(
            [Parameter(Mandatory = $true)][string]$OutputRoot,
            [Parameter(Mandatory = $true)][string]$RunId
        )

        [pscustomobject]@{
            runId = $RunId
            updatedUtc = '2026-09-07T00:00:00.0000000Z'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path -Path $OutputRoot -ChildPath 'current-run.json') -Encoding UTF8
    }
}

Describe 'Resume run manifest schema-version selection' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-run-schema-selection-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith { @() }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith { @() }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects invalid-version marker targets and repairs the marker to an older valid run' {
        $validRun = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')
        $invalidCases = @(
            [pscustomobject]@{ Value = 'placeholder'; Omit = $true; Label = 'missing' },
            [pscustomobject]@{ Value = $null; Omit = $false; Label = 'null' },
            [pscustomobject]@{ Value = ''; Omit = $false; Label = 'empty' },
            [pscustomobject]@{ Value = 1.1; Omit = $false; Label = 'numeric' },
            [pscustomobject]@{ Value = ([pscustomobject]@{ value = '1.1' }); Omit = $false; Label = 'object' },
            [pscustomobject]@{ Value = '999.0'; Omit = $false; Label = 'unsupported' }
        )

        $index = 0
        foreach ($case in $invalidCases) {
            $index++
            $invalidRunId = ('invalid-marker-{0}' -f $index)
            Write-TestRunManifest -OutputRoot $script:testRoot -RunId $invalidRunId -SchemaVersion $case.Value -OmitSchemaVersion:$case.Omit | Out-Null
            Write-TestRunMarker -OutputRoot $script:testRoot -RunId $invalidRunId

            $resumed = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
            if ([string]$resumed.runId -ne [string]$validRun.runId) {
                throw ('Expected invalid marker schemaVersion case [{0}] to fall back to run {1}; actual {2}.' -f $case.Label, $validRun.runId, $resumed.runId)
            }

            $marker = Get-Content -LiteralPath (Join-Path -Path $script:testRoot -ChildPath 'current-run.json') -Raw | ConvertFrom-Json
            if ([string]$marker.runId -ne [string]$validRun.runId) {
                throw ('Expected marker repair after invalid schemaVersion case [{0}].' -f $case.Label)
            }

            if (Test-Path -LiteralPath (Join-Path -Path $script:testRoot -ChildPath (Join-Path -Path $invalidRunId -ChildPath 'checkpoints'))) {
                throw ('Invalid marker candidate [{0}] must not receive checkpoint state.' -f $case.Label)
            }
        }
    }

    It 'skips a newer invalid-version directory during fallback when no marker exists' {
        $validRun = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')
        Remove-Item -LiteralPath (Join-Path -Path $script:testRoot -ChildPath 'current-run.json') -Force

        Start-Sleep -Milliseconds 25
        $invalidRunId = 'newer-invalid-fallback'
        Write-TestRunManifest -OutputRoot $script:testRoot -RunId $invalidRunId -SchemaVersion '999.0' | Out-Null

        $resumed = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
        if ([string]$resumed.runId -ne [string]$validRun.runId) {
            throw ('Expected newer invalid-version fallback candidate to be skipped for run {0}; actual {1}.' -f $validRun.runId, $resumed.runId)
        }

        if (Test-Path -LiteralPath (Join-Path -Path $script:testRoot -ChildPath (Join-Path -Path $invalidRunId -ChildPath 'checkpoints'))) {
            throw 'Newer invalid-version fallback candidate must not receive checkpoint state.'
        }
    }

    It 'keeps supported legacy 1.0 and current 1.1 manifests selectable' {
        foreach ($supportedVersion in @('1.0', '1.1')) {
            $caseRoot = Join-Path -Path $script:testRoot -ChildPath ('supported-' + $supportedVersion.Replace('.', '-'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            $runId = ('supported-{0}' -f $supportedVersion.Replace('.', '-'))
            Write-TestRunManifest -OutputRoot $caseRoot -RunId $runId -SchemaVersion $supportedVersion | Out-Null
            Write-TestRunMarker -OutputRoot $caseRoot -RunId $runId

            $resumed = Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
            if ([string]$resumed.runId -ne $runId) {
                throw ('Expected supported manifest schemaVersion {0} to remain selectable.' -f $supportedVersion)
            }

            $manifest = Get-Content -LiteralPath (Join-Path -Path $caseRoot -ChildPath (Join-Path -Path $runId -ChildPath 'manifest/run-manifest.json')) -Raw | ConvertFrom-Json
            if ([string]$manifest.schemaVersion -ne '1.1') {
                throw ('Expected selected manifest version {0} to finish through established 1.1 manifest normalization.' -f $supportedVersion)
            }
        }
    }
}
