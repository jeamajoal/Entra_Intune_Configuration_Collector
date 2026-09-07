BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestCheckpointBatchIdentity {
        return [ordered]@{
            runId = 'checkpoint-batchid-type'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
        }
    }

    function Write-TestCheckpointBatchFixture {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestCheckpointBatchIdentity
        $checkpointPath = Get-CollectorCheckpointPath -RunPath $RunPath -Stage $identity.stage -Section $identity.section -Family $identity.family
        if (Test-Path -LiteralPath $checkpointPath) {
            Remove-Item -LiteralPath $checkpointPath -Force
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $identity.runId -Stage $identity.stage -Section $identity.section -Family $identity.family
        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        $batches = Split-CollectorItems -Items $items -BatchSize 100
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Failed' -Attempts 1 -ItemCount 1 -SuccessCount 0 -FailedCount 1 -ArtifactPath $null -ErrorMessage 'fixture'
        return Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint
    }

    function Write-TestPersistedBatchId {
        param(
            [Parameter(Mandatory = $true)][string]$CheckpointPath,
            [Parameter(Mandatory = $true)][ValidateSet('Plan', 'Recorded')][string]$Target,
            [AllowNull()][object]$Value,
            [switch]$Omit
        )

        $persisted = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        $batch = if ($Target -eq 'Plan') { $persisted.plan.batches[0] } else { $persisted.batches[0] }
        if ($Omit) {
            $batch.PSObject.Properties.Remove('batchId')
        }
        else {
            $batch.batchId = $Value
        }

        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    }

    function Invoke-TestCheckpointBatchLoad {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestCheckpointBatchIdentity
        return Get-CollectorCheckpoint -RunPath $RunPath -RunId $identity.runId -Stage $identity.stage -Section $identity.section -Family $identity.family
    }

    function Get-TestStage1BatchIdContext {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'checkpoint-batchid-stage1'
            GraphToken = 'test-token'
            BatchSize = 100
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $false
            ReprocessFailedOnly = $false
        }
    }
}

Describe 'Persisted checkpoint batchId type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-batchid-type-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects missing, null, empty, whitespace, and non-string batchId values for planned and recorded batches without mutating persisted evidence' {
        $invalidCases = @(
            [pscustomobject]@{ Label = 'missing'; Omit = $true; Value = 'placeholder' },
            [pscustomobject]@{ Label = 'null'; Omit = $false; Value = $null },
            [pscustomobject]@{ Label = 'empty'; Omit = $false; Value = '' },
            [pscustomobject]@{ Label = 'whitespace'; Omit = $false; Value = '   ' },
            [pscustomobject]@{ Label = 'numeric'; Omit = $false; Value = 1 },
            [pscustomobject]@{ Label = 'boolean'; Omit = $false; Value = $true },
            [pscustomobject]@{ Label = 'object'; Omit = $false; Value = ([pscustomobject]@{ value = '0001' }) },
            [pscustomobject]@{ Label = 'single-element-array'; Omit = $false; Value = @('0001') }
        )

        foreach ($target in @('Plan', 'Recorded')) {
            foreach ($case in $invalidCases) {
                $checkpointPath = Write-TestCheckpointBatchFixture -RunPath $script:testRoot
                Write-TestPersistedBatchId -CheckpointPath $checkpointPath -Target $target -Value $case.Value -Omit:$case.Omit
                $before = Get-Content -LiteralPath $checkpointPath -Raw

                $errorMessage = $null
                try {
                    Invoke-TestCheckpointBatchLoad -RunPath $script:testRoot | Out-Null
                }
                catch {
                    $errorMessage = $_.Exception.Message
                }

                if ([string]::IsNullOrWhiteSpace([string]$errorMessage)) {
                    throw ('Expected invalid {0} batchId case [{1}] to fail closed.' -f $target, $case.Label)
                }
                if ($errorMessage -notmatch 'batchId' -or $errorMessage -notmatch 'non-empty string') {
                    throw ('Expected strict {0} batchId type rejection for case [{1}]; actual: {2}' -f $target, $case.Label, $errorMessage)
                }

                $after = Get-Content -LiteralPath $checkpointPath -Raw
                if ($after -ne $before) {
                    throw ('Expected rejected {0} batchId case [{1}] to leave persisted checkpoint evidence unchanged.' -f $target, $case.Label)
                }
            }
        }
    }

    It 'continues to load valid non-empty string batch ids' {
        Write-TestCheckpointBatchFixture -RunPath $script:testRoot | Out-Null
        $checkpoint = Invoke-TestCheckpointBatchLoad -RunPath $script:testRoot

        if (-not ($checkpoint.plan.batches[0].batchId -is [string]) -or [string]$checkpoint.plan.batches[0].batchId -ne '0001') {
            throw 'Expected valid planned batchId string 0001 to load unchanged.'
        }
        if (-not ($checkpoint.batches[0].batchId -is [string]) -or [string]$checkpoint.batches[0].batchId -ne '0001') {
            throw 'Expected valid recorded batchId string 0001 to load unchanged.'
        }
    }

    It 'fails Stage1 resume before a coercible recorded batchId can be treated as an already-successful batch' {
        $context = Get-TestStage1BatchIdContext -RunPath $script:testRoot
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'current-item' })
        }

        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        Write-TestPersistedBatchId -CheckpointPath $checkpointPath -Target Recorded -Value @('0001')
        $before = Get-Content -LiteralPath $checkpointPath -Raw

        $context.Resume = $true
        $errorMessage = $null
        try {
            Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch 'batchId') {
            throw ('Expected Stage1 resume to fail closed on coercible recorded batchId before skip/reuse; actual error: {0}' -f $errorMessage)
        }

        $after = Get-Content -LiteralPath $checkpointPath -Raw
        if ($after -ne $before) {
            throw 'Expected Stage1 resume rejection to leave the malformed persisted checkpoint unchanged.'
        }
    }

    It 'fails Stage1 resume before a coercible planned batchId can be normalized by current-plan replacement' {
        $context = Get-TestStage1BatchIdContext -RunPath $script:testRoot
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'current-item' })
        }

        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        Write-TestPersistedBatchId -CheckpointPath $checkpointPath -Target Plan -Value @('0001')
        $before = Get-Content -LiteralPath $checkpointPath -Raw

        $context.Resume = $true
        $errorMessage = $null
        try {
            Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch 'batchId') {
            throw ('Expected Stage1 resume to reject coercible planned batchId before plan normalization; actual error: {0}' -f $errorMessage)
        }

        $after = Get-Content -LiteralPath $checkpointPath -Raw
        if ($after -ne $before) {
            throw 'Expected planned batchId rejection to leave persisted checkpoint evidence unchanged.'
        }
    }
}
