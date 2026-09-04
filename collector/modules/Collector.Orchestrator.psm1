Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop

$script:SupportedStages = @('Stage1', 'Stage2', 'Stage3')
$script:SupportedSections = @('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo')

function Resolve-CollectorStages {
    [CmdletBinding()]
    param(
        [string[]]$Stages = @('All')
    )

    if (-not $Stages -or $Stages.Count -eq 0) {
        return @($script:SupportedStages)
    }

    if ($Stages -contains 'All') {
        return @($script:SupportedStages)
    }

    $resolved = @()
    foreach ($supportedStage in $script:SupportedStages) {
        if ($Stages -contains $supportedStage) {
            $resolved += $supportedStage
        }
    }

    if ($resolved.Count -eq 0) {
        throw 'No valid stage selection resolved. Supported values are All, Stage1, Stage2, Stage3.'
    }

    return $resolved
}

function Resolve-CollectorSections {
    [CmdletBinding()]
    param(
        [string[]]$Sections
    )

    if (-not $Sections -or $Sections.Count -eq 0) {
        return @($script:SupportedSections)
    }

    $resolved = @()
    foreach ($supportedSection in $script:SupportedSections) {
        if ($Sections -contains $supportedSection) {
            $resolved += $supportedSection
        }
    }

    if ($resolved.Count -eq 0) {
        throw 'No valid section selection resolved. Supported values are entra-apps, entra-pim, intune-core, onprem-ad-gpo.'
    }

    return $resolved
}

function New-CollectorInvocationParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GraphToken,

        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Stages,

        [Parameter(Mandatory = $true)]
        [string[]]$Sections,

        [Parameter(Mandatory = $true)]
        [hashtable]$RuntimeOptions
    )

    [pscustomobject]@{
        graphTokenSupplied = [bool](-not [string]::IsNullOrWhiteSpace($GraphToken))
        outputRoot = $OutputRoot
        stages = @($Stages)
        sections = @($Sections)
        resume = [bool]$RuntimeOptions.Resume
        reprocessFailedOnly = [bool]$RuntimeOptions.ReprocessFailedOnly
        force = [bool]$RuntimeOptions.Force
        batchSize = [int]$RuntimeOptions.BatchSize
        maxRetries = [int]$RuntimeOptions.MaxRetries
        baseBackoffSeconds = [double]$RuntimeOptions.BaseBackoffSeconds
        maxBackoffSeconds = [double]$RuntimeOptions.MaxBackoffSeconds
        throttleMilliseconds = [int]$RuntimeOptions.ThrottleMilliseconds
    }
}

function New-CollectorRunManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Parameters
    )

    [pscustomobject]@{
        schemaVersion = '1.1'
        runId = $RunId
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        completedUtc = $null
        status = 'InProgress'
        parameters = $Parameters
        stageResults = @()
        checkpointSummary = @()
        failures = @()
        invocations = @()
    }
}

function Get-CollectorRunManifestForInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Parameters,

        [switch]$Resume
    )

    if (-not $Resume) {
        return New-CollectorRunManifest -RunId $RunId -Parameters $Parameters
    }

    $manifestPath = Get-CollectorManifestPath -RunPath $RunPath
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw ('Resume requested for run {0}, but its run manifest is missing: {1}' -f $RunId, $manifestPath)
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw ('Resume requested for run {0}, but its run manifest is unreadable: {1}' -f $RunId, $_.Exception.Message)
    }

    if ([string]$manifest.runId -ne $RunId) {
        throw ('Resume manifest runId mismatch. Expected {0}; found {1}.' -f $RunId, [string]$manifest.runId)
    }

    foreach ($propertyName in @('stageResults', 'checkpointSummary', 'failures')) {
        if ($manifest.PSObject.Properties.Match($propertyName).Count -eq 0 -or $null -eq $manifest.$propertyName) {
            $manifest | Add-Member -MemberType NoteProperty -Name $propertyName -Value @() -Force
        }
    }

    if ($manifest.PSObject.Properties.Match('invocations').Count -eq 0 -or $null -eq $manifest.invocations) {
        $legacyInvocation = [pscustomobject]@{
            startedUtc = [string]$manifest.startedUtc
            completedUtc = $manifest.completedUtc
            status = [string]$manifest.status
            parameters = $manifest.parameters
            stageResults = @($manifest.stageResults)
            failures = @($manifest.failures)
        }
        $manifest | Add-Member -MemberType NoteProperty -Name invocations -Value @($legacyInvocation) -Force
    }

    $manifest.schemaVersion = '1.1'
    return $manifest
}

function New-CollectorInvocationRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Parameters
    )

    [pscustomobject]@{
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        completedUtc = $null
        status = 'InProgress'
        parameters = $Parameters
        stageResults = @()
        failures = @()
    }
}

function Add-CollectorManifestStageResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Manifest,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Invocation,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$StageResult
    )

    $Invocation.stageResults += $StageResult
    $Manifest.stageResults += $StageResult

    if ($StageResult.failedBatches -gt 0 -and $StageResult.errors) {
        foreach ($errorMessage in @($StageResult.errors)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$errorMessage)) {
                $failure = [pscustomobject]@{
                    stage = $StageResult.stage
                    section = $StageResult.section
                    family = $StageResult.family
                    error = [string]$errorMessage
                }
                $Invocation.failures += $failure
                $Manifest.failures += $failure
            }
        }
    }
}

function Start-CollectorRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GraphToken,

        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [string[]]$Stages = @('All'),

        [string[]]$Sections,

        [switch]$Resume,

        [switch]$ReprocessFailedOnly,

        [switch]$Force,

        [int]$BatchSize = 100,

        [int]$MaxRetries = 5,

        [double]$BaseBackoffSeconds = 2,

        [double]$MaxBackoffSeconds = 30,

        [int]$ThrottleMilliseconds = 100
    )

    $resolvedStages = Resolve-CollectorStages -Stages $Stages
    $resolvedSections = Resolve-CollectorSections -Sections $Sections
    $run = Resolve-CollectorRun -OutputRoot $OutputRoot -Resume:$Resume

    $context = @{
        RunId = $run.runId
        RunPath = $run.runPath
        GraphToken = $GraphToken
        Resume = [bool]$Resume
        ReprocessFailedOnly = [bool]$ReprocessFailedOnly
        Force = [bool]$Force
        BatchSize = $BatchSize
        MaxRetries = $MaxRetries
        BaseBackoffSeconds = $BaseBackoffSeconds
        MaxBackoffSeconds = $MaxBackoffSeconds
        ThrottleMilliseconds = $ThrottleMilliseconds
        PartialStageResults = [System.Collections.Generic.List[object]]::new()
    }

    $parameters = New-CollectorInvocationParameters -GraphToken $GraphToken -OutputRoot $OutputRoot -Stages $resolvedStages -Sections $resolvedSections -RuntimeOptions $context
    $manifest = Get-CollectorRunManifestForInvocation -RunPath $run.runPath -RunId $run.runId -Parameters $parameters -Resume:$Resume
    $invocation = New-CollectorInvocationRecord -Parameters $parameters

    $manifest.parameters = $parameters
    $manifest.status = 'InProgress'
    $manifest.completedUtc = $null
    $manifest.invocations += $invocation
    $manifestPath = Save-CollectorManifest -RunPath $run.runPath -Manifest $manifest

    try {
        foreach ($stage in $resolvedStages) {
            $stageResults = @()
            $context.PartialStageResults.Clear()

            switch ($stage) {
                'Stage1' {
                    $stageResults = @(Invoke-CollectorStage1 -Context $context -Sections $resolvedSections)
                }

                'Stage2' {
                    $stageResults = @(Invoke-CollectorStage2 -Context $context -Sections $resolvedSections)
                }

                'Stage3' {
                    $stageResults = @(Invoke-CollectorStage3 -Context $context -Sections $resolvedSections)
                }
            }

            $resultsToPersist = if ($context.PartialStageResults.Count -gt 0) { @($context.PartialStageResults) } else { @($stageResults) }
            foreach ($stageResult in $resultsToPersist) {
                Add-CollectorManifestStageResult -Manifest $manifest -Invocation $invocation -StageResult $stageResult
            }

            if ($resultsToPersist.Count -gt 0) {
                Save-CollectorManifest -RunPath $run.runPath -Manifest $manifest | Out-Null
            }
        }

        $manifest.checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $run.runPath)
        $invocation.status = if ($invocation.failures.Count -gt 0) { 'CompletedWithErrors' } else { 'Completed' }
        $manifest.status = $invocation.status
    }
    catch {
        foreach ($stageResult in @($context.PartialStageResults)) {
            Add-CollectorManifestStageResult -Manifest $manifest -Invocation $invocation -StageResult $stageResult
        }
        $context.PartialStageResults.Clear()

        $failure = [pscustomobject]@{
            stage = if ($_.Exception.Data['CollectorStage']) { [string]$_.Exception.Data['CollectorStage'] } else { 'orchestration' }
            section = if ($_.Exception.Data['CollectorSection']) { [string]$_.Exception.Data['CollectorSection'] } else { 'all' }
            family = if ($_.Exception.Data['CollectorFamily']) { [string]$_.Exception.Data['CollectorFamily'] } else { 'all' }
            error = $_.Exception.Message
        }

        $invocation.failures += $failure
        $manifest.failures += $failure
        $manifest.checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $run.runPath)
        $invocation.status = 'Failed'
        $manifest.status = 'Failed'
        throw
    }
    finally {
        $completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $invocation.completedUtc = $completedUtc
        $manifest.completedUtc = $completedUtc
        $manifestPath = Save-CollectorManifest -RunPath $run.runPath -Manifest $manifest
    }

    [pscustomobject]@{
        runId = $run.runId
        runPath = $run.runPath
        manifestPath = $manifestPath
        status = $invocation.status
        stageResults = @($invocation.stageResults)
        checkpointSummary = @($manifest.checkpointSummary)
        failures = @($invocation.failures)
    }
}

Export-ModuleMember -Function @(
    'Resolve-CollectorStages',
    'Resolve-CollectorSections',
    'Start-CollectorRun'
)
