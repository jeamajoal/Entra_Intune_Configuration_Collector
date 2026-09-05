Set-StrictMode -Version Latest

$retryModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Retry.psm1'
Import-Module -Name $retryModulePath -Force -ErrorAction Stop

function Get-CollectorGraphHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GraphToken
    )

    return @{
        Authorization = 'Bearer {0}' -f $GraphToken
        Accept = 'application/json'
    }
}

function Resolve-CollectorGraphUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [switch]$AbsoluteUri
    )

    if ($AbsoluteUri -or $Endpoint -match '^https?://') {
        return $Endpoint
    }

    return 'https://graph.microsoft.com{0}' -f $Endpoint
}

function Invoke-CollectorGraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GraphToken,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [switch]$AbsoluteUri,

        [int]$MaxRetries = 5,

        [double]$BaseBackoffSeconds = 2,

        [double]$MaxBackoffSeconds = 30,

        [int]$ThrottleMilliseconds = 100
    )

    $uri = Resolve-CollectorGraphUri -Endpoint $Endpoint -AbsoluteUri:$AbsoluteUri
    $headers = Get-CollectorGraphHeader -GraphToken $GraphToken
    $effectiveThrottleMilliseconds = $ThrottleMilliseconds

    $invokeRequest = {
        if ($effectiveThrottleMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $effectiveThrottleMilliseconds
        }

        $requestParams = @{
            Uri = $uri
            Method = 'GET'
            Headers = $headers
            ErrorAction = 'Stop'
        }

        Invoke-RestMethod @requestParams
    }

    Invoke-CollectorRetry -ScriptBlock $invokeRequest -MaxRetries $MaxRetries -BaseBackoffSeconds $BaseBackoffSeconds -MaxBackoffSeconds $MaxBackoffSeconds
}

function Invoke-CollectorGraphCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GraphToken,

        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [int]$MaxRetries = 5,

        [double]$BaseBackoffSeconds = 2,

        [double]$MaxBackoffSeconds = 30,

        [int]$ThrottleMilliseconds = 100
    )

    $items = @()
    $currentEndpoint = $Endpoint
    $isAbsoluteUri = $false

    while ($currentEndpoint) {
        $response = Invoke-CollectorGraphRequest -GraphToken $GraphToken -Endpoint $currentEndpoint -AbsoluteUri:$isAbsoluteUri -MaxRetries $MaxRetries -BaseBackoffSeconds $BaseBackoffSeconds -MaxBackoffSeconds $MaxBackoffSeconds -ThrottleMilliseconds $ThrottleMilliseconds

        if ($null -eq $response) {
            break
        }

        if ($response -is [System.Array]) {
            $items += @($response)
        }
        elseif ($response.PSObject.Properties.Match('value').Count -gt 0) {
            $items += @($response.value)
        }
        else {
            $items += ,$response
        }

        $nextLink = $null
        if ($response.PSObject.Properties.Match('@odata.nextLink').Count -gt 0) {
            $nextLink = $response.'@odata.nextLink'
        }

        if ($nextLink) {
            $currentEndpoint = [string]$nextLink
            $isAbsoluteUri = $true
        }
        else {
            $currentEndpoint = $null
        }
    }

    return $items
}

Export-ModuleMember -Function @(
    'Invoke-CollectorGraphRequest',
    'Invoke-CollectorGraphCollection'
)
