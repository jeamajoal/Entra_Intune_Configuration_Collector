Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

function Initialize-CollectorDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    return $Path
}

function Get-CollectorRunMarkerPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot
    )

    Join-Path -Path $OutputRoot -ChildPath 'current-run.json'
}

function Write-CollectorRunMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [string]$RunId
    )

    $markerPath = Get-CollectorRunMarkerPath -OutputRoot $OutputRoot
    $marker = [pscustomobject]@{
        runId = $RunId
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding UTF8
}

function Test-CollectorResumeRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId) -or $RunId -match '[\\/]' -or $RunId -eq '.' -or $RunId -eq '..') {
        return $false
    }

    $runPath = Join-Path -Path $OutputRoot -ChildPath $RunId
    if (-not (Test-Path -LiteralPath $runPath -PathType Container)) {
        return $false
    }

    $manifestPath = Join-Path -Path $runPath -ChildPath 'manifest\run-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        return $false
    }

    if ($null -eq $manifest -or $manifest.PSObject.Properties.Match('runId').Count -eq 0) {
        return $false
    }

    return -not [string]::IsNullOrWhiteSpace([string]$manifest.runId) -and [string]$manifest.runId -eq $RunId
}

function Resolve-CollectorRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [switch]$Resume
    )

    $runId = $null
    if ($Resume) {
        if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
            throw 'Resume requested but no prior run artifacts were found under OutputRoot.'
        }

        $markerPath = Get-CollectorRunMarkerPath -OutputRoot $OutputRoot
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try {
                $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
                $markerRunId = [string]$marker.runId
                if (Test-CollectorResumeRun -OutputRoot $OutputRoot -RunId $markerRunId) {
                    $runId = $markerRunId
                }
            }
            catch {
                $runId = $null
            }
        }

        if (-not $runId) {
            $candidateDirectories = @(Get-ChildItem -LiteralPath $OutputRoot -Directory | Sort-Object -Property LastWriteTimeUtc -Descending)
            foreach ($candidateDirectory in $candidateDirectories) {
                if (Test-CollectorResumeRun -OutputRoot $OutputRoot -RunId $candidateDirectory.Name) {
                    $runId = $candidateDirectory.Name
                    break
                }
            }
        }

        if (-not $runId) {
            throw 'Resume requested but no prior run artifacts were found under OutputRoot.'
        }

        $runPath = Join-Path -Path $OutputRoot -ChildPath $runId
    }
    else {
        Initialize-CollectorDirectory -Path $OutputRoot | Out-Null
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $runId = '{0}-{1}' -f $timestamp, ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $runPath = Join-Path -Path $OutputRoot -ChildPath $runId
        Initialize-CollectorDirectory -Path $runPath | Out-Null
        Initialize-CollectorDirectory -Path (Join-Path -Path $runPath -ChildPath 'manifest') | Out-Null
        Initialize-CollectorDirectory -Path (Join-Path -Path $runPath -ChildPath 'checkpoints') | Out-Null
    }

    Write-CollectorRunMarker -OutputRoot $OutputRoot -RunId $runId

    [pscustomobject]@{
        runId = $runId
        runPath = $runPath
    }
}

function Split-CollectorItems {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The exported function intentionally splits an item collection into multiple batches and its established contract is plural.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCmdletCorrectly', '', Justification = 'Write-Output -NoEnumerate is intentional here to preserve the nested batch collection as one pipeline object.')]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [int]$BatchSize
    )

    if ($BatchSize -le 0) {
        throw 'BatchSize must be greater than zero.'
    }

    $batches = [System.Collections.Generic.List[object]]::new()

    if (-not $Items -or $Items.Count -eq 0) {
        $batches.Add([object][object[]]@())
        Write-Output -NoEnumerate $batches
        return
    }

    for ($index = 0; $index -lt $Items.Count; $index += $BatchSize) {
        $endIndex = [Math]::Min($index + $BatchSize - 1, $Items.Count - 1)
        $batch = [object[]]@($Items[$index..$endIndex])
        $batches.Add([object]$batch)
    }

    Write-Output -NoEnumerate $batches
}

function Get-CollectorCanonicalArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$BatchId
    )

    $relativePath = Join-Path -Path $Stage -ChildPath (Join-Path -Path $Section -ChildPath (Join-Path -Path $Family -ChildPath ('batch-{0}.json' -f $BatchId)))
    return [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath $relativePath))
}

function Write-CollectorSnapshotArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [int]$BatchNumber,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    $batchId = '{0:D4}' -f $BatchNumber
    $artifactPath = Get-CollectorCanonicalArtifactPath -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family -BatchId $batchId
    $stageFolder = Split-Path -Path $artifactPath -Parent
    Initialize-CollectorDirectory -Path $stageFolder | Out-Null

    $Snapshot | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

    [pscustomobject]@{
        batchId = $batchId
        artifactPath = $artifactPath
    }
}

function Get-CollectorSnapshotFiles {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'This exported function intentionally returns the collection of snapshot files for a family.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    $familyPath = Join-Path -Path $RunPath -ChildPath (Join-Path -Path $Stage -ChildPath (Join-Path -Path $Section -ChildPath $Family))
    if (-not (Test-Path -LiteralPath $familyPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $familyPath -Filter 'batch-*.json' -File | Sort-Object -Property Name)
}

function Get-CollectorSnapshotItems {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'This exported function intentionally returns the collection of items across snapshot files.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [string]$ExpectedRunId
    )

    $checkpointPath = Join-Path -Path $RunPath -ChildPath (Join-Path -Path (Join-Path -Path 'checkpoints' -ChildPath $Stage) -ChildPath (Join-Path -Path $Section -ChildPath ($Family + '.json')))
    if (-not (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
        throw ('Snapshot loading requires a persisted checkpoint for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }

    try {
        $checkpointIdentity = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    }
    catch {
        throw ('Snapshot loading cannot read checkpoint identity for {0}/{1}/{2}: {3}' -f $Stage, $Section, $Family, $_.Exception.Message)
    }

    if ($null -eq $checkpointIdentity -or $checkpointIdentity.PSObject.Properties.Match('runId').Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$checkpointIdentity.runId)) {
        throw ('Snapshot loading requires a checkpoint run identity for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }

    $runId = [string]$checkpointIdentity.runId
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and $runId -ne $ExpectedRunId) {
        throw ('Snapshot loading run identity mismatch for {0}/{1}/{2}: expected runId={3}; found {4}.' -f $Stage, $Section, $Family, $ExpectedRunId, $runId)
    }

    $manifestPath = Get-CollectorManifestPath -RunPath $RunPath
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
        catch {
            throw ('Snapshot loading cannot validate manifest run identity for {0}/{1}/{2}: {3}' -f $Stage, $Section, $Family, $_.Exception.Message)
        }

        if ($null -eq $manifest -or $manifest.PSObject.Properties.Match('runId').Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$manifest.runId) -or [string]$manifest.runId -ne $runId) {
            throw ('Snapshot loading run identity does not match the persisted manifest for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
        }
    }

    $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage $Stage -Section $Section -Family $Family
    if ($checkpoint.PSObject.Properties.Match('plan').Count -eq 0 -or $null -eq $checkpoint.plan -or -not [bool]$checkpoint.plan.completed) {
        throw ('Snapshot loading requires a completed checkpoint plan for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }

    $plannedBatches = @($checkpoint.plan.batches)
    $checkpointBatches = @($checkpoint.batches)
    $expectedBatchCount = [int]$checkpoint.plan.expectedBatchCount
    if ($expectedBatchCount -le 0 -or $plannedBatches.Count -ne $expectedBatchCount -or $checkpointBatches.Count -ne $expectedBatchCount) {
        throw ('Snapshot checkpoint plan is incomplete or inconsistent for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }

    $plannedBatchIds = @($plannedBatches | ForEach-Object { [string]$_.batchId })
    $checkpointBatchIds = @($checkpointBatches | ForEach-Object { [string]$_.batchId })
    $plannedBatchIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($batchId in $plannedBatchIds) {
        if ([string]::IsNullOrWhiteSpace($batchId) -or -not $plannedBatchIdSet.Add($batchId)) {
            throw ('Snapshot checkpoint plan contains an empty or duplicate batch identity for {0}/{1}/{2}: {3}' -f $Stage, $Section, $Family, $batchId)
        }
    }

    $checkpointBatchIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($batchId in $checkpointBatchIds) {
        if ([string]::IsNullOrWhiteSpace($batchId) -or -not $checkpointBatchIdSet.Add($batchId)) {
            throw ('Snapshot checkpoint contains an empty or duplicate recorded batch identity for {0}/{1}/{2}: {3}' -f $Stage, $Section, $Family, $batchId)
        }
    }

    if (-not $plannedBatchIdSet.SetEquals($checkpointBatchIdSet)) {
        throw ('Snapshot checkpoint planned and recorded batch identities do not match for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }

    $items = @()
    foreach ($plannedBatch in $plannedBatches) {
        $batchId = [string]$plannedBatch.batchId
        $plannedItemCount = 0
        if ($plannedBatch.PSObject.Properties.Match('itemCount').Count -eq 0 -or -not [int]::TryParse([string]$plannedBatch.itemCount, [ref]$plannedItemCount) -or $plannedItemCount -lt 0) {
            throw ('Snapshot checkpoint plan has an invalid itemCount for {0}/{1}/{2} batch {3}.' -f $Stage, $Section, $Family, $batchId)
        }

        $checkpointBatch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
        if ($null -eq $checkpointBatch -or [string]$checkpointBatch.status -ne 'Succeeded' -or [string]::IsNullOrWhiteSpace([string]$checkpointBatch.artifactPath)) {
            throw ('Snapshot checkpoint batch {0} is not a successful persisted batch for {1}/{2}/{3}.' -f $batchId, $Stage, $Section, $Family)
        }

        $checkpointItemCount = 0
        if ($checkpointBatch.PSObject.Properties.Match('itemCount').Count -eq 0 -or -not [int]::TryParse([string]$checkpointBatch.itemCount, [ref]$checkpointItemCount) -or $checkpointItemCount -lt 0) {
            throw ('Snapshot checkpoint batch has an invalid itemCount for {0}/{1}/{2} batch {3}.' -f $Stage, $Section, $Family, $batchId)
        }

        $checkpointSuccessCount = 0
        $checkpointFailedCount = 0
        if (
            $checkpointBatch.PSObject.Properties.Match('successCount').Count -eq 0 -or
            $checkpointBatch.PSObject.Properties.Match('failedCount').Count -eq 0 -or
            -not [int]::TryParse([string]$checkpointBatch.successCount, [ref]$checkpointSuccessCount) -or
            -not [int]::TryParse([string]$checkpointBatch.failedCount, [ref]$checkpointFailedCount) -or
            $checkpointSuccessCount -lt 0 -or
            $checkpointFailedCount -lt 0
        ) {
            throw ('Snapshot checkpoint batch has invalid success/failure counts for {0}/{1}/{2} batch {3}.' -f $Stage, $Section, $Family, $batchId)
        }
        if ($checkpointSuccessCount -ne $checkpointItemCount -or $checkpointFailedCount -ne 0) {
            throw ('Snapshot checkpoint batch success/failure counts are inconsistent for {0}/{1}/{2} batch {3}: itemCount={4}; successCount={5}; failedCount={6}.' -f $Stage, $Section, $Family, $batchId, $checkpointItemCount, $checkpointSuccessCount, $checkpointFailedCount)
        }

        if ($checkpointItemCount -ne $plannedItemCount) {
            throw ('Snapshot cardinality mismatch for {0}/{1}/{2} batch {3}: planned itemCount={4}; checkpoint itemCount={5}.' -f $Stage, $Section, $Family, $batchId, $plannedItemCount, $checkpointItemCount)
        }

        $artifactPath = Get-CollectorCanonicalArtifactPath -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family -BatchId $batchId
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw ('Expected snapshot artifact is missing for {0}/{1}/{2} batch {3}: {4}' -f $Stage, $Section, $Family, $batchId, $artifactPath)
        }

        try {
            $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        }
        catch {
            throw ('Expected snapshot artifact is unreadable for {0}/{1}/{2} batch {3}: {4}' -f $Stage, $Section, $Family, $batchId, $_.Exception.Message)
        }

        if ($null -eq $snapshot) {
            throw ('Expected snapshot artifact is null for {0}/{1}/{2} batch {3}: {4}' -f $Stage, $Section, $Family, $batchId, $artifactPath)
        }

        $expectedIdentity = @{
            runId = $runId
            stage = $Stage
            section = $Section
            family = $Family
            batchId = $batchId
        }
        foreach ($identityName in @('runId', 'stage', 'section', 'family', 'batchId')) {
            if ($snapshot.PSObject.Properties.Match($identityName).Count -eq 0) {
                throw ('Snapshot identity mismatch at {0}: required identity property {1} is missing.' -f $artifactPath, $identityName)
            }

            $actualValue = [string]$snapshot.$identityName
            $expectedValue = [string]$expectedIdentity[$identityName]
            if ($actualValue -ne $expectedValue) {
                throw ('Snapshot identity mismatch at {0}: expected {1}={2}; found {3}.' -f $artifactPath, $identityName, $expectedValue, $actualValue)
            }
        }

        if ($snapshot.PSObject.Properties.Match('items').Count -eq 0) {
            throw ('Expected snapshot artifact has no items property for {0}/{1}/{2} batch {3}: {4}' -f $Stage, $Section, $Family, $batchId, $artifactPath)
        }

        $snapshotItemCount = 0
        if ($snapshot.PSObject.Properties.Match('itemCount').Count -eq 0 -or -not [int]::TryParse([string]$snapshot.itemCount, [ref]$snapshotItemCount) -or $snapshotItemCount -lt 0) {
            throw ('Expected snapshot artifact has an invalid itemCount for {0}/{1}/{2} batch {3}: {4}' -f $Stage, $Section, $Family, $batchId, $artifactPath)
        }

        $actualItemCount = @($snapshot.items).Count
        if ($snapshotItemCount -ne $plannedItemCount -or $actualItemCount -ne $plannedItemCount) {
            throw ('Snapshot cardinality mismatch for {0}/{1}/{2} batch {3}: planned itemCount={4}; snapshot itemCount={5}; actual items={6}.' -f $Stage, $Section, $Family, $batchId, $plannedItemCount, $snapshotItemCount, $actualItemCount)
        }

        $items += @($snapshot.items)
    }

    return $items
}

function Test-CollectorInventoryArtifacts {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'This exported readiness test validates the complete set of inventory artifacts for a family.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [string]$ExpectedRunId
    )

    $checkpointPath = Join-Path -Path $RunPath -ChildPath (Join-Path -Path (Join-Path -Path 'checkpoints' -ChildPath 'stage1') -ChildPath (Join-Path -Path $Section -ChildPath ($Family + '.json')))
    if (-not (Test-Path -LiteralPath $checkpointPath)) {
        return $false
    }

    try {
        $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    }
    catch {
        return $false
    }

    if ([string]$checkpoint.stage -ne 'stage1' -or [string]$checkpoint.section -ne $Section -or [string]$checkpoint.family -ne $Family) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId)) {
        if ($checkpoint.PSObject.Properties.Match('runId').Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$checkpoint.runId) -or [string]$checkpoint.runId -ne $ExpectedRunId) {
            return $false
        }
    }

    $manifestPath = Join-Path -Path $RunPath -ChildPath 'manifest\run-manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
        catch {
            return $false
        }

        if ($null -eq $manifest -or $manifest.PSObject.Properties.Match('runId').Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$manifest.runId)) {
            return $false
        }
        if ($checkpoint.PSObject.Properties.Match('runId').Count -eq 0 -or [string]$checkpoint.runId -ne [string]$manifest.runId) {
            return $false
        }
    }

    if ($checkpoint.PSObject.Properties.Match('plan').Count -eq 0 -or $null -eq $checkpoint.plan -or -not [bool]$checkpoint.plan.completed) {
        return $false
    }

    $batches = @($checkpoint.batches)
    if ($batches.Count -eq 0 -or $batches.Count -ne [int]$checkpoint.plan.expectedBatchCount -or @($checkpoint.plan.batches).Count -ne [int]$checkpoint.plan.expectedBatchCount) {
        return $false
    }

    foreach ($batch in $batches) {
        if ([string]$batch.status -ne 'Succeeded') {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace([string]$batch.artifactPath)) {
            return $false
        }

        $artifactPath = Get-CollectorCanonicalArtifactPath -RunPath $RunPath -Stage 'stage1' -Section $Section -Family $Family -BatchId ([string]$batch.batchId)
        if (-not (Test-Path -LiteralPath $artifactPath)) {
            return $false
        }
    }

    return $true
}

function Get-CollectorManifestPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath
    )

    Join-Path -Path $RunPath -ChildPath 'manifest\run-manifest.json'
}

function Save-CollectorManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest
    )

    $manifestPath = Get-CollectorManifestPath -RunPath $RunPath
    $manifestDirectory = Split-Path -Path $manifestPath -Parent

    Initialize-CollectorDirectory -Path $manifestDirectory | Out-Null

    $manifestJson = $Manifest | ConvertTo-Json -Depth 30
    $uniqueSuffix = [Guid]::NewGuid().ToString('N')
    $fileName = [System.IO.Path]::GetFileName($manifestPath)
    $tempPath = Join-Path -Path $manifestDirectory -ChildPath ('.{0}.{1}.tmp' -f $fileName, $uniqueSuffix)
    $backupPath = Join-Path -Path $manifestDirectory -ChildPath ('.{0}.{1}.bak' -f $fileName, $uniqueSuffix)

    try {
        [System.IO.File]::WriteAllText($tempPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))
        Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json | Out-Null

        if (Test-Path -LiteralPath $manifestPath) {
            [System.IO.File]::Replace($tempPath, $manifestPath, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $manifestPath)
        }
    }
    finally {
        foreach ($temporaryPath in @($tempPath, $backupPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $manifestPath
}

Export-ModuleMember -Function @(
    'Resolve-CollectorRun',
    'Split-CollectorItems',
    'Write-CollectorSnapshotArtifact',
    'Get-CollectorSnapshotFiles',
    'Get-CollectorSnapshotItems',
    'Test-CollectorInventoryArtifacts',
    'Get-CollectorManifestPath',
    'Save-CollectorManifest'
)