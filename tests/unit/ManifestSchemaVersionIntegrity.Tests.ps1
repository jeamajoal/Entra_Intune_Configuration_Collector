BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
    $script:orchestratorModule = Get-Module -Name 'Collector.Orchestrator' -ErrorAction Stop

    function Get-TestManifestDocument {
        param(
            [Parameter(Mandatory = $true)]
            [object]$SchemaVersion,

            [switch]$IncludeInvocations
        )

        $manifest = [ordered]@{
            schemaVersion = $SchemaVersion
            runId = 'manifest-schema-version-test'
            startedUtc = '2026-09-07T00:00:00.0000000Z'
            completedUtc = '2026-09-07T00:01:00.0000000Z'
            status = 'Completed'
            parameters = [pscustomobject]@{ sections = @('onprem-ad-gpo') }
            stageResults = @()
            checkpointSummary = @()
            failures = @()
        }

        if ($IncludeInvocations) {
            $manifest.invocations = @()
        }

        return [pscustomobject]$manifest
    }

    function Invoke-TestManifestLoad {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        $parameters = [pscustomobject]@{ sections = @('onprem-ad-gpo') }
        return & $script:orchestratorModule {
            param($InnerRunPath, $InnerParameters)
            Get-CollectorRunManifestForInvocation -RunPath $InnerRunPath -RunId 'manifest-schema-version-test' -Parameters $InnerParameters -Resume
        } $RunPath $parameters
    }
}

Describe 'Persisted manifest schema-version integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-manifest-schema-version-' + [Guid]::NewGuid().ToString('N'))
        $script:manifestDirectory = Join-Path -Path $script:testRoot -ChildPath 'manifest'
        $script:manifestPath = Join-Path -Path $script:manifestDirectory -ChildPath 'run-manifest.json'
        New-Item -Path $script:manifestDirectory -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts current 1.1 persisted manifests without legacy migration' {
        $manifest = Get-TestManifestDocument -SchemaVersion '1.1' -IncludeInvocations
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:manifestPath -Encoding UTF8

        $loaded = Invoke-TestManifestLoad -RunPath $script:testRoot

        if ([string]$loaded.schemaVersion -ne '1.1' -or @($loaded.invocations).Count -ne 0) {
            throw 'Expected current manifest schema 1.1 to remain current without creating a legacy invocation.'
        }
    }

    It 'accepts intentional legacy 1.0 and upgrades it through the established history migration' {
        $manifest = Get-TestManifestDocument -SchemaVersion '1.0'
        $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:manifestPath -Encoding UTF8

        $loaded = Invoke-TestManifestLoad -RunPath $script:testRoot

        if ([string]$loaded.schemaVersion -ne '1.1' -or @($loaded.invocations).Count -ne 1) {
            throw 'Expected legacy manifest schema 1.0 to upgrade to 1.1 with one historical invocation.'
        }
    }

    It 'rejects missing, null, empty, non-string, and unsupported persisted schema versions before normalization' {
        $invalidManifests = @()

        $missing = Get-TestManifestDocument -SchemaVersion 'placeholder' -IncludeInvocations
        $missing.PSObject.Properties.Remove('schemaVersion')
        $invalidManifests += $missing
        $invalidManifests += (Get-TestManifestDocument -SchemaVersion $null -IncludeInvocations)
        $invalidManifests += (Get-TestManifestDocument -SchemaVersion '' -IncludeInvocations)
        $invalidManifests += (Get-TestManifestDocument -SchemaVersion 1.1 -IncludeInvocations)
        $invalidManifests += (Get-TestManifestDocument -SchemaVersion ([pscustomobject]@{ value = '1.1' }) -IncludeInvocations)
        $invalidManifests += (Get-TestManifestDocument -SchemaVersion '999.0' -IncludeInvocations)

        foreach ($invalidManifest in $invalidManifests) {
            $invalidManifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:manifestPath -Encoding UTF8

            $threw = $false
            try {
                Invoke-TestManifestLoad -RunPath $script:testRoot | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'schemaVersion') {
                    throw ('Expected bounded schemaVersion rejection; actual error: {0}' -f $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected invalid persisted manifest schemaVersion to fail closed: {0}' -f ($invalidManifest | ConvertTo-Json -Depth 10 -Compress))
            }
        }
    }
}
