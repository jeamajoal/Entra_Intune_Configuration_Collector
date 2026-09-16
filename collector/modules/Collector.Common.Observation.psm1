Set-StrictMode -Version Latest

$script:CollectorObservationSchemaVersion = '1.0'
$script:CollectorEvidenceStateSchemaVersion = '1.0'
$script:CollectorEvidenceStateCombinations = @{
    'available' = @('complete', 'partial')
    'permission-denied' = @('unavailable')
    'feature-unavailable' = @('unavailable')
    'license-unavailable' = @('unavailable')
    'retention-limited' = @('partial')
    'failed' = @('failed')
}

function ConvertTo-CollectorObservationUtcString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [string]$Label = 'Observation timestamp'
    )

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')
    }

    if ($Value -is [datetime]) {
        $dateTimeValue = [datetime]$Value
        if ($dateTimeValue.Kind -eq [System.DateTimeKind]::Unspecified) {
            throw ('{0} must carry an explicit UTC/local kind or offset; unspecified DateTime values are ambiguous.' -f $Label)
        }
        return ([DateTimeOffset]$dateTimeValue).ToUniversalTime().ToString('o')
    }

    if (-not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw ('{0} must be a DateTimeOffset, timezone-aware DateTime, or round-trip timestamp string.' -f $Label)
    }

    $text = [string]$Value
    if ($text -notmatch '(Z|[+-][0-9]{2}:[0-9]{2})$') {
        throw ('{0} must include an explicit UTC designator or numeric offset: {1}' -f $Label, $text)
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw ('{0} is not a valid round-trip timestamp: {1}' -f $Label, $text)
    }

    return $parsed.ToUniversalTime().ToString('o')
}

function Get-CollectorObservationPlanIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedStartUtc,

        [Parameter(Mandatory = $true)]
        [string]$RequestedEndUtc,

        [AllowNull()]
        [string]$EventTimeProperty
    )

    $material = [ordered]@{
        schemaVersion = $script:CollectorObservationSchemaVersion
        requestedStartUtc = $RequestedStartUtc
        requestedEndUtc = $RequestedEndUtc
        eventTimeProperty = $EventTimeProperty
    } | ConvertTo-Json -Depth 5 -Compress

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
        $hashBytes = $sha256.ComputeHash($bytes)
        $hex = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
        return ('sha256:{0}' -f $hex)
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-CollectorObservationPropertySet {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedProperties
    )

    if ($null -eq $InputObject) {
        return $false
    }

    $actual = @($InputObject.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    $expected = @($ExpectedProperties | Sort-Object -CaseSensitive)
    if ($actual.Count -ne $expected.Count) {
        return $false
    }

    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ([string]$actual[$index] -cne [string]$expected[$index]) {
            return $false
        }
    }

    return $true
}

function New-CollectorObservationDescriptor {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs and returns an in-memory observation descriptor.')]
    param(
        [Parameter(Mandatory = $true)]
        [object]$RequestedStartUtc,

        [Parameter(Mandatory = $true)]
        [object]$RequestedEndUtc,

        [AllowNull()]
        [string]$EventTimeProperty,

        [AllowNull()]
        [object]$ProviderAvailableStartUtc,

        [AllowNull()]
        [object]$ProviderAvailableEndUtc,

        [AllowNull()]
        [string]$RetentionCaveat
    )

    $requestedStart = ConvertTo-CollectorObservationUtcString -Value $RequestedStartUtc -Label 'Requested observation start'
    $requestedEnd = ConvertTo-CollectorObservationUtcString -Value $RequestedEndUtc -Label 'Requested observation end'
    if ([DateTimeOffset]::Parse($requestedStart) -ge [DateTimeOffset]::Parse($requestedEnd)) {
        throw 'Requested observation start must be earlier than requested observation end.'
    }

    $eventProperty = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$EventTimeProperty)) {
        $eventProperty = ([string]$EventTimeProperty).Trim()
    }

    $providerStart = $null
    if ($null -ne $ProviderAvailableStartUtc) {
        $providerStart = ConvertTo-CollectorObservationUtcString -Value $ProviderAvailableStartUtc -Label 'Provider-available observation start'
    }

    $providerEnd = $null
    if ($null -ne $ProviderAvailableEndUtc) {
        $providerEnd = ConvertTo-CollectorObservationUtcString -Value $ProviderAvailableEndUtc -Label 'Provider-available observation end'
    }

    if ($null -ne $providerStart -and $null -ne $providerEnd -and [DateTimeOffset]::Parse($providerStart) -ge [DateTimeOffset]::Parse($providerEnd)) {
        throw 'Provider-available observation start must be earlier than provider-available observation end.'
    }

    $retention = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$RetentionCaveat)) {
        $retention = ([string]$RetentionCaveat).Trim()
    }

    $providerAvailable = $null
    if ($null -ne $providerStart -or $null -ne $providerEnd -or $null -ne $retention) {
        $providerAvailable = [pscustomobject][ordered]@{
            startUtc = $providerStart
            endUtc = $providerEnd
            retentionCaveat = $retention
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = $script:CollectorObservationSchemaVersion
        requested = [pscustomobject][ordered]@{
            startUtc = $requestedStart
            endUtc = $requestedEnd
        }
        eventTimeProperty = $eventProperty
        providerAvailable = $providerAvailable
        planIdentity = Get-CollectorObservationPlanIdentity -RequestedStartUtc $requestedStart -RequestedEndUtc $requestedEnd -EventTimeProperty $eventProperty
    }
}

function Test-CollectorObservationDescriptor {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Observation
    )

    if (-not (Test-CollectorObservationPropertySet -InputObject $Observation -ExpectedProperties @('schemaVersion', 'requested', 'eventTimeProperty', 'providerAvailable', 'planIdentity'))) {
        return $false
    }
    if (-not ($Observation.schemaVersion -is [string]) -or [string]$Observation.schemaVersion -cne $script:CollectorObservationSchemaVersion) {
        return $false
    }
    if (-not (Test-CollectorObservationPropertySet -InputObject $Observation.requested -ExpectedProperties @('startUtc', 'endUtc'))) {
        return $false
    }

    try {
        $requestedStart = ConvertTo-CollectorObservationUtcString -Value $Observation.requested.startUtc -Label 'Persisted requested observation start'
        $requestedEnd = ConvertTo-CollectorObservationUtcString -Value $Observation.requested.endUtc -Label 'Persisted requested observation end'
    }
    catch {
        return $false
    }

    if ([string]$Observation.requested.startUtc -cne $requestedStart -or [string]$Observation.requested.endUtc -cne $requestedEnd) {
        return $false
    }
    if ([DateTimeOffset]::Parse($requestedStart) -ge [DateTimeOffset]::Parse($requestedEnd)) {
        return $false
    }

    $eventProperty = $null
    if ($null -ne $Observation.eventTimeProperty) {
        if (-not ($Observation.eventTimeProperty -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Observation.eventTimeProperty)) {
            return $false
        }
        $eventProperty = [string]$Observation.eventTimeProperty
    }

    if ($null -ne $Observation.providerAvailable) {
        if (-not (Test-CollectorObservationPropertySet -InputObject $Observation.providerAvailable -ExpectedProperties @('startUtc', 'endUtc', 'retentionCaveat'))) {
            return $false
        }

        $providerStart = $null
        if ($null -ne $Observation.providerAvailable.startUtc) {
            try { $providerStart = ConvertTo-CollectorObservationUtcString -Value $Observation.providerAvailable.startUtc -Label 'Persisted provider-available observation start' }
            catch { return $false }
            if ([string]$Observation.providerAvailable.startUtc -cne $providerStart) { return $false }
        }

        $providerEnd = $null
        if ($null -ne $Observation.providerAvailable.endUtc) {
            try { $providerEnd = ConvertTo-CollectorObservationUtcString -Value $Observation.providerAvailable.endUtc -Label 'Persisted provider-available observation end' }
            catch { return $false }
            if ([string]$Observation.providerAvailable.endUtc -cne $providerEnd) { return $false }
        }

        if ($null -ne $providerStart -and $null -ne $providerEnd -and [DateTimeOffset]::Parse($providerStart) -ge [DateTimeOffset]::Parse($providerEnd)) {
            return $false
        }

        if ($null -ne $Observation.providerAvailable.retentionCaveat -and (-not ($Observation.providerAvailable.retentionCaveat -is [string]) -or [string]::IsNullOrWhiteSpace([string]$Observation.providerAvailable.retentionCaveat))) {
            return $false
        }

        if ($null -eq $providerStart -and $null -eq $providerEnd -and $null -eq $Observation.providerAvailable.retentionCaveat) {
            return $false
        }
    }

    if (-not ($Observation.planIdentity -is [string]) -or [string]$Observation.planIdentity -notmatch '^sha256:[0-9a-f]{64}$') {
        return $false
    }

    $expectedIdentity = Get-CollectorObservationPlanIdentity -RequestedStartUtc $requestedStart -RequestedEndUtc $requestedEnd -EventTimeProperty $eventProperty
    return ([string]$Observation.planIdentity -ceq $expectedIdentity)
}

function New-CollectorEvidenceState {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This function only constructs and returns an in-memory evidence-state descriptor.')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('available', 'permission-denied', 'feature-unavailable', 'license-unavailable', 'retention-limited', 'failed')]
        [string]$Availability,

        [Parameter(Mandatory = $true)]
        [ValidateSet('complete', 'partial', 'unavailable', 'failed')]
        [string]$Completeness,

        [AllowNull()]
        [string]$Detail
    )

    if ($script:CollectorEvidenceStateCombinations[$Availability] -cnotcontains $Completeness) {
        throw ('Invalid evidence-state combination: availability={0}, completeness={1}.' -f $Availability, $Completeness)
    }

    $detailValue = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Detail)) {
        $detailValue = ([string]$Detail).Trim()
    }

    return [pscustomobject][ordered]@{
        schemaVersion = $script:CollectorEvidenceStateSchemaVersion
        availability = $Availability
        completeness = $Completeness
        detail = $detailValue
    }
}

function Test-CollectorEvidenceState {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$EvidenceState
    )

    if (-not (Test-CollectorObservationPropertySet -InputObject $EvidenceState -ExpectedProperties @('schemaVersion', 'availability', 'completeness', 'detail'))) {
        return $false
    }
    if (-not ($EvidenceState.schemaVersion -is [string]) -or [string]$EvidenceState.schemaVersion -cne $script:CollectorEvidenceStateSchemaVersion) {
        return $false
    }
    if (-not ($EvidenceState.availability -is [string]) -or -not $script:CollectorEvidenceStateCombinations.ContainsKey([string]$EvidenceState.availability)) {
        return $false
    }
    if (-not ($EvidenceState.completeness -is [string]) -or $script:CollectorEvidenceStateCombinations[[string]$EvidenceState.availability] -cnotcontains [string]$EvidenceState.completeness) {
        return $false
    }
    if ($null -ne $EvidenceState.detail -and (-not ($EvidenceState.detail -is [string]) -or [string]::IsNullOrWhiteSpace([string]$EvidenceState.detail))) {
        return $false
    }

    return $true
}

function Test-CollectorBoundedEvidenceContract {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Observation,

        [AllowNull()]
        [object]$EvidenceState
    )

    if (-not (Test-CollectorObservationDescriptor -Observation $Observation) -or -not (Test-CollectorEvidenceState -EvidenceState $EvidenceState)) {
        return $false
    }

    if ([string]$EvidenceState.availability -eq 'retention-limited') {
        if ($null -eq $Observation.providerAvailable) {
            return $false
        }
    }

    if ([string]$EvidenceState.availability -eq 'available' -and [string]$EvidenceState.completeness -eq 'complete' -and $null -ne $Observation.providerAvailable) {
        $requestedStart = [DateTimeOffset]::Parse([string]$Observation.requested.startUtc)
        $requestedEnd = [DateTimeOffset]::Parse([string]$Observation.requested.endUtc)
        if ($null -ne $Observation.providerAvailable.startUtc -and [DateTimeOffset]::Parse([string]$Observation.providerAvailable.startUtc) -gt $requestedStart) {
            return $false
        }
        if ($null -ne $Observation.providerAvailable.endUtc -and [DateTimeOffset]::Parse([string]$Observation.providerAvailable.endUtc) -lt $requestedEnd) {
            return $false
        }
    }

    return $true
}

Export-ModuleMember -Function @(
    'ConvertTo-CollectorObservationUtcString',
    'New-CollectorObservationDescriptor',
    'Test-CollectorObservationDescriptor',
    'New-CollectorEvidenceState',
    'Test-CollectorEvidenceState',
    'Test-CollectorBoundedEvidenceContract'
)
