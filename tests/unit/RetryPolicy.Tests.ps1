$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Retry.psm1') -Force -ErrorAction Stop

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
}
