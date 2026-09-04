Set-StrictMode -Version Latest

function New-CollectorDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
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

    $marker | ConvertTo-Json -Depth 5 | Set-Content -Path $markerPath -Encoding UTF8
}

function Resolve-CollectorRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [switch]$Resume
    )

    New-CollectorDirectory -Path $OutputRoot | Out-Null

    $runId = $null
    if ($Resume) {
        $markerPath = Get-CollectorRunMarkerPath -OutputRoot $OutputRoot
        if (Test-Path -Path $markerPath) {
            try {
                $marker = Get-Content -Path $markerPath -Raw | ConvertFrom-Json
                if ($marker.runId) {
                    $markerRunPath = Join-Path -Path $OutputRoot -ChildPath $marker.runId
                    if (Test-Path -Path $markerRunPath) {
                        $runId = [string]$marker.runId
                    }
                }
            }
            catch {
                $runId = $null
            }
        }

        if (-not $runId) {
            $candidateDirectories = @(Get-ChildItem -Path $OutputRoot -Directory | Sort-Object -Property LastWriteTimeUtc -Descending)
            if ($candidateDirectories.Count -gt 0) {
                $runId = $candidateDirectories[0].Name
            }
        }

        if (-not $runId) {
            throw 'Resume requested but no prior run artifacts were found under OutputRoot.'
        }
    }
    else {
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $runId = '{0}-{1}' -f $timestamp, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    $runPath = Join-Path -Path $OutputRoot -ChildPath $runId
    New-CollectorDirectory -Path $runPath | Out-Null
    New-CollectorDirectory -Path (Join-Path -Path $runPath -ChildPath 'manifest') | Out-Null
    New-CollectorDirectory -Path (Join-Path -Path $runPath -ChildPath 'checkpoints') | Out-Null

    Write-CollectorRunMarker -OutputRoot $OutputRoot -RunId $runId

    [pscustomobject]@{
        runId = $runId
        runPath = $runPath
    }
}

function Split-CollectorItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,

        [Parameter(Mandatory = $true)]
        [int]$BatchSize
    )

    if ($BatchSize -le 0) {
        throw 'BatchSize must be greater than zero.'
    }

    $batches = @()
    if (-not $Items -or $Items.Count -eq 0) {
        return $batches
    }

    for ($index = 0; $index -lt $Items.Count; $index += $BatchSize) {
        $endIndex = [Math]::Min($index + $BatchSize - 1, $Items.Count - 1)
        $batch = @($Items[$index..$endIndex])
        $batches += ,$batch
    }

    return $batches
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

    $stageFolder = Join-Path -Path $RunPath -ChildPath (Join-Path -Path $Stage -ChildPath (Join-Path -Path $Section -ChildPath $Family))
    New-CollectorDirectory -Path $stageFolder | Out-Null

    $batchId = '{0:D4}' -f $BatchNumber
    $artifactPath = Join-Path -Path $stageFolder -ChildPath ('batch-{0}.json' -f $batchId)

    $Snapshot | ConvertTo-Json -Depth 50 | Set-Content -Path $artifactPath -Encoding UTF8

    [pscustomobject]@{
        batchId = $batchId
        artifactPath = $artifactPath
    }
}

function Get-CollectorSnapshotFiles {
    [CmdletBinding()]
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
    if (-not (Test-Path -Path $familyPath)) {
        return @()
    }

    return @(Get-ChildItem -Path $familyPath -Filter 'batch-*.json' -File | Sort-Object -Property Name)
}

function Get-CollectorSnapshotItems {
    [CmdletBinding()]
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
        $snapshot = Get-Content -Path $snapshotFile.FullName -Raw | ConvertFrom-Json
        if ($snapshot.items) {
            $items += @($snapshot.items)
        }
    }

    return $items
}

function Test-CollectorInventoryArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    $files = Get-CollectorSnapshotFiles -RunPath $RunPath -Stage 'stage1' -Section $Section -Family $Family
    if ($null -eq $files) {
        return $false
    }

    return @($files).Count -gt 0
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

    New-CollectorDirectory -Path $manifestDirectory | Out-Null
    $Manifest | ConvertTo-Json -Depth 30 | Set-Content -Path $manifestPath -Encoding UTF8

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
