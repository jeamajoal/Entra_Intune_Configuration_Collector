BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Write-TestCheckpointFixture {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Stage
        )

        $runId = ([System.IO.DirectoryInfo]$RunPath).Name
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage $Stage -Section 'onprem-ad-gpo' -Family 'domains'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Failed' -Attempts 1 -ItemCount 0 -SuccessCount 0 -FailedCount 0 -ArtifactPath $null -ErrorMessage 'fixture error'
        return Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint
    }

    function Invoke-TestCheckpointLoad {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Stage
        )

        $runId = ([System.IO.DirectoryInfo]$RunPath).Name
        return Get-CollectorCheckpoint -RunPath $RunPath -RunId $runId -Stage $Stage -Section 'onprem-ad-gpo' -Family 'domains'
    }
}

Describe 'Persisted checkpoint temporal and error metadata integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-temporal-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects malformed top-level updatedUtc before a stage resume path can normalize it' {
        $invalidCases = @(
            [pscustomobject]@{ label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ label = 'array'; omit = $false; value = [object[]]@('2026-09-08T00:00:00.0000000Z') },
            [pscustomobject]@{ label = 'object'; omit = $false; value = ([pscustomobject]@{ value = '2026-09-08T00:00:00.0000000Z' }) },
            [pscustomobject]@{ label = 'number'; omit = $false; value = 1 },
            [pscustomobject]@{ label = 'boolean'; omit = $false; value = $true }
        )

        foreach ($stage in @('stage1', 'stage2', 'stage3')) {
            foreach ($invalidCase in $invalidCases) {
                $runPath = Join-Path -Path $script:testRoot -ChildPath ($stage + '-top-' + $invalidCase.label)
                New-Item -Path $runPath -ItemType Directory -Force | Out-Null
                $checkpointPath = Write-TestCheckpointFixture -RunPath $runPath -Stage $stage
                $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json

                if ($invalidCase.omit) {
                    $persisted.PSObject.Properties.Remove('updatedUtc')
                }
                else {
                    $persisted.updatedUtc = $invalidCase.value
                }
                $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
                $before = Get-Content -LiteralPath $checkpointPath -Raw

                $threw = $false
                try {
                    $checkpoint = Invoke-TestCheckpointLoad -RunPath $runPath -Stage $stage
                    $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches @(@()) -BatchSize 100 -Resume
                    Save-CollectorCheckpoint -RunPath $runPath -Checkpoint $checkpoint | Out-Null
                }
                catch {
                    $threw = $true
                    if ($_.Exception.Message -notmatch 'updatedUtc') {
                        throw ('Expected bounded top-level updatedUtc rejection for {0}/{1}; actual: {2}' -f $stage, $invalidCase.label, $_.Exception.Message)
                    }
                }

                if (-not $threw) {
                    throw ('Expected malformed top-level updatedUtc [{0}] to fail closed for {1}.' -f $invalidCase.label, $stage)
                }

                $after = Get-Content -LiteralPath $checkpointPath -Raw
                if ($after -ne $before) {
                    throw ('Expected rejected top-level updatedUtc [{0}] for {1} to remain byte-for-byte unchanged.' -f $invalidCase.label, $stage)
                }
            }
        }
    }

    It 'rejects malformed recorded-batch updatedUtc without rewriting durable evidence' {
        $invalidCases = @(
            [pscustomobject]@{ label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ label = 'array'; omit = $false; value = [object[]]@('2026-09-08T00:00:00.0000000Z') },
            [pscustomobject]@{ label = 'object'; omit = $false; value = ([pscustomobject]@{ value = '2026-09-08T00:00:00.0000000Z' }) },
            [pscustomobject]@{ label = 'number'; omit = $false; value = 1 },
            [pscustomobject]@{ label = 'boolean'; omit = $false; value = $true }
        )

        foreach ($invalidCase in $invalidCases) {
            $runPath = Join-Path -Path $script:testRoot -ChildPath ('batch-time-' + $invalidCase.label)
            New-Item -Path $runPath -ItemType Directory -Force | Out-Null
            $checkpointPath = Write-TestCheckpointFixture -RunPath $runPath -Stage 'stage1'
            $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            $batch = @($persisted.batches)[0]

            if ($invalidCase.omit) {
                $batch.PSObject.Properties.Remove('updatedUtc')
            }
            else {
                $batch.updatedUtc = $invalidCase.value
            }
            $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
            $before = Get-Content -LiteralPath $checkpointPath -Raw

            $threw = $false
            try {
                Invoke-TestCheckpointLoad -RunPath $runPath -Stage 'stage1' | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'updatedUtc') {
                    throw ('Expected bounded batch updatedUtc rejection for [{0}]; actual: {1}' -f $invalidCase.label, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected malformed batch updatedUtc [{0}] to fail closed.' -f $invalidCase.label)
            }

            $after = Get-Content -LiteralPath $checkpointPath -Raw
            if ($after -ne $before) {
                throw ('Expected rejected batch updatedUtc [{0}] to remain byte-for-byte unchanged.' -f $invalidCase.label)
            }
        }
    }

    It 'accepts missing null or string batch error and rejects non-string non-null error values' {
        $validCases = @(
            [pscustomobject]@{ label = 'missing'; omit = $true; value = $null },
            [pscustomobject]@{ label = 'null'; omit = $false; value = $null },
            [pscustomobject]@{ label = 'string'; omit = $false; value = 'persisted failure' }
        )

        foreach ($validCase in $validCases) {
            $runPath = Join-Path -Path $script:testRoot -ChildPath ('error-valid-' + $validCase.label)
            New-Item -Path $runPath -ItemType Directory -Force | Out-Null
            $checkpointPath = Write-TestCheckpointFixture -RunPath $runPath -Stage 'stage1'
            $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            $batch = @($persisted.batches)[0]

            if ($validCase.omit) {
                $batch.PSObject.Properties.Remove('error')
            }
            else {
                $batch.error = $validCase.value
            }
            $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

            $loaded = Invoke-TestCheckpointLoad -RunPath $runPath -Stage 'stage1'
            if (@($loaded.batches).Count -ne 1) {
                throw ('Expected valid batch error state [{0}] to remain loadable.' -f $validCase.label)
            }
        }

        $invalidCases = @(
            [pscustomobject]@{ label = 'array'; value = [object[]]@('bad') },
            [pscustomobject]@{ label = 'object'; value = ([pscustomobject]@{ value = 'bad' }) },
            [pscustomobject]@{ label = 'number'; value = 1 },
            [pscustomobject]@{ label = 'boolean'; value = $true }
        )

        foreach ($invalidCase in $invalidCases) {
            $runPath = Join-Path -Path $script:testRoot -ChildPath ('error-invalid-' + $invalidCase.label)
            New-Item -Path $runPath -ItemType Directory -Force | Out-Null
            $checkpointPath = Write-TestCheckpointFixture -RunPath $runPath -Stage 'stage1'
            $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            @($persisted.batches)[0].error = $invalidCase.value
            $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
            $before = Get-Content -LiteralPath $checkpointPath -Raw

            $threw = $false
            try {
                Invoke-TestCheckpointLoad -RunPath $runPath -Stage 'stage1' | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'persisted error') {
                    throw ('Expected bounded batch error rejection for [{0}]; actual: {1}' -f $invalidCase.label, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected malformed batch error [{0}] to fail closed.' -f $invalidCase.label)
            }

            $after = Get-Content -LiteralPath $checkpointPath -Raw
            if ($after -ne $before) {
                throw ('Expected rejected batch error [{0}] to remain byte-for-byte unchanged.' -f $invalidCase.label)
            }
        }
    }

    It 'keeps valid checkpoint timestamps usable through the shared resume save path on every supported stage identity' {
        foreach ($stage in @('stage1', 'stage2', 'stage3')) {
            $runPath = Join-Path -Path $script:testRoot -ChildPath ($stage + '-valid')
            New-Item -Path $runPath -ItemType Directory -Force | Out-Null
            $checkpointPath = Write-TestCheckpointFixture -RunPath $runPath -Stage $stage

            $loaded = Invoke-TestCheckpointLoad -RunPath $runPath -Stage $stage
            if (
                -not (($loaded.updatedUtc -is [string]) -or ($loaded.updatedUtc -is [datetime])) -or
                -not ((@($loaded.batches)[0].updatedUtc -is [string]) -or (@($loaded.batches)[0].updatedUtc -is [datetime]))
            ) {
                throw ('Expected valid persisted timestamps to materialize as string or DateTime on {0}.' -f $stage)
            }

            $loaded = Initialize-CollectorCheckpointPlan -Checkpoint $loaded -Batches @(@()) -BatchSize 100 -Resume
            Save-CollectorCheckpoint -RunPath $runPath -Checkpoint $loaded | Out-Null

            if (-not (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
                throw ('Expected valid {0} checkpoint to remain persisted after shared resume save path.' -f $stage)
            }
        }
    }
}
