BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestStatusCheckpointIdentity {
        return [ordered]@{
            runId = 'checkpoint-status-type'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
        }
    }

    function Write-TestStatusCheckpointFixture {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestStatusCheckpointIdentity
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

    function Write-TestPersistedStatus {
        param(
            [Parameter(Mandatory = $true)][string]$CheckpointPath,
            [AllowNull()][object]$Value,
            [switch]$Omit
        )

        $persisted = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        $batch = $persisted.batches[0]
        if ($Omit) {
            $batch.PSObject.Properties.Remove('status')
        }
        else {
            $batch.status = $Value
        }

        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    }

    function Invoke-TestStatusCheckpointLoad {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestStatusCheckpointIdentity
        return Get-CollectorCheckpoint -RunPath $RunPath -RunId $identity.runId -Stage $identity.stage -Section $identity.section -Family $identity.family
    }

    function Get-TestStage1StatusContext {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'checkpoint-status-stage1'
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

Describe 'Persisted checkpoint batch status type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-status-type-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects missing, null, empty, whitespace, non-string, unsupported, and wrong-case persisted statuses without mutation' {
        $invalidCases = @(
            [pscustomobject]@{ Label = 'missing'; Omit = $true; Value = 'placeholder' },
            [pscustomobject]@{ Label = 'null'; Omit = $false; Value = $null },
            [pscustomobject]@{ Label = 'empty'; Omit = $false; Value = '' },
            [pscustomobject]@{ Label = 'whitespace'; Omit = $false; Value = '   ' },
            [pscustomobject]@{ Label = 'numeric'; Omit = $false; Value = 1 },
            [pscustomobject]@{ Label = 'boolean'; Omit = $false; Value = $true },
            [pscustomobject]@{ Label = 'object'; Omit = $false; Value = ([pscustomobject]@{ value = 'Succeeded' }) },
            [pscustomobject]@{ Label = 'single-element-array'; Omit = $false; Value = @('Succeeded') },
            [pscustomobject]@{ Label = 'unsupported-string'; Omit = $false; Value = 'Completed' },
            [pscustomobject]@{ Label = 'wrong-case'; Omit = $false; Value = 'succeeded' }
        )

        foreach ($case in $invalidCases) {
            $checkpointPath = Write-TestStatusCheckpointFixture -RunPath $script:testRoot
            Write-TestPersistedStatus -CheckpointPath $checkpointPath -Value $case.Value -Omit:$case.Omit
            $before = Get-Content -LiteralPath $checkpointPath -Raw

            $errorMessage = $null
            try {
                Invoke-TestStatusCheckpointLoad -RunPath $script:testRoot | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }

            if ([string]::IsNullOrWhiteSpace([string]$errorMessage)) {
                throw ('Expected persisted status case [{0}] to fail closed.' -f $case.Label)
            }
            if ($errorMessage -notmatch 'status' -or $errorMessage -notmatch 'Succeeded') {
                throw ('Expected strict persisted status rejection for case [{0}]; actual: {1}' -f $case.Label, $errorMessage)
            }

            $after = Get-Content -LiteralPath $checkpointPath -Raw
            if ($after -ne $before) {
                throw ('Expected rejected persisted status case [{0}] to leave checkpoint evidence unchanged.' -f $case.Label)
            }
        }
    }

    It 'continues to load every supported exact-case status string' {
        foreach ($status in @('Succeeded', 'Failed', 'InProgress', 'Missing')) {
            $checkpointPath = Write-TestStatusCheckpointFixture -RunPath $script:testRoot
            Write-TestPersistedStatus -CheckpointPath $checkpointPath -Value $status

            $checkpoint = Invoke-TestStatusCheckpointLoad -RunPath $script:testRoot
            if (-not ($checkpoint.batches[0].status -is [string]) -or [string]$checkpoint.batches[0].status -cne $status) {
                throw ('Expected supported persisted status [{0}] to load unchanged.' -f $status)
            }
        }
    }

    It 'fails Stage1 resume before a coercible Succeeded status can be reused or skipped' {
        $context = Get-TestStage1StatusContext -RunPath $script:testRoot
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'current-item' })
        }

        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        Write-TestPersistedStatus -CheckpointPath $checkpointPath -Value @('Succeeded')
        $before = Get-Content -LiteralPath $checkpointPath -Raw

        $context.Resume = $true
        $errorMessage = $null
        try {
            Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch 'status') {
            throw ('Expected Stage1 resume to fail closed on coercible Succeeded status before skip/reuse; actual error: {0}' -f $errorMessage)
        }

        $after = Get-Content -LiteralPath $checkpointPath -Raw
        if ($after -ne $before) {
            throw 'Expected Stage1 resume status rejection to leave the malformed persisted checkpoint unchanged.'
        }
    }
}
