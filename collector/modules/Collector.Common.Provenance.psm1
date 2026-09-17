Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Observation.psm1') -Force -ErrorAction Stop

$script:CollectorSnapshotSchemaVersion = '1.0'
$script:CollectorSnapshotIdentityProperties = @('runId', 'stage', 'section', 'family', 'batchId')
$script:CollectorSnapshotStringProvenanceProperties = @('sourceType', 'sourceName', 'apiVersion')
$script:CollectorPersistedJsonObjectTypeName = 'System.Management.Automation.PSCustomObject'

function Test-CollectorSnapshotSchemaVersion {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot -or $Snapshot.PSObject.Properties.Match('schemaVersion').Count -eq 0) {
        return $false
    }

    if (-not ($Snapshot.schemaVersion -is [string]) -or [string]$Snapshot.schemaVersion -ne $script:CollectorSnapshotSchemaVersion) {
        return $false
    }

    if ($Snapshot.PSObject.Properties.Match('items').Count -eq 0 -or -not ($Snapshot.items -is [System.Array])) {
        return $false
    }

    if ($Snapshot.PSObject.Properties.Match('collectedUtc').Count -eq 0) {
        return $false
    }

    if (-not ($Snapshot.collectedUtc -is [string]) -and -not ($Snapshot.collectedUtc -is [datetime])) {
        return $false
    }

    foreach ($provenancePropertyName in $script:CollectorSnapshotStringProvenanceProperties) {
        if (
            $Snapshot.PSObject.Properties.Match($provenancePropertyName).Count -eq 0 -or
            -not ($Snapshot.$provenancePropertyName -is [string])
        ) {
            return $false
        }
    }

    if (
        $Snapshot.PSObject.Properties.Match('isBeta').Count -eq 0 -or
        -not ($Snapshot.isBeta -is [bool])
    ) {
        return $false
    }

    if ($Snapshot.PSObject.Properties.Match('requestContext').Count -eq 0 -or $null -eq $Snapshot.requestContext) {
        return $false
    }

    if ($Snapshot.requestContext.GetType().FullName -ne $script:CollectorPersistedJsonObjectTypeName) {
        return $false
    }

    foreach ($identityName in $script:CollectorSnapshotIdentityProperties) {
        if ($Snapshot.PSObject.Properties.Match($identityName).Count -eq 0) {
            continue
        }

        if (-not ($Snapshot.$identityName -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Snapshot.$identityName)) {
            return $false
        }
    }

    $hasObservation = $Snapshot.PSObject.Properties.Match('observation').Count -gt 0
    $hasEvidenceState = $Snapshot.PSObject.Properties.Match('evidenceState').Count -gt 0
    if ($hasObservation -xor $hasEvidenceState) {
        return $false
    }
    if ($hasObservation -and -not (Test-CollectorBoundedEvidenceContract -Observation $Snapshot.observation -EvidenceState $Snapshot.evidenceState)) {
        return $false
    }

    return $true
}

function New-CollectorProvenanceSnapshot {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function constructs and returns an in-memory provenance snapshot; it does not change external state.')]
    param(
        [string]$SchemaVersion = '1.0',

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$BatchId,

        [Parameter(Mandatory = $true)]
        [string]$SourceType,

        [Parameter(Mandatory = $true)]
        [string]$SourceName,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion,

        [bool]$IsBeta = $false,

        [hashtable]$RequestContext = @{},

        [AllowNull()]
        [object]$Observation,

        [AllowNull()]
        [object]$EvidenceState,

        [Parameter(Mandatory = $true)]
        [int]$ItemCount,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    if (($null -eq $Observation) -xor ($null -eq $EvidenceState)) {
        throw 'Observation and EvidenceState must be supplied together for bounded evidence.'
    }
    if ($null -ne $Observation -and -not (Test-CollectorBoundedEvidenceContract -Observation $Observation -EvidenceState $EvidenceState)) {
        throw 'Observation and EvidenceState do not form a valid bounded-evidence contract.'
    }

    $snapshot = [ordered]@{
        schemaVersion = $SchemaVersion
        runId = $RunId
        stage = $Stage
        section = $Section
        family = $Family
        batchId = $BatchId
        collectedUtc = (Get-Date).ToUniversalTime().ToString('o')
        sourceType = $SourceType
        sourceName = $SourceName
        apiVersion = $ApiVersion
        isBeta = [bool]$IsBeta
        requestContext = if ($RequestContext) { $RequestContext } else { @{} }
        itemCount = $ItemCount
        items = @($Items)
    }

    if ($null -ne $Observation) {
        $snapshot.observation = $Observation
        $snapshot.evidenceState = $EvidenceState
    }

    return $snapshot
}

Export-ModuleMember -Function @(
    'Test-CollectorSnapshotSchemaVersion',
    'New-CollectorProvenanceSnapshot'
)
