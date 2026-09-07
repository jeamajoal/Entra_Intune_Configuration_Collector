param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Write-TestAttemptsCheckpoint {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [AllowNull()][string]$AttemptsToken,
            [switch]$OmitAttempts,
            [switch]$NullBatch
        )

        $runId = ([System.IO.DirectoryInfo]$RunPath).Name
        $checkpointPath = Get-CollectorCheckpointPath -RunPath $RunPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null

        if ($NullBatch) {
            $batchesJson = '[null]'
        }
        else {
            $attemptsProperty = if ($OmitAttempts) { '' } else { '"attempts":' + $AttemptsToken + ',' }
            $batchesJson = '[{' +
                '"batchId":"0001",' +
                '"status":"Failed",' +
                $attemptsProperty +
                '"itemCount":1,' +
                '"successCount":0,' +
                '"failedCount":1,' +
                '"artifactPath":"legacy-relative.json",' +
                '"error":"prior failure",' +
                '"updatedUtc":"2026-09-07T00:00:00.0000000Z"' +
            '}]'
        }

        $checkpointJson = '{' +
            '"schemaVersion":"1.0",' +
            '"runId":"' + $runId + '",' +
            '"stage":"stage1",' +
            '"section":"entra-apps",' +
            '"family":"applications",' +
            '"updatedUtc":"2026-09-07T00:00:00.0000000Z",' +
            '"plan":null,' +
            '"batches":' + $batchesJson +
        '}'

        Set-Content -LiteralPath $checkpointPath -Value $checkpointJson -Encoding UTF8
        return $checkpointPath
    }
}

Describe 'Persisted checkpoint attempts integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-attempts-integrity-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'run-attempts'
        New-Item -Path $script:runPath -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'accepts valid persisted zero and integral attempt values and preserves artifact canonicalization' {
        foreach ($attemptsToken in @('0', '1', '1.0', '2147483647')) {
            Write-TestAttemptsCheckpoint -RunPath $script:runPath -AttemptsToken $attemptsToken | Out-Null

            $checkpoint = Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-attempts' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            $batch = @($checkpoint.batches)[0]
            $attempts = Get-CollectorBatchCountValue -Batch $batch -PropertyName 'attempts'
            if ($null -eq $attempts -or $attempts -lt 0) {
                throw ('Expected valid persisted attempts token {0} to load.' -f $attemptsToken)
            }
            if (-not [System.IO.Path]::IsPathRooted([string]$batch.artifactPath)) {
                throw 'Expected valid checkpoint loading to preserve artifact-path canonicalization.'
            }
        }
    }

    It 'rejects schema-invalid persisted attempt values instead of coercing them' {
        $invalidTokens = @(
            '"1"',
            'true',
            '{"value":1}',
            '1.5',
            '1.0000000000000002',
            '-1',
            '2147483648',
            'null'
        )

        foreach ($attemptsToken in $invalidTokens) {
            Write-TestAttemptsCheckpoint -RunPath $script:runPath -AttemptsToken $attemptsToken | Out-Null

            $threw = $false
            try {
                Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-attempts' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'invalid persisted attempts') {
                    throw ('Expected checkpoint attempts-integrity error for token {0}; actual: {1}' -f $attemptsToken, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected schema-invalid persisted attempts token {0} to be rejected.' -f $attemptsToken)
            }
        }
    }

    It 'rejects a missing persisted attempts property' {
        Write-TestAttemptsCheckpoint -RunPath $script:runPath -AttemptsToken '1' -OmitAttempts | Out-Null

        $threw = $false
        try {
            Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-attempts' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'invalid persisted attempts') {
                throw ('Expected missing attempts integrity error; actual: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected checkpoint loading to reject a missing persisted attempts property.'
        }
    }

    It 'keeps the shared numeric helper compatible with supported integral runtime types for attempts' {
        $validRuntimeValues = @(
            [int]0,
            [long]1,
            [double]2.0,
            [decimal]3
        )

        foreach ($runtimeValue in $validRuntimeValues) {
            $batch = [pscustomobject]@{ attempts = $runtimeValue }
            $parsed = Get-CollectorBatchCountValue -Batch $batch -PropertyName 'attempts'
            if ($null -eq $parsed -or $parsed -ne [int]$runtimeValue) {
                throw ('Expected attempts runtime type {0} with value {1} to remain accepted.' -f $runtimeValue.GetType().FullName, $runtimeValue)
            }
        }
    }

    It 'preserves singleton null batches for the existing summary validator' {
        Write-TestAttemptsCheckpoint -RunPath $script:runPath -AttemptsToken '1' -NullBatch | Out-Null

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:runPath -RunId 'run-attempts' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $batches = @($checkpoint.batches)
        if ($batches.Count -ne 1 -or $null -ne $batches[0]) {
            throw 'Expected persisted batches=[null] to remain preserved for downstream summary validation.'
        }
    }
}
