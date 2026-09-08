Set-StrictMode -Version Latest

$catalogModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Catalog.psm1'
$catalogModules = @(Import-Module -Name $catalogModulePath -PassThru -ErrorAction Stop)
if ($catalogModules.Count -lt 1) {
    throw 'Offline package validation could not load the catalog module.'
}
$script:CollectorCatalogModule = $catalogModules[0]

function ConvertTo-CollectorValidationTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

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
        throw ('{0} is not a valid round-trip timestamp.' -f $Label)
    }
    return $parsed.ToUniversalTime()
}

function Get-CollectorExpectedKnowledgeCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [string]$ExpectedRunId
    )

    $builder = {
        param($InnerRunPath, $InnerExpectedRunId)

        $run = Get-CollectorCatalogRunState -RunPath $InnerRunPath -ExpectedRunId $InnerExpectedRunId
        $summary = @(Get-CollectorCheckpointSummary -RunPath $run.RunPath)
        Assert-CollectorCatalogManifestSummary -ActualSummary $summary -Manifest $run.Manifest
        $artifacts = @(Get-CollectorCatalogArtifactSet -RunPath $run.RunPath -RunId $run.RunId -RunStatus ([string]$run.Manifest.status) -ManifestCompletedUtc $run.CompletedUtc -CheckpointSummary $summary)
        $dependencies = @(Get-CollectorCatalogDependencySet -Artifacts $artifacts)
        $relationships = @(Get-CollectorCatalogRelationshipSet -Artifacts $artifacts)

        $catalog = [pscustomobject][ordered]@{
            schemaVersion = '1.0'
            catalogId = ('catalog-v1:{0}' -f $run.RunId)
            runId = $run.RunId
            runStatus = [string]$run.Manifest.status
            sourceManifest = [pscustomobject][ordered]@{
                relativePath = 'manifest/run-manifest.json'
                schemaVersion = [string]$run.Manifest.schemaVersion
                completedUtc = $run.CompletedUtc.ToString('o')
                status = [string]$run.Manifest.status
                invocationCount = [int]$run.InvocationCount
            }
            artifacts = @($artifacts)
            dependencies = @($dependencies)
            relationships = @($relationships)
        }

        return [pscustomobject]@{
            RunPath = $run.RunPath
            RunId = $run.RunId
            Catalog = $catalog
        }
    }

    $results = @($script:CollectorCatalogModule.Invoke($builder, [object[]]@($RunPath, $ExpectedRunId)))
    if ($results.Count -ne 1 -or $null -eq $results[0]) {
        throw 'Offline package validation could not construct one canonical expected catalog model.'
    }
    return $results[0]
}

function Read-CollectorPersistedKnowledgeCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath
    )

    $catalogPath = Join-Path -Path $RunPath -ChildPath 'catalog/knowledge-catalog.json'
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw ('Missing canonical knowledge catalog: {0}' -f $catalogPath)
    }

    try {
        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    }
    catch {
        throw ('Knowledge catalog is unreadable JSON: {0}' -f $_.Exception.Message)
    }

    if ($null -eq $catalog) {
        throw 'Knowledge catalog cannot be null.'
    }

    return [pscustomobject]@{
        Path = [System.IO.Path]::GetFullPath($catalogPath)
        Catalog = $catalog
    }
}

function Compare-CollectorCatalogValue {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -eq 'catalog.sourceManifest.completedUtc') {
        $actualTimestamp = ConvertTo-CollectorValidationTimestamp -Value $Actual -Label $Path
        $expectedTimestamp = ConvertTo-CollectorValidationTimestamp -Value $Expected -Label $Path
        if ($actualTimestamp.UtcDateTime.Ticks -ne $expectedTimestamp.UtcDateTime.Ticks) {
            throw ('Catalog contract mismatch at {0}.' -f $Path)
        }
        return
    }

    if ($null -eq $Expected) {
        if ($null -ne $Actual) {
            throw ('Catalog contract mismatch at {0}: expected null.' -f $Path)
        }
        return
    }

    if ($Expected -is [System.Management.Automation.PSCustomObject]) {
        if (-not ($Actual -is [System.Management.Automation.PSCustomObject])) {
            throw ('Catalog contract mismatch at {0}: expected object.' -f $Path)
        }

        $expectedNames = @($Expected.PSObject.Properties.Name)
        $actualNames = @($Actual.PSObject.Properties.Name)
        if ($actualNames.Count -ne $expectedNames.Count) {
            throw ('Catalog contract mismatch at {0}: property set differs.' -f $Path)
        }

        foreach ($name in $expectedNames) {
            $actualProperties = @($Actual.PSObject.Properties | Where-Object { $_.Name -ceq $name })
            if ($actualProperties.Count -ne 1) {
                throw ('Catalog contract mismatch at {0}: missing or wrong-case property {1}.' -f $Path, $name)
            }
            Compare-CollectorCatalogValue -Actual $actualProperties[0].Value -Expected $Expected.$name -Path ('{0}.{1}' -f $Path, $name)
        }
        return
    }

    if ($Expected -is [System.Array]) {
        if (-not ($Actual -is [System.Array])) {
            throw ('Catalog contract mismatch at {0}: expected array.' -f $Path)
        }
        $actualArray = @($Actual)
        $expectedArray = @($Expected)
        if ($actualArray.Count -ne $expectedArray.Count) {
            throw ('Catalog contract mismatch at {0}: array count differs.' -f $Path)
        }
        for ($index = 0; $index -lt $expectedArray.Count; $index++) {
            Compare-CollectorCatalogValue -Actual $actualArray[$index] -Expected $expectedArray[$index] -Path ('{0}[{1}]' -f $Path, $index)
        }
        return
    }

    if ($Expected -is [bool]) {
        if (-not ($Actual -is [bool]) -or [bool]$Actual -ne [bool]$Expected) {
            throw ('Catalog contract mismatch at {0}: Boolean value differs.' -f $Path)
        }
        return
    }

    if ($Expected -is [int] -or $Expected -is [long]) {
        if (-not ($Actual -is [byte] -or $Actual -is [sbyte] -or $Actual -is [int16] -or $Actual -is [uint16] -or $Actual -is [int] -or $Actual -is [uint32] -or $Actual -is [long] -or $Actual -is [uint64])) {
            throw ('Catalog contract mismatch at {0}: expected integer.' -f $Path)
        }
        if ([decimal]$Actual -ne [decimal]$Expected) {
            throw ('Catalog contract mismatch at {0}: integer value differs.' -f $Path)
        }
        return
    }

    if ($Expected -is [string]) {
        if (-not ($Actual -is [string]) -or [string]$Actual -cne [string]$Expected) {
            throw ('Catalog contract mismatch at {0}: string value differs.' -f $Path)
        }
        return
    }

    if ($Actual -ne $Expected) {
        throw ('Catalog contract mismatch at {0}.' -f $Path)
    }
}

function Invoke-CollectorKnowledgePackageValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [string]$ExpectedRunId
    )

    $resultRunId = $ExpectedRunId
    $resultCatalogPath = $null

    try {
        $expectedModel = Get-CollectorExpectedKnowledgeCatalog -RunPath $RunPath -ExpectedRunId $ExpectedRunId
        $resultRunId = [string]$expectedModel.RunId
        $persisted = Read-CollectorPersistedKnowledgeCatalog -RunPath $expectedModel.RunPath
        $resultCatalogPath = $persisted.Path

        Compare-CollectorCatalogValue -Actual $persisted.Catalog -Expected $expectedModel.Catalog -Path 'catalog'

        $families = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($artifact in @($expectedModel.Catalog.artifacts)) {
            $families.Add(('{0}|{1}|{2}' -f $artifact.stage, $artifact.section, $artifact.family)) | Out-Null
        }

        return [pscustomobject][ordered]@{
            valid = $true
            status = 'Valid'
            runId = $resultRunId
            catalogPath = $resultCatalogPath
            artifactCount = @($expectedModel.Catalog.artifacts).Count
            familyCount = $families.Count
            dependencyCount = @($expectedModel.Catalog.dependencies).Count
            relationshipCount = @($expectedModel.Catalog.relationships).Count
            message = 'Knowledge package is internally coherent.'
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            valid = $false
            status = 'Invalid'
            runId = $resultRunId
            catalogPath = $resultCatalogPath
            artifactCount = 0
            familyCount = 0
            dependencyCount = 0
            relationshipCount = 0
            message = ('Knowledge package validation failed: {0}' -f $_.Exception.Message)
        }
    }
}

Export-ModuleMember -Function 'Invoke-CollectorKnowledgePackageValidation'
