BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'

    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Validation.Package.psm1') -Force -ErrorAction Stop

    function Write-TestValidationJson {
        param(
            [Parameter(Mandatory = $true)] [string]$Path,
            [Parameter(Mandatory = $true)] [object]$Value
        )

        [System.IO.File]::WriteAllText(
            $Path,
            ($Value | ConvertTo-Json -Depth 30 -Compress),
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    function Add-TestValidationFamily {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$RunId,
            [Parameter(Mandatory = $true)] [string]$Stage,
            [Parameter(Mandatory = $true)] [string]$Section,
            [Parameter(Mandatory = $true)] [string]$Family,
            [AllowEmptyCollection()] [object[]]$Items = @()
        )

        $batches = Collector.Storage.Artifacts\Split-CollectorItems -Items ([object[]]@($Items)) -BatchSize 100
        $checkpoint = Collector.Storage.Checkpoints\Get-CollectorCheckpoint -RunPath $RunPath -RunId $RunId -Stage $Stage -Section $Section -Family $Family
        $checkpoint = Collector.Storage.Checkpoints\Initialize-CollectorCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100
        $snapshot = Collector.Common.Provenance\New-CollectorProvenanceSnapshot -RunId $RunId -Stage $Stage -Section $Section -Family $Family -BatchId '0001' -SourceType 'Test' -SourceName ('Test ' + $Family) -ApiVersion 'test-v1' -IsBeta:$false -RequestContext @{ marker = 'REQUEST-CONTEXT-MARKER' } -ItemCount $Items.Count -Items $Items
        $artifact = Collector.Storage.Artifacts\Write-CollectorSnapshotArtifact -RunPath $RunPath -Stage $Stage -Section $Section -Family $Family -BatchNumber 1 -Snapshot $snapshot
        $checkpoint = Collector.Storage.Checkpoints\Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status Succeeded -Attempts 1 -ItemCount $Items.Count -SuccessCount $Items.Count -FailedCount 0 -ArtifactPath $artifact.artifactPath
        $checkpoint = Collector.Storage.Checkpoints\Complete-CollectorCheckpointPlan -Checkpoint $checkpoint
        Collector.Storage.Checkpoints\Save-CollectorCheckpoint -RunPath $RunPath -Checkpoint $checkpoint | Out-Null

        return $artifact.artifactPath
    }

    function Write-TestValidationManifest {
        param(
            [Parameter(Mandatory = $true)] [string]$RunPath,
            [Parameter(Mandatory = $true)] [string]$RunId
        )

        $completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $parameters = [pscustomobject]@{}
        $manifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = $RunId
            startedUtc = $completedUtc
            completedUtc = $completedUtc
            status = 'Completed'
            parameters = $parameters
            stageResults = @()
            checkpointSummary = @(Collector.Storage.Checkpoints\Get-CollectorCheckpointSummary -RunPath $RunPath)
            failures = @()
            invocations = @([pscustomobject]@{
                startedUtc = $completedUtc
                completedUtc = $completedUtc
                status = 'Completed'
                parameters = $parameters
                stageResults = @()
                failures = @()
            })
        }
        Collector.Storage.Artifacts\Save-CollectorManifest -RunPath $RunPath -Manifest $manifest | Out-Null
    }

    function Get-TestKnowledgePackageFixture {
        param([switch]$IncludeStage2)

        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-package-validation-' + [Guid]::NewGuid().ToString('N'))
        $runId = 'run-' + [Guid]::NewGuid().ToString('N')
        $runPath = Join-Path -Path $root -ChildPath $runId
        New-Item -Path $runPath -ItemType Directory -Force | Out-Null

        $stage1Artifact = Add-TestValidationFamily -RunPath $runPath -RunId $runId -Stage stage1 -Section entra-apps -Family applications -Items @([pscustomobject]@{ id = 'app-1'; payloadMarker = 'TENANT-PAYLOAD-MARKER' })
        $stage2Artifact = $null
        if ($IncludeStage2) {
            $stage2Artifact = Add-TestValidationFamily -RunPath $runPath -RunId $runId -Stage stage2 -Section entra-apps -Family applicationCredentials -Items @([pscustomobject]@{ id = 'app-1' })
        }

        Write-TestValidationManifest -RunPath $runPath -RunId $runId
        $catalogResult = Collector.Storage.Catalog\Export-CollectorKnowledgeCatalog -RunPath $runPath -ExpectedRunId $runId

        return [pscustomobject]@{
            root = $root
            runId = $runId
            runPath = $runPath
            catalogPath = $catalogResult.catalogPath
            manifestPath = Join-Path -Path $runPath -ChildPath 'manifest/run-manifest.json'
            checkpointPath = Join-Path -Path $runPath -ChildPath 'checkpoints/stage1/entra-apps/applications.json'
            stage1ArtifactPath = $stage1Artifact
            stage2ArtifactPath = $stage2Artifact
        }
    }

    function Get-TestValidationFileContentSignature {
        param([Parameter(Mandatory = $true)] [string]$Path)
        return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }
}

Describe 'Offline knowledge package validation' {
    BeforeEach {
        $script:package = $null
    }

    AfterEach {
        if ($script:package -and (Test-Path -LiteralPath $script:package.root)) {
            Remove-Item -LiteralPath $script:package.root -Recurse -Force
        }
    }

    It 'returns success with validated artifact and family counts for a coherent package' {
        $script:package = Get-TestKnowledgePackageFixture

        $result = Collector.Validation.Package\Invoke-CollectorKnowledgePackageValidation -RunPath $script:package.runPath -ExpectedRunId $script:package.runId
        if (-not $result.valid -or [string]$result.status -ne 'Valid') {
            throw ('Expected valid package result; actual: {0}' -f $result.message)
        }
        if ([int]$result.artifactCount -ne 1 -or [int]$result.familyCount -ne 1 -or [int]$result.dependencyCount -ne 0 -or [int]$result.relationshipCount -ne 0) {
            throw 'Expected validated counts for the one-family package.'
        }
    }

    It 'fails closed when a catalog-referenced snapshot is missing without rewriting the catalog' {
        $script:package = Get-TestKnowledgePackageFixture
        $catalogBefore = Get-TestValidationFileContentSignature -Path $script:package.catalogPath
        Remove-Item -LiteralPath $script:package.stage1ArtifactPath -Force

        $result = Collector.Validation.Package\Invoke-CollectorKnowledgePackageValidation -RunPath $script:package.runPath
        if ($result.valid -or $result.message -notmatch 'canonical snapshot') {
            throw ('Expected missing-snapshot failure; actual: {0}' -f $result.message)
        }
        if ((Get-TestValidationFileContentSignature -Path $script:package.catalogPath) -cne $catalogBefore) {
            throw 'Validation must not rewrite the persisted catalog when source evidence is missing.'
        }
    }

    It 'rejects stale run identity in the persisted catalog' {
        $script:package = Get-TestKnowledgePackageFixture
        $catalog = Get-Content -LiteralPath $script:package.catalogPath -Raw | ConvertFrom-Json
        $catalog.runId = 'different-run'
        Write-TestValidationJson -Path $script:package.catalogPath -Value $catalog

        $result = Collector.Validation.Package\Invoke-CollectorKnowledgePackageValidation -RunPath $script:package.runPath
        if ($result.valid -or $result.message -notmatch 'catalog\.runId') {
            throw ('Expected catalog run identity mismatch; actual: {0}' -f $result.message)
        }
    }

    It 'rejects unsupported catalog schema version' {
        $script:package = Get-TestKnowledgePackageFixture
        $catalog = Get-Content -LiteralPath $script:package.catalogPath -Raw | ConvertFrom-Json
        $catalog.schemaVersion = '2.0'
        Write-TestValidationJson -Path $script:package.catalogPath -Value $catalog

        $result = Collector.Validation.Package\Invoke-CollectorKnowledgePackageValidation -RunPath $script:package.runPath
        if ($result.valid -or $result.message -notmatch 'catalog\.schemaVersion') {
            throw ('Expected unsupported catalog schema failure; actual: {0}' -f $result.message)
        }
    }

    It 'rejects malformed checkpoint state through the existing strict checkpoint boundary' {
        $script:package = Get-TestKnowledgePackageFixture
        $checkpoint = Get-Content -LiteralPath $script:package.checkpointPath -Raw | ConvertFrom-Json
        $checkpoint.schemaVersion = '9.9'
        Write-TestValidationJson -Path $script:package.checkpointPath -Value $checkpoint

        $result = Collector.Validation.Package\Invoke-CollectorKnowledgePackageValidation -RunPath $script:package.runPath
        if ($result.valid -or $result.message -notmatch 'checkpoint schemaVersion') {
            throw ('Expected malformed checkpoint failure; actual: {0}' -f $result.message)
        }
        if ($result.message -match 'TENANT-PAYLOAD-MARKER') {
            throw 'Validation failure output must not dump collected tenant payload data.'
        }
    }

    It 'rejects a broken dependency descriptor without exposing payload data' {
        $script:package = Get-TestKnowledgePackageFixture -IncludeStage2
        $catalog = Get-Content -LiteralPath $script:package.catalogPath -Raw | ConvertFrom-Json
        $catalog.dependencies[0].provider.family = 'groups'
        Write-TestValidationJson -Path $script:package.catalogPath -Value $catalog

        $result = Collector.Validation.Package\Invoke-CollectorKnowledgePackageValidation -RunPath $script:package.runPath
        if ($result.valid -or $result.message -notmatch 'catalog\.dependencies\[0\]\.provider\.family') {
            throw ('Expected broken dependency failure; actual: {0}' -f $result.message)
        }
        if ($result.message -match 'TENANT-PAYLOAD-MARKER') {
            throw 'Dependency failure output must not include collected payload data.'
        }
    }

    It 'does not rewrite manifest checkpoint snapshot or catalog evidence during successful validation' {
        $script:package = Get-TestKnowledgePackageFixture
        $before = @{
            manifest = Get-TestValidationFileContentSignature -Path $script:package.manifestPath
            checkpoint = Get-TestValidationFileContentSignature -Path $script:package.checkpointPath
            snapshot = Get-TestValidationFileContentSignature -Path $script:package.stage1ArtifactPath
            catalog = Get-TestValidationFileContentSignature -Path $script:package.catalogPath
        }

        $result = Collector.Validation.Package\Invoke-CollectorKnowledgePackageValidation -RunPath $script:package.runPath
        if (-not $result.valid) {
            throw ('Expected successful validation; actual: {0}' -f $result.message)
        }

        foreach ($name in $before.Keys) {
            $path = switch ($name) {
                'manifest' { $script:package.manifestPath }
                'checkpoint' { $script:package.checkpointPath }
                'snapshot' { $script:package.stage1ArtifactPath }
                'catalog' { $script:package.catalogPath }
            }
            if ((Get-TestValidationFileContentSignature -Path $path) -cne $before[$name]) {
                throw ('Validation rewrote source evidence: {0}.' -f $name)
            }
        }
    }

    It 'supports compact machine-readable JSON output from the operator command' {
        $script:package = Get-TestKnowledgePackageFixture
        $commandPath = Join-Path -Path $repoRoot -ChildPath 'collector/Test-KnowledgePackage.ps1'
        $json = & $commandPath -RunPath $script:package.runPath -ExpectedRunId $script:package.runId -AsJson
        $result = $json | ConvertFrom-Json

        if (-not [bool]$result.valid -or [string]$result.status -ne 'Valid' -or [int]$result.artifactCount -ne 1) {
            throw 'Expected machine-readable validation command output.'
        }
    }
}
