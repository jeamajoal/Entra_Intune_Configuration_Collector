Set-StrictMode -Version Latest

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
        [string]$Family
    )

    $items = @()
    $snapshotFiles = Get-CollectorSnapshotFiles -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family
    foreach ($snapshotFile in $snapshotFiles) {
        $snapshot = Get-Content -LiteralPath $snapshotFile.FullName -Raw | ConvertFrom-Json
        if ($snapshot.items) {
            $items += @($snapshot.items)
        }
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
        [string]$Family
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
    $Manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

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
