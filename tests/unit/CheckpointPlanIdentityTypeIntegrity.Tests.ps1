BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestPlanIdentityCheckpointIdentity {
        return [ordered]@{
            runId = 'checkpoint-plan-identity-type'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
        }
    }

    function Get-TestPlanIdentityBatchSet {
        $items = [object[]]@([pscustomobject]@{ id = 'one' })
        return Split-CollectorItems -Items $items -BatchSize 100
    }

    function Write-TestPlanIdentityCheckpointFixture {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestPlanIdentityCheckpointIdentity
        $checkpointPath = Get-CollectorCheckpointPath -RunPath $RunPath -Stage $identity.stage -Section $identity.section -Family $identity.family
        if (Test-Path -LiteralPath $checkpointPath) {
            Remove-Item -LiteralPath $checkpointPath -Force
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $identity.runId -Stage $identity.stage -Section $identity.section -Family $identity.family
        $batches = Get-TestPlanIdentityBatchSet
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Failed' -Attempts 1 -ItemCount 1 -SuccessCount 0 -FailedCount 1 -ArtifactPath $null -ErrorMessage 'fixture'
        return Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint
    }

    function Write-TestPersistedPlanIdentity {
        param(
            [Parameter(Mandatory = $true)][string]$CheckpointPath,
            [Parameter(Mandatory = $true)][ValidateSet('planVersion', 'sourceFingerprint')][string]$PropertyName,
            [AllowNull()][object]$Value,
            [switch]$Omit,
            [switch]$SingleElementArray
        )

        $persisted = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        if ($Omit) {
            $persisted.plan.PSObject.Properties.Remove($PropertyName)
        }
        elseif ($SingleElementArray) {
            $originalValue = [string]$persisted.plan.$PropertyName
            $placeholder = '__single_element_plan_identity_array__'
            $persisted.plan.$PropertyName = $placeholder
            $json = $persisted | ConvertTo-Json -Depth 30
            $arrayJson = ConvertTo-Json -InputObject @($originalValue) -Compress
            $pattern = '"{0}"\s*:\s*"{1}"' -f [regex]::Escape($PropertyName), [regex]::Escape($placeholder)
            $replacement = '"{0}": {1}' -f $PropertyName, $arrayJson
            $json = $json -replace $pattern, $replacement
            Set-Content -LiteralPath $CheckpointPath -Value $json -Encoding UTF8
            return
        }
        else {
            $persisted.plan.$PropertyName = $Value
        }

        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    }

    function Invoke-TestPlanIdentityCheckpointLoad {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestPlanIdentityCheckpointIdentity
        return Get-CollectorCheckpoint -RunPath $RunPath -RunId $identity.runId -Stage $identity.stage -Section $identity.section -Family $identity.family
    }

    function Get-TestPlanIdentityStage1Context {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath,
            [Parameter(Mandatory = $true)][string]$RunId
        )

        return @{
            RunPath = $RunPath
            RunId = $RunId
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

Describe 'Persisted checkpoint plan identity string integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-plan-identity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects missing, null, empty, whitespace, non-string, and coercible array plan identities without mutation' {
        $invalidCases = @(
            [pscustomobject]@{ Label = 'missing'; Omit = $true; Array = $false; Value = 'placeholder' },
            [pscustomobject]@{ Label = 'null'; Omit = $false; Array = $false; Value = $null },
            [pscustomobject]@{ Label = 'empty'; Omit = $false; Array = $false; Value = '' },
            [pscustomobject]@{ Label = 'whitespace'; Omit = $false; Array = $false; Value = '   ' },
            [pscustomobject]@{ Label = 'numeric'; Omit = $false; Array = $false; Value = 1 },
            [pscustomobject]@{ Label = 'boolean'; Omit = $false; Array = $false; Value = $true },
            [pscustomobject]@{ Label = 'object'; Omit = $false; Array = $false; Value = ([pscustomobject]@{ value = 'identity' }) },
            [pscustomobject]@{ Label = 'single-element-array'; Omit = $false; Array = $true; Value = 'placeholder' }
        )

        foreach ($propertyName in @('planVersion', 'sourceFingerprint')) {
            foreach ($case in $invalidCases) {
                $checkpointPath = Write-TestPlanIdentityCheckpointFixture -RunPath $script:testRoot
                Write-TestPersistedPlanIdentity -CheckpointPath $checkpointPath -PropertyName $propertyName -Value $case.Value -Omit:$case.Omit -SingleElementArray:$case.Array
                $before = Get-Content -LiteralPath $checkpointPath -Raw

                $errorMessage = $null
                try {
                    Invoke-TestPlanIdentityCheckpointLoad -RunPath $script:testRoot | Out-Null
                }
                catch {
                    $errorMessage = $_.Exception.Message
                }

                if ([string]::IsNullOrWhiteSpace([string]$errorMessage)) {
                    throw ('Expected persisted {0} case [{1}] to fail closed.' -f $propertyName, $case.Label)
                }
                if ($errorMessage -notmatch [regex]::Escape($propertyName) -or $errorMessage -notmatch 'non-empty string') {
                    throw ('Expected strict persisted {0} rejection for case [{1}]; actual: {2}' -f $propertyName, $case.Label, $errorMessage)
                }

                $after = Get-Content -LiteralPath $checkpointPath -Raw
                if ($after -ne $before) {
                    throw ('Expected rejected persisted {0} case [{1}] to leave checkpoint evidence unchanged.' -f $propertyName, $case.Label)
                }
            }
        }
    }

    It 'continues to load valid non-empty plan identity strings unchanged' {
        $checkpointPath = Write-TestPlanIdentityCheckpointFixture -RunPath $script:testRoot
        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        $expectedPlanVersion = [string]$persisted.plan.planVersion
        $expectedSourceFingerprint = [string]$persisted.plan.sourceFingerprint

        $loaded = Invoke-TestPlanIdentityCheckpointLoad -RunPath $script:testRoot
        if (-not ($loaded.plan.planVersion -is [string]) -or [string]$loaded.plan.planVersion -cne $expectedPlanVersion) {
            throw 'Expected valid persisted planVersion to load unchanged.'
        }
        if (-not ($loaded.plan.sourceFingerprint -is [string]) -or [string]$loaded.plan.sourceFingerprint -cne $expectedSourceFingerprint) {
            throw 'Expected valid persisted sourceFingerprint to load unchanged.'
        }
    }

    It 'preserves ordinary valid-string resume mismatch behavior for plan identity changes' {
        $batches = Get-TestPlanIdentityBatchSet
        foreach ($propertyName in @('planVersion', 'sourceFingerprint')) {
            $checkpointPath = Write-TestPlanIdentityCheckpointFixture -RunPath $script:testRoot
            Write-TestPersistedPlanIdentity -CheckpointPath $checkpointPath -PropertyName $propertyName -Value 'different'
            $checkpoint = Invoke-TestPlanIdentityCheckpointLoad -RunPath $script:testRoot

            $errorMessage = $null
            try {
                Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100 -Resume | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }

            if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch '^Resume plan mismatch') {
                throw ('Expected ordinary string mismatch for {0} to remain owned by resume compatibility; actual: {1}' -f $propertyName, $errorMessage)
            }
        }
    }

    It 'fails real Stage1 resume before coercible plan identity arrays can be normalized or reused' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'current-item' })
        }

        foreach ($propertyName in @('planVersion', 'sourceFingerprint')) {
            $runPath = Join-Path -Path $script:testRoot -ChildPath ('stage1-' + $propertyName)
            New-Item -Path $runPath -ItemType Directory -Force | Out-Null
            $runId = 'checkpoint-plan-identity-stage1-' + $propertyName
            $context = Get-TestPlanIdentityStage1Context -RunPath $runPath -RunId $runId

            Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

            $checkpointPath = Get-CollectorCheckpointPath -RunPath $runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
            Write-TestPersistedPlanIdentity -CheckpointPath $checkpointPath -PropertyName $propertyName -SingleElementArray
            $before = Get-Content -LiteralPath $checkpointPath -Raw

            $context.Resume = $true
            $errorMessage = $null
            try {
                Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }

            if ([string]::IsNullOrWhiteSpace([string]$errorMessage) -or $errorMessage -notmatch [regex]::Escape($propertyName)) {
                throw ('Expected Stage1 resume to fail closed on coercible persisted {0}; actual error: {1}' -f $propertyName, $errorMessage)
            }

            $after = Get-Content -LiteralPath $checkpointPath -Raw
            if ($after -ne $before) {
                throw ('Expected Stage1 resume rejection for {0} to leave malformed checkpoint evidence unchanged.' -f $propertyName)
            }
        }
    }
}
