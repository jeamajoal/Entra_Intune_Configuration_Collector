Set-StrictMode -Version Latest

function New-CollectorProvenanceSnapshot {
    [CmdletBinding()]
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

Export-ModuleMember -Function New-CollectorProvenanceSnapshot
