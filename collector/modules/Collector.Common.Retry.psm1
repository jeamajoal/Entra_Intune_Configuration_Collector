Set-StrictMode -Version Latest

function Get-CollectorRetryMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    $message = [string]$ErrorRecord

    $statusCode = $null
    $retryAfterSeconds = $null
    $isTimeout = $false

    if ($exception -is [System.TimeoutException]) {
        $isTimeout = $true
    }

    if ($message -match '(?i)timed?\s*out|timeout') {
        $isTimeout = $true
    }

    if ($exception -and $exception.PSObject.Properties.Match('StatusCode').Count -gt 0) {
        try {
            $statusCode = [int]$exception.StatusCode
        }
        catch {
            $statusCode = $null
        }
    }

    if ($exception -and $exception.PSObject.Properties.Match('Response').Count -gt 0 -and $exception.Response) {
        $response = $exception.Response

        if (-not $statusCode -and $response.PSObject.Properties.Match('StatusCode').Count -gt 0) {
            try {
                $statusCode = [int]$response.StatusCode
            }
            catch {
                $statusCode = $null
            }
        }

        if ($response.PSObject.Properties.Match('Headers').Count -gt 0 -and $response.Headers) {
            try {
                $retryAfterHeader = $response.Headers['Retry-After']
                if ($retryAfterHeader) {
                    $firstValue = if ($retryAfterHeader -is [System.Array]) { $retryAfterHeader[0] } else { $retryAfterHeader }
                    $parsedRetryAfter = 0
                    if ([int]::TryParse([string]$firstValue, [ref]$parsedRetryAfter)) {
                        $retryAfterSeconds = $parsedRetryAfter
                    }
                    else {
                        $retryAfterDate = [datetimeoffset]::MinValue
                        if ([datetimeoffset]::TryParse([string]$firstValue, [ref]$retryAfterDate)) {
                            $delaySeconds = [int][Math]::Ceiling(($retryAfterDate.UtcDateTime - (Get-Date).ToUniversalTime()).TotalSeconds)
                            if ($delaySeconds -gt 0) {
                                $retryAfterSeconds = $delaySeconds
                            }
                        }
                    }
                }
            }
            catch {
                $retryAfterSeconds = $null
            }
        }
    }

    if (-not $statusCode -and $message -match '\b(429|500|502|503|504)\b') {
        $statusCode = [int]$Matches[1]
    }

    [pscustomobject]@{
        StatusCode = $statusCode
        RetryAfterSeconds = $retryAfterSeconds
        IsTimeout = $isTimeout
    }
}

function Get-CollectorRetryDelaySeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Attempt,

        [Parameter(Mandatory = $true)]
        [double]$BaseBackoffSeconds,

        [Parameter(Mandatory = $true)]
        [double]$MaxBackoffSeconds
    )

    if ($MaxBackoffSeconds -le 0) {
        return 0
    }

    $effectiveBase = [Math]::Max($BaseBackoffSeconds, 0)
    $delayWithoutJitter = [Math]::Min($MaxBackoffSeconds, $effectiveBase * [Math]::Pow(2, $Attempt - 1))

    $jitterMaxMs = [Math]::Max(1, [int]([Math]::Round($effectiveBase * 1000)))
    $jitterMs = Get-Random -Minimum 0 -Maximum $jitterMaxMs
    $delayWithJitter = $delayWithoutJitter + ($jitterMs / 1000.0)

    return [Math]::Min($MaxBackoffSeconds, $delayWithJitter)
}

function Invoke-CollectorRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [int]$MaxRetries = 5,

        [double]$BaseBackoffSeconds = 2,

        [double]$MaxBackoffSeconds = 30,

        [int[]]$TransientStatusCodes = @(429, 500, 502, 503, 504),

        [scriptblock]$OnRetry
    )

    if ($MaxRetries -lt 0) {
        throw 'MaxRetries must be greater than or equal to zero.'
    }

    $totalAttempts = $MaxRetries + 1

    for ($attempt = 1; $attempt -le $totalAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $retryMetadata = Get-CollectorRetryMetadata -ErrorRecord $_
            $isTransientStatus = $retryMetadata.StatusCode -and ($TransientStatusCodes -contains [int]$retryMetadata.StatusCode)
            $shouldRetry = $retryMetadata.IsTimeout -or $isTransientStatus
            $hasRetryBudget = $attempt -lt $totalAttempts

            if (-not $shouldRetry -or -not $hasRetryBudget) {
                throw
            }

            if ($retryMetadata.RetryAfterSeconds -and $retryMetadata.RetryAfterSeconds -gt 0) {
                $delaySeconds = [Math]::Min($MaxBackoffSeconds, [double]$retryMetadata.RetryAfterSeconds)
            }
            else {
                $delaySeconds = Get-CollectorRetryDelaySeconds -Attempt $attempt -BaseBackoffSeconds $BaseBackoffSeconds -MaxBackoffSeconds $MaxBackoffSeconds
            }

            if ($OnRetry) {
                & $OnRetry -ArgumentList @($attempt, $retryMetadata, $delaySeconds, $_)
            }

            if ($delaySeconds -gt 0) {
                Start-Sleep -Milliseconds ([int]([Math]::Ceiling($delaySeconds * 1000)))
            }
        }
    }
}

Export-ModuleMember -Function Invoke-CollectorRetry, Get-CollectorRetryMetadata
