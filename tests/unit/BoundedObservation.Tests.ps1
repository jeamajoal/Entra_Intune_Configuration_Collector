BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.BoundedObservations.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Observation.psm1') -Force -ErrorAction Stop

    function Get-TestBoundedRunFixture {
        param([string]$RunId = ('bounded-' + [Guid]::NewGuid().ToString('N')))
        $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-bounded-' + [Guid]::NewGuid().ToString('N'))
        $runPath = Join-Path -Path $root -ChildPath $RunId
        New-Item -Path $runPath -ItemType Directory -Force | Out-Null
        return [pscustomobject]@{ root = $root; runPath = $runPath; runId = $RunId }
    }

    function Get-TestObservationFixture {
        param(
            [object]$Start = '2026-09-16T00:00:00Z',
            [object]$End = '2026-09-17T00:00:00Z',
            [object]$ProviderStart = $null,
            [object]$ProviderEnd = $null,
            [string]$RetentionCaveat = $null
        )

        return New-CollectorObservationDescriptor `
            -RequestedStartUtc $Start `
            -RequestedEndUtc $End `
            -EventTimeProperty 'createdDateTime' `
            -ProviderAvailableStartUtc $ProviderStart `
            -ProviderAvailableEndUtc $ProviderEnd `
            -RetentionCaveat $RetentionCaveat
    }

    function Add-TestBoundedFamily {
        param(
            [Parameter(Mandatory = $true)] [object]$Run,
            [Parameter(Mandatory = $true)] [object]$Observation,
            [Parameter(Mandatory = $true)] [object]$EvidenceState,
            [string]$Family = 'applications',
            [AllowEmptyCollection()] [object[]]$Items = @()
        )

        $batches = Split-CollectorItems -Items @($Items) -BatchSize 100
        $checkpoint = Get-CollectorCheckpoint -RunPath $Run.runPath -RunId $Run.runId -Stage 'stage1' -Section 'entra-apps' -Family $Family
        $checkpoint = Initialize-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100 -Observation $Observation
        $snapshot = New-CollectorProvenanceSnapshot -RunId $Run.runId -Stage 'stage1' -Section 'entra-apps' -Family $Family -BatchId '0001' -SourceType 'Test' -SourceName 'bounded-test' -ApiVersion 'test-v1' -RequestContext @{} -Observation $Observation -EvidenceState $EvidenceState -ItemCount $Items.Count -Items $Items
        $artifact = Write-CollectorSnapshotArtifact -RunPath $Run.runPath -Stage 'stage1' -Section 'entra-apps' -Family $Family -BatchNumber 1 -Snapshot $snapshot
        $checkpoint = Set-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001' -Status Succeeded -Attempts 1 -ItemCount $Items.Count -SuccessCount $Items.Count -FailedCount 0 -ArtifactPath $artifact.artifactPath
        $checkpoint = Complete-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint
        Save-CollectorCheckpoint -RunPath $Run.runPath -Checkpoint $checkpoint | Out-Null
        return [pscustomobject]@{ checkpoint = $checkpoint; artifactPath = $artifact.artifactPath }
    }

    function Write-TestBoundedManifest {
        param([Parameter(Mandatory = $true)][object]$Run)
        $completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $parameters = [pscustomobject]@{}
        $invocation = [pscustomobject]@{
            startedUtc = $completedUtc
            completedUtc = $completedUtc
            status = 'Completed'
            parameters = $parameters
            stageResults = @()
            failures = @()
        }
        $manifest = [pscustomobject]@{
            schemaVersion = '1.1'
            runId = $Run.runId
            startedUtc = $completedUtc
            completedUtc = $completedUtc
            status = 'Completed'
            parameters = $parameters
            stageResults = @()
            checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $Run.runPath)
            failures = @()
            invocations = @($invocation)
        }
        Save-CollectorManifest -RunPath $Run.runPath -Manifest $manifest | Out-Null
    }
}

Describe 'Bounded observation descriptor' {
    It 'normalizes equivalent requested windows to the same UTC plan identity' {
        $offsetWindow = Get-TestObservationFixture -Start '2026-09-15T19:00:00-05:00' -End '2026-09-16T19:00:00-05:00'
        $utcWindow = Get-TestObservationFixture -Start '2026-09-16T00:00:00Z' -End '2026-09-17T00:00:00Z'

        if ([string]$offsetWindow.requested.startUtc -ne '2026-09-16T00:00:00.0000000+00:00') {
            throw ('Expected canonical UTC start; actual: {0}' -f [string]$offsetWindow.requested.startUtc)
        }
        if ([string]$offsetWindow.planIdentity -cne [string]$utcWindow.planIdentity) {
            throw 'Equivalent absolute windows must have the same plan identity.'
        }
    }

    It 'rejects ambiguous timestamps without an explicit offset' {
        { Get-TestObservationFixture -Start '2026-09-16T00:00:00' } | Should -Throw '*explicit UTC designator or numeric offset*'
    }

    It 'rejects an inverted requested window' {
        { Get-TestObservationFixture -Start '2026-09-17T00:00:00Z' -End '2026-09-16T00:00:00Z' } | Should -Throw '*earlier than requested observation end*'
    }

    It 'keeps provider availability separate from requested time' {
        $observation = Get-TestObservationFixture -ProviderStart '2026-09-16T06:00:00Z' -ProviderEnd '2026-09-17T00:00:00Z' -RetentionCaveat 'Provider retained only part of the requested interval.'
        if ([string]$observation.requested.startUtc -eq [string]$observation.providerAvailable.startUtc) {
            throw 'Requested and provider-available boundaries must remain distinct.'
        }
        if (-not (Test-CollectorObservationDescriptor -Observation $observation)) {
            throw 'Expected provider availability metadata to remain a valid observation descriptor.'
        }
    }
}

Describe 'Bounded evidence state vocabulary' {
    It 'accepts the closed terminal state combinations' {
        $valid = @(
            @('available', 'complete'),
            @('available', 'partial'),
            @('permission-denied', 'unavailable'),
            @('feature-unavailable', 'unavailable'),
            @('license-unavailable', 'unavailable'),
            @('retention-limited', 'partial'),
            @('failed', 'failed')
        )
        foreach ($pair in $valid) {
            $state = New-CollectorEvidenceState -Availability $pair[0] -Completeness $pair[1]
            if (-not (Test-CollectorEvidenceState -EvidenceState $state)) {
                throw ('Expected valid evidence state {0}/{1}.' -f $pair[0], $pair[1])
            }
        }
    }

    It 'rejects an ambiguous mutated availability/completeness combination' {
        $state = New-CollectorEvidenceState -Availability 'permission-denied' -Completeness 'unavailable'
        $state.completeness = 'complete'
        if (Test-CollectorEvidenceState -EvidenceState $state) {
            throw 'Permission-denied evidence must not be described as complete.'
        }
    }

    It 'requires provider evidence for a retention-limited classification' {
        $observation = Get-TestObservationFixture
        $state = New-CollectorEvidenceState -Availability 'retention-limited' -Completeness 'partial'
        if (Test-CollectorBoundedEvidenceContract -Observation $observation -EvidenceState $state) {
            throw 'Retention-limited evidence without a provider window/caveat must fail closed.'
        }
    }

    It 'does not permit complete availability to overclaim a narrower provider window' {
        $observation = Get-TestObservationFixture -ProviderStart '2026-09-16T06:00:00Z' -ProviderEnd '2026-09-17T00:00:00Z'
        $state = New-CollectorEvidenceState -Availability 'available' -Completeness 'complete'
        if (Test-CollectorBoundedEvidenceContract -Observation $observation -EvidenceState $state) {
            throw 'Complete evidence must not claim coverage before the provider-available start.'
        }
    }
}

Describe 'Bounded provenance compatibility' {
    It 'preserves the existing point-in-time snapshot contract' {
        $snapshot = New-CollectorProvenanceSnapshot -RunId 'timeless' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'timeless' -ApiVersion 'test-v1' -RequestContext @{} -ItemCount 0 -Items @()
        if ($snapshot.Contains('observation') -or $snapshot.Contains('evidenceState')) {
            throw 'Point-in-time snapshots must not acquire synthetic observation metadata.'
        }
        $roundTrip = ($snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $roundTrip)) {
            throw 'Existing point-in-time snapshots must remain valid.'
        }
    }

    It 'persists an explicit complete zero-result bounded observation' {
        $observation = Get-TestObservationFixture
        $state = New-CollectorEvidenceState -Availability 'available' -Completeness 'complete'
        $snapshot = New-CollectorProvenanceSnapshot -RunId 'bounded-zero' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'bounded-zero' -ApiVersion 'test-v1' -RequestContext @{} -Observation $observation -EvidenceState $state -ItemCount 0 -Items @()
        $roundTrip = ($snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        if (-not (Test-CollectorObservationDescriptor -Observation $roundTrip.observation)) {
            throw 'Round-tripped bounded observation descriptor is invalid.'
        }
        if (-not (Test-CollectorEvidenceState -EvidenceState $roundTrip.evidenceState)) {
            throw 'Round-tripped bounded evidence state is invalid.'
        }
        if (-not (Test-CollectorBoundedEvidenceContract -Observation $roundTrip.observation -EvidenceState $roundTrip.evidenceState)) {
            throw 'Round-tripped bounded observation/evidence pair is invalid.'
        }
        if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $roundTrip)) {
            throw 'Expected complete zero-result bounded evidence to be schema-valid.'
        }
        if ([string]$roundTrip.evidenceState.availability -ne 'available' -or [string]$roundTrip.evidenceState.completeness -ne 'complete') {
            throw 'Zero-result bounded evidence must remain distinguishable from unavailable evidence.'
        }
    }

    It 'requires observation and evidence state as an atomic pair' {
        $observation = Get-TestObservationFixture
        {
            New-CollectorProvenanceSnapshot -RunId 'bad-pair' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Test' -SourceName 'bad-pair' -ApiVersion 'test-v1' -RequestContext @{} -Observation $observation -ItemCount 0 -Items @()
        } | Should -Throw '*must be supplied together*'
    }
}

Describe 'Bounded checkpoint resume identity' {
    BeforeEach {
        $script:run = Get-TestBoundedRunFixture
    }

    AfterEach {
        if ($script:run -and (Test-Path -LiteralPath $script:run.root)) {
            Remove-Item -LiteralPath $script:run.root -Recurse -Force
        }
    }

    It 'accepts a semantically equivalent UTC window on resume' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:run.runPath -RunId $script:run.runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $batches = Split-CollectorItems -Items @() -BatchSize 100
        $checkpoint = Initialize-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100 -Observation (Get-TestObservationFixture -Start '2026-09-15T19:00:00-05:00' -End '2026-09-16T19:00:00-05:00')
        Save-CollectorCheckpoint -RunPath $script:run.runPath -Checkpoint $checkpoint | Out-Null

        $persisted = Get-CollectorCheckpoint -RunPath $script:run.runPath -RunId $script:run.runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        { Initialize-CollectorBoundedCheckpointPlan -Checkpoint $persisted -Batches $batches -BatchSize 100 -Observation (Get-TestObservationFixture) -Resume | Out-Null } | Should -Not -Throw
    }

    It 'fails closed when the requested observation window changes on resume' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:run.runPath -RunId $script:run.runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        $batches = Split-CollectorItems -Items @() -BatchSize 100
        $checkpoint = Initialize-CollectorBoundedCheckpointPlan -Checkpoint $checkpoint -Batches $batches -BatchSize 100 -Observation (Get-TestObservationFixture)
        Save-CollectorCheckpoint -RunPath $script:run.runPath -Checkpoint $checkpoint | Out-Null

        $persisted = Get-CollectorCheckpoint -RunPath $script:run.runPath -RunId $script:run.runId -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        {
            Initialize-CollectorBoundedCheckpointPlan -Checkpoint $persisted -Batches $batches -BatchSize 100 -Observation (Get-TestObservationFixture -Start '2026-09-16T01:00:00Z') -Resume | Out-Null
        } | Should -Throw '*observation-window mismatch*'
    }

    It 'marks a terminal retention-limited observation complete without calling it complete evidence' {
        $observation = Get-TestObservationFixture -ProviderStart '2026-09-16T06:00:00Z' -ProviderEnd '2026-09-17T00:00:00Z' -RetentionCaveat 'Six hours precede provider retention.'
        $state = New-CollectorEvidenceState -Availability 'retention-limited' -Completeness 'partial'
        $result = Add-TestBoundedFamily -Run $script:run -Observation $observation -EvidenceState $state

        if (-not [bool]$result.checkpoint.plan.completed) {
            throw 'A terminal retention-limited observation should complete execution planning.'
        }
        $snapshot = Get-Content -LiteralPath $result.artifactPath -Raw | ConvertFrom-Json
        if ([string]$snapshot.evidenceState.completeness -ne 'partial') {
            throw 'Terminal execution must not rewrite retention-limited evidence as complete.'
        }
    }

    It 'does not complete a plan when a succeeded batch claims ordinary collector failure evidence' {
        $observation = Get-TestObservationFixture
        $state = New-CollectorEvidenceState -Availability 'failed' -Completeness 'failed'
        $result = Add-TestBoundedFamily -Run $script:run -Observation $observation -EvidenceState $state
        if ([bool]$result.checkpoint.plan.completed) {
            throw 'Ordinary collector failure evidence cannot satisfy a bounded checkpoint plan.'
        }
    }
}

Describe 'Offline package validation of bounded evidence' {
    BeforeEach {
        $script:run = Get-TestBoundedRunFixture
    }

    AfterEach {
        if ($script:run -and (Test-Path -LiteralPath $script:run.root)) {
            Remove-Item -LiteralPath $script:run.root -Recurse -Force
        }
    }

    It 'admits a terminal bounded zero-result family through offline catalog generation' {
        $observation = Get-TestObservationFixture
        $state = New-CollectorEvidenceState -Availability 'available' -Completeness 'complete'
        Add-TestBoundedFamily -Run $script:run -Observation $observation -EvidenceState $state | Out-Null
        Write-TestBoundedManifest -Run $script:run

        $result = Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath -ExpectedRunId $script:run.runId
        $catalog = Get-Content -LiteralPath $result.catalogPath -Raw | ConvertFrom-Json
        if (@($catalog.artifacts).Count -ne 1 -or [int]$catalog.artifacts[0].itemCount -ne 0) {
            throw 'Expected offline catalog generation to admit the validated bounded zero-result artifact.'
        }
    }

    It 'fails offline catalog regeneration after invalid availability/completeness mutation' {
        $observation = Get-TestObservationFixture
        $state = New-CollectorEvidenceState -Availability 'available' -Completeness 'complete'
        $family = Add-TestBoundedFamily -Run $script:run -Observation $observation -EvidenceState $state
        Write-TestBoundedManifest -Run $script:run
        Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath | Out-Null

        $snapshot = Get-Content -LiteralPath $family.artifactPath -Raw | ConvertFrom-Json
        $snapshot.evidenceState.availability = 'permission-denied'
        $snapshot.evidenceState.completeness = 'complete'
        [System.IO.File]::WriteAllText($family.artifactPath, ($snapshot | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))

        { Export-CollectorKnowledgeCatalog -RunPath $script:run.runPath | Out-Null } | Should -Throw '*Malformed snapshot contract*'
    }
}
