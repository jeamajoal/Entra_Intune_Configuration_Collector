$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop

function Assert-ZeroItemFamilyArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Section,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    $artifactPath = Join-Path -Path $RunPath -ChildPath (Join-Path -Path $Stage -ChildPath (Join-Path -Path $Section -ChildPath (Join-Path -Path $Family -ChildPath 'batch-0001.json')))
    if (-not (Test-Path -LiteralPath $artifactPath)) {
        throw ('Expected zero-item artifact to exist: ' + $artifactPath)
    }

    $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
    if ([int]$snapshot.itemCount -ne 0 -or @($snapshot.items).Count -ne 0) {
        throw ('Expected zero-item snapshot for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }

    $checkpointPath = Join-Path -Path $RunPath -ChildPath (Join-Path -Path 'checkpoints' -ChildPath (Join-Path -Path $Stage -ChildPath (Join-Path -Path $Section -ChildPath ($Family + '.json'))))
    if (-not (Test-Path -LiteralPath $checkpointPath)) {
        throw ('Expected zero-item checkpoint to exist: ' + $checkpointPath)
    }

    $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    if (@($checkpoint.batches).Count -ne 1) {
        throw ('Expected exactly one zero-item checkpoint batch for {0}/{1}/{2}; actual {3}.' -f $Stage, $Section, $Family, @($checkpoint.batches).Count)
    }

    $batch = @($checkpoint.batches)[0]
    if ([string]$batch.status -ne 'Succeeded' -or [int]$batch.itemCount -ne 0) {
        throw ('Expected succeeded zero-item checkpoint batch for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }

    if (-not $checkpoint.plan -or -not [bool]$checkpoint.plan.completed -or [int]$checkpoint.plan.expectedBatchCount -ne 1) {
        throw ('Expected completed one-batch zero-item plan for {0}/{1}/{2}.' -f $Stage, $Section, $Family)
    }
}

Describe 'Zero-item batch execution' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-zero-item-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        $script:context = @{
            RunPath = $script:testRoot
            RunId = 'zero-item-run'
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

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'returns one explicit empty batch and preserves normal batch boundaries' {
        $emptyBatches = Split-CollectorItems -Items @() -BatchSize 100
        if ($emptyBatches.Count -ne 1) {
            throw ('Expected one empty batch; actual ' + $emptyBatches.Count + '.')
        }

        if (@($emptyBatches[0]).Count -ne 0) {
            throw 'Expected the single batch to contain zero items.'
        }

        $normalBatches = Split-CollectorItems -Items @(1, 2, 3, 4, 5) -BatchSize 2
        if ($normalBatches.Count -ne 3) {
            throw ('Expected three normal batches; actual ' + $normalBatches.Count + '.')
        }

        $counts = @(@($normalBatches[0]).Count, @($normalBatches[1]).Count, @($normalBatches[2]).Count)
        if (($counts -join ',') -ne '2,2,1') {
            throw ('Expected batch sizes 2,2,1; actual ' + ($counts -join ',') + '.')
        }
    }

    It 'persists successful zero-item artifacts and checkpoints through Stage1 Stage2 and Stage3' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith { @() }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith { @() }

        $stage1Results = @(Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps'))
        if ($stage1Results.Count -ne 3) {
            throw ('Expected three Stage1 entra-apps family results; actual ' + $stage1Results.Count + '.')
        }

        foreach ($family in @('applications', 'servicePrincipals', 'groups')) {
            $result = @($stage1Results | Where-Object { $_.family -eq $family })[0]
            if (-not $result -or $result.batchCount -ne 1 -or $result.succeededBatches -ne 1 -or $result.itemCount -ne 0) {
                throw ('Expected Stage1 zero-item success for family ' + $family + '.')
            }
            Assert-ZeroItemFamilyArtifacts -RunPath $script:testRoot -Stage 'stage1' -Section 'entra-apps' -Family $family
        }

        $stage2Results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('entra-apps'))
        foreach ($family in @('applications', 'servicePrincipals', 'groups')) {
            $result = @($stage2Results | Where-Object { $_.family -eq $family })[0]
            if (-not $result -or $result.batchCount -ne 1 -or $result.succeededBatches -ne 1 -or $result.itemCount -ne 0) {
                throw ('Expected Stage2 zero-item success for family ' + $family + '.')
            }
            Assert-ZeroItemFamilyArtifacts -RunPath $script:testRoot -Stage 'stage2' -Section 'entra-apps' -Family $family
        }

        $stage3Results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps'))
        foreach ($family in @('servicePrincipalAppRoleAssignedTo', 'groupMembers', 'delegatedGrants')) {
            $result = @($stage3Results | Where-Object { $_.family -eq $family })[0]
            if (-not $result -or $result.batchCount -ne 1 -or $result.succeededBatches -ne 1 -or $result.itemCount -ne 0) {
                throw ('Expected Stage3 zero-item success for family ' + $family + '.')
            }
            Assert-ZeroItemFamilyArtifacts -RunPath $script:testRoot -Stage 'stage3' -Section 'entra-apps' -Family $family
        }
    }
}
