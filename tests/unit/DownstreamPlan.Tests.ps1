$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop

function New-DownstreamPlanContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [int]$BatchSize = 2,

        [bool]$Resume = $false
    )

    @{
        RunPath = $RunPath
        RunId = 'downstream-plan-run'
        GraphToken = 'test-token'
        BatchSize = $BatchSize
        MaxRetries = 0
        BaseBackoffSeconds = 0
        MaxBackoffSeconds = 0
        ThrottleMilliseconds = 0
        Resume = $Resume
        ReprocessFailedOnly = $false
    }
}

Describe 'Downstream checkpoint plan identity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-downstream-plan-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $global:CollectorDownstreamPlanSourceItems = @(
            [pscustomobject]@{ id = 'one' },
            [pscustomobject]@{ id = 'two' }
        )

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @($global:CollectorDownstreamPlanSourceItems)
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            [pscustomobject]@{ id = 'detail' }
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @()
        }
    }

    AfterEach {
        Remove-Variable -Name CollectorDownstreamPlanSourceItems -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'allows compatible Stage2 resume and rejects a changed BatchSize' {
        $initialContext = New-DownstreamPlanContext -RunPath $script:testRoot -BatchSize 2 -Resume:$false
        Invoke-CollectorStage1 -Context $initialContext -Sections @('entra-apps') | Out-Null
        Invoke-CollectorStage2 -Context $initialContext -Sections @('entra-apps') | Out-Null

        $resumeContext = New-DownstreamPlanContext -RunPath $script:testRoot -BatchSize 2 -Resume:$true
        $resumeResults = @(Invoke-CollectorStage2 -Context $resumeContext -Sections @('entra-apps'))
        $applications = @($resumeResults | Where-Object { $_.family -eq 'applications' })[0]
        if (-not $applications -or [int]$applications.skippedBatches -ne 1 -or [int]$applications.succeededBatches -ne 0) {
            throw 'Expected compatible Stage2 resume to reuse the successful planned batch.'
        }

        $changedBatchSizeContext = New-DownstreamPlanContext -RunPath $script:testRoot -BatchSize 1 -Resume:$true
        $threw = $false
        try {
            Invoke-CollectorStage2 -Context $changedBatchSizeContext -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected Stage2 resume to reject a changed BatchSize before reusing numeric batch IDs.'
        }
    }

    It 'rejects Stage2 resume after Stage1 source membership changes' {
        $initialContext = New-DownstreamPlanContext -RunPath $script:testRoot -BatchSize 2 -Resume:$false
        Invoke-CollectorStage1 -Context $initialContext -Sections @('entra-apps') | Out-Null
        Invoke-CollectorStage2 -Context $initialContext -Sections @('entra-apps') | Out-Null

        $global:CollectorDownstreamPlanSourceItems = @(
            [pscustomobject]@{ id = 'one' },
            [pscustomobject]@{ id = 'two' },
            [pscustomobject]@{ id = 'three' }
        )
        Invoke-CollectorStage1 -Context $initialContext -Sections @('entra-apps') | Out-Null

        $resumeContext = New-DownstreamPlanContext -RunPath $script:testRoot -BatchSize 2 -Resume:$true
        $threw = $false
        try {
            Invoke-CollectorStage2 -Context $resumeContext -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected Stage2 resume to reject refreshed Stage1 membership.'
        }
    }

    It 'rejects Stage3 resume after Stage1 source identity changes' {
        $initialContext = New-DownstreamPlanContext -RunPath $script:testRoot -BatchSize 2 -Resume:$false
        Invoke-CollectorStage1 -Context $initialContext -Sections @('entra-apps') | Out-Null
        Invoke-CollectorStage3 -Context $initialContext -Sections @('entra-apps') | Out-Null

        $global:CollectorDownstreamPlanSourceItems = @(
            [pscustomobject]@{ id = 'two' },
            [pscustomobject]@{ id = 'one' }
        )
        Invoke-CollectorStage1 -Context $initialContext -Sections @('entra-apps') | Out-Null

        $resumeContext = New-DownstreamPlanContext -RunPath $script:testRoot -BatchSize 2 -Resume:$true
        $threw = $false
        try {
            Invoke-CollectorStage3 -Context $resumeContext -Sections @('entra-apps') | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected Stage3 resume to reject reordered refreshed Stage1 source identity.'
        }
    }
}
