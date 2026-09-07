Set-StrictMode -Version Latest

$script:CollectorSnapshotSchemaVersion = '1.0'

function Test-CollectorSnapshotSchemaVersion {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot -or $Snapshot.PSObject.Properties.Match('schemaVersion').Count -eq 0) {
        return $false
    }

    return ($Snapshot.schemaVersion -is [string]) -and [string]$Snapshot.schemaVersion -eq $script:CollectorSnapshotSchemaVersion
}

function New-CollectorProvenanceSnapshot {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function constructs and returns an in-memory provenance snapshot; it does not change external state.')]
    param(
        [string]$SchemaVersion = $script:CollectorSnapshotSchemaVersion,

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
