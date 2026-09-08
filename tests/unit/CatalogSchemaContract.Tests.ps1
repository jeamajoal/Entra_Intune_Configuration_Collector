BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $schemaPath = Join-Path -Path $repoRoot -ChildPath 'collector/schemas/catalog.schema.json'
    $script:catalogSchema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    $script:catalogDefinitions = $script:catalogSchema.PSObject.Properties['$defs'].Value
}

Describe 'Offline knowledge catalog v1 schema contract' {
    It 'pins the catalog version and deterministic catalog identity shape' {
        if ([string]$script:catalogSchema.properties.schemaVersion.const -ne '1.0') {
            throw 'Expected catalog schemaVersion to be pinned to 1.0.'
        }
        if ([string]$script:catalogSchema.properties.catalogId.pattern -ne '^catalog-v1:.+$') {
            throw 'Expected catalogId to use the catalog-v1:<runId> identity namespace.'
        }
        if ([int]$script:catalogSchema.properties.artifacts.minItems -ne 1) {
            throw 'Expected a completed-run catalog to require at least one raw artifact descriptor.'
        }

        $required = @($script:catalogSchema.required)
        foreach ($name in @('schemaVersion', 'catalogId', 'runId', 'runStatus', 'sourceManifest', 'artifacts', 'dependencies', 'relationships')) {
            if ($required -notcontains $name) {
                throw ('Expected catalog top-level contract to require {0}.' -f $name)
            }
        }
    }

    It 'keeps artifact descriptors as metadata-only references to canonical raw evidence' {
        $artifact = $script:catalogDefinitions.artifact
        $required = @($artifact.required)
        foreach ($name in @('runId', 'stage', 'section', 'family', 'batchId', 'kind', 'relativePath', 'checkpointRelativePath', 'snapshotSchemaVersion', 'checkpointSchemaVersion', 'itemCount', 'provenance')) {
            if ($required -notcontains $name) {
                throw ('Expected artifact descriptor to require {0}.' -f $name)
            }
        }

        foreach ($forbiddenPayloadField in @('items', 'requestContext', 'payload')) {
            if ($artifact.properties.PSObject.Properties.Name -contains $forbiddenPayloadField) {
                throw ('Catalog artifact descriptors must not copy raw payload field {0}.' -f $forbiddenPayloadField)
            }
        }

        $artifactPathPattern = [string]$artifact.properties.relativePath.pattern
        if (-not [regex]::IsMatch('stage1/entra-apps/applications/batch-0001.json', $artifactPathPattern)) {
            throw 'Expected canonical snapshot relative path to satisfy the catalog path contract.'
        }
        if ([regex]::IsMatch('../stage1/entra-apps/applications/batch-0001.json', $artifactPathPattern)) {
            throw 'Catalog relative paths must reject traversal outside the run package.'
        }
    }

    It 'binds stage and kind consistently for artifact and dependency owners' {
        $expected = @{
            stage1 = 'inventory'
            stage2 = 'detail'
            stage3 = 'relationship'
        }

        foreach ($ownerName in @('artifact', 'dependencyEndpoint')) {
            $owner = $script:catalogDefinitions.PSObject.Properties[$ownerName].Value
            $mappings = @{}
            foreach ($rule in @($owner.allOf)) {
                $stage = [string]$rule.if.properties.stage.const
                $kind = [string]$rule.then.properties.kind.const
                if (-not [string]::IsNullOrWhiteSpace($stage)) {
                    $mappings[$stage] = $kind
                }
            }

            foreach ($stage in $expected.Keys) {
                if (-not $mappings.ContainsKey($stage) -or [string]$mappings[$stage] -ne [string]$expected[$stage]) {
                    throw ('Expected catalog {0} stage {1} to require kind {2}.' -f $ownerName, $stage, $expected[$stage])
                }
            }
        }
    }

    It 'defines explicit execution and reference dependency semantics' {
        $dependency = $script:catalogDefinitions.dependency
        $dependencyTypes = @($dependency.properties.dependencyType.enum)
        foreach ($dependencyType in @('execution-input', 'reference')) {
            if ($dependencyTypes -notcontains $dependencyType) {
                throw ('Expected dependencyType to support {0}.' -f $dependencyType)
            }
        }

        foreach ($endpointName in @('consumer', 'provider')) {
            if ($dependency.required -notcontains $endpointName) {
                throw ('Expected dependency descriptor to require {0}.' -f $endpointName)
            }
        }
    }

    It 'requires relationship families to publish source and target identity domains' {
        $relationship = $script:catalogDefinitions.relationship
        if ([string]$relationship.properties.stage.const -ne 'stage3') {
            throw 'Expected relationship descriptors to be bound to stage3.'
        }

        foreach ($name in @('section', 'family', 'relationshipType', 'sourceIdentityDomains', 'targetIdentityDomains')) {
            if ($relationship.required -notcontains $name) {
                throw ('Expected relationship descriptor to require {0}.' -f $name)
            }
        }

        if ([int]$relationship.properties.sourceIdentityDomains.minItems -ne 1 -or [int]$relationship.properties.targetIdentityDomains.minItems -ne 1) {
            throw 'Expected relationship source and target identity-domain sets to be non-empty.'
        }
    }

    It 'binds the catalog to terminal persisted manifest evidence without adding a provider dependency' {
        $sourceManifest = $script:catalogDefinitions.sourceManifest
        if ([string]$sourceManifest.properties.relativePath.const -ne 'manifest/run-manifest.json') {
            throw 'Expected the catalog to reference the canonical run manifest path.'
        }

        $statuses = @($sourceManifest.properties.status.enum)
        foreach ($status in @('Completed', 'CompletedWithErrors')) {
            if ($statuses -notcontains $status) {
                throw ('Expected source manifest contract to admit terminal status {0}.' -f $status)
            }
        }
        foreach ($nonTerminal in @('InProgress', 'Failed')) {
            if ($statuses -contains $nonTerminal) {
                throw ('Catalog generation must not treat manifest status {0} as a terminal source package.' -f $nonTerminal)
            }
        }
    }
}
