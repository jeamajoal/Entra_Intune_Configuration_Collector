BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
}

Describe 'Run manifest persistence' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-manifest-persistence-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'creates and replaces the canonical manifest without direct Set-Content persistence' {
        Mock -ModuleName 'Collector.Storage.Artifacts' -CommandName Set-Content -MockWith {
            throw 'Save-CollectorManifest must not write the canonical manifest with Set-Content.'
        }

        $firstManifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = 'manifest-persistence-test'
            status = 'InProgress'
            stageResults = @()
        }
        $manifestPath = Save-CollectorManifest -RunPath $script:testRoot -Manifest $firstManifest
        $firstRead = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        if ([string]$firstRead.runId -ne 'manifest-persistence-test' -or [string]$firstRead.status -ne 'InProgress') {
            throw 'Expected the initial canonical manifest to contain the first persisted document.'
        }

        $replacementManifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = 'manifest-persistence-test'
            status = 'Completed'
            stageResults = @([pscustomobject]@{ stage = 'stage1'; family = 'applications' })
        }
        Save-CollectorManifest -RunPath $script:testRoot -Manifest $replacementManifest | Out-Null
        $replacementRead = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        if ([string]$replacementRead.status -ne 'Completed' -or @($replacementRead.stageResults).Count -ne 1) {
            throw 'Expected the canonical manifest to contain the validated replacement document.'
        }

        $manifestDirectory = Split-Path -Path $manifestPath -Parent
        $debris = @(Get-ChildItem -LiteralPath $manifestDirectory -File | Where-Object { $_.Name -match '^\.run-manifest\.json\..+\.(tmp|bak)$' })
        if ($debris.Count -ne 0) {
            throw ('Expected no temporary or backup manifest files after successful replacement; found ' + $debris.Count + '.')
        }
    }

    It 'preserves the prior canonical manifest when replacement validation fails' {
        $firstManifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = 'manifest-persistence-test'
            status = 'InProgress'
        }
        $manifestPath = Save-CollectorManifest -RunPath $script:testRoot -Manifest $firstManifest
        $beforeBytes = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestPath))

        Mock -ModuleName 'Collector.Storage.Artifacts' -CommandName ConvertFrom-Json -MockWith {
            throw 'simulated replacement validation failure'
        }

        $replacementManifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = 'manifest-persistence-test'
            status = 'Completed'
        }

        $threw = $false
        try {
            Save-CollectorManifest -RunPath $script:testRoot -Manifest $replacementManifest | Out-Null
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected manifest persistence to fail when temporary replacement JSON validation fails.'
        }

        $afterBytes = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestPath))
        if ($afterBytes -ne $beforeBytes) {
            throw 'Expected the prior canonical manifest to remain byte-for-byte unchanged after replacement validation failure.'
        }

        $manifestDirectory = Split-Path -Path $manifestPath -Parent
        $debris = @(Get-ChildItem -LiteralPath $manifestDirectory -File | Where-Object { $_.Name -match '^\.run-manifest\.json\..+\.(tmp|bak)$' })
        if ($debris.Count -ne 0) {
            throw ('Expected failed replacement cleanup to remove temporary/backup manifest files; found ' + $debris.Count + '.')
        }
    }
}
