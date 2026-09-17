Set-StrictMode -Version Latest

$script:GraphAuthStateTypeName = 'Collector.GraphAuthState'

function New-CollectorGraphAuthState {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs an in-memory authentication state object.')]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$GraphToken,

        [AllowNull()]
        [scriptblock]$GraphTokenProvider
    )

    $state = [pscustomobject]@{
        currentToken = if ([string]::IsNullOrWhiteSpace($GraphToken)) { $null } else { $GraphToken }
        tokenProvider = $GraphTokenProvider
    }
    $state.PSObject.TypeNames.Insert(0, $script:GraphAuthStateTypeName)
    return $state
}

function Test-CollectorGraphAuthState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$AuthInput
    )

    return (
        $null -ne $AuthInput -and
        $AuthInput.PSObject.TypeNames -contains $script:GraphAuthStateTypeName
    )
}

function Test-CollectorGraphRefreshAvailable {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$AuthInput
    )

    if (-not (Test-CollectorGraphAuthState -AuthInput $AuthInput)) {
        return $false
    }

    return (
        $AuthInput.PSObject.Properties.Match('tokenProvider').Count -gt 0 -and
        $AuthInput.tokenProvider -is [scriptblock]
    )
}

function Invoke-CollectorGraphTokenProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$GraphTokenProvider,

        [Parameter(Mandatory = $true)]
        [bool]$ForceRefresh
    )

    try {
        $providerOutput = @(& $GraphTokenProvider $ForceRefresh)
    }
    catch {
        throw 'GraphTokenProvider failed while acquiring a Microsoft Graph access token.'
    }

    if (
        $providerOutput.Count -ne 1 -or
        -not ($providerOutput[0] -is [string]) -or
        [string]::IsNullOrWhiteSpace([string]$providerOutput[0])
    ) {
        throw 'GraphTokenProvider must return exactly one non-empty token string.'
    }

    return [string]$providerOutput[0]
}

function Get-CollectorGraphAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$AuthInput,

        [switch]$ForceRefresh
    )

    if ($AuthInput -is [string]) {
        if ($ForceRefresh) {
            throw 'Graph token refresh was requested, but the supplied authentication input is a static token.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$AuthInput)) {
            throw 'Microsoft Graph access token is empty.'
        }
        return [string]$AuthInput
    }

    if (-not (Test-CollectorGraphAuthState -AuthInput $AuthInput)) {
        throw 'Unsupported Microsoft Graph authentication input. Expected a token string or collector Graph auth state.'
    }

    $tokenProvider = if (
        $AuthInput.PSObject.Properties.Match('tokenProvider').Count -gt 0 -and
        $AuthInput.tokenProvider -is [scriptblock]
    ) {
        [scriptblock]$AuthInput.tokenProvider
    }
    else {
        $null
    }

    if ($ForceRefresh) {
        if ($null -eq $tokenProvider) {
            throw 'Graph token refresh was requested, but no GraphTokenProvider is available.'
        }

        $replacementToken = Invoke-CollectorGraphTokenProvider -GraphTokenProvider $tokenProvider -ForceRefresh $true
        $AuthInput.currentToken = $replacementToken
        return $replacementToken
    }

    if (
        $AuthInput.PSObject.Properties.Match('currentToken').Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$AuthInput.currentToken)
    ) {
        return [string]$AuthInput.currentToken
    }

    if ($null -eq $tokenProvider) {
        throw 'No Microsoft Graph access token is available.'
    }

    $initialToken = Invoke-CollectorGraphTokenProvider -GraphTokenProvider $tokenProvider -ForceRefresh $false
    $AuthInput.currentToken = $initialToken
    return $initialToken
}

Export-ModuleMember -Function @(
    'New-CollectorGraphAuthState',
    'Get-CollectorGraphAccessToken',
    'Test-CollectorGraphRefreshAvailable'
)
