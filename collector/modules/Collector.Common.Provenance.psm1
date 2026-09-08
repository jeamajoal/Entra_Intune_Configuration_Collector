Set-StrictMode -Version Latest

$script:CollectorSnapshotSchemaVersion = '1.0'
$script:CollectorSnapshotIdentityProperties = @('runId', 'stage', 'section', 'family', 'batchId')

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

    foreach ($identityName in $script:CollectorSnapshotIdentityProperties) {
        if ($Snapshot.PSObject.Properties.Match($identityName).Count -eq 0) {
            continue
        }

        if (-not ($Snapshot.$identityName -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Snapshot.$identityName)) {
            return $false
        }
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

        [Parameter(Mandatory = $true)]
        [int]$ItemCount,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    [ordered]@{
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
}

Export-ModuleMember -Function @(
    'Test-CollectorSnapshotSchemaVersion',
    'New-CollectorProvenanceSnapshot'
)
