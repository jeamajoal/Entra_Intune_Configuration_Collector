BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
}

Describe 'Stage1 checkpoint plan identity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage1-plan-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'keeps downstream readiness incomplete when expected later work was never recorded' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'plan-crash' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $batches = [object[]]@([object[]]@([pscustomobject]@{ id = 'one' }), [object[]]@([pscustomobject]@{ id = 'two' }))
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 1
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        $artifactDirectory = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications'
        New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
        $artifactPath = [System.IO.Path]::GetFullPath((Join-Path -Path $artifactDirectory -ChildPath 'batch-0001.json'))
        '{"items":[{"id":"one"}]}' | Set-Content -LiteralPath $artifactPath -Encoding UTF8
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifactPath -ErrorMessage $null
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        if ([int]$checkpoint.plan.expectedBatchCount -ne 2 -or [bool]$checkpoint.plan.completed) {
            throw 'Expected the persisted plan to retain two expected batches and remain incomplete.'
        }

        if (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section 'entra-apps' -Family 'applications') {
            throw 'Expected downstream readiness to reject the interrupted Stage1 family.'
        }
    }

    It 'allows a compatible resume plan but rejects reordered membership and BatchSize changes' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'plan-resume' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $originalBatches = [object[]]@([object[]]@([pscustomobject]@{ id = 'one' }), [object[]]@([pscustomobject]@{ id = 'two' }))
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $originalBatches -BatchSize 1

        try {
            $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $originalBatches -BatchSize 1 -Resume
        }
        catch {
            throw ('Expected identical Stage1 plan to resume. Actual: ' + $_.Exception.Message)
        }

        foreach ($case in @(
            [pscustomobject]@{ Batches = [object[]]@([object[]]@([pscustomobject]@{ id = 'two' }), [object[]]@([pscustomobject]@{ id = 'one' })); BatchSize = 1; Name = 'reorder' },
            [pscustomobject]@{ Batches = [object[]]@([object[]]@([pscustomobject]@{ id = 'one' }), [object[]]@([pscustomobject]@{ id = 'two' }), [object[]]@([pscustomobject]@{ id = 'three' })); BatchSize = 1; Name = 'membership-add' },
            [pscustomobject]@{ Batches = $originalBatches; BatchSize = 2; Name = 'batch-size' }
        )) {
            $threw = $false
            try {
                Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $case.Batches -BatchSize $case.BatchSize -Resume | Out-Null
            }
            catch {
                $threw = $true
            }
            if (-not $threw) {
                throw ('Expected incompatible resume rejection for ' + $case.Name + '.')
            }
        }
    }

    It 'rejects legacy successful numeric batches that have no plan identity' {
        $artifactPath = Join-Path -Path $script:testRoot -ChildPath 'stage1/entra-apps/applications/batch-0001.json'
        New-Item -Path (Split-Path -Path $artifactPath -Parent) -ItemType Directory -Force | Out-Null
        '{}' | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'legacy-plan' -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status 'Succeeded' -Attempts 1 -ItemCount 1 -SuccessCount 1 -FailedCount 0 -ArtifactPath $artifactPath -ErrorMessage $null

        $threw = $false
        try {
            Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches ([object[]]@([object[]]@([pscustomobject]@{ id = 'one' }))) -BatchSize 100 -Resume | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected legacy successful checkpoint without plan identity to be rejected during resume.'
        }
    }

    It 'persists and completes the Stage1 plan through the public stage execution path' {
        $context = @{
            RunPath = $script:testRoot
            RunId = 'public-stage1-plan'
            GraphToken = 'test-token'
            BatchSize = 1
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $false
            ReprocessFailedOnly = $false
        }

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' })
        }

        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null

        foreach ($family in @('applications', 'servicePrincipals', 'groups')) {
            $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'public-stage1-plan' -Stage 'stage1' -Section 'entra-apps' -Family $family
            if (-not [bool]$checkpoint.plan.completed -or [int]$checkpoint.plan.expectedBatchCount -ne 2 -or [int]$checkpoint.plan.batchSize -ne 1) {
                throw ('Expected completed two-batch Stage1 plan for ' + $family + '.')
            }
            if (-not (Test-CollectorInventoryArtifacts -RunPath $script:testRoot -Section 'entra-apps' -Family $family)) {
                throw ('Expected completed Stage1 plan to satisfy readiness for ' + $family + '.')
            }
        }
    }
}
