BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestCheckpointIdentity {
        return [ordered]@{
            runId = 'checkpoint-identity-type'
            stage = 'stage1'
            section = 'entra-apps'
            family = 'applications'
        }
    }

    function Write-TestCheckpointFixture {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestCheckpointIdentity
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $identity.runId -Stage $identity.stage -Section $identity.section -Family $identity.family
        return Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint
    }

    function Invoke-TestCheckpointLoad {
        param(
            [Parameter(Mandatory = $true)][string]$RunPath
        )

        $identity = Get-TestCheckpointIdentity
        return Get-CollectorCheckpoint -RunPath $RunPath -RunId $identity.runId -Stage $identity.stage -Section $identity.section -Family $identity.family
    }
}

Describe 'Persisted checkpoint identity type integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-checkpoint-identity-type-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects missing, null, empty, whitespace, and non-string persisted top-level identities without mutating the file' {
        $identity = Get-TestCheckpointIdentity
        $identityNames = @('runId', 'stage', 'section', 'family')
        $invalidCases = @(
            [pscustomobject]@{ Label = 'missing'; Omit = $true; Value = 'placeholder' },
            [pscustomobject]@{ Label = 'null'; Omit = $false; Value = $null },
            [pscustomobject]@{ Label = 'empty'; Omit = $false; Value = '' },
            [pscustomobject]@{ Label = 'whitespace'; Omit = $false; Value = '   ' },
            [pscustomobject]@{ Label = 'numeric'; Omit = $false; Value = 123 },
            [pscustomobject]@{ Label = 'boolean'; Omit = $false; Value = $true },
            [pscustomobject]@{ Label = 'object'; Omit = $false; Value = ([pscustomobject]@{ value = 'checkpoint-identity-type' }) }
        )

        foreach ($identityName in $identityNames) {
            foreach ($case in $invalidCases) {
                $checkpointPath = Write-TestCheckpointFixture -RunPath $script:testRoot
                $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
                if ($case.Omit) {
                    $persisted.PSObject.Properties.Remove($identityName)
                }
                else {
                    $persisted.$identityName = $case.Value
                }
                $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
                $before = Get-Content -LiteralPath $checkpointPath -Raw

                $errorMessage = $null
                try {
                    Invoke-TestCheckpointLoad -RunPath $script:testRoot | Out-Null
                }
                catch {
                    $errorMessage = $_.Exception.Message
                }

                if ([string]::IsNullOrWhiteSpace([string]$errorMessage)) {
                    throw ('Expected schema-invalid checkpoint identity [{0}] case [{1}] to fail closed.' -f $identityName, $case.Label)
                }
                if ($errorMessage -notmatch 'Checkpoint identity mismatch' -or $errorMessage -notmatch [regex]::Escape($identityName)) {
                    throw ('Expected checkpoint identity rejection to identify [{0}] for case [{1}]; actual: {2}' -f $identityName, $case.Label, $errorMessage)
                }

                $after = Get-Content -LiteralPath $checkpointPath -Raw
                if ($after -ne $before) {
                    throw ('Expected rejected checkpoint identity [{0}] case [{1}] to leave persisted evidence unchanged.' -f $identityName, $case.Label)
                }
            }
        }
    }

    It 'rejects a single-element array even when it contains the exact expected identity text' {
        $identity = Get-TestCheckpointIdentity

        foreach ($identityName in @('runId', 'stage', 'section', 'family')) {
            $checkpointPath = Write-TestCheckpointFixture -RunPath $script:testRoot
            $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            $expectedValue = [string]$identity[$identityName]
            $persisted.$identityName = @($expectedValue)
            $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

            $threw = $false
            try {
                Invoke-TestCheckpointLoad -RunPath $script:testRoot | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'must be a non-empty string') {
                    throw ('Expected strict type rejection for coercible array identity [{0}]; actual: {1}' -f $identityName, $_.Exception.Message)
                }
            }

            if (-not $threw) {
                throw ('Expected single-element array checkpoint identity [{0}] to be rejected instead of string-coerced.' -f $identityName)
            }
        }
    }

    It 'continues to load matching non-empty string identities' {
        $checkpointPath = Write-TestCheckpointFixture -RunPath $script:testRoot
        $loaded = Invoke-TestCheckpointLoad -RunPath $script:testRoot
        $identity = Get-TestCheckpointIdentity

        foreach ($identityName in @('runId', 'stage', 'section', 'family')) {
            if (-not ($loaded.$identityName -is [string]) -or $loaded.$identityName -ne [string]$identity[$identityName]) {
                throw ('Expected matching string checkpoint identity [{0}] to load unchanged.' -f $identityName)
            }
        }

        if (-not (Test-Path -LiteralPath $checkpointPath -PathType Leaf)) {
            throw 'Expected valid persisted checkpoint to remain present after loading.'
        }
    }

    It 'preserves established fail-closed behavior for a mismatched valid string identity' {
        $checkpointPath = Write-TestCheckpointFixture -RunPath $script:testRoot
        $persisted = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
        $persisted.runId = 'different-run'
        $persisted | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        $threw = $false
        try {
            Invoke-TestCheckpointLoad -RunPath $script:testRoot | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'runId' -or $_.Exception.Message -notmatch 'mismatch') {
                throw ('Expected established string mismatch error; actual: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected a valid-string runId mismatch to remain rejected.'
        }
    }
}
