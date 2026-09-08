Set-StrictMode -Version Latest

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

$script:CollectorCatalogStages = @('stage1', 'stage2', 'stage3')
$script:CollectorCatalogSections = @('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo')
$script:CollectorCatalogStageKinds = @{
    stage1 = 'inventory'
    stage2 = 'detail'
    stage3 = 'relationship'
}

$script:CollectorCatalogDependencyDefinitions = @(
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'entra-apps'; consumerFamily = 'applications'; providerFamilies = @('applications') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'entra-apps'; consumerFamily = 'servicePrincipals'; providerFamilies = @('servicePrincipals') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'entra-apps'; consumerFamily = 'groups'; providerFamilies = @('groups') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'entra-apps'; consumerFamily = 'applicationCredentials'; providerFamilies = @('applications') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'entra-apps'; consumerFamily = 'servicePrincipalCredentials'; providerFamilies = @('servicePrincipals') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'entra-pim'; consumerFamily = 'roleAssignmentScheduleInstances'; providerFamilies = @('roleAssignmentScheduleInstances') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'entra-pim'; consumerFamily = 'roleEligibilityScheduleInstances'; providerFamilies = @('roleEligibilityScheduleInstances') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'intune-core'; consumerFamily = 'mobileApps'; providerFamilies = @('mobileApps') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'intune-core'; consumerFamily = 'deviceManagementScripts'; providerFamilies = @('deviceManagementScripts') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'onprem-ad-gpo'; consumerFamily = 'domains'; providerFamilies = @('domains') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'onprem-ad-gpo'; consumerFamily = 'organizationalUnits'; providerFamilies = @('organizationalUnits') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'onprem-ad-gpo'; consumerFamily = 'groups'; providerFamilies = @('groups') },
    [pscustomobject]@{ consumerStage = 'stage2'; section = 'onprem-ad-gpo'; consumerFamily = 'gpos'; providerFamilies = @('gpos') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'entra-apps'; consumerFamily = 'groupMembers'; providerFamilies = @('groups') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'entra-apps'; consumerFamily = 'servicePrincipalAppRoleAssignedTo'; providerFamilies = @('servicePrincipals') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'entra-apps'; consumerFamily = 'applicationFederatedIdentityCredentials'; providerFamilies = @('applications') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'entra-apps'; consumerFamily = 'delegatedGrants'; providerFamilies = @('servicePrincipals') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'entra-pim'; consumerFamily = 'pimScheduleEdges'; providerFamilies = @('roleAssignmentScheduleInstances', 'roleEligibilityScheduleInstances') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'intune-core'; consumerFamily = 'mobileAppAssignments'; providerFamilies = @('mobileApps') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'intune-core'; consumerFamily = 'deviceManagementScriptAssignments'; providerFamilies = @('deviceManagementScripts') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'onprem-ad-gpo'; consumerFamily = 'domainRootAcl'; providerFamilies = @('domains') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'onprem-ad-gpo'; consumerFamily = 'ouAcl'; providerFamilies = @('organizationalUnits') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'onprem-ad-gpo'; consumerFamily = 'gpoPermissions'; providerFamilies = @('gpos') },
    [pscustomobject]@{ consumerStage = 'stage3'; section = 'onprem-ad-gpo'; consumerFamily = 'groupMembersOnPrem'; providerFamilies = @('groups') }
)

$script:CollectorCatalogRelationshipDefinitions = @(
    [pscustomobject]@{ section = 'onprem-ad-gpo'; family = 'domainRootAcl'; relationshipType = 'acl'; sourceDomains = @('ad.domain'); targetDomains = @('ad.security-principal') },
    [pscustomobject]@{ section = 'onprem-ad-gpo'; family = 'ouAcl'; relationshipType = 'acl'; sourceDomains = @('ad.organizational-unit'); targetDomains = @('ad.security-principal') },
    [pscustomobject]@{ section = 'onprem-ad-gpo'; family = 'gpoPermissions'; relationshipType = 'acl'; sourceDomains = @('gpo.policy'); targetDomains = @('ad.security-principal') },
    [pscustomobject]@{ section = 'entra-apps'; family = 'groupMembers'; relationshipType = 'membership'; sourceDomains = @('entra.group'); targetDomains = @('entra.directory-object') },
    [pscustomobject]@{ section = 'onprem-ad-gpo'; family = 'groupMembersOnPrem'; relationshipType = 'membership'; sourceDomains = @('ad.group'); targetDomains = @('ad.directory-object') },
    [pscustomobject]@{ section = 'intune-core'; family = 'mobileAppAssignments'; relationshipType = 'assignment'; sourceDomains = @('intune.mobile-app'); targetDomains = @('intune.assignment-target') },
    [pscustomobject]@{ section = 'intune-core'; family = 'deviceManagementScriptAssignments'; relationshipType = 'assignment'; sourceDomains = @('intune.device-management-script'); targetDomains = @('intune.assignment-target') },
    [pscustomobject]@{ section = 'entra-apps'; family = 'servicePrincipalAppRoleAssignedTo'; relationshipType = 'assignment'; sourceDomains = @('entra.service-principal'); targetDomains = @('entra.directory-object') },
    [pscustomobject]@{ section = 'entra-apps'; family = 'applicationFederatedIdentityCredentials'; relationshipType = 'federated-trust'; sourceDomains = @('entra.application'); targetDomains = @('entra.federated-identity-credential') },
    [pscustomobject]@{ section = 'entra-apps'; family = 'delegatedGrants'; relationshipType = 'grant'; sourceDomains = @('entra.service-principal'); targetDomains = @('entra.service-principal', 'entra.directory-object') },
    [pscustomobject]@{ section = 'entra-pim'; family = 'pimScheduleEdges'; relationshipType = 'role-governance'; sourceDomains = @('entra.pim-role-assignment-schedule-instance', 'entra.pim-role-eligibility-schedule-instance'); targetDomains = @('entra.directory-object', 'entra.directory-role-definition', 'entra.directory-scope', 'entra.app-scope') }
)

function ConvertTo-CollectorCatalogTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw ('{0} must be a non-empty persisted string timestamp.' -f $Label)
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw ('{0} is not a valid round-trip timestamp: {1}' -f $Label, $Value)
    }

    return $parsed.ToUniversalTime()
}

function Get-CollectorCatalogRunIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath
    )

    if (-not (Test-Path -LiteralPath $RunPath -PathType Container)) {
        throw ('Catalog generation requires an existing run directory: {0}' -f $RunPath)
    }

    $fullRunPath = [System.IO.Path]::GetFullPath($RunPath)
    $runDirectory = [System.IO.DirectoryInfo]$fullRunPath
    if ([string]::IsNullOrWhiteSpace([string]$runDirectory.Name)) {
        throw ('Catalog generation cannot determine run identity from run path: {0}' -f $RunPath)
    }

    return [pscustomobject]@{
        RunPath = $fullRunPath
        RunId = [string]$runDirectory.Name
    }
}

function Get-CollectorCatalogManifestState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [string]$ExpectedRunId
    )

    $manifestPath = Get-CollectorManifestPath -RunPath $RunPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw ('Catalog generation requires the canonical run manifest: {0}' -f $manifestPath)
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw ('Catalog generation cannot read the run manifest: {0}' -f $_.Exception.Message)
    }

    if ($null -eq $manifest) {
        throw 'Catalog generation cannot use a null run manifest.'
    }

    if (
        $manifest.PSObject.Properties.Match('schemaVersion').Count -eq 0 -or
        -not ($manifest.schemaVersion -is [string]) -or
        @('1.0', '1.1') -cnotcontains [string]$manifest.schemaVersion
    ) {
        throw 'Catalog generation requires manifest schemaVersion string 1.0 or 1.1.'
    }

    if (
        $manifest.PSObject.Properties.Match('runId').Count -eq 0 -or
        -not ($manifest.runId -is [string]) -or
        [string]::IsNullOrWhiteSpace([string]$manifest.runId)
    ) {
        throw 'Catalog generation requires a non-empty string manifest runId.'
    }

    if ([string]$manifest.runId -ne $RunId) {
        throw ('Catalog generation run identity mismatch. Run directory={0}; manifest={1}.' -f $RunId, $manifest.runId)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunId) -and [string]$manifest.runId -ne $ExpectedRunId) {
        throw ('Catalog generation run identity mismatch. Expected={0}; manifest={1}.' -f $ExpectedRunId, $manifest.runId)
    }

    if (
        $manifest.PSObject.Properties.Match('status').Count -eq 0 -or
        -not ($manifest.status -is [string]) -or
        @('Completed', 'CompletedWithErrors') -cnotcontains [string]$manifest.status
    ) {
        throw ('Catalog generation requires terminal manifest status Completed or CompletedWithErrors; found {0}.' -f [string]$manifest.status)
    }

    if ($manifest.PSObject.Properties.Match('completedUtc').Count -eq 0) {
        throw 'Catalog generation requires manifest completedUtc.'
    }
    $completedUtc = ConvertTo-CollectorCatalogTimestamp -Value $manifest.completedUtc -Label 'manifest completedUtc'

    $invocationCount = 1
    if ($manifest.PSObject.Properties.Match('invocations').Count -gt 0 -and $null -ne $manifest.invocations) {
        if (-not ($manifest.invocations -is [System.Array])) {
            throw 'Catalog generation requires manifest invocations to be an array when present.'
        }
        $invocationCount = @($manifest.invocations).Count
    }
    elseif ([string]$manifest.schemaVersion -eq '1.1') {
        throw 'Catalog generation requires manifest schemaVersion 1.1 to contain invocations.'
    }

    if ($invocationCount -lt 1) {
        throw 'Catalog generation requires at least one manifest invocation.'
    }

    if ($manifest.PSObject.Properties.Match('checkpointSummary').Count -eq 0 -or $null -eq $manifest.checkpointSummary -or -not ($manifest.checkpointSummary -is [System.Array])) {
        throw 'Catalog generation requires manifest checkpointSummary to be an array.'
    }

    return [pscustomobject]@{
        Manifest = $manifest
        ManifestPath = $manifestPath
        CompletedUtc = $completedUtc
        InvocationCount = [int]$invocationCount
    }
}

function Get-CollectorCatalogSummaryCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [switch]$AllowMissingAsZero
    )

    if ($Row.PSObject.Properties.Match($PropertyName).Count -eq 0) {
        if ($AllowMissingAsZero) {
            return 0
        }
        throw ('Manifest checkpoint summary is missing required property {0}.' -f $PropertyName)
    }

    $value = Get-CollectorBatchCountValue -Batch $Row -PropertyName $PropertyName
    if ($null -eq $value) {
        throw ('Manifest checkpoint summary property {0} is not a non-negative integer.' -f $PropertyName)
    }
    return [int]$value
}

function Assert-CollectorCatalogManifestSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ActualSummary,

        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    $persistedSummary = @($Manifest.checkpointSummary)
    if ($persistedSummary.Count -ne $ActualSummary.Count) {
        throw ('Catalog generation checkpoint summary count mismatch. Manifest={0}; actual={1}.' -f $persistedSummary.Count, $ActualSummary.Count)
    }

    $persistedByKey = @{}
    foreach ($row in $persistedSummary) {
        if ($null -eq $row) {
            throw 'Manifest checkpoint summary contains a null row.'
        }
        foreach ($identityName in @('stage', 'section', 'family')) {
            if ($row.PSObject.Properties.Match($identityName).Count -eq 0 -or -not ($row.$identityName -is [string]) -or [string]::IsNullOrWhiteSpace([string]$row.$identityName)) {
                throw ('Manifest checkpoint summary has invalid {0}.' -f $identityName)
            }
        }
        $key = '{0}|{1}|{2}' -f [string]$row.stage, [string]$row.section, [string]$row.family
        if ($persistedByKey.ContainsKey($key)) {
            throw ('Manifest checkpoint summary contains duplicate identity {0}.' -f $key)
        }
        $persistedByKey[$key] = $row
    }

    foreach ($actual in $ActualSummary) {
        $key = '{0}|{1}|{2}' -f [string]$actual.stage, [string]$actual.section, [string]$actual.family
        if (-not $persistedByKey.ContainsKey($key)) {
            throw ('Manifest checkpoint summary is missing current checkpoint identity {0}.' -f $key)
        }

        $persisted = $persistedByKey[$key]
        $comparisons = @(
            [pscustomobject]@{ Name = 'batchCount'; Actual = [int]$actual.batchCount; Persisted = (Get-CollectorCatalogSummaryCount -Row $persisted -PropertyName 'batchCount') },
            [pscustomobject]@{ Name = 'succeededBatches'; Actual = [int]$actual.succeededBatches; Persisted = (Get-CollectorCatalogSummaryCount -Row $persisted -PropertyName 'succeededBatches') },
            [pscustomobject]@{ Name = 'failedBatches'; Actual = [int]$actual.failedBatches; Persisted = (Get-CollectorCatalogSummaryCount -Row $persisted -PropertyName 'failedBatches') },
            [pscustomobject]@{ Name = 'missingBatches'; Actual = [int]$actual.missingBatches; Persisted = (Get-CollectorCatalogSummaryCount -Row $persisted -PropertyName 'missingBatches' -AllowMissingAsZero) },
            [pscustomobject]@{ Name = 'inProgressBatches'; Actual = [int]$actual.inProgressBatches; Persisted = (Get-CollectorCatalogSummaryCount -Row $persisted -PropertyName 'inProgressBatches' -AllowMissingAsZero) },
            [pscustomobject]@{ Name = 'itemCount'; Actual = [int]$actual.itemCount; Persisted = (Get-CollectorCatalogSummaryCount -Row $persisted -PropertyName 'itemCount') }
        )
        foreach ($comparison in $comparisons) {
            if ($comparison.Actual -ne $comparison.Persisted) {
                throw ('Catalog generation checkpoint summary mismatch for {0} property {1}. Manifest={2}; actual={3}.' -f $key, $comparison.Name, $comparison.Persisted, $comparison.Actual)
            }
        }
    }
}

function Get-CollectorCatalogKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage
    )

    if (-not $script:CollectorCatalogStageKinds.ContainsKey($Stage)) {
        throw ('Catalog generation does not support stage {0}.' -f $Stage)
    }
    return [string]$script:CollectorCatalogStageKinds[$Stage]
}

function Get-CollectorCatalogCanonicalSnapshotPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RunPath,
        [Parameter(Mandatory = $true)] [string]$Stage,
        [Parameter(Mandatory = $true)] [string]$Section,
        [Parameter(Mandatory = $true)] [string]$Family,
        [Parameter(Mandatory = $true)] [string]$BatchId
    )

    $relativePath = Join-Path -Path $Stage -ChildPath (Join-Path -Path $Section -ChildPath (Join-Path -Path $Family -ChildPath ('batch-{0}.json' -f $BatchId)))
    return [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath $relativePath))
}

function Assert-CollectorCatalogIdentityShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Stage,
        [Parameter(Mandatory = $true)] [string]$Section,
        [Parameter(Mandatory = $true)] [string]$Family
    )

    if ($script:CollectorCatalogStages -cnotcontains $Stage) {
        throw ('Catalog generation encountered unsupported stage {0}.' -f $Stage)
    }
    if ($script:CollectorCatalogSections -cnotcontains $Section) {
        throw ('Catalog generation encountered unsupported section {0}.' -f $Section)
    }
    if ($Family -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw ('Catalog generation encountered invalid family identity {0}.' -f $Family)
    }
}

function Get-CollectorCatalogArtifactDescriptors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RunPath,
        [Parameter(Mandatory = $true)] [string]$RunId,
        [Parameter(Mandatory = $true)] [string]$RunStatus,
        [Parameter(Mandatory = $true)] [DateTimeOffset]$ManifestCompletedUtc,
        [Parameter(Mandatory = $true)] [object[]]$CheckpointSummary
    )

    $stageRank = @{ stage1 = 1; stage2 = 2; stage3 = 3 }
    $sectionRank = @{ 'entra-apps' = 1; 'entra-pim' = 2; 'intune-core' = 3; 'onprem-ad-gpo' = 4 }
    $sortedSummary = @($CheckpointSummary | Sort-Object @{ Expression = { $stageRank[[string]$_.stage] } }, @{ Expression = { $sectionRank[[string]$_.section] } }, @{ Expression = { [string]$_.family } })
    $descriptors = @()

    foreach ($summary in $sortedSummary) {
        $stage = [string]$summary.stage
        $section = [string]$summary.section
        $family = [string]$summary.family
        Assert-CollectorCatalogIdentityShape -Stage $stage -Section $section -Family $family

        if ([int]$summary.inProgressBatches -gt 0) {
            throw ('Catalog generation cannot use terminal manifest evidence while checkpoint {0}/{1}/{2} still contains InProgress batches.' -f $stage, $section, $family)
        }
        if ($RunStatus -eq 'Completed' -and ([int]$summary.failedBatches -gt 0 -or [int]$summary.missingBatches -gt 0 -or [int]$summary.succeededBatches -ne [int]$summary.batchCount)) {
            throw ('Catalog generation found non-success checkpoint state under a Completed manifest for {0}/{1}/{2}.' -f $stage, $section, $family)
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId $RunId -Stage $stage -Section $section -Family $family
        $checkpointUpdatedUtc = ConvertTo-CollectorCatalogTimestamp -Value $checkpoint.updatedUtc -Label ('checkpoint updatedUtc for {0}/{1}/{2}' -f $stage, $section, $family)
        if ($checkpointUpdatedUtc -gt $ManifestCompletedUtc) {
            throw ('Catalog generation found checkpoint evidence newer than the terminal manifest for {0}/{1}/{2}.' -f $stage, $section, $family)
        }

        if ($checkpoint.PSObject.Properties.Match('plan').Count -eq 0 -or $null -eq $checkpoint.plan) {
            throw ('Catalog generation requires a persisted checkpoint plan for {0}/{1}/{2}.' -f $stage, $section, $family)
        }
        if ($checkpoint.plan.PSObject.Properties.Match('completed').Count -eq 0 -or -not ($checkpoint.plan.completed -is [bool])) {
            throw ('Catalog generation requires a boolean checkpoint plan completion state for {0}/{1}/{2}.' -f $stage, $section, $family)
        }
        if ($RunStatus -eq 'Completed' -and -not [bool]$checkpoint.plan.completed) {
            throw ('Catalog generation requires completed checkpoint plans under a Completed manifest for {0}/{1}/{2}.' -f $stage, $section, $family)
        }

        $expectedBatchCount = Get-CollectorBatchCountValue -Batch $checkpoint.plan -PropertyName 'expectedBatchCount'
        $plannedBatches = @($checkpoint.plan.batches)
        $recordedBatches = @($checkpoint.batches)
        if ($null -eq $expectedBatchCount -or $expectedBatchCount -lt 1 -or $plannedBatches.Count -ne $expectedBatchCount -or $recordedBatches.Count -ne $expectedBatchCount) {
            throw ('Catalog generation requires a complete checkpoint batch identity set for {0}/{1}/{2}.' -f $stage, $section, $family)
        }

        $plannedById = @{}
        foreach ($plannedBatch in $plannedBatches) {
            if ($null -eq $plannedBatch -or $plannedBatch.PSObject.Properties.Match('batchId').Count -eq 0 -or -not ($plannedBatch.batchId -is [string]) -or [string]$plannedBatch.batchId -notmatch '^[0-9]{4,}$') {
                throw ('Catalog generation found an invalid planned batch identity for {0}/{1}/{2}.' -f $stage, $section, $family)
            }
            $plannedBatchId = [string]$plannedBatch.batchId
            if ($plannedById.ContainsKey($plannedBatchId)) {
                throw ('Catalog generation found duplicate planned batch identity {0} for {1}/{2}/{3}.' -f $plannedBatchId, $stage, $section, $family)
            }
            $plannedById[$plannedBatchId] = $plannedBatch
        }

        $recordedById = @{}
        foreach ($recordedBatch in $recordedBatches) {
            if ($null -eq $recordedBatch -or $recordedBatch.PSObject.Properties.Match('batchId').Count -eq 0 -or -not ($recordedBatch.batchId -is [string]) -or [string]$recordedBatch.batchId -notmatch '^[0-9]{4,}$') {
                throw ('Catalog generation found an invalid recorded batch identity for {0}/{1}/{2}.' -f $stage, $section, $family)
            }
            $recordedBatchId = [string]$recordedBatch.batchId
            if ($recordedById.ContainsKey($recordedBatchId)) {
                throw ('Catalog generation found duplicate recorded batch identity {0} for {1}/{2}/{3}.' -f $recordedBatchId, $stage, $section, $family)
            }
            $recordedById[$recordedBatchId] = $recordedBatch
        }

        if ($plannedById.Count -ne $recordedById.Count) {
            throw ('Catalog generation checkpoint planned/recorded batch identities differ for {0}/{1}/{2}.' -f $stage, $section, $family)
        }
        foreach ($plannedBatchId in $plannedById.Keys) {
            if (-not $recordedById.ContainsKey($plannedBatchId)) {
                throw ('Catalog generation checkpoint is missing recorded batch {0} for {1}/{2}/{3}.' -f $plannedBatchId, $stage, $section, $family)
            }
        }

        $sortedBatchIds = @($recordedById.Keys | Sort-Object { [long]$_ })
        foreach ($batchId in $sortedBatchIds) {
            $batch = $recordedById[$batchId]
            if ([string]$batch.status -ne 'Succeeded') {
                continue
            }
            if (-not (Test-CollectorSucceededBatchCountIntegrity -Batch $batch)) {
                throw ('Catalog generation found invalid succeeded-batch counts for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }
            if ($batch.PSObject.Properties.Match('artifactPath').Count -eq 0 -or -not ($batch.artifactPath -is [string]) -or [string]::IsNullOrWhiteSpace([string]$batch.artifactPath)) {
                throw ('Catalog generation requires a persisted artifact path for succeeded {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }

            $batchUpdatedUtc = ConvertTo-CollectorCatalogTimestamp -Value $batch.updatedUtc -Label ('checkpoint batch updatedUtc for {0}/{1}/{2}/{3}' -f $stage, $section, $family, $batchId)
            if ($batchUpdatedUtc -gt $ManifestCompletedUtc) {
                throw ('Catalog generation found batch evidence newer than the terminal manifest for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }

            $plannedBatch = $plannedById[$batchId]
            $plannedItemCount = Get-CollectorBatchCountValue -Batch $plannedBatch -PropertyName 'itemCount'
            $checkpointItemCount = Get-CollectorBatchCountValue -Batch $batch -PropertyName 'itemCount'
            if ($null -eq $plannedItemCount -or $null -eq $checkpointItemCount) {
                throw ('Catalog generation found invalid item counts for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }
            if ($stage -ne 'stage3' -and $plannedItemCount -ne $checkpointItemCount) {
                throw ('Catalog generation found planned/checkpoint cardinality mismatch for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }

            $artifactPath = Get-CollectorCatalogCanonicalSnapshotPath -RunPath $RunPath -Stage $stage -Section $section -Family $family -BatchId $batchId
            if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                throw ('Catalog generation requires canonical snapshot {0}.' -f $artifactPath)
            }
            try {
                $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
            }
            catch {
                throw ('Catalog generation cannot read snapshot {0}: {1}' -f $artifactPath, $_.Exception.Message)
            }
            if (-not (Test-CollectorSnapshotSchemaVersion -Snapshot $snapshot)) {
                throw ('Catalog generation found unsupported or malformed snapshot schema for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }

            $expectedIdentity = @{ runId = $RunId; stage = $stage; section = $section; family = $family; batchId = $batchId }
            foreach ($identityName in @('runId', 'stage', 'section', 'family', 'batchId')) {
                if ($snapshot.PSObject.Properties.Match($identityName).Count -eq 0 -or -not ($snapshot.$identityName -is [string]) -or [string]$snapshot.$identityName -ne [string]$expectedIdentity[$identityName]) {
                    throw ('Catalog generation snapshot identity mismatch for {0}/{1}/{2} batch {3}: {4}.' -f $stage, $section, $family, $batchId, $identityName)
                }
            }

            $snapshotCollectedUtc = ConvertTo-CollectorCatalogTimestamp -Value $snapshot.collectedUtc -Label ('snapshot collectedUtc for {0}/{1}/{2}/{3}' -f $stage, $section, $family, $batchId)
            if ($snapshotCollectedUtc -gt $ManifestCompletedUtc) {
                throw ('Catalog generation found snapshot evidence newer than the terminal manifest for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }

            $snapshotItemCount = Get-CollectorBatchCountValue -Batch $snapshot -PropertyName 'itemCount'
            if ($null -eq $snapshotItemCount -or $snapshotItemCount -ne $checkpointItemCount -or @($snapshot.items).Count -ne $checkpointItemCount) {
                throw ('Catalog generation snapshot/checkpoint cardinality mismatch for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
            }

            if ($stage -eq 'stage1') {
                if ($plannedBatch.PSObject.Properties.Match('fingerprint').Count -eq 0 -or -not ($plannedBatch.fingerprint -is [string]) -or [string]::IsNullOrWhiteSpace([string]$plannedBatch.fingerprint)) {
                    throw ('Catalog generation requires Stage1 plan fingerprint for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
                }
                $snapshotFingerprint = Get-CollectorSnapshotBatchFingerprint -Items @($snapshot.items)
                if ($snapshotFingerprint -ne [string]$plannedBatch.fingerprint) {
                    throw ('Catalog generation Stage1 fingerprint mismatch for {0}/{1}/{2} batch {3}.' -f $stage, $section, $family, $batchId)
                }
            }

            foreach ($provenanceName in @('sourceType', 'sourceName', 'apiVersion')) {
                if (-not ($snapshot.$provenanceName -is [string]) -or [string]::IsNullOrWhiteSpace([string]$snapshot.$provenanceName)) {
                    throw ('Catalog generation requires non-empty snapshot provenance {0} for {1}/{2}/{3} batch {4}.' -f $provenanceName, $stage, $section, $family, $batchId)
                }
            }

            $relativePath = '{0}/{1}/{2}/batch-{3}.json' -f $stage, $section, $family, $batchId
            $checkpointRelativePath = 'checkpoints/{0}/{1}/{2}.json' -f $stage, $section, $family
            $descriptors += [pscustomobject][ordered]@{
                runId = $RunId
                stage = $stage
                section = $section
                family = $family
                batchId = $batchId
                kind = Get-CollectorCatalogKind -Stage $stage
                relativePath = $relativePath
                checkpointRelativePath = $checkpointRelativePath
                snapshotSchemaVersion = [string]$snapshot.schemaVersion
                checkpointSchemaVersion = [string]$checkpoint.schemaVersion
                itemCount = [int]$snapshotItemCount
                provenance = [pscustomobject][ordered]@{
                    sourceType = [string]$snapshot.sourceType
                    sourceName = [string]$snapshot.sourceName
                    apiVersion = [string]$snapshot.apiVersion
                    isBeta = [bool]$snapshot.isBeta
                }
            }
        }
    }

    if ($descriptors.Count -lt 1) {
        throw 'Catalog generation found no admissible successful snapshot artifacts.'
    }

    return @($descriptors)
}

function Get-CollectorCatalogFamilyKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Stage,
        [Parameter(Mandatory = $true)] [string]$Section,
        [Parameter(Mandatory = $true)] [string]$Family
    )
    return ('{0}|{1}|{2}' -f $Stage, $Section, $Family)
}

function Get-CollectorCatalogDependencyDescriptors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Artifacts
    )

    $families = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($artifact in $Artifacts) {
        $families.Add((Get-CollectorCatalogFamilyKey -Stage $artifact.stage -Section $artifact.section -Family $artifact.family)) | Out-Null
    }

    $definitionsByConsumer = @{}
    foreach ($definition in $script:CollectorCatalogDependencyDefinitions) {
        $consumerKey = Get-CollectorCatalogFamilyKey -Stage $definition.consumerStage -Section $definition.section -Family $definition.consumerFamily
        $definitionsByConsumer[$consumerKey] = $definition
    }

    $dependencies = @()
    $consumerArtifacts = @($Artifacts | Where-Object { $_.stage -eq 'stage2' -or $_.stage -eq 'stage3' } | Sort-Object stage, section, family)
    $seenConsumers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($artifact in $consumerArtifacts) {
        $consumerKey = Get-CollectorCatalogFamilyKey -Stage $artifact.stage -Section $artifact.section -Family $artifact.family
        if (-not $seenConsumers.Add($consumerKey)) {
            continue
        }
        if (-not $definitionsByConsumer.ContainsKey($consumerKey)) {
            throw ('Catalog generation has no dependency contract for admitted consumer {0}.' -f $consumerKey)
        }

        $definition = $definitionsByConsumer[$consumerKey]
        foreach ($providerFamily in @($definition.providerFamilies)) {
            $providerKey = Get-CollectorCatalogFamilyKey -Stage 'stage1' -Section $definition.section -Family $providerFamily
            if (-not $families.Contains($providerKey)) {
                throw ('Catalog generation cannot resolve required execution-input provider {0} for consumer {1}.' -f $providerKey, $consumerKey)
            }
            $dependencies += [pscustomobject][ordered]@{
                dependencyType = 'execution-input'
                consumer = [pscustomobject][ordered]@{
                    stage = [string]$definition.consumerStage
                    section = [string]$definition.section
                    family = [string]$definition.consumerFamily
                    kind = Get-CollectorCatalogKind -Stage ([string]$definition.consumerStage)
                }
                provider = [pscustomobject][ordered]@{
                    stage = 'stage1'
                    section = [string]$definition.section
                    family = [string]$providerFamily
                    kind = 'inventory'
                }
            }
        }
    }

    return @($dependencies | Sort-Object @{ Expression = { [string]$_.consumer.stage } }, @{ Expression = { [string]$_.consumer.section } }, @{ Expression = { [string]$_.consumer.family } }, @{ Expression = { [string]$_.provider.family } })
}

function Get-CollectorCatalogRelationshipDescriptors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Artifacts
    )

    $definitions = @{}
    foreach ($definition in $script:CollectorCatalogRelationshipDefinitions) {
        $key = '{0}|{1}' -f [string]$definition.section, [string]$definition.family
        $definitions[$key] = $definition
    }

    $relationships = @()
    $seenFamilies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($artifact in @($Artifacts | Where-Object { $_.stage -eq 'stage3' } | Sort-Object section, family)) {
        $key = '{0}|{1}' -f [string]$artifact.section, [string]$artifact.family
        if (-not $seenFamilies.Add($key)) {
            continue
        }
        if (-not $definitions.ContainsKey($key)) {
            throw ('Catalog generation has no relationship identity-domain contract for admitted Stage3 family {0}.' -f $key)
        }
        $definition = $definitions[$key]
        $relationships += [pscustomobject][ordered]@{
            stage = 'stage3'
            section = [string]$definition.section
            family = [string]$definition.family
            relationshipType = [string]$definition.relationshipType
            sourceIdentityDomains = @($definition.sourceDomains)
            targetIdentityDomains = @($definition.targetDomains)
        }
    }

    return @($relationships | Sort-Object section, family)
}

function Save-CollectorKnowledgeCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RunPath,
        [Parameter(Mandatory = $true)] [object]$Catalog
    )

    $catalogDirectory = Join-Path -Path $RunPath -ChildPath 'catalog'
    if (-not (Test-Path -LiteralPath $catalogDirectory -PathType Container)) {
        New-Item -Path $catalogDirectory -ItemType Directory -Force | Out-Null
    }

    $catalogPath = Join-Path -Path $catalogDirectory -ChildPath 'knowledge-catalog.json'
    $catalogJson = $Catalog | ConvertTo-Json -Depth 30 -Compress
    $suffix = [Guid]::NewGuid().ToString('N')
    $tempPath = Join-Path -Path $catalogDirectory -ChildPath ('.knowledge-catalog.json.{0}.tmp' -f $suffix)
    $backupPath = Join-Path -Path $catalogDirectory -ChildPath ('.knowledge-catalog.json.{0}.bak' -f $suffix)

    try {
        [System.IO.File]::WriteAllText($tempPath, $catalogJson, [System.Text.UTF8Encoding]::new($false))
        $roundTrip = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json
        if ($null -eq $roundTrip -or [string]$roundTrip.catalogId -ne [string]$Catalog.catalogId -or [string]$roundTrip.runId -ne [string]$Catalog.runId) {
            throw 'Catalog temporary-file round-trip identity validation failed.'
        }

        if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
            [System.IO.File]::Replace($tempPath, $catalogPath, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $catalogPath)
        }
    }
    finally {
        foreach ($temporaryPath in @($tempPath, $backupPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $catalogPath
}

function Export-CollectorKnowledgeCatalog {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This command explicitly materializes the derived offline catalog and has no WhatIf contract.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [string]$ExpectedRunId
    )

    $run = Get-CollectorCatalogRunIdentity -RunPath $RunPath
    $manifestState = Get-CollectorCatalogManifestState -RunPath $run.RunPath -RunId $run.RunId -ExpectedRunId $ExpectedRunId
    $checkpointSummary = @(Get-CollectorCheckpointSummary -RunPath $run.RunPath)
    Assert-CollectorCatalogManifestSummary -ActualSummary $checkpointSummary -Manifest $manifestState.Manifest

    $artifacts = @(Get-CollectorCatalogArtifactDescriptors -RunPath $run.RunPath -RunId $run.RunId -RunStatus ([string]$manifestState.Manifest.status) -ManifestCompletedUtc $manifestState.CompletedUtc -CheckpointSummary $checkpointSummary)
    $dependencies = @(Get-CollectorCatalogDependencyDescriptors -Artifacts $artifacts)
    $relationships = @(Get-CollectorCatalogRelationshipDescriptors -Artifacts $artifacts)

    $catalog = [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        catalogId = ('catalog-v1:{0}' -f $run.RunId)
        runId = $run.RunId
        runStatus = [string]$manifestState.Manifest.status
        sourceManifest = [pscustomobject][ordered]@{
            relativePath = 'manifest/run-manifest.json'
            schemaVersion = [string]$manifestState.Manifest.schemaVersion
            completedUtc = [string]$manifestState.Manifest.completedUtc
            status = [string]$manifestState.Manifest.status
            invocationCount = [int]$manifestState.InvocationCount
        }
        artifacts = @($artifacts)
        dependencies = @($dependencies)
        relationships = @($relationships)
    }

    $catalogPath = Save-CollectorKnowledgeCatalog -RunPath $run.RunPath -Catalog $catalog
    return [pscustomobject]@{
        runId = $run.RunId
        catalogPath = $catalogPath
        artifactCount = $artifacts.Count
        dependencyCount = $dependencies.Count
        relationshipCount = $relationships.Count
        runStatus = [string]$manifestState.Manifest.status
    }
}

Export-ModuleMember -Function 'Export-CollectorKnowledgeCatalog'
