Set-StrictMode -Version Latest

function Get-CollectorCheckpointPath {
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

    Join-Path -Path $RunPath -ChildPath (Join-Path -Path (Join-Path -Path 'checkpoints' -ChildPath $Stage) -ChildPath (Join-Path -Path $Section -ChildPath ($Family + '.json')))
}

function New-CollectorCheckpointDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    [pscustomobject]@{
        schemaVersion = '1.0'
        runId = $RunId
        stage = $Stage
        section = $Section
        family = $Family
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        batches = @()
    }
}

function Invoke-CollectorAtomicFileReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        [System.IO.File]::Replace($SourcePath, $DestinationPath, $null, $true)
        return
    }

    [System.IO.File]::Move($SourcePath, $DestinationPath)
}

function Get-CollectorCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    $checkpointPath = Get-CollectorCheckpointPath -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family

    if (-not (Test-Path -LiteralPath $checkpointPath)) {
        return New-CollectorCheckpointDocument -RunId $RunId -Stage $Stage -Section $Section -Family $Family
    }

    $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    if (-not $checkpoint.batches) {
        $checkpoint | Add-Member -MemberType NoteProperty -Name batches -Value @() -Force
    }

    return $checkpoint
}

function Save-CollectorCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint
    )

    $checkpointPath = Get-CollectorCheckpointPath -RunPath $RunPath -Stage $Checkpoint.stage -Section $Checkpoint.section -Family $Checkpoint.family
    $checkpointDirectory = Split-Path -Path $checkpointPath -Parent

    if (-not (Test-Path -LiteralPath $checkpointDirectory)) {
        New-Item -Path $checkpointDirectory -ItemType Directory -Force | Out-Null
    }

    $Checkpoint.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $checkpointJson = $Checkpoint | ConvertTo-Json -Depth 20
    $tempFileName = '.{0}.{1}.tmp' -f ([System.IO.Path]::GetFileName($checkpointPath)), ([Guid]::NewGuid().ToString('N'))
    $tempPath = Join-Path -Path $checkpointDirectory -ChildPath $tempFileName

    try {
        [System.IO.File]::WriteAllText($tempPath, $checkpointJson, [System.Text.UTF8Encoding]::new($false))
        Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json | Out-Null
        Invoke-CollectorAtomicFileReplace -SourcePath $tempPath -DestinationPath $checkpointPath
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $checkpointPath
}

function Get-CollectorCheckpointBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [string]$BatchId
    )

    $existingBatch = $Checkpoint.batches | Where-Object { $_.batchId -eq $BatchId } | Select-Object -First 1
    return $existingBatch
}

function Set-CollectorCheckpointBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [string]$BatchId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Succeeded', 'Failed', 'InProgress', 'Missing')]
        [string]$Status,

        [int]$Attempts = 1,

        [int]$ItemCount = 0,

        [int]$SuccessCount = 0,

        [int]$FailedCount = 0,

        [string]$ArtifactPath,

        [Alias('Error')]
        [string]$ErrorMessage
    )

    $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $Checkpoint -BatchId $BatchId
    if (-not $existingBatch) {
        $existingBatch = [pscustomobject]@{
            batchId = $BatchId
            status = $Status
            attempts = $Attempts
            itemCount = $ItemCount
            successCount = $SuccessCount
            failedCount = $FailedCount
            artifactPath = $ArtifactPath
            error = $ErrorMessage
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $Checkpoint.batches += $existingBatch
        return $Checkpoint
    }

    $existingBatch.status = $Status
    $existingBatch.attempts = $Attempts
    $existingBatch.itemCount = $ItemCount
    $existingBatch.successCount = $SuccessCount
    $existingBatch.failedCount = $FailedCount
    $existingBatch.artifactPath = $ArtifactPath
    $existingBatch.error = $ErrorMessage
    $existingBatch.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')

    return $Checkpoint
}

function Get-CollectorBatchExecutionDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [string]$BatchId,

        [switch]$Resume,

        [switch]$ReprocessFailedOnly
    )

    if (-not $Resume) {
        return [pscustomobject]@{
            ShouldProcess = $true
            MarkMissing = $false
            Reason = 'NoResumeRequested'
        }
    }

    $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $Checkpoint -BatchId $BatchId
    if (-not $existingBatch) {
        return [pscustomobject]@{
            ShouldProcess = $true
            MarkMissing = $false
            Reason = 'BatchNotFound'
        }
    }

    $artifactExists = $false
    if ($existingBatch.artifactPath) {
        $artifactExists = Test-Path -LiteralPath $existingBatch.artifactPath
    }

    if ($existingBatch.status -eq 'Succeeded' -and $artifactExists) {
        return [pscustomobject]@{
            ShouldProcess = $false
            MarkMissing = $false
            Reason = 'SucceededWithArtifact'
        }
    }

    if ($existingBatch.status -eq 'Succeeded' -and -not $artifactExists) {
        return [pscustomobject]@{
            ShouldProcess = $true
            MarkMissing = $true
            Reason = 'MissingArtifact'
        }
    }

    if ($ReprocessFailedOnly) {
        return [pscustomobject]@{
            ShouldProcess = $true
            MarkMissing = $false
            Reason = 'ReprocessFailedOnly'
        }
    }

    return [pscustomobject]@{
        ShouldProcess = $true
        MarkMissing = $false
        Reason = 'ResumeReprocess'
    }
}

function Get-CollectorCheckpointFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath
    )

    $checkpointRoot = Join-Path -Path $RunPath -ChildPath 'checkpoints'
    if (-not (Test-Path -LiteralPath $checkpointRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $checkpointRoot -Filter '*.json' -Recurse -File)
}

function Get-CollectorCheckpointSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath
    )

    $summary = @()
    $checkpointFiles = Get-CollectorCheckpointFiles -RunPath $RunPath

    foreach ($checkpointFile in $checkpointFiles) {
        $checkpoint = Get-Content -LiteralPath $checkpointFile.FullName -Raw | ConvertFrom-Json
        $batchCount = @($checkpoint.batches).Count
        $succeededBatches = @($checkpoint.batches | Where-Object { $_.status -eq 'Succeeded' }).Count
        $failedBatches = @($checkpoint.batches | Where-Object { $_.status -eq 'Failed' }).Count
        $missingBatches = @($checkpoint.batches | Where-Object { $_.status -eq 'Missing' }).Count
        $inProgressBatches = @($checkpoint.batches | Where-Object { $_.status -eq 'InProgress' }).Count
        $itemCount = 0
        if ($checkpoint.batches) {
            $itemCount = ($checkpoint.batches | Measure-Object -Property itemCount -Sum).Sum
        }

        $summary += [pscustomobject]@{
            stage = $checkpoint.stage
            section = $checkpoint.section
            family = $checkpoint.family
            batchCount = $batchCount
            succeededBatches = $succeededBatches
            failedBatches = $failedBatches
            missingBatches = $missingBatches
            inProgressBatches = $inProgressBatches
            itemCount = if ($itemCount) { [int]$itemCount } else { 0 }
        }
    }

    return $summary
}

Export-ModuleMember -Function @(
    'Get-CollectorCheckpointPath',
    'Get-CollectorCheckpoint',
    'Save-CollectorCheckpoint',
    'Get-CollectorCheckpointBatch',
    'Set-CollectorCheckpointBatch',
    'Get-CollectorBatchExecutionDecision',
    'Get-CollectorCheckpointSummary'
)
