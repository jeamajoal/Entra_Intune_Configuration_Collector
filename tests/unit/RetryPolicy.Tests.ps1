BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Retry.psm1') -Force -ErrorAction Stop

    function Get-RetryErrorRecord {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Response,

            [string]$Message = 'HTTP 429 throttle'
        )

        $exception = [System.Exception]::new($Message)
        $exception | Add-Member -MemberType NoteProperty -Name Response -Value $Response -Force
        [System.Management.Automation.ErrorRecord]::new(
            $exception,
            'CollectorRetryTest',
            [System.Management.Automation.ErrorCategory]::LimitsExceeded,
            $null
        )
    }
}

Describe 'Retry policy behavior' {
    It 'retries transient failures and eventually succeeds' {
        $script:attemptCount = 0

        $result = Invoke-CollectorRetry -ScriptBlock {
            $script:attemptCount++
            if ($script:attemptCount -lt 3) {
                throw 'HTTP 429 throttle'
            }

            return 'ok'
        } -MaxRetries 5 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0

        if ($result -ne 'ok') {
            throw ('Expected retry result ok but found ' + [string]$result + '.')
        }

        if ($script:attemptCount -ne 3) {
            throw ('Expected retry attempts 3 but found ' + $script:attemptCount + '.')
        }
    }

    It 'does not retry non-transient failures' {
        $script:attemptCount = 0

        $threw = $false
        try {
            Invoke-CollectorRetry -ScriptBlock {
                $script:attemptCount++
                throw 'HTTP 400 bad request'
            } -MaxRetries 5 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0
        }
        catch {
            $threw = $true
        }

        if (-not $threw) {
            throw 'Expected non-transient failure to throw without retry success.'
        }

        if ($script:attemptCount -ne 1) {
            throw ('Expected one attempt for non-transient failure but found ' + $script:attemptCount + '.')
        }
    }

    It 'retries timeout exceptions' {
        $script:attemptCount = 0

        $result = Invoke-CollectorRetry -ScriptBlock {
            $script:attemptCount++
            if ($script:attemptCount -lt 2) {
                throw ([System.TimeoutException]::new('operation timed out'))
            }

            return 'recovered'
        } -MaxRetries 3 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0

        if ($result -ne 'recovered') {
            throw ('Expected retry result recovered but found ' + [string]$result + '.')
        }

        if ($script:attemptCount -ne 2) {
            throw ('Expected retry attempts 2 but found ' + $script:attemptCount + '.')
        }
    }

    It 'reads integer Retry-After from HttpResponseHeaders' {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]429)
        try {
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', '17')
            $metadata = Get-CollectorRetryMetadata -ErrorRecord (Get-RetryErrorRecord -Response $response)

            if ([int]$metadata.StatusCode -ne 429 -or [int]$metadata.RetryAfterSeconds -ne 17) {
                throw ('Expected Retry-After metadata 429/17; actual {0}/{1}.' -f $metadata.StatusCode, $metadata.RetryAfterSeconds)
            }
        }
        finally {
            $response.Dispose()
        }
    }

    It 'keeps legacy dictionary Retry-After support' {
        $response = [pscustomobject]@{
            StatusCode = 429
            Headers = @{ 'Retry-After' = '11' }
        }
        $metadata = Get-CollectorRetryMetadata -ErrorRecord (Get-RetryErrorRecord -Response $response)

        if ([int]$metadata.RetryAfterSeconds -ne 11) {
            throw ('Expected legacy Retry-After 11; actual ' + [string]$metadata.RetryAfterSeconds + '.')
        }
    }

    It 'parses HTTP-date Retry-After values' {
        $retryAt = (Get-Date).ToUniversalTime().AddSeconds(30)
        $response = [pscustomobject]@{
            StatusCode = 429
            Headers = @{ 'Retry-After' = $retryAt.ToString('R') }
        }
        $metadata = Get-CollectorRetryMetadata -ErrorRecord (Get-RetryErrorRecord -Response $response)

        if (-not $metadata.RetryAfterSeconds -or [double]$metadata.RetryAfterSeconds -lt 1 -or [double]$metadata.RetryAfterSeconds -gt 31) {
            throw ('Expected positive HTTP-date retry delay at most 31 seconds; actual ' + [string]$metadata.RetryAfterSeconds + '.')
        }
    }

    It 'keeps distant HTTP-date Retry-After values wider than Int32 until the retry cap is applied' {
        $retryAt = (Get-Date).ToUniversalTime().AddYears(80)
        $response = [pscustomobject]@{
            StatusCode = 429
            Headers = @{ 'Retry-After' = $retryAt.ToString('R') }
        }
        $metadata = Get-CollectorRetryMetadata -ErrorRecord (Get-RetryErrorRecord -Response $response)

        if ([double]$metadata.RetryAfterSeconds -le [int]::MaxValue) {
            throw ('Expected distant Retry-After to remain wider than Int32; actual ' + [string]$metadata.RetryAfterSeconds + '.')
        }
    }

    It 'caps valid Retry-After at MaxBackoffSeconds before sleeping' {
        Mock -ModuleName 'Collector.Common.Retry' -CommandName Start-Sleep -MockWith { }
        $script:attemptCount = 0

        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]429)
        try {
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', '17')
            $exception = [System.Exception]::new('HTTP 429 throttle')
            $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response -Force

            $result = Invoke-CollectorRetry -ScriptBlock {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) {
                    throw $exception
                }
                'ok'
            } -MaxRetries 1 -BaseBackoffSeconds 1 -MaxBackoffSeconds 3

            if ($result -ne 'ok') {
                throw ('Expected retry result ok; actual ' + [string]$result + '.')
            }
            Assert-MockCalled -ModuleName 'Collector.Common.Retry' -CommandName Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 3000 }
        }
        finally {
            $response.Dispose()
        }
    }

    It 'leaves invalid Retry-After unset for fallback backoff' {
        $response = [pscustomobject]@{
            StatusCode = 429
            Headers = @{ 'Retry-After' = 'not-a-delay' }
        }
        $metadata = Get-CollectorRetryMetadata -ErrorRecord (Get-RetryErrorRecord -Response $response)

        if ($null -ne $metadata.RetryAfterSeconds) {
            throw ('Expected invalid Retry-After to remain unset; actual ' + [string]$metadata.RetryAfterSeconds + '.')
        }
    }
}
