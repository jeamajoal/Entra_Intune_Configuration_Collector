$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Common.Provenance.psm1') -Force -ErrorAction Stop

Describe 'Provenance envelope' {
    It 'contains all required top-level fields' {
        $snapshot = New-CollectorProvenanceSnapshot -RunId 'run-test' -Stage 'stage1' -Section 'entra-apps' -Family 'applications' -BatchId '0001' -SourceType 'Graph' -SourceName 'Graph /v1.0/applications' -ApiVersion 'v1.0' -IsBeta:$false -RequestContext @{ endpoint = '/v1.0/applications' } -ItemCount 1 -Items @(@{ id = 'a1' })

        $propertyNames = $snapshot.Keys
        $requiredFields = @(
            'schemaVersion',
            'runId',
            'stage',
            'section',
            'family',
            'batchId',
            'collectedUtc',
            'sourceType',
            'sourceName',
            'apiVersion',
            'isBeta',
            'requestContext',
            'itemCount',
            'items'
        )

        foreach ($field in $requiredFields) {
            if (-not ($propertyNames -contains $field)) {
                throw ('Expected snapshot to contain property ' + $field + '.')
            }
        }

        if ($snapshot.runId -ne 'run-test') {
            throw ('Expected runId run-test but found ' + [string]$snapshot.runId + '.')
        }

        if ($snapshot.stage -ne 'stage1') {
            throw ('Expected stage stage1 but found ' + [string]$snapshot.stage + '.')
        }

        if ($snapshot.section -ne 'entra-apps') {
            throw ('Expected section entra-apps but found ' + [string]$snapshot.section + '.')
        }

        if ($snapshot.family -ne 'applications') {
            throw ('Expected family applications but found ' + [string]$snapshot.family + '.')
        }

        if ($snapshot.batchId -ne '0001') {
            throw ('Expected batchId 0001 but found ' + [string]$snapshot.batchId + '.')
        }

        if ($snapshot.itemCount -ne 1) {
            throw ('Expected itemCount 1 but found ' + [string]$snapshot.itemCount + '.')
        }

        if (@($snapshot.items).Count -ne 1) {
            throw ('Expected one collected item but found ' + @($snapshot.items).Count + '.')
        }
    }
}
