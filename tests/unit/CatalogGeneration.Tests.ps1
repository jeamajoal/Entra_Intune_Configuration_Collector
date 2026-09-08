BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop

    function Add-TestCatalogFamily {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$RunId,
            [Parameter(Mandatory = $true)] [string]$Stage,
            [Parameter(Mandatory = $true)] [string]$Section,
            [Parameter(Mandatory = $true)] [string]$Family,
            [AllowEmptyCollection()] [object[]]$Items = @(),
            [ValidateSet('Succeeded', 'Failed', 'Missing', 'InProgress')] [string]$Status = 'Succeeded'
        )

        $planItems = [object[]]@($Items)
        $batches = Split-CollectorItems -Items $planItems -BatchSize 100
        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $RunId -Stage $Stage -Section $Section -Family $Family
        $checkpoint = Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100
        $artifactPath = $null

        if ($Status -eq 'Succeeded') {
            $snapshot = New-CollectorProvenanceSnapshot -RunId $RunId -Stage $Stage -Section $Section -Family $Family -BatchId '0001' -SourceType 'Test' -SourceName ('Test ' + $Family) -ApiVersion 'test-v1' -IsBeta:$false -RequestContext @{ marker = 'REQUEST-CONTEXT-MARKER' } -ItemCount $Items.Count -Items $Items
            $artifact = Write-CollectorSnapshotArtifact -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family -BatchNumber 1 -Snapshot $snapshot
            $artifactPath = $artifact.artifactPath
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status Succeeded -Attempts 1 -ItemCount $Items.Count -SuccessCount $Items.Count -FailedCount 0 -ArtifactPath $artifactPath
        }
        else {
            $failedCount = 0
            $errorMessage = $null
            if ($Status -eq 'Failed') {
                $failedCount = $Items.Count
                $errorMessage = 'fixture failure'
            }
            $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status $Status -Attempts 1 -ItemCount $Items.Count -SuccessCount 0 -FailedCount $failedCount -ArtifactPath $null -ErrorMessage $errorMessage
        }

        $checkpoint = Complete-CollectorCheckpointPlan -Checkpoint $checkpoint
        Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null
        return $artifactPath
    }

    function Write-TestCatalogManifest {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$RunId,
            [ValidateSet('Completed', 'CompletedWithErrors')] [string]$Status = 'Completed'
        )

        $completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $parameters = [pscustomobject]@{}
        $invocation = [pscustomobject]@{
            startedUtc = $completedUtc
            completedUtc = $completedUtc
            status = $Status
            parameters = $parameters
            stageResults = @()
            failures = @()
        }
        $manifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = $RunId
            startedUtc = $completedUtc
            completedUtc = $completedUtc
            status = $Status
            parameters = $parameters
            stageResults = @()
            checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $RunPath)
            failures = @()
            invocations = @($invocation)
        }
        Save-CollectorManifest -RunPath $RunPath -Manifest $manifest | Out-Null
    }

    function Get-TestCatalogRunFixture {
        param([string]$Name = ('run-' + [Guid]::NewGuid().ToString('N')))
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-catalog-' + [Guid]::NewGuid().ToString('N'))
        $runPath = Join-Path -Path $root -ChildPath $Name
        New-Item -Path $runPath -ItemType Directory -Force | Out-Null
        return [pscustomobject]@{ root = $root; runPath = $runPath; runId = $Name }
    }
}

Describe 'Offline knowledge catalog generation' {
    BeforeEach {
        $script:run = Get-TestCatalogRunFixture
    }

    AfterEach {
        if ($script:run -and (Test-Path -LiteralPath $script:run.root)) {
            Remove-Item -LiteralPath $script:run.root -Recurse -Force
        }
    }

    It 'emits metadata-only descriptors at the canonical catalog path' {
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-apps -Family applications -Items @([pscustomobject]@{ id = 'app-1'; payloadMarker = 'TENANT-PAYLOAD-MARKER' }) | Out-Null
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId

        $result = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath -ExpectedRunId $script:run.runId
        if (-not (Test-Path -LiteralPath $result.catalogPath -PathType Leaf)) {
            throw 'Expected catalog file to be persisted.'
        }
        if ([System.IO.Path]::GetFileName($result.catalogPath) -ne 'knowledge-catalog.json') {
            throw 'Expected canonical knowledge-catalog.json file name.'
        }

        $raw = Get-Content -LiteralPath $result.catalogPath -Raw
        $catalog = $raw | ConvertFrom-Json
        if ([string]$catalog.schemaVersion -ne '1.0' -or [string]$catalog.catalogId -ne ('catalog-v1:' + $script:run.runId)) {
            throw 'Expected v1 deterministic catalog identity.'
        }
        if (@($catalog.artifacts).Count -ne 1) {
            throw 'Expected one admitted artifact descriptor.'
        }
        $artifact = $catalog.artifacts[0]
        if ([string]$artifact.relativePath -ne 'stage1/entra-apps/applications/batch-0001.json' -or [string]$artifact.checkpointRelativePath -ne 'checkpoints/stage1/entra-apps/applications.json') {
            throw 'Expected canonical forward-slash relative artifact/checkpoint paths.'
        }
        if ([string]$artifact.kind -ne 'inventory' -or [int]$artifact.itemCount -ne 1) {
            throw 'Expected Stage1 inventory descriptor and validated item count.'
        }
        if ($raw -match 'TENANT-PAYLOAD-MARKER' -or $raw -match 'REQUEST-CONTEXT-MARKER' -or $artifact.PSObject.Properties.Name -contains 'items' -or $artifact.PSObject.Properties.Name -contains 'requestContext') {
            throw 'Catalog must not copy raw tenant payload or requestContext data.'
        }
    }

    It 'regenerates byte-identical deterministic content from unchanged evidence' {
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-apps -Family applications -Items @([pscustomobject]@{ id = 'app-1' }) | Out-Null
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId

        $firstResult = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath
        $first = Get-Content -LiteralPath $firstResult.catalogPath -Raw
        $secondResult = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath
        $second = Get-Content -LiteralPath $secondResult.catalogPath -Raw

        if ($first -cne $second) {
            throw 'Expected unchanged source evidence to regenerate byte-identical catalog content.'
        }
    }

    It 'preserves successful zero-item families as catalog artifacts' {
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-apps -Family groups -Items @() | Out-Null
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId

        $result = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath
        $catalog = Get-Content -LiteralPath $result.catalogPath -Raw | ConvertFrom-Json
        if (@($catalog.artifacts).Count -ne 1 -or [int]$catalog.artifacts[0].itemCount -ne 0) {
            throw 'Expected successful zero-item family to remain discoverable with itemCount 0.'
        }
    }

    It 'fails closed on missing source evidence without replacing the previous catalog' {
        $artifactPath = Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-apps -Family applications -Items @([pscustomobject]@{ id = 'app-1' })
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId
        $result = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath
        $before = Get-Content -LiteralPath $result.catalogPath -Raw

        Remove-Item -LiteralPath $artifactPath -Force
        $threw = $false
        try {
            Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected missing canonical snapshot to fail catalog regeneration.'
        }
        $after = Get-Content -LiteralPath $result.catalogPath -Raw
        if ($before -cne $after) {
            throw 'Failed regeneration must not replace the previous valid catalog.'
        }
    }

    It 'emits required Stage2 execution-input dependencies only when the provider evidence resolves' {
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-apps -Family applications -Items @([pscustomobject]@{ id = 'app-1' }) | Out-Null
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage2 -Section entra-apps -Family applicationCredentials -Items @([pscustomobject]@{ id = 'app-1' }) | Out-Null
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId

        $result = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath
        $catalog = Get-Content -LiteralPath $result.catalogPath -Raw | ConvertFrom-Json
        if (@($catalog.dependencies).Count -ne 1) {
            throw 'Expected one Stage2 execution-input dependency.'
        }
        $dependency = $catalog.dependencies[0]
        if ([string]$dependency.dependencyType -ne 'execution-input' -or [string]$dependency.consumer.family -ne 'applicationCredentials' -or [string]$dependency.provider.family -ne 'applications' -or [string]$dependency.provider.kind -ne 'inventory') {
            throw 'Expected applicationCredentials -> Stage1 applications dependency contract.'
        }
    }

    It 'rejects admitted downstream evidence when its required Stage1 provider is absent' {
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage2 -Section entra-apps -Family applicationCredentials -Items @([pscustomobject]@{ id = 'app-1' }) | Out-Null
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId

        $threw = $false
        try {
            Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'execution-input provider') {
                throw ('Expected unresolved provider failure; actual: {0}' -f $_.Exception.Message)
            }
        }
        if (-not $threw) {
            throw 'Expected unresolved Stage1 dependency to fail closed.'
        }
    }

    It 'publishes PIM relationship identity domains including application scope' {
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-pim -Family roleAssignmentScheduleInstances -Items @([pscustomobject]@{ id = 'active-1' }) | Out-Null
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-pim -Family roleEligibilityScheduleInstances -Items @([pscustomobject]@{ id = 'eligible-1' }) | Out-Null
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage3 -Section entra-pim -Family pimScheduleEdges -Items @([pscustomobject]@{ scheduleId = 'active-1'; appScopeId = '/appScope' }) | Out-Null
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId

        $result = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath
        $catalog = Get-Content -LiteralPath $result.catalogPath -Raw | ConvertFrom-Json
        if (@($catalog.dependencies).Count -ne 2 -or @($catalog.relationships).Count -ne 1) {
            throw 'Expected two PIM Stage1 dependencies and one relationship descriptor.'
        }
        if (@($catalog.relationships[0].targetIdentityDomains) -notcontains 'entra.app-scope') {
            throw 'Expected PIM relationship target domains to include entra.app-scope.'
        }
    }

    It 'allows partial successful evidence only when the terminal manifest says CompletedWithErrors' {
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-apps -Family applications -Items @([pscustomobject]@{ id = 'app-1' }) | Out-Null
        Add-TestCatalogFamily -RunPath $script:run.runPath -RunId $script:run.runId -Stage stage1 -Section entra-apps -Family groups -Items @([pscustomobject]@{ id = 'group-1' }) -Status Failed | Out-Null
        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId -Status CompletedWithErrors

        $result = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath
        $catalog = Get-Content -LiteralPath $result.catalogPath -Raw | ConvertFrom-Json
        if ([string]$catalog.runStatus -ne 'CompletedWithErrors' -or @($catalog.artifacts).Count -ne 1 -or [string]$catalog.artifacts[0].family -ne 'applications') {
            throw 'Expected CompletedWithErrors catalog to retain only validated successful evidence.'
        }

        Write-TestCatalogManifest -RunPath $script:run.runPath -RunId $script:run.runId -Status Completed
        $threw = $false
        try {
            Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected Completed manifest with failed checkpoint state to fail closed.'
        }
    }
}
