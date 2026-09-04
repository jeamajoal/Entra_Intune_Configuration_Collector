$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop

Describe 'Inventory-first enforcement' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-inventory-first-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -Path $script:testRoot) {
            Remove-Item -Path $script:testRoot -Recurse -Force
        }
    }

    It 'hard-fails Stage2 when Stage1 artifacts are missing for selected section family' {
        $threw = $false
        try {
            Assert-CollectorInventoryFirstForStage2 -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected Stage2 inventory-first assertion to throw when Stage1 artifacts are missing.'
        }
    }

    It 'passes Stage2 inventory check when Stage1 artifacts exist for selected section family' {
        $artifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications'
        New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
        '{}' | Set-Content -Path (Join-Path -Path $artifactDirectory -ChildPath 'batch-0001.json') -Encoding UTF8

        try {
            Assert-CollectorInventoryFirstForStage2 -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        }
        catch {
            throw ('Expected Stage2 inventory-first assertion to pass when Stage1 artifacts exist. Actual: ' + $_.Exception.Message)
        }
    }

    It 'hard-fails Stage3 when Stage1 artifacts are missing for selected dependency family' {
        $threw = $false
        try {
            Assert-CollectorInventoryFirstForStage3 -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Families @('groups')
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected Stage3 inventory-first assertion to throw when dependency artifacts are missing.'
        }
    }

    It 'passes Stage3 inventory check when Stage1 artifacts exist for all selected dependency families' {
        $groupArtifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/onprem-ad-gpo/groups'
        New-Item -Path $groupArtifactDirectory -ItemType Directory -Force | Out-Null
        '{}' | Set-Content -Path (Join-Path -Path $groupArtifactDirectory -ChildPath 'batch-0001.json') -Encoding UTF8

        $gpoArtifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/onprem-ad-gpo/gpos'
        New-Item -Path $gpoArtifactDirectory -ItemType Directory -Force | Out-Null
        '{}' | Set-Content -Path (Join-Path -Path $gpoArtifactDirectory -ChildPath 'batch-0001.json') -Encoding UTF8

        try {
            Assert-CollectorInventoryFirstForStage3 -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Families @('groups', 'gpos')
        }
        catch {
            throw ('Expected Stage3 inventory-first assertion to pass when dependency artifacts exist. Actual: ' + $_.Exception.Message)
        }
    }
}
