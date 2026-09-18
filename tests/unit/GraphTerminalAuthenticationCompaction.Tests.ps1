BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'

    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function New-TerminalAuthBatchContext {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        @{
            RunPath = $RunPath
            RunId = 'terminal-auth-batch-run'
            GraphToken = 'test-token'
            BatchSize = 25
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $false
            ReprocessFailedOnly = $false
        }
    }

    function Initialize-TerminalAuthStage1Fixture {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$Context
        )

        Invoke-CollectorStage1 -Context $Context -Sections @('entra-apps') | Out-Null
    }
}

Describe 'Terminal Graph authentication batch compaction' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-terminal-auth-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)
            if ($Endpoint -eq '/v1.0/applications') {
                return @(
                    [pscustomobject]@{ id = 'one' },
                    [pscustomobject]@{ id = 'two' },
                    [pscustomobject]@{ id = 'three' }
                )
            }
            return @()
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'compacts generic Stage2 terminal auth while preserving partial success and source cardinality' {
        $context = New-TerminalAuthBatchContext -RunPath $script:testRoot
        Initialize-TerminalAuthStage1Fixture -Context $context

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)

            if ($Endpoint -like '*/one') {
                return [pscustomobject]@{ id = 'one'; displayName = 'Collected before auth failure' }
            }
            if ($Endpoint -like '*/two') {
                $exception = [System.InvalidOperationException]::new('Microsoft Graph authentication remained unauthorized (HTTP 401) after one token refresh.')
                $exception.Data['CollectorGraphAuthenticationTerminal'] = $true
                throw $exception
            }
            throw ('Stage2 must not request Graph after terminal authentication: {0}' -f $Endpoint)
        }

        $stage2Module = @(Get-Module -Name 'Collector.Stage2.Details')[0]
        $runner = {
            param($InnerContext)
            Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-apps' -Family 'applications' -EndpointTemplate '/v1.0/applications/{id}'
        }
        $result = @($stage2Module.Invoke($runner, [object[]]@($context)))[0]

        Assert-MockCalled -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -Times 2 -Exactly -Scope It
        [int]$result.failedBatches | Should -Be 1
        [int]$result.itemCount | Should -Be 3

        $snapshot = Get-Content -LiteralPath (Join-Path $script:testRoot 'stage2/entra-apps/applications/batch-0001.json') -Raw | ConvertFrom-Json
        @($snapshot.items).Count | Should -Be 3
        [string]$snapshot.items[0].id | Should -Be 'one'
        [string]$snapshot.items[1]._collectorErrorClass | Should -Be 'terminal-authentication'
        [string]$snapshot.items[2].id | Should -Be 'three'
        [string]$snapshot.items[2]._collectorNotAttemptedReason | Should -Be 'terminal-authentication'

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $context.RunId -Stage 'stage2' -Section 'entra-apps' -Family 'applications'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        [string]$batch.status | Should -Be 'Failed'
        [int]$batch.itemCount | Should -Be 3
        [int]$batch.successCount | Should -Be 1
        [int]$batch.failedCount | Should -Be 2
        [regex]::Matches([string]$batch.error, 'HTTP 401').Count | Should -Be 1
        [string]$batch.error | Should -Match '1 item\(s\) were not attempted'
    }

    It 'compacts generic Stage3 terminal auth while preserving partial relationship evidence and source cardinality' {
        $context = New-TerminalAuthBatchContext -RunPath $script:testRoot
        Initialize-TerminalAuthStage1Fixture -Context $context

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)

            if ($Endpoint -like '*/one/owners') {
                return @([pscustomobject]@{ id = 'owner-one' })
            }
            if ($Endpoint -like '*/two/owners') {
                $exception = [System.InvalidOperationException]::new('Microsoft Graph authentication remained unauthorized (HTTP 401) after one token refresh.')
                $exception.Data['CollectorGraphAuthenticationTerminal'] = $true
                throw $exception
            }
            throw ('Stage3 must not request Graph after terminal authentication: {0}' -f $Endpoint)
        }

        $stage3Module = @(Get-Module -Name 'Collector.Stage3.Relationships')[0]
        $runner = {
            param($InnerContext)
            Invoke-CollectorStage3GraphPerObjectFamily -Context $InnerContext -Section 'entra-apps' -Family 'applicationOwnersTerminalTest' -DependencyFamily 'applications' -EndpointTemplate '/v1.0/applications/{id}/owners'
        }
        $result = @($stage3Module.Invoke($runner, [object[]]@($context)))[0]

        Assert-MockCalled -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -Times 2 -Exactly -Scope It
        [int]$result.failedBatches | Should -Be 1
        [int]$result.itemCount | Should -Be 3

        $snapshot = Get-Content -LiteralPath (Join-Path $script:testRoot 'stage3/entra-apps/applicationOwnersTerminalTest/batch-0001.json') -Raw | ConvertFrom-Json
        @($snapshot.items).Count | Should -Be 3
        [string]$snapshot.items[0].parentId | Should -Be 'one'
        [int]$snapshot.items[0].relationshipCount | Should -Be 1
        [string]$snapshot.items[1]._collectorErrorClass | Should -Be 'terminal-authentication'
        [string]$snapshot.items[2].parentId | Should -Be 'three'
        [string]$snapshot.items[2]._collectorNotAttemptedReason | Should -Be 'terminal-authentication'

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $context.RunId -Stage 'stage3' -Section 'entra-apps' -Family 'applicationOwnersTerminalTest'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        [string]$batch.status | Should -Be 'Failed'
        [int]$batch.itemCount | Should -Be 3
        [int]$batch.successCount | Should -Be 1
        [int]$batch.failedCount | Should -Be 2
        [regex]::Matches([string]$batch.error, 'HTTP 401').Count | Should -Be 1
        [string]$batch.error | Should -Match '1 item\(s\) were not attempted'
    }

    It 'keeps every specialized Intune per-object loop on the shared terminal-auth compaction contract' {
        $configurationSource = Get-Content -LiteralPath (Join-Path $moduleRoot 'Collector.Stage.IntuneConfiguration.psm1') -Raw
        $securitySource = Get-Content -LiteralPath (Join-Path $moduleRoot 'Collector.Stage.IntuneSecurity.psm1') -Raw
        $enrollmentSource = Get-Content -LiteralPath (Join-Path $moduleRoot 'Collector.Stage.IntuneEnrollment.psm1') -Raw

        $configurationSource | Should -Match 'Test-CollectorGraphTerminalAuthenticationError'
        $configurationSource | Should -Match 'New-CollectorStage2TerminalAuthenticationRemainder'
        $securitySource | Should -Match 'Test-CollectorGraphTerminalAuthenticationError'
        $securitySource | Should -Match 'New-CollectorStage2TerminalAuthenticationRemainder'
        $enrollmentSource | Should -Match 'Test-CollectorGraphTerminalAuthenticationError'
        $enrollmentSource | Should -Match 'New-CollectorStage3TerminalAuthenticationRemainder'
    }
}
