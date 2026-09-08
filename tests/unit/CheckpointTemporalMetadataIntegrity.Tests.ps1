[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Pester mocks execute in imported module scope; this test-only global bridges source fixture state into those mocks and is removed during teardown.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestCheckpointContext {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [bool]$Resume = $false
        )

        return @{
            RunPath = $RunPath
            RunId = 'checkpoint-temporal-run'
            GraphToken = 'test-token'
            BatchSize = 2
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $Resume
            ReprocessFailedOnly = $false
        }
    }

    function Write-TestCheckpointJson {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [pscustomobject]$Checkpoint
        )

        $Checkpoint | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    function Invoke-TestStageSeed {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('stage1', 'stage2', 'stage3')]
            [string]$Stage,

            [Parameter(Mandatory = $true)]
            [hashtable]$Context
        )

        Invoke-CollectorStage1 -Context $Context -Sections @('entra-apps') | Out-Null
        if ($Stage -eq 'stage2') {
            Invoke-CollectorStage2 -Context $Context -Sections @('entra-apps') | Out-Null
        }
        elseif ($Stage -eq 'stage3') {
            Invoke-CollectorStage3 -Context $Context -Sections @('entra-apps') | Out-Null
        }
    }
}

Describe 'Persisted checkpoint temporal and error metadata integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-temporal-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        $global:CollectorCheckpointTemporalItems = @(
            [pscustomobject]@{ id = 'one' },
            [pscustomobject]@{ id = 'two' }
        )

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @($global:CollectorCheckpointTemporalItems)
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            [pscustomobject]@{ id = 'detail' }
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @()
        }
    }

    AfterEach {
        Remove-Variable -Name CollectorCheckpointTemporalItems -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects malformed top-level and recorded-batch timestamp or error metadata without rewriting persisted evidence' {
        $runId = 'checkpoint-temporal-run'
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches @(@([pscustomobject]@{ id = 'one' })) -BatchSize 100
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Failed' -Attempts 1 -ItemCount 1 -SuccessCount 0 -FailedCount 1 -ArtifactPath $null -ErrorMessage 'seed failure'
        $checkpointPath = Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint
        $baselineRaw = Get-Content -LiteralPath $checkpointPath -Raw

        $invalidTimestampValues = @(
            [pscustomobject]@{ label = 'null'; value = $null },
            [pscustomobject]@{ label = 'object'; value = ([pscustomobject]@{ bad = $true }) },
            [pscustomobject]@{ label = 'number'; value = 1 },
            [pscustomobject]@{ label = 'boolean'; value = $true }
        )

        foreach ($target in @('checkpoint.updatedUtc', 'batch.updatedUtc')) {
            foreach ($invalidValue in $invalidTimestampValues) {
                Set-Content -LiteralPath $checkpointPath -Value $baselineRaw -Encoding UTF8
                $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
                if ($target -eq 'checkpoint.updatedUtc') {
                    $persisted.updatedUtc = $invalidValue.value
                }
                else {
                    $persisted.batches[0].updatedUtc = $invalidValue.value
                }
                Write-TestCheckpointJson -Path $checkpointPath -Checkpoint $persisted
                $before = Get-Content -LiteralPath $checkpointPath -Raw

                $threw = $false
                try {
                    Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null
                }
                catch {
                    $threw = $true
                    if ($_.Exception.Message -notmatch 'updatedUtc') {
                        throw ('Expected {0} invalid {1} timestamp rejection; actual error: {2}' -f $target, $invalidValue.label, $_.Exception.Message)
                    }
                }

                if (-not $threw) {
                    throw ('Expected {0} invalid {1} timestamp to fail closed.' -f $target, $invalidValue.label)
                }
                if ((Get-Content -LiteralPath $checkpointPath -Raw) -ne $before) {
                    throw ('Expected rejected {0} invalid {1} timestamp bytes to remain unchanged.' -f $target, $invalidValue.label)
                }
            }
        }

        Set-Content -LiteralPath $checkpointPath -Value $baselineRaw -Encoding UTF8
        $missingTop = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        $missingTop.PSObject.Properties.Remove('updatedUtc')
        Write-TestCheckpointJson -Path $checkpointPath -Checkpoint $missingTop
        $missingTopBefore = Get-Content -LiteralPath $checkpointPath -Raw
        { Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null } | Should -Throw '*updatedUtc*'
        (Get-Content -LiteralPath $checkpointPath -Raw) | Should -BeExactly $missingTopBefore

        Set-Content -LiteralPath $checkpointPath -Value $baselineRaw -Encoding UTF8
        $missingBatch = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        $missingBatch.batches[0].PSObject.Properties.Remove('updatedUtc')
        Write-TestCheckpointJson -Path $checkpointPath -Checkpoint $missingBatch
        $missingBatchBefore = Get-Content -LiteralPath $checkpointPath -Raw
        { Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null } | Should -Throw '*updatedUtc*'
        (Get-Content -LiteralPath $checkpointPath -Raw) | Should -BeExactly $missingBatchBefore

        $invalidErrorValues = @(
            [pscustomobject]@{ label = 'object'; value = ([pscustomobject]@{ bad = $true }) },
            [pscustomobject]@{ label = 'number'; value = 1 },
            [pscustomobject]@{ label = 'boolean'; value = $true },
            [pscustomobject]@{ label = 'array'; value = [object[]]@('bad', 'worse') }
        )
        foreach ($invalidValue in $invalidErrorValues) {
            Set-Content -LiteralPath $checkpointPath -Value $baselineRaw -Encoding UTF8
            $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            $persisted.batches[0].error = $invalidValue.value
            Write-TestCheckpointJson -Path $checkpointPath -Checkpoint $persisted
            $before = Get-Content -LiteralPath $checkpointPath -Raw

            { Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications' | Out-Null } | Should -Throw '*invalid persisted error*'
            (Get-Content -LiteralPath $checkpointPath -Raw) | Should -BeExactly $before
        }
    }

    It 'accepts valid persisted timestamp materialization and string or null error values' {
        $runId = 'checkpoint-temporal-run'
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches @(@([pscustomobject]@{ id = 'one' })) -BatchSize 100
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Failed' -Attempts 1 -ItemCount 1 -SuccessCount 0 -FailedCount 1 -ArtifactPath $null -ErrorMessage 'seed failure'
        $checkpointPath = Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint

        $loaded = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        if ($null -eq $loaded -or [string]$loaded.batches[0].error -ne 'seed failure') {
            throw 'Expected a valid persisted checkpoint with string error to load.'
        }

        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        $persisted.batches[0].error = $null
        Write-TestCheckpointJson -Path $checkpointPath -Checkpoint $persisted
        $loadedNullError = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        if ($null -ne $loadedNullError.batches[0].error) {
            throw 'Expected null persisted batch error to remain valid.'
        }
    }

    It 'rejects malformed checkpoint timestamps before Stage1, Stage2, and Stage3 resume can save' {
        foreach ($stage in @('stage1', 'stage2', 'stage3')) {
            $caseRoot = Join-Path -Path $script:testRoot -ChildPath $stage
            New-Item -Path $caseRoot -ItemType Directory -Force | Out-Null
            $initialContext = Get-TestCheckpointContext -RunPath $caseRoot -Resume:$false
            Invoke-TestStageSeed -Stage $stage -Context $initialContext

            $checkpointRoot = Join-Path -Path $caseRoot -ChildPath (Join-Path -Path 'checkpoints' -ChildPath (Join-Path -Path $stage -ChildPath 'entra-apps'))
            $checkpointFiles = @(Get-ChildItem -LiteralPath $checkpointRoot -Filter '*.json' -File)
            if ($checkpointFiles.Count -eq 0) {
                throw ('Expected seeded {0} checkpoint files.' -f $stage)
            }

            $beforeByPath = @{}
            foreach ($checkpointFile in $checkpointFiles) {
                $persisted = Get-Content -LiteralPath $checkpointFile.FullName -Raw | ConvertFrom-Json
                $persisted.updatedUtc = [pscustomobject]@{ bad = $true }
                Write-TestCheckpointJson -Path $checkpointFile.FullName -Checkpoint $persisted
                $beforeByPath[$checkpointFile.FullName] = Get-Content -LiteralPath $checkpointFile.FullName -Raw
            }

            $resumeContext = Get-TestCheckpointContext -RunPath $caseRoot -Resume:$true
            $threw = $false
            try {
                switch ($stage) {
                    'stage1' { Invoke-CollectorStage1 -Context $resumeContext -Sections @('entra-apps') | Out-Null }
                    'stage2' { Invoke-CollectorStage2 -Context $resumeContext -Sections @('entra-apps') | Out-Null }
                    'stage3' { Invoke-CollectorStage3 -Context $resumeContext -Sections @('entra-apps') | Out-Null }
                }
            }
            catch {
                $threw = $true
            }

            if (-not $threw) {
                throw ('Expected {0} resume to reject malformed persisted checkpoint updatedUtc before saving.' -f $stage)
            }

            foreach ($path in $beforeByPath.Keys) {
                if ((Get-Content -LiteralPath $path -Raw) -ne $beforeByPath[$path]) {
                    throw ('Expected rejected {0} checkpoint [{1}] to remain byte-for-byte unchanged.' -f $stage, $path)
                }
            }
        }
    }
}
