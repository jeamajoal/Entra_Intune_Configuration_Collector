Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop

$script:SupportedStages = @('Stage1', 'Stage2', 'Stage3')
$script:SupportedSections = @('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo')
$script:GraphBackedSections = @('entra-apps', 'entra-pim', 'intune-core')

function Resolve-CollectorStages {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'This exported selector resolves a collection of requested stages and its established public name is intentionally plural.')]
    param(
        [string[]]$Stages = @('All')
    )

    if (-not $Stages -or $Stages.Count -eq 0) {
        return @($script:SupportedStages)
    }

    $supportedSelections = @('All') + @($script:SupportedStages)
    $invalidStages = @($Stages | Where-Object { $supportedSelections -notcontains $_ })
    if ($invalidStages.Count -gt 0) {
        throw ('Unsupported stage selection(s): {0}. Supported values are All, Stage1, Stage2, Stage3.' -f ($invalidStages -join ', '))
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'This exported selector resolves a collection of requested sections and its established public name is intentionally plural.')]
    param(
        [string[]]$Sections
    )

    if (-not $Sections -or $Sections.Count -eq 0) {
        return @($script:SupportedSections)
    }

    $invalidSections = @($Sections | Where-Object { $script:SupportedSections -notcontains $_ })
    if ($invalidSections.Count -gt 0) {
        throw ('Unsupported section selection(s): {0}. Supported values are entra-apps, entra-pim, intune-core, onprem-ad-gpo.' -f ($invalidSections -join ', '))
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

function Assert-CollectorGraphTokenForSections {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The assertion evaluates the complete selected section set, so the established plural noun reflects the input contract.')]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$GraphToken,

        [Parameter(Mandatory = $true)]
        [string[]]$Sections
    )

    $selectedGraphSections = @($Sections | Where-Object { $script:GraphBackedSections -contains $_ })
    if ($selectedGraphSections.Count -gt 0 -and [string]::IsNullOrWhiteSpace($GraphToken)) {
        throw ('GraphToken is required when Graph-backed sections are selected: {0}.' -f ($selectedGraphSections -join ', '))
    }
}

function New-CollectorInvocationParameters {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs and returns an in-memory invocation parameter object.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Parameters describes the intentionally multi-property invocation parameter object.')]
    param(
        [AllowNull()]
        [AllowEmptyString()]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs and returns an in-memory manifest object.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs and returns an in-memory invocation record.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-CollectorRun is the explicit execution entry point; WhatIf semantics are not part of the collector contract and adding them would change public behavior.')]
    param(
        [AllowNull()]
        [AllowEmptyString()]
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

    if ($ReprocessFailedOnly -and -not $Resume) {
        throw 'ReprocessFailedOnly requires Resume.'
    }
    if ($BatchSize -le 0) {
        throw 'BatchSize must be greater than zero.'
    }
    if ($MaxRetries -lt 0) {
        throw 'MaxRetries must be greater than or equal to zero.'
    }
    if ([double]::IsNaN($BaseBackoffSeconds) -or [double]::IsInfinity($BaseBackoffSeconds) -or $BaseBackoffSeconds -lt 0) {
        throw 'BaseBackoffSeconds must be a finite number greater than or equal to zero.'
    }
    if ([double]::IsNaN($MaxBackoffSeconds) -or [double]::IsInfinity($MaxBackoffSeconds) -or $MaxBackoffSeconds -lt 0) {
        throw 'MaxBackoffSeconds must be a finite number greater than or equal to zero.'
    }
    if ($ThrottleMilliseconds -lt 0) {
        throw 'ThrottleMilliseconds must be greater than or equal to zero.'
    }

    $resolvedStages = Resolve-CollectorStages -Stages $Stages
    $resolvedSections = Resolve-CollectorSections -Sections $Sections
    Assert-CollectorGraphTokenForSections -GraphToken $GraphToken -Sections $resolvedSections
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

            $resultsToPersist = @()
            if ($context.PartialStageResults.Count -gt 0) {
                $resultsToPersist = @($context.PartialStageResults)
            }
            else {
                $resultsToPersist = @($stageResults)
            }

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
        $caughtError = $_

        foreach ($stageResult in @($context.PartialStageResults)) {
            Add-CollectorManifestStageResult -Manifest $manifest -Invocation $invocation -StageResult $stageResult
        }
        $context.PartialStageResults.Clear()

        $failure = [pscustomobject]@{
            stage = if ($caughtError.Exception.Data['CollectorStage']) { [string]$caughtError.Exception.Data['CollectorStage'] } else { 'orchestration' }
            section = if ($caughtError.Exception.Data['CollectorSection']) { [string]$caughtError.Exception.Data['CollectorSection'] } else { 'all' }
            family = if ($caughtError.Exception.Data['CollectorFamily']) { [string]$caughtError.Exception.Data['CollectorFamily'] } else { 'all' }
            error = $caughtError.Exception.Message
        }

        $invocation.failures += $failure
        $manifest.failures += $failure
        $invocation.status = 'Failed'
        $manifest.status = 'Failed'

        try {
            $manifest.checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $run.runPath)
        }
        catch {
            Write-Verbose ('Checkpoint summary refresh failed while preserving terminal collector failure state: {0}' -f $_.Exception.Message)
        }

        throw $caughtError
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
