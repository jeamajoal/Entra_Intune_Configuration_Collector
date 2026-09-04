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

function New-CollectorRunManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunId,

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
        schemaVersion = '1.0'
        runId = $RunId
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        completedUtc = $null
        status = 'InProgress'
        parameters = [pscustomobject]@{
            graphTokenSupplied = [bool](-not [string]::IsNullOrWhiteSpace($GraphToken))
            outputRoot = $OutputRoot
            stages = $Stages
            sections = $Sections
            resume = [bool]$RuntimeOptions.Resume
            reprocessFailedOnly = [bool]$RuntimeOptions.ReprocessFailedOnly
            force = [bool]$RuntimeOptions.Force
            batchSize = [int]$RuntimeOptions.BatchSize
            maxRetries = [int]$RuntimeOptions.MaxRetries
            baseBackoffSeconds = [double]$RuntimeOptions.BaseBackoffSeconds
            maxBackoffSeconds = [double]$RuntimeOptions.MaxBackoffSeconds
            throttleMilliseconds = [int]$RuntimeOptions.ThrottleMilliseconds
        }
        stageResults = @()
        checkpointSummary = @()
        failures = @()
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
    }

    $manifest = New-CollectorRunManifest -RunId $run.runId -GraphToken $GraphToken -OutputRoot $OutputRoot -Stages $resolvedStages -Sections $resolvedSections -RuntimeOptions $context
    $manifestPath = Save-CollectorManifest -RunPath $run.runPath -Manifest $manifest

    try {
        foreach ($stage in $resolvedStages) {
            $stageResults = @()

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

            $manifest.stageResults += $stageResults

            foreach ($stageResult in $stageResults) {
                if ($stageResult.failedBatches -gt 0 -and $stageResult.errors) {
                    foreach ($errorMessage in @($stageResult.errors)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$errorMessage)) {
                            $manifest.failures += [pscustomobject]@{
                                stage = $stageResult.stage
                                section = $stageResult.section
                                family = $stageResult.family
                                error = [string]$errorMessage
                            }
                        }
                    }
                }
            }
        }

        $manifest.checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $run.runPath)
        $manifest.status = if ($manifest.failures.Count -gt 0) { 'CompletedWithErrors' } else { 'Completed' }
    }
    catch {
        $manifest.failures += [pscustomobject]@{
            stage = 'orchestration'
            section = 'all'
            family = 'all'
            error = $_.Exception.Message
        }

        $manifest.checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $run.runPath)
        $manifest.status = 'Failed'
        throw
    }
    finally {
        $manifest.completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $manifestPath = Save-CollectorManifest -RunPath $run.runPath -Manifest $manifest
    }

    [pscustomobject]@{
        runId = $run.runId
        runPath = $run.runPath
        manifestPath = $manifestPath
        status = $manifest.status
        stageResults = $manifest.stageResults
        checkpointSummary = $manifest.checkpointSummary
        failures = $manifest.failures
    }
}

Export-ModuleMember -Function @(
    'Resolve-CollectorStages',
    'Resolve-CollectorSections',
    'Start-CollectorRun'
)
