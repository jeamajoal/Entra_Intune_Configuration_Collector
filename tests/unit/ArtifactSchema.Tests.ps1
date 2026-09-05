BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:schemaFiles = @(
        (Join-Path -Path $repoRoot -ChildPath 'collector/schemas/snapshot.schema.json')
        (Join-Path -Path $repoRoot -ChildPath 'collector/schemas/checkpoint.schema.json')
        (Join-Path -Path $repoRoot -ChildPath 'collector/schemas/manifest.schema.json')
    )
}

Describe 'Schema files' {

    It 'parses as valid JSON' {
        foreach ($schemaPath in $script:schemaFiles) {
            try {
                Get-Content -Path $schemaPath -Raw | ConvertFrom-Json | Out-Null
            }
            catch {
                throw ('Expected schema to parse as valid JSON: ' + $schemaPath + '. Actual: ' + $_.Exception.Message)
            }
        }
    }

    It 'contains required top-level JSON Schema keys' {
        $requiredKeys = @('$schema', 'title', 'type', 'properties', 'required')

        foreach ($schemaPath in $script:schemaFiles) {
            $schema = Get-Content -Path $schemaPath -Raw | ConvertFrom-Json
            $propertyNames = $schema.PSObject.Properties.Name

            foreach ($requiredKey in $requiredKeys) {
                if (-not ($propertyNames -contains $requiredKey)) {
                    throw ('Expected schema file to contain top-level key ' + $requiredKey + ': ' + $schemaPath)
                }
            }
        }
    }
}
