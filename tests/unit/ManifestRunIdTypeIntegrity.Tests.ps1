BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
    $script:orchestratorModule = Get-Module -Name 'Collector.Orchestrator' -ErrorAction Stop

    function Write-TestRunIdManifest {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [AllowNull()][AllowEmptyString()][object]$RunId,
            [string]$SchemaVersion = '1.1',
            [switch]$OmitRunId
        )

        $manifestDirectory = Join-Path -Path $RunPath -ChildPath 'manifest'
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
        if ($OmitRunId) {
            $manifest.PSObject.Properties.Remove('runId')
        }

        $manifestPath = Join-Path -Path $manifestDirectory -ChildPath 'run-manifest.json'
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        return $manifestPath
    }

    function Invoke-TestRunIdManifestLoad {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$RunId
        )

        $parameters = [pscustomobject]@{ sections = @('onprem-ad-gpo') }
        return & $script:orchestratorModule {
            param($InnerRunPath, $InnerRunId, $InnerParameters)
            Get-CollectorRunManifestForInvocation -RunPath $InnerRunPath -RunId $InnerRunId -Parameters $InnerParameters -Resume
        } $RunPath $RunId $parameters
    }

    function Write-TestRunIdMarker {
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

Describe 'Persisted manifest runId type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-manifest-runid-type-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith { @() }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith { @() }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects missing, null, empty, and non-string persisted runId values before resume normalization' {
        $invalidCases = @(
            [pscustomobject]@{ Value = 'placeholder'; Omit = $true; Label = 'missing'; ExpectedRunId = 'manifest-runid-type-test' },
            [pscustomobject]@{ Value = $null; Omit = $false; Label = 'null'; ExpectedRunId = 'manifest-runid-type-test' },
            [pscustomobject]@{ Value = ''; Omit = $false; Label = 'empty'; ExpectedRunId = 'manifest-runid-type-test' },
            [pscustomobject]@{ Value = 123; Omit = $false; Label = 'numeric'; ExpectedRunId = '123' },
            [pscustomobject]@{ Value = $true; Omit = $false; Label = 'boolean'; ExpectedRunId = 'True' },
            [pscustomobject]@{ Value = ([pscustomobject]@{ value = 'manifest-runid-type-test' }); Omit = $false; Label = 'object'; ExpectedRunId = 'manifest-runid-type-test' },
            [pscustomobject]@{ Value = @('manifest-runid-type-test'); Omit = $false; Label = 'array'; ExpectedRunId = 'manifest-runid-type-test' }
        )

        foreach ($case in $invalidCases) {
            Write-TestRunIdManifest -RunPath $script:testRoot -RunId $case.Value -OmitRunId:$case.Omit | Out-Null

            $threw = $false
            try {
                Invoke-TestRunIdManifestLoad -RunPath $script:testRoot -RunId $case.ExpectedRunId | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'runId.*invalid') {
                    throw ('Expected invalid runId type rejection for case [{0}]; actual error: {1}' -f $case.Label, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected schema-invalid persisted runId case to fail closed before normalization: {0}.' -f $case.Label)
            }
        }
    }

    It 'does not bind a coercible numeric manifest runId candidate when an older valid run exists' {
        $validRun = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')

        $invalidRunId = '123'
        $invalidRunPath = Join-Path -Path $script:testRoot -ChildPath $invalidRunId
        Write-TestRunIdManifest -RunPath $invalidRunPath -RunId 123 | Out-Null
        Write-TestRunIdMarker -OutputRoot $script:testRoot -RunId $invalidRunId

        $resumed = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
        if ([string]$resumed.runId -ne [string]$validRun.runId) {
            throw ('Expected numeric-runId marker target to fall back to older valid run {0}; actual {1}.' -f $validRun.runId, $resumed.runId)
        }

        $marker = Get-Content -LiteralPath (Join-Path -Path $script:testRoot -ChildPath 'current-run.json') -Raw | ConvertFrom-Json
        if ([string]$marker.runId -ne [string]$validRun.runId) {
            throw 'Expected current-run marker to be repaired to the older valid run after rejecting numeric manifest runId identity.'
        }
    }

    It 'keeps matching non-empty string runId values selectable for supported manifest versions' {
        foreach ($supportedVersion in @('1.0', '1.1')) {
            $caseRoot = Join-Path -Path $script:testRoot -ChildPath ('supported-' + $supportedVersion.Replace('.', '-'))
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            $runId = ('supported-runid-' + $supportedVersion.Replace('.', '-'))
            $runPath = Join-Path -Path $caseRoot -ChildPath $runId
            Write-TestRunIdManifest -RunPath $runPath -RunId $runId -SchemaVersion $supportedVersion | Out-Null
            Write-TestRunIdMarker -OutputRoot $caseRoot -RunId $runId

            $resumed = Start-CollectorRun -OutputRoot $caseRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
            if ([string]$resumed.runId -ne $runId) {
                throw ('Expected matching string runId to remain selectable for manifest version {0}.' -f $supportedVersion)
            }

            $manifest = Get-Content -LiteralPath (Join-Path -Path $runPath -ChildPath 'manifest/run-manifest.json') -Raw | ConvertFrom-Json
            if ([string]$manifest.runId -ne $runId -or [string]$manifest.schemaVersion -ne '1.1') {
                throw ('Expected supported manifest version {0} with matching string runId to resume and normalize normally.' -f $supportedVersion)
            }
        }
    }

    It 'continues to reject a valid string runId that does not match the selected run' {
        $validRun = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')

        $mismatchedRunId = 'selected-run'
        $mismatchedRunPath = Join-Path -Path $script:testRoot -ChildPath $mismatchedRunId
        Write-TestRunIdManifest -RunPath $mismatchedRunPath -RunId 'different-run' | Out-Null
        Write-TestRunIdMarker -OutputRoot $script:testRoot -RunId $mismatchedRunId

        $resumed = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('onprem-ad-gpo') -Resume
        if ([string]$resumed.runId -ne [string]$validRun.runId) {
            throw ('Expected mismatched string runId candidate to fall back to valid run {0}; actual {1}.' -f $validRun.runId, $resumed.runId)
        }

        $threw = $false
        try {
            Invoke-TestRunIdManifestLoad -RunPath $mismatchedRunPath -RunId $mismatchedRunId | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'runId mismatch') {
                throw ('Expected established runId mismatch rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected valid string manifest runId mismatch to fail closed.'
        }
    }
}
