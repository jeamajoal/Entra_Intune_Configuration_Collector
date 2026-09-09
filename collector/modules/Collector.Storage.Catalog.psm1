Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

$script:CollectorCatalogStages = @('stage1', 'stage2', 'stage3')
$script:CollectorCatalogSections = @('entra-apps', 'entra-pim', 'entra-ca', 'entra-governance', 'intune-core', 'onprem-ad-gpo')
$script:CollectorCatalogStageKinds = @{ stage1 = 'inventory'; stage2 = 'detail'; stage3 = 'relationship' }

$script:CollectorCatalogDependencies = @{
    'stage2|entra-apps|applications' = @('applications')
    'stage2|entra-apps|servicePrincipals' = @('servicePrincipals')
    'stage2|entra-apps|groups' = @('groups')
    'stage2|entra-apps|applicationCredentials' = @('applications')
    'stage2|entra-apps|servicePrincipalCredentials' = @('servicePrincipals')
    'stage2|entra-pim|roleAssignmentScheduleInstances' = @('roleAssignmentScheduleInstances')
    'stage2|entra-pim|roleEligibilityScheduleInstances' = @('roleEligibilityScheduleInstances')
    'stage2|entra-ca|conditionalAccessPolicies' = @('conditionalAccessPolicies')
    'stage2|entra-ca|namedLocations' = @('namedLocations')
    'stage2|entra-ca|authenticationStrengthPolicies' = @('authenticationStrengthPolicies')
    'stage2|entra-ca|authenticationContextClassReferences' = @('authenticationContextClassReferences')
    'stage2|entra-governance|administrativeUnits' = @('administrativeUnits')
    'stage2|entra-governance|roleDefinitions' = @('roleDefinitions')
    'stage2|entra-governance|roleAssignments' = @('roleAssignments')
    'stage2|intune-core|mobileApps' = @('mobileApps')
    'stage2|intune-core|deviceManagementScripts' = @('deviceManagementScripts')
    'stage2|onprem-ad-gpo|domains' = @('domains')
    'stage2|onprem-ad-gpo|organizationalUnits' = @('organizationalUnits')
    'stage2|onprem-ad-gpo|groups' = @('groups')
    'stage2|onprem-ad-gpo|gpos' = @('gpos')
    'stage3|entra-apps|groupMembers' = @('groups')
    'stage3|entra-apps|servicePrincipalAppRoleAssignedTo' = @('servicePrincipals')
    'stage3|entra-apps|applicationFederatedIdentityCredentials' = @('applications')
    'stage3|entra-apps|delegatedGrants' = @('servicePrincipals')
    'stage3|entra-pim|pimScheduleEdges' = @('roleAssignmentScheduleInstances', 'roleEligibilityScheduleInstances')
    'stage3|entra-ca|conditionalAccessPolicyReferences' = @('conditionalAccessPolicies')
    'stage3|entra-governance|administrativeUnitMembers' = @('administrativeUnits')
    'stage3|entra-governance|administrativeUnitScopedRoleMembers' = @('administrativeUnits')
    'stage3|entra-governance|activeRoleAssignmentEdges' = @('roleAssignments')
    'stage3|intune-core|mobileAppAssignments' = @('mobileApps')
    'stage3|intune-core|deviceManagementScriptAssignments' = @('deviceManagementScripts')
    'stage3|onprem-ad-gpo|domainRootAcl' = @('domains')
    'stage3|onprem-ad-gpo|ouAcl' = @('organizationalUnits')
    'stage3|onprem-ad-gpo|gpoPermissions' = @('gpos')
    'stage3|onprem-ad-gpo|groupMembersOnPrem' = @('groups')
}

$script:CollectorCatalogRelationships = @{
    'onprem-ad-gpo|domainRootAcl' = [pscustomobject]@{ Type = 'acl'; Source = @('ad.domain'); Target = @('ad.security-principal') }
    'onprem-ad-gpo|ouAcl' = [pscustomobject]@{ Type = 'acl'; Source = @('ad.organizational-unit'); Target = @('ad.security-principal') }
    'onprem-ad-gpo|gpoPermissions' = [pscustomobject]@{ Type = 'acl'; Source = @('gpo.policy'); Target = @('ad.security-principal') }
    'entra-apps|groupMembers' = [pscustomobject]@{ Type = 'membership'; Source = @('entra.group'); Target = @('entra.directory-object') }
    'onprem-ad-gpo|groupMembersOnPrem' = [pscustomobject]@{ Type = 'membership'; Source = @('ad.group'); Target = @('ad.directory-object') }
    'intune-core|mobileAppAssignments' = [pscustomobject]@{ Type = 'assignment'; Source = @('intune.mobile-app'); Target = @('intune.assignment-target') }
    'intune-core|deviceManagementScriptAssignments' = [pscustomobject]@{ Type = 'assignment'; Source = @('intune.device-management-script'); Target = @('intune.assignment-target') }
    'entra-apps|servicePrincipalAppRoleAssignedTo' = [pscustomobject]@{ Type = 'assignment'; Source = @('entra.service-principal'); Target = @('entra.directory-object') }
    'entra-apps|applicationFederatedIdentityCredentials' = [pscustomobject]@{ Type = 'federated-trust'; Source = @('entra.application'); Target = @('entra.federated-identity-credential') }
    'entra-apps|delegatedGrants' = [pscustomobject]@{ Type = 'grant'; Source = @('entra.service-principal'); Target = @('entra.service-principal', 'entra.directory-object') }
    'entra-pim|pimScheduleEdges' = [pscustomobject]@{ Type = 'role-governance'; Source = @('entra.pim-role-assignment-schedule-instance', 'entra.pim-role-eligibility-schedule-instance'); Target = @('entra.directory-object', 'entra.directory-role-definition', 'entra.directory-scope', 'entra.app-scope') }
    'entra-ca|conditionalAccessPolicyReferences' = [pscustomobject]@{ Type = 'policy-reference'; Source = @('entra.conditional-access-policy'); Target = @('entra.user', 'entra.group', 'entra.directory-role-template', 'entra.application-app-id', 'entra.service-principal', 'entra.named-location', 'entra.authentication-context', 'entra.authentication-strength-policy', 'entra.terms-of-use', 'entra.custom-authentication-factor', 'entra.tenant', 'entra.conditional-access-template', 'entra.conditional-access-user-action', 'entra.conditional-access-selector') }
    'entra-governance|administrativeUnitMembers' = [pscustomobject]@{ Type = 'membership'; Source = @('entra.administrative-unit'); Target = @('entra.directory-object') }
    'entra-governance|administrativeUnitScopedRoleMembers' = [pscustomobject]@{ Type = 'role-governance'; Source = @('entra.administrative-unit'); Target = @('entra.directory-role', 'entra.user') }
    'entra-governance|activeRoleAssignmentEdges' = [pscustomobject]@{ Type = 'role-governance'; Source = @('entra.role-assignment'); Target = @('entra.directory-object', 'entra.directory-role-definition', 'entra.tenant', 'entra.administrative-unit', 'entra.app-scope', 'entra.directory-scope') }
}

function Get-CollectorCatalogKey {
    param([string]$Stage, [string]$Section, [string]$Family)
    return ('{0}|{1}|{2}' -f $Stage, $Section, $Family)
}

function Get-CollectorCatalogKind {
    param([Parameter(Mandatory = $true)][string]$Stage)
    if (-not $script:CollectorCatalogStageKinds.ContainsKey($Stage)) {
        throw ('Catalog generation does not support stage {0}.' -f $Stage)
    }
    return [string]$script:CollectorCatalogStageKinds[$Stage]
}

function ConvertTo-CollectorCatalogTimestamp {
    param([Parameter(Mandatory = $true)][object]$Value, [Parameter(Mandatory = $true)][string]$Label)

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }

    if ($Value -is [datetime]) {
        $dateTimeValue = [datetime]$Value
        if ($dateTimeValue.Kind -eq [System.DateTimeKind]::Unspecified) {
            $dateTimeValue = [DateTime]::SpecifyKind($dateTimeValue, [System.DateTimeKind]::Utc)
        }
        return ([DateTimeOffset]$dateTimeValue).ToUniversalTime()
    }

    if (-not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw ('{0} must be a persisted string or parsed date/time timestamp.' -f $Label)
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw ('{0} is not a valid round-trip timestamp: {1}' -f $Label, $Value)
    }
    return $parsed.ToUniversalTime()
}

function Get-CollectorCatalogRunState {
    param([Parameter(Mandatory = $true)][string]$RunPath, [string]$ExpectedRunId)

    if (-not (Test-Path -LiteralPath $RunPath -PathType Container)) {
        throw ('Catalog generation requires an existing run directory: {0}' -f $RunPath)
    }
    $fullRunPath = [System.IO.Path]::GetFullPath($RunPath)
    $runId = ([System.IO.DirectoryInfo]$fullRunPath).Name
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw ('Catalog generation cannot determine run identity from run path: {0}' -f $RunPath)
    }

    $manifestPath = Get-CollectorManifestPath -RunPath $fullRunPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw ('Catalog generation requires the canonical run manifest: {0}' -f $manifestPath)
    }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw ('Catalog generation cannot read the run manifest: {0}' -f $_.Exception.Message) }
    if ($null -eq $manifest) { throw 'Catalog generation cannot use a null run manifest.' }

    if ($manifest.PSObject.Properties.Match('schemaVersion').Count -eq 0 -or -not ($manifest.schemaVersion -is [string]) -or @('1.0', '1.1') -cnotcontains [string]$manifest.schemaVersion) {
        throw 'Catalog generation requires manifest schemaVersion string 1.0 or 1.1.'
    }
    if ($manifest.PSObject.Properties.Match('runId').Count -eq 0 -or -not ($manifest.runId -is [string]) -or [string]::IsNullOrWhiteSpace([string]$manifest.runId)) {
        throw 'Catalog generation requires a non-empty string manifest runId.'
    }
    if ([string]$manifest.runId -ne $runId -or (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and [string]$manifest.runId -ne $ExpectedRunId)) {
        throw ('Catalog generation run identity mismatch. Directory={0}; manifest={1}; expected={2}.' -f $runId, $manifest.runId, $ExpectedRunId)
    }
    if ($manifest.PSObject.Properties.Match('status').Count -eq 0 -or -not ($manifest.status -is [string]) -or @('Completed', 'CompletedWithErrors') -cnotcontains [string]$manifest.status) {
        throw 'Catalog generation requires terminal manifest status Completed or CompletedWithErrors.'
    }
    if ($manifest.PSObject.Properties.Match('completedUtc').Count -eq 0) { throw 'Catalog generation requires manifest completedUtc.' }
    $completedUtc = ConvertTo-CollectorCatalogTimestamp -Value $manifest.completedUtc -Label 'manifest completedUtc'

    $invocationCount = 1
    if ($manifest.PSObject.Properties.Match('invocations').Count -gt 0 -and $null -ne $manifest.invocations) {
        if (-not ($manifest.invocations -is [System.Array])) { throw 'Catalog generation requires manifest invocations to be an array when present.' }
        $invocationCount = @($manifest.invocations).Count
    }
    elseif ([string]$manifest.schemaVersion -eq '1.1') { throw 'Catalog generation requires manifest schemaVersion 1.1 to contain invocations.' }
    if ($invocationCount -lt 1) { throw 'Catalog generation requires at least one manifest invocation.' }
    if ($manifest.PSObject.Properties.Match('checkpointSummary').Count -eq 0 -or $null -eq $manifest.checkpointSummary -or -not ($manifest.checkpointSummary -is [System.Array])) {
        throw 'Catalog generation requires manifest checkpointSummary to be an array.'
    }

    return [pscustomobject]@{ RunPath = $fullRunPath; RunId = $runId; Manifest = $manifest; CompletedUtc = $completedUtc; InvocationCount = [int]$invocationCount }
}

function Get-CollectorCatalogSummaryCount {
    param([Parameter(Mandatory = $true)][object]$Row, [Parameter(Mandatory = $true)][string]$Name, [switch]$AllowMissingAsZero)
    if ($Row.PSObject.Properties.Match($Name).Count -eq 0) {
        if ($AllowMissingAsZero) { return 0 }
        throw ('Manifest checkpoint summary is missing required property {0}.' -f $Name)
    }
    $value = Get-CollectorBatchCountValue -Batch $Row -PropertyName $Name
    if ($null -eq $value) { throw ('Manifest checkpoint summary property {0} is not a non-negative integer.' -f $Name) }
    return [int]$value
}

function Assert-CollectorCatalogManifestSummary {
    param([Parameter(Mandatory = $true)][object[]]$ActualSummary, [Parameter(Mandatory = $true)][object]$Manifest)

    $persistedRows = @($Manifest.checkpointSummary)
    if ($persistedRows.Count -ne $ActualSummary.Count) {
        throw ('Catalog generation checkpoint summary count mismatch. Manifest={0}; actual={1}.' -f $persistedRows.Count, $ActualSummary.Count)
    }
    $persisted = @{}
    foreach ($row in $persistedRows) {
        if ($null -eq $row) { throw 'Manifest checkpoint summary contains a null row.' }
        foreach ($name in @('stage', 'section', 'family')) {
            if ($row.PSObject.Properties.Match($name).Count -eq 0 -or -not ($row.$name -is [string]) -or [string]::IsNullOrWhiteSpace([string]$row.$name)) {
                throw ('Manifest checkpoint summary has invalid {0}.' -f $name)
            }
        }
        $key = Get-CollectorCatalogKey -Stage $row.stage -Section $row.section -Family $row.family
        if ($persisted.ContainsKey($key)) { throw ('Manifest checkpoint summary contains duplicate identity {0}.' -f $key) }
        $persisted[$key] = $row
    }

    foreach ($actual in $ActualSummary) {
        $key = Get-CollectorCatalogKey -Stage $actual.stage -Section $actual.section -Family $actual.family
        if (-not $persisted.ContainsKey($key)) { throw ('Manifest checkpoint summary is missing current checkpoint identity {0}.' -f $key) }
        $row = $persisted[$key]
        $checks = @{
            batchCount = Get-CollectorCatalogSummaryCount -Row $row -Name 'batchCount'
            succeededBatches = Get-CollectorCatalogSummaryCount -Row $row -Name 'succeededBatches'
            failedBatches = Get-CollectorCatalogSummaryCount -Row $row -Name 'failedBatches'
            missingBatches = Get-CollectorCatalogSummaryCount -Row $row -Name 'missingBatches' -AllowMissingAsZero
            inProgressBatches = Get-CollectorCatalogSummaryCount -Row $row -Name 'inProgressBatches' -AllowMissingAsZero
            itemCount = Get-CollectorCatalogSummaryCount -Row $row -Name 'itemCount'
        }
        foreach ($name in $checks.Keys) {
            if ([int]$actual.$name -ne [int]$checks[$name]) {
                throw ('Catalog generation checkpoint summary mismatch for {0} property {1}.' -f $key, $name)
            }
        }
    }
}

function Assert-CollectorCatalogIdentityShape {
    param([string]$Stage, [string]$Section, [string]$Family)
    if ($script:CollectorCatalogStages -cnotcontains $Stage) { throw ('Catalog generation encountered unsupported stage {0}.' -f $Stage) }
    if ($script:CollectorCatalogSections -cnotcontains $Section) { throw ('Catalog generation encountered unsupported section {0}.' -f $Section) }
    if ($Family -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw ('Catalog generation encountered invalid family identity {0}.' -f $Family) }
}

function Get-CollectorCatalogSnapshotPath {
    param([string]$RunPath, [string]$Stage, [string]$Section, [string]$Family, [string]$BatchId)
    return [System.IO.Path]::GetFullPath((Join-Path $RunPath (Join-Path $Stage (Join-Path $Section (Join-Path $Family ('batch-{0}.json' -f $BatchId))))))
}

function Get-CollectorCatalogArtifactSet {
    param([string]$RunPath, [string]$RunId, [string]$RunStatus, [DateTimeOffset]$ManifestCompletedUtc, [object[]]$CheckpointSummary)

    $stageRank = @{ stage1 = 1; stage2 = 2; stage3 = 3 }
    $sectionRank = @{ 'entra-apps' = 1; 'entra-pim' = 2; 'entra-ca' = 3; 'entra-governance' = 4; 'intune-core' = 5; 'onprem-ad-gpo' = 6 }
    $summaryRows = @($CheckpointSummary | Sort-Object @{ Expression = { $stageRank[[string]$_.stage] } }, @{ Expression = { $sectionRank[[string]$_.section] } }, @{ Expression = { [string]$_.family } })
    $artifacts = @()

    foreach ($summary in $summaryRows) {
        $stage = [string]$summary.stage; $section = [string]$summary.section; $family = [string]$summary.family
        Assert-CollectorCatalogIdentityShape -Stage $stage -Section $section -Family $family
        if ([int]$summary.inProgressBatches -gt 0) { throw ('Terminal catalog source contains InProgress batches for {0}/{1}/{2}.' -f $stage, $section, $family) }
        if ($RunStatus -eq 'Completed' -and ([int]$summary.failedBatches -gt 0 -or [int]$summary.missingBatches -gt 0 -or [int]$summary.succeededBatches -ne [int]$summary.batchCount)) {
            throw ('Completed manifest has non-success checkpoint state for {0}/{1}/{2}.' -f $stage, $section, $family)
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $RunId -Stage $stage -Section $section -Family $family
        if ((ConvertTo-CollectorCatalogTimestamp $checkpoint.updatedUtc ('checkpoint updatedUtc for {0}/{1}/{2}' -f $stage, $section, $family)) -gt $ManifestCompletedUtc) {
            throw ('Checkpoint evidence is newer than the terminal manifest for {0}/{1}/{2}.' -f $stage, $section, $family)
        }
        if ($checkpoint.PSObject.Properties.Match('plan').Count -eq 0 -or $null -eq $checkpoint.plan) { throw ('Missing checkpoint plan for {0}/{1}/{2}.' -f $stage, $section, $family) }
        if ($checkpoint.plan.PSObject.Properties.Match('completed').Count -eq 0 -or -not ($checkpoint.plan.completed -is [bool])) { throw ('Invalid checkpoint plan completion state for {0}/{1}/{2}.' -f $stage, $section, $family) }
        if ($RunStatus -eq 'Completed' -and -not [bool]$checkpoint.plan.completed) { throw ('Completed manifest has incomplete checkpoint plan for {0}/{1}/{2}.' -f $stage, $section, $family) }

        $expectedCount = Get-CollectorBatchCountValue -Batch $checkpoint.plan -PropertyName 'expectedBatchCount'
        $planned = @($checkpoint.plan.batches); $recorded = @($checkpoint.batches)
        if ($null -eq $expectedCount -or $expectedCount -lt 1 -or $planned.Count -ne $expectedCount -or $recorded.Count -ne $expectedCount) {
            throw ('Checkpoint batch identity set is incomplete for {0}/{1}/{2}.' -f $stage, $section, $family)
        }

        $plannedById = @{}; $recordedById = @{}
        foreach ($batch in $planned) {
            if ($null -eq $batch -or $batch.PSObject.Properties.Match('batchId').Count -eq 0 -or -not ($batch.batchId -is [string]) -or [string]$batch.batchId -notmatch '^[0-9]{4,}$') { throw ('Invalid planned batch identity for {0}/{1}/{2}.' -f $stage, $section, $family) }
            if ($plannedById.ContainsKey([string]$batch.batchId)) { throw ('Duplicate planned batch identity for {0}/{1}/{2}.' -f $stage, $section, $family) }
            $plannedById[[string]$batch.batchId] = $batch
        }
        foreach ($batch in $recorded) {
            if ($null -eq $batch -or $batch.PSObject.Properties.Match('batchId').Count -eq 0 -or -not ($batch.batchId -is [string]) -or [string]$batch.batchId -notmatch '^[0-9]{4,}$') { throw ('Invalid recorded batch identity for {0}/{1}/{2}.' -f $stage, $section, $family) }
            if ($recordedById.ContainsKey([string]$batch.batchId)) { throw ('Duplicate recorded batch identity for {0}/{1}/{2}.' -f $stage, $section, $family) }
            $recordedById[[string]$batch.batchId] = $batch
        }
        foreach ($batchId in $plannedById.Keys) { if (-not $recordedById.ContainsKey($batchId)) { throw ('Missing recorded batch {0} for {1}/{2}/{3}.' -f $batchId, $stage, $section, $family) } }

        foreach ($batchId in @($recordedById.Keys | Sort-Object { [long]$_ })) {
            $batch = $recordedById[$batchId]
            if ([string]$batch.status -ne 'Succeeded') { continue }
            if (-not (Test-CollectorSucceededBatchCountIntegrity -Batch $batch)) { throw ('Invalid succeeded-batch counts for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }
            if ($batch.PSObject.Properties.Match('artifactPath').Count -eq 0 -or -not ($batch.artifactPath -is [string]) -or [string]::IsNullOrWhiteSpace([string]$batch.artifactPath)) { throw ('Succeeded batch lacks artifact path for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }
            if ((ConvertTo-CollectorCatalogTimestamp $batch.updatedUtc ('batch updatedUtc for {0}/{1}/{2}/{3}' -f $stage, $section, $family, $batchId)) -gt $ManifestCompletedUtc) { throw ('Batch evidence is newer than terminal manifest for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }

            $plannedBatch = $plannedById[$batchId]
            $plannedCount = Get-CollectorBatchCountValue -Batch $plannedBatch -PropertyName 'itemCount'
            $checkpointCount = Get-CollectorBatchCountValue -Batch $batch -PropertyName 'itemCount'
            if ($null -eq $plannedCount -or $null -eq $checkpointCount -or ($stage -ne 'stage3' -and $plannedCount -ne $checkpointCount)) { throw ('Planned/checkpoint cardinality mismatch for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }

            $snapshotPath = Get-CollectorCatalogSnapshotPath -RunPath $RunPath -Stage $stage -Section $section -Family $family -BatchId $batchId
            if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw ('Catalog generation requires canonical snapshot {0}.' -f $snapshotPath) }
            try { $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json }
            catch { throw ('Catalog generation cannot read snapshot {0}: {1}' -f $snapshotPath, $_.Exception.Message) }
            if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $snapshot)) { throw ('Malformed snapshot contract for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }

            $expectedIdentity = @{ runId = $RunId; stage = $stage; section = $section; family = $family; batchId = $batchId }
            foreach ($name in @('runId', 'stage', 'section', 'family', 'batchId')) {
                if ($snapshot.PSObject.Properties.Match($name).Count -eq 0 -or -not ($snapshot.$name -is [string]) -or [string]$snapshot.$name -ne [string]$expectedIdentity[$name]) { throw ('Snapshot identity mismatch for {0}/{1}/{2}/{3}: {4}.' -f $stage, $section, $family, $batchId, $name) }
            }
            if ((ConvertTo-CollectorCatalogTimestamp $snapshot.collectedUtc ('snapshot collectedUtc for {0}/{1}/{2}/{3}' -f $stage, $section, $family, $batchId)) -gt $ManifestCompletedUtc) { throw ('Snapshot evidence is newer than terminal manifest for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }

            $snapshotCount = Get-CollectorBatchCountValue -Batch $snapshot -PropertyName 'itemCount'
            if ($null -eq $snapshotCount -or $snapshotCount -ne $checkpointCount -or @($snapshot.items).Count -ne $checkpointCount) { throw ('Snapshot/checkpoint cardinality mismatch for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }
            if ($stage -eq 'stage1') {
                if ($plannedBatch.PSObject.Properties.Match('fingerprint').Count -eq 0 -or -not ($plannedBatch.fingerprint -is [string]) -or [string]::IsNullOrWhiteSpace([string]$plannedBatch.fingerprint)) { throw ('Stage1 plan fingerprint missing for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }
                if ((Get-CollectorSnapshotBatchFingerprint -Items @($snapshot.items)) -ne [string]$plannedBatch.fingerprint) { throw ('Stage1 fingerprint mismatch for {0}/{1}/{2}/{3}.' -f $stage, $section, $family, $batchId) }
            }
            foreach ($name in @('sourceType', 'sourceName', 'apiVersion')) { if (-not ($snapshot.$name -is [string]) -or [string]::IsNullOrWhiteSpace([string]$snapshot.$name)) { throw ('Snapshot provenance {0} is invalid for {1}/{2}/{3}/{4}.' -f $name, $stage, $section, $family, $batchId) } }

            $artifacts += [pscustomobject][ordered]@{
                runId = $RunId; stage = $stage; section = $section; family = $family; batchId = $batchId; kind = Get-CollectorCatalogKind $stage
                relativePath = ('{0}/{1}/{2}/batch-{3}.json' -f $stage, $section, $family, $batchId)
                checkpointRelativePath = ('checkpoints/{0}/{1}/{2}.json' -f $stage, $section, $family)
                snapshotSchemaVersion = [string]$snapshot.schemaVersion; checkpointSchemaVersion = [string]$checkpoint.schemaVersion; itemCount = [int]$snapshotCount
                provenance = [pscustomobject][ordered]@{ sourceType = [string]$snapshot.sourceType; sourceName = [string]$snapshot.sourceName; apiVersion = [string]$snapshot.apiVersion; isBeta = [bool]$snapshot.isBeta }
            }
        }
    }
    if ($artifacts.Count -lt 1) { throw 'Catalog generation found no admissible successful snapshot artifacts.' }
    return @($artifacts)
}

function Get-CollectorCatalogDependencySet {
    param([object[]]$Artifacts)
    $families = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($artifact in $Artifacts) { $families.Add((Get-CollectorCatalogKey $artifact.stage $artifact.section $artifact.family)) | Out-Null }

    $dependencies = @(); $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($artifact in @($Artifacts | Where-Object { $_.stage -eq 'stage2' -or $_.stage -eq 'stage3' } | Sort-Object stage, section, family)) {
        $consumerKey = Get-CollectorCatalogKey $artifact.stage $artifact.section $artifact.family
        if (-not $seen.Add($consumerKey)) { continue }
        if (-not $script:CollectorCatalogDependencies.ContainsKey($consumerKey)) { throw ('Catalog generation has no dependency contract for admitted consumer {0}.' -f $consumerKey) }
        foreach ($providerFamily in @($script:CollectorCatalogDependencies[$consumerKey])) {
            $providerKey = Get-CollectorCatalogKey 'stage1' $artifact.section $providerFamily
            if (-not $families.Contains($providerKey)) { throw ('Catalog generation cannot resolve required execution-input provider {0} for consumer {1}.' -f $providerKey, $consumerKey) }
            $dependencies += [pscustomobject][ordered]@{
                dependencyType = 'execution-input'
                consumer = [pscustomobject][ordered]@{ stage = [string]$artifact.stage; section = [string]$artifact.section; family = [string]$artifact.family; kind = Get-CollectorCatalogKind ([string]$artifact.stage) }
                provider = [pscustomobject][ordered]@{ stage = 'stage1'; section = [string]$artifact.section; family = [string]$providerFamily; kind = 'inventory' }
            }
        }
    }
    return @($dependencies | Sort-Object @{ Expression = { [string]$_.consumer.stage } }, @{ Expression = { [string]$_.consumer.section } }, @{ Expression = { [string]$_.consumer.family } }, @{ Expression = { [string]$_.provider.family } })
}

function Get-CollectorCatalogRelationshipSet {
    param([object[]]$Artifacts)
    $relationships = @(); $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($artifact in @($Artifacts | Where-Object { $_.stage -eq 'stage3' } | Sort-Object section, family)) {
        $key = '{0}|{1}' -f $artifact.section, $artifact.family
        if (-not $seen.Add($key)) { continue }
        if (-not $script:CollectorCatalogRelationships.ContainsKey($key)) { throw ('Catalog generation has no relationship identity-domain contract for admitted Stage3 family {0}.' -f $key) }
        $definition = $script:CollectorCatalogRelationships[$key]
        $relationships += [pscustomobject][ordered]@{ stage = 'stage3'; section = [string]$artifact.section; family = [string]$artifact.family; relationshipType = [string]$definition.Type; sourceIdentityDomains = @($definition.Source); targetIdentityDomains = @($definition.Target) }
    }
    return @($relationships | Sort-Object section, family)
}

function Save-CollectorKnowledgeCatalog {
    param([string]$RunPath, [object]$Catalog)
    $directory = Join-Path $RunPath 'catalog'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
    $path = Join-Path $directory 'knowledge-catalog.json'; $suffix = [Guid]::NewGuid().ToString('N')
    $temp = Join-Path $directory ('.knowledge-catalog.json.{0}.tmp' -f $suffix); $backup = Join-Path $directory ('.knowledge-catalog.json.{0}.bak' -f $suffix)
    try {
        [System.IO.File]::WriteAllText($temp, ($Catalog | ConvertTo-Json -Depth 30 -Compress), [System.Text.UTF8Encoding]::new($false))
        $roundTrip = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
        if ($null -eq $roundTrip -or [string]$roundTrip.catalogId -ne [string]$Catalog.catalogId -or [string]$roundTrip.runId -ne [string]$Catalog.runId) { throw 'Catalog temporary-file round-trip identity validation failed.' }
        if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::Replace($temp, $path, $backup, $true) } else { [System.IO.File]::Move($temp, $path) }
    }
    finally { foreach ($item in @($temp, $backup)) { if (Test-Path -LiteralPath $item) { Remove-Item -LiteralPath $item -Force -ErrorAction SilentlyContinue } } }
    return $path
}

function Export-CollectorKnowledgeCatalog {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This command explicitly materializes the derived offline catalog and has no WhatIf contract.')]
    param([Parameter(Mandatory = $true)][string]$RunPath, [string]$ExpectedRunId)

    $run = Get-CollectorCatalogRunState -RunPath $RunPath -ExpectedRunId $ExpectedRunId
    $summary = @(Get-CollectorCheckpointSummary -RunPath $run.RunPath)
    Assert-CollectorCatalogManifestSummary -ActualSummary $summary -Manifest $run.Manifest
    $artifacts = @(Get-CollectorCatalogArtifactSet -RunPath $run.RunPath -RunId $run.RunId -RunStatus ([string]$run.Manifest.status) -ManifestCompletedUtc $run.CompletedUtc -CheckpointSummary $summary)
    $dependencies = @(Get-CollectorCatalogDependencySet -Artifacts $artifacts)
    $relationships = @(Get-CollectorCatalogRelationshipSet -Artifacts $artifacts)

    $catalog = [pscustomobject][ordered]@{
        schemaVersion = '1.0'; catalogId = ('catalog-v1:{0}' -f $run.RunId); runId = $run.RunId; runStatus = [string]$run.Manifest.status
        sourceManifest = [pscustomobject][ordered]@{ relativePath = 'manifest/run-manifest.json'; schemaVersion = [string]$run.Manifest.schemaVersion; completedUtc = $run.CompletedUtc.ToString('o'); status = [string]$run.Manifest.status; invocationCount = [int]$run.InvocationCount }
        artifacts = @($artifacts); dependencies = @($dependencies); relationships = @($relationships)
    }
    $catalogPath = Save-CollectorKnowledgeCatalog -RunPath $run.RunPath -Catalog $catalog
    return [pscustomobject]@{ runId = $run.RunId; catalogPath = $catalogPath; artifactCount = $artifacts.Count; dependencyCount = $dependencies.Count; relationshipCount = $relationships.Count; runStatus = [string]$run.Manifest.status }
}

Export-ModuleMember -Function 'Export-CollectorKnowledgeCatalog'
