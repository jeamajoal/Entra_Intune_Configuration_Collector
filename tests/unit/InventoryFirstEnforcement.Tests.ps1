$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
# Import the checkpoint module last because Stage2/Stage3 force-import it into their own module scopes.
# The direct import restores its exported commands for this test file's helper functions.
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

function New-TestStage1CheckpointBatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$BatchId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Succeeded', 'Failed', 'InProgress', 'Missing')]
        [string]$Status,

        [string]$ArtifactPath,

        [int]$ItemCount = 1
    )

    $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId 'inventory-first-test' -Stage 'stage1' -Section $Section -Family $Family
    $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $BatchId -Status $Status -Attempts 1 -ItemCount $ItemCount -SuccessCount $(if ($Status -eq 'Succeeded') { $ItemCount } else { 0 }) -FailedCount $(if ($Status -eq 'Succeeded') { 0 } else { $ItemCount }) -ArtifactPath $ArtifactPath -Error $(if ($Status -eq 'Succeeded') { $null } else { 'test failure' })
    Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
}

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

    It 'hard-fails Stage2 when Stage1 artifacts and checkpoint are missing' {
        $threw = $false
        try {
            Assert-CollectorInventoryFirstForStage2 -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected Stage2 inventory-first assertion to throw when Stage1 inventory evidence is missing.'
        }
    }

    It 'hard-fails Stage2 when a Stage1 artifact exists without a checkpoint' {
        $artifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications'
        New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
        '{"items":[]}' | Set-Content -Path (Join-Path -Path $artifactDirectory -ChildPath 'batch-0001.json') -Encoding UTF8

        $threw = $false
        try {
            Assert-CollectorInventoryFirstForStage2 -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected Stage2 inventory-first assertion to reject an orphan Stage1 artifact without checkpoint evidence.'
        }
    }

    It 'passes Stage2 when every recorded Stage1 batch succeeded and its artifact exists' {
        $artifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications'
        New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
        $artifactPath = Join-Path -Path $artifactDirectory -ChildPath 'batch-0001.json'
        '{"items":[]}' | Set-Content -Path $artifactPath -Encoding UTF8
        New-TestStage1CheckpointBatch -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications' -BatchId '0001' -Status 'Succeeded' -ArtifactPath $artifactPath -ItemCount 0

        try {
            Assert-CollectorInventoryFirstForStage2 -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        }
        catch {
            throw ('Expected Stage2 inventory-first assertion to pass for complete recorded Stage1 evidence. Actual: ' + $_.Exception.Message)
        }
    }

    It 'hard-fails Stage2 when any recorded Stage1 batch failed' {
        $artifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications'
        New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
        $artifactPath = Join-Path -Path $artifactDirectory -ChildPath 'batch-0001.json'
        '{"items":[{"id":"one"}]}' | Set-Content -Path $artifactPath -Encoding UTF8
        New-TestStage1CheckpointBatch -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications' -BatchId '0001' -Status 'Succeeded' -ArtifactPath $artifactPath
        New-TestStage1CheckpointBatch -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications' -BatchId '0002' -Status 'Failed' -ArtifactPath $null

        $threw = $false
        try {
            Assert-CollectorInventoryFirstForStage2 -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected Stage2 inventory-first assertion to reject a Stage1 checkpoint containing a failed batch.'
        }
    }

    It 'hard-fails Stage2 when a succeeded Stage1 checkpoint batch references a missing artifact' {
        $missingArtifactPath = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
        New-TestStage1CheckpointBatch -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications' -BatchId '0001' -Status 'Succeeded' -ArtifactPath $missingArtifactPath

        $threw = $false
        try {
            Assert-CollectorInventoryFirstForStage2 -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications'
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected Stage2 inventory-first assertion to reject a succeeded checkpoint whose artifact is missing.'
        }
    }

    It 'passes Stage3 when every dependency family has succeeded recorded batches and artifacts' {
        foreach ($family in @('groups', 'gpos')) {
            $artifactDirectory = Join-Path -Path $script:testRoot -ChildPath ('stage1/onprem-ad-gpo/' + $family)
            New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
            $artifactPath = Join-Path -Path $artifactDirectory -ChildPath 'batch-0001.json'
            '{"items":[]}' | Set-Content -Path $artifactPath -Encoding UTF8
            New-TestStage1CheckpointBatch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family $family -BatchId '0001' -Status 'Succeeded' -ArtifactPath $artifactPath -ItemCount 0
        }

        try {
            Assert-CollectorInventoryFirstForStage3 -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Families @('groups', 'gpos')
        }
        catch {
            throw ('Expected Stage3 inventory-first assertion to pass when all dependency checkpoint/artifact evidence is complete. Actual: ' + $_.Exception.Message)
        }
    }

    It 'hard-fails Stage3 when any dependency family has non-succeeded checkpoint state' {
        $groupArtifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/onprem-ad-gpo/groups'
        New-Item -Path $groupArtifactDirectory -ItemType Directory -Force | Out-Null
        $groupArtifactPath = Join-Path -Path $groupArtifactDirectory -ChildPath 'batch-0001.json'
        '{"items":[]}' | Set-Content -Path $groupArtifactPath -Encoding UTF8
        New-TestStage1CheckpointBatch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family 'groups' -BatchId '0001' -Status 'Succeeded' -ArtifactPath $groupArtifactPath -ItemCount 0
        New-TestStage1CheckpointBatch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family 'gpos' -BatchId '0001' -Status 'InProgress' -ArtifactPath $null

        $threw = $false
        try {
            Assert-CollectorInventoryFirstForStage3 -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Families @('groups', 'gpos')
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected Stage3 inventory-first assertion to reject a dependency family with non-succeeded checkpoint state.'
        }
    }
}
