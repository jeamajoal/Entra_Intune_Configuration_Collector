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

function Get-CollectorCheckpointCanonicalArtifactPath {
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

function Get-CollectorPlanHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hashBytes = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function New-CollectorCheckpointPlan {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs and returns an in-memory checkpoint plan.')]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Batches,

        [Parameter(Mandatory = $true)]
        [int]$BatchSize
    )

    $planBatches = @()
    $batchNumber = 0

    foreach ($batch in $Batches) {
        $batchNumber++
        $batchItems = [object[]]@($batch)
        $serializedBatch = ConvertTo-Json -InputObject $batchItems -Depth 50 -Compress
        if ([string]::IsNullOrWhiteSpace($serializedBatch)) {
            $serializedBatch = '[]'
        }

        $planBatches += [pscustomobject]@{
            batchId = '{0:D4}' -f $batchNumber
            itemCount = $batchItems.Count
            fingerprint = Get-CollectorPlanHash -Value $serializedBatch
        }
    }

    $sourceMaterial = ConvertTo-Json -InputObject @($planBatches | Select-Object -Property batchId, itemCount, fingerprint) -Depth 10 -Compress
    if ([string]::IsNullOrWhiteSpace($sourceMaterial)) {
        $sourceMaterial = '[]'
    }

    [pscustomobject]@{
        planVersion = '1.0'
        batchSize = $BatchSize
        expectedBatchCount = $planBatches.Count
        sourceFingerprint = Get-CollectorPlanHash -Value $sourceMaterial
        completed = $false
        batches = @($planBatches)
    }
}

function Initialize-CollectorCheckpointPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Batches,

        [Parameter(Mandatory = $true)]
        [int]$BatchSize,

        [switch]$Resume
    )

    $currentPlan = New-CollectorCheckpointPlan -Batches $Batches -BatchSize $BatchSize
    $hasPlan = $Checkpoint.PSObject.Properties.Match('plan').Count -gt 0 -and $null -ne $Checkpoint.plan

    if ($Resume -and $hasPlan) {
        $existingPlan = $Checkpoint.plan
        $compatible = (
            [string]$existingPlan.planVersion -eq [string]$currentPlan.planVersion -and
            [int]$existingPlan.batchSize -eq [int]$currentPlan.batchSize -and
            [int]$existingPlan.expectedBatchCount -eq [int]$currentPlan.expectedBatchCount -and
            [string]$existingPlan.sourceFingerprint -eq [string]$currentPlan.sourceFingerprint
        )

        if (-not $compatible) {
            throw ('Resume plan mismatch for {0}/{1}/{2}. Existing plan fingerprint or BatchSize does not match current input; stale numeric batch IDs will not be reused.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
        }
    }
    elseif ($Resume -and -not $hasPlan) {
        $priorSucceeded = @($Checkpoint.batches | Where-Object { $_.status -eq 'Succeeded' }).Count
        if ($priorSucceeded -gt 0) {
            throw ('Resume checkpoint for {0}/{1}/{2} contains prior successful batches but no persisted plan identity. Start the family without -Resume so stale numeric batch IDs are not reused.' -f $Checkpoint.stage, $Checkpoint.section, $Checkpoint.family)
        }

        $Checkpoint.batches = @()
    }
    elseif (-not $Resume) {
        $Checkpoint.batches = @()
    }

    if ($Checkpoint.PSObject.Properties.Match('plan').Count -eq 0) {
        $Checkpoint | Add-Member -MemberType NoteProperty -Name plan -Value $currentPlan
    }
    else {
        $Checkpoint.plan = $currentPlan
    }

    return $Checkpoint
}

function Complete-CollectorCheckpointPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Checkpoint
    )

    if ($Checkpoint.PSObject.Properties.Match('plan').Count -eq 0 -or $null -eq $Checkpoint.plan) {
        return $Checkpoint
    }

    $isComplete = $true
    foreach ($plannedBatch in @($Checkpoint.plan.batches)) {
        $existingBatch = Get-CollectorCheckpointBatch -Checkpoint $Checkpoint -BatchId ([string]$plannedBatch.batchId)
        if (-not $existingBatch -or [string]$existingBatch.status -ne 'Succeeded' -or [string]::IsNullOrWhiteSpace([string]$existingBatch.artifactPath) -or -not (Test-Path -LiteralPath $existingBatch.artifactPath)) {
            $isComplete = $false
            break
        }
    }

    if (@($Checkpoint.plan.batches).Count -ne [int]$Checkpoint.plan.expectedBatchCount -or @($Checkpoint.batches).Count -ne [int]$Checkpoint.plan.expectedBatchCount) {
        $isComplete = $false
    }

    $Checkpoint.plan.completed = [bool]$isComplete
    return $Checkpoint
}

function New-CollectorCheckpointDocument {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs and returns an in-memory checkpoint document.')]
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
        plan = $null
        batches = @()
    }
}

function Invoke-CollectorAtomicFileReplace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        [System.IO.File]::Replace($SourcePath, $DestinationPath, $BackupPath, $true)
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
    if ($null -eq $checkpoint) {
        throw ('Checkpoint identity mismatch at {0}: checkpoint document is null.' -f $checkpointPath)
    }

    $expectedIdentity = @{
        runId = $RunId
        stage = $Stage
        section = $Section
        family = $Family
    }
    foreach ($identityName in @('runId', 'stage', 'section', 'family')) {
        if ($checkpoint.PSObject.Properties.Match($identityName).Count -eq 0) {
            throw ('Checkpoint identity mismatch at {0}: required identity property {1} is missing.' -f $checkpointPath, $identityName)
        }

        $actualValue = [string]$checkpoint.$identityName
        $expectedValue = [string]$expectedIdentity[$identityName]
        if ($actualValue -ne $expectedValue) {
            throw ('Checkpoint identity mismatch at {0}: expected {1}={2}; found {3}.' -f $checkpointPath, $identityName, $expectedValue, $actualValue)
        }
    }

    if (-not $checkpoint.batches) {
        $checkpoint | Add-Member -MemberType NoteProperty -Name batches -Value @() -Force
    }
    if ($checkpoint.PSObject.Properties.Match('plan').Count -eq 0) {
        $checkpoint | Add-Member -MemberType NoteProperty -Name plan -Value $null
    }

    foreach ($batch in @($checkpoint.batches)) {
        if ($batch -and -not [string]::IsNullOrWhiteSpace([string]$batch.artifactPath)) {
            $batch.artifactPath = Get-CollectorCheckpointCanonicalArtifactPath -RunPath $RunPath -Stage ([string]$checkpoint.stage) -Section ([string]$checkpoint.section) -Family ([string]$checkpoint.family) -BatchId ([string]$batch.batchId)
        }
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
    $checkpointJson = $Checkpoint | ConvertTo-Json -Depth 30
    $uniqueSuffix = [Guid]::NewGuid().ToString('N')
    $fileName = [System.IO.Path]::GetFileName($checkpointPath)
    $tempPath = Join-Path -Path $checkpointDirectory -ChildPath ('.{0}.{1}.tmp' -f $fileName, $uniqueSuffix)
    $backupPath = Join-Path -Path $checkpointDirectory -ChildPath ('.{0}.{1}.bak' -f $fileName, $uniqueSuffix)

    try {
        [System.IO.File]::WriteAllText($tempPath, $checkpointJson, [System.Text.UTF8Encoding]::new($false))
        Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json | Out-Null
        Invoke-CollectorAtomicFileReplace -SourcePath $tempPath -DestinationPath $checkpointPath -BackupPath $backupPath
    }
    finally {
        foreach ($temporaryPath in @($tempPath, $backupPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function mutates only the supplied in-memory checkpoint object; persistence is performed separately by Save-CollectorCheckpoint.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'This private helper intentionally returns the collection of checkpoint files beneath a run.')]
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
    if ($checkpointFiles.Count -eq 0) {
        return $summary
    }

    $runId = ([System.IO.DirectoryInfo]$RunPath).Name
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw ('Cannot determine checkpoint summary run identity from run path: {0}' -f $RunPath)
    }

    $checkpointRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath 'checkpoints'))
    $separatorChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $checkpointRootPrefix = $checkpointRoot.TrimEnd($separatorChars) + [System.IO.Path]::DirectorySeparatorChar

    foreach ($checkpointFile in $checkpointFiles) {
        $checkpointPath = [System.IO.Path]::GetFullPath($checkpointFile.FullName)
        if (-not $checkpointPath.StartsWith($checkpointRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('Checkpoint summary path is outside the canonical checkpoint root: {0}' -f $checkpointPath)
        }

        $relativePath = $checkpointPath.Substring($checkpointRootPrefix.Length)
        $pathParts = @($relativePath -split '[\\/]')
        if ($pathParts.Count -ne 3 -or [System.IO.Path]::GetExtension($pathParts[2]) -ne '.json') {
            throw ('Checkpoint summary path does not match checkpoints/<stage>/<section>/<family>.json: {0}' -f $checkpointPath)
        }

        $stage = [string]$pathParts[0]
        $section = [string]$pathParts[1]
        $family = [System.IO.Path]::GetFileNameWithoutExtension([string]$pathParts[2])
        if ([string]::IsNullOrWhiteSpace($stage) -or [string]::IsNullOrWhiteSpace($section) -or [string]::IsNullOrWhiteSpace($family)) {
            throw ('Checkpoint summary path contains an empty identity component: {0}' -f $checkpointPath)
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage $stage -Section $section -Family $family
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
    'Initialize-CollectorCheckpointPlan',
    'Complete-CollectorCheckpointPlan',
    'Get-CollectorCheckpointSummary'
)