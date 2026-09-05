$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.Graph.psm1') -Force -ErrorAction Stop

function New-CredentialFederationContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath
    )

    @{
        RunPath = $RunPath
        RunId = 'credential-federation-run'
        GraphToken = 'test-token'
        BatchSize = 100
        MaxRetries = 0
        BaseBackoffSeconds = 0
        MaxBackoffSeconds = 0
        ThrottleMilliseconds = 0
        Resume = $false
        ReprocessFailedOnly = $false
    }
}

function Get-CredentialFederationSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    $artifactPath = Join-Path -Path $RunPath -ChildPath (Join-Path -Path $Stage -ChildPath (Join-Path -Path 'entra-apps' -ChildPath (Join-Path -Path $Family -ChildPath 'batch-0001.json')))
    if (-not (Test-Path -LiteralPath $artifactPath)) {
        throw ('Expected artifact was not created: ' + $artifactPath)
    }

    [pscustomobject]@{
        Path = $artifactPath
        Raw = Get-Content -LiteralPath $artifactPath -Raw
        Snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
    }
}

Describe 'Entra credential and federated identity metadata' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-credential-federation-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        $global:CollectorCredentialStage2Calls = New-Object 'System.Collections.Generic.List[object]'
        $global:CollectorCredentialStage3Endpoints = New-Object 'System.Collections.Generic.List[string]'
        $global:CollectorCredentialProviderSleeps = New-Object 'System.Collections.Generic.List[int]'

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'object-1' })
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            $global:CollectorCredentialStage2Calls.Add([pscustomobject]@{
                Endpoint = [string]$Endpoint
                ThrottleMilliseconds = [int]$ThrottleMilliseconds
            }) | Out-Null

            if ($Endpoint -match '\$select=id,keyCredentials,passwordCredentials$') {
                return [pscustomobject]@{
                    id = 'object-1'
                    keyCredentials = @(
                        [pscustomobject]@{
                            customKeyIdentifier = 'thumbprint-id'
                            displayName = 'Signing certificate'
                            endDateTime = '2027-01-01T00:00:00Z'
                            key = 'RAW_PUBLIC_KEY_MUST_NOT_PERSIST'
                            keyId = '11111111-1111-1111-1111-111111111111'
                            privateKey = 'PRIVATE_KEY_MUST_NOT_PERSIST'
                            startDateTime = '2026-01-01T00:00:00Z'
                            type = 'AsymmetricX509Cert'
                            usage = 'Verify'
                        }
                    )
                    passwordCredentials = @(
                        [pscustomobject]@{
                            customKeyIdentifier = 'PASSWORD_BINARY_IDENTIFIER_MUST_NOT_PERSIST'
                            displayName = 'Client secret'
                            endDateTime = '2027-02-01T00:00:00Z'
                            hint = 'sec'
                            keyId = '22222222-2222-2222-2222-222222222222'
                            secretText = 'TOP_SECRET_MUST_NOT_PERSIST'
                            startDateTime = '2026-02-01T00:00:00Z'
                        }
                    )
                    unexpectedProperty = 'UNEXPECTED_MUST_NOT_PERSIST'
                }
            }

            return [pscustomobject]@{ id = 'object-1' }
        }

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            $global:CollectorCredentialStage3Endpoints.Add([string]$Endpoint) | Out-Null

            if ($Endpoint -match '/federatedIdentityCredentials\?\$select=') {
                return @(
                    [pscustomobject]@{
                        id = 'fic-1'
                        name = 'github-main'
                        issuer = 'https://token.actions.githubusercontent.com'
                        subject = 'repo:example/repo:ref:refs/heads/main'
                        audiences = @('api://AzureADTokenExchange')
                        description = 'GitHub Actions main branch'
                        unexpectedProperty = 'FIC_UNEXPECTED_MUST_NOT_PERSIST'
                    }
                )
            }

            return @()
        }

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Start-Sleep -MockWith {
            $global:CollectorCredentialProviderSleeps.Add([int]$Milliseconds) | Out-Null
        }

        Mock -ModuleName 'Collector.Provider.Graph' -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{ id = 'provider-test' }
        }
    }

    AfterEach {
        Remove-Variable -Name CollectorCredentialStage2Calls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name CollectorCredentialStage3Endpoints -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name CollectorCredentialProviderSleeps -Scope Global -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'collects allowlisted credential metadata with the 400 millisecond key-credential rate floor' {
        $context = New-CredentialFederationContext -RunPath $script:testRoot
        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
        $stage2Results = @(Invoke-CollectorStage2 -Context $context -Sections @('entra-apps'))

        foreach ($family in @('applicationCredentials', 'servicePrincipalCredentials')) {
            $result = @($stage2Results | Where-Object { $_.family -eq $family })[0]
            if (-not $result -or [int]$result.succeededBatches -ne 1 -or [int]$result.failedBatches -ne 0) {
                throw ('Expected successful Stage2 credential family ' + $family + '.')
            }
        }

        $credentialCalls = @($global:CollectorCredentialStage2Calls | Where-Object { $_.Endpoint -match '\$select=id,keyCredentials,passwordCredentials$' })
        if ($credentialCalls.Count -ne 2) {
            throw ('Expected exactly two credential detail calls; actual ' + $credentialCalls.Count + '.')
        }
        foreach ($call in $credentialCalls) {
            if ([int]$call.ThrottleMilliseconds -lt 400) {
                throw ('Credential detail call used throttle below 400 ms: ' + $call.ThrottleMilliseconds + '.')
            }
        }

        $applicationArtifact = Get-CredentialFederationSnapshot -RunPath $script:testRoot -Stage 'stage2' -Family 'applicationCredentials'
        $servicePrincipalArtifact = Get-CredentialFederationSnapshot -RunPath $script:testRoot -Stage 'stage2' -Family 'servicePrincipalCredentials'

        foreach ($artifact in @($applicationArtifact, $servicePrincipalArtifact)) {
            $snapshot = $artifact.Snapshot
            $item = $snapshot.items[0]
            $keyCredential = $item.keyCredentials[0]
            $passwordCredential = $item.passwordCredentials[0]

            if ([string]$keyCredential.customKeyIdentifier -ne 'thumbprint-id' -or [string]$keyCredential.keyId -ne '11111111-1111-1111-1111-111111111111' -or [string]$keyCredential.type -ne 'AsymmetricX509Cert' -or [string]$keyCredential.usage -ne 'Verify') {
                throw 'Expected safe key-credential identifiers/type/usage were not preserved.'
            }
            if ([string]$passwordCredential.keyId -ne '22222222-2222-2222-2222-222222222222' -or [string]$passwordCredential.displayName -ne 'Client secret') {
                throw 'Expected safe password-credential metadata was not preserved.'
            }

            foreach ($forbiddenKeyProperty in @('key', 'privateKey')) {
                if ($keyCredential.PSObject.Properties.Match($forbiddenKeyProperty).Count -gt 0) {
                    throw ('Forbidden key credential property persisted: ' + $forbiddenKeyProperty + '.')
                }
            }
            foreach ($forbiddenPasswordProperty in @('secretText', 'hint', 'customKeyIdentifier')) {
                if ($passwordCredential.PSObject.Properties.Match($forbiddenPasswordProperty).Count -gt 0) {
                    throw ('Forbidden password credential property persisted: ' + $forbiddenPasswordProperty + '.')
                }
            }
            if ($item.PSObject.Properties.Match('unexpectedProperty').Count -gt 0) {
                throw 'Unexpected credential response fields must not survive the allowlist transform.'
            }

            foreach ($forbiddenValue in @('RAW_PUBLIC_KEY_MUST_NOT_PERSIST', 'PRIVATE_KEY_MUST_NOT_PERSIST', 'TOP_SECRET_MUST_NOT_PERSIST', 'PASSWORD_BINARY_IDENTIFIER_MUST_NOT_PERSIST', 'UNEXPECTED_MUST_NOT_PERSIST')) {
                if ($artifact.Raw.Contains($forbiddenValue)) {
                    throw ('Forbidden credential value persisted in artifact: ' + $forbiddenValue + '.')
                }
            }

            if ((@($snapshot.requestContext.selectedProperties) -join ',') -ne 'id,keyCredentials,passwordCredentials') {
                throw 'Credential provenance selectedProperties does not match the request contract.'
            }
            if ([int]$snapshot.requestContext.minimumThrottleMilliseconds -ne 400 -or [int]$snapshot.requestContext.effectiveThrottleMilliseconds -lt 400) {
                throw 'Credential provenance does not record the 400 ms minimum/effective rate contract.'
            }
        }

        if ([string]$applicationArtifact.Snapshot.requestContext.dependencyFamily -ne 'applications') {
            throw 'Application credential provenance must identify applications as its Stage1 dependency.'
        }
        if ([string]$servicePrincipalArtifact.Snapshot.requestContext.dependencyFamily -ne 'servicePrincipals') {
            throw 'Service-principal credential provenance must identify servicePrincipals as its Stage1 dependency.'
        }
    }

    It 'enforces the requested throttle value as a provider pre-request sleep' {
        Invoke-CollectorGraphRequest -GraphToken 'test-token' -Endpoint '/v1.0/applications/object-1?$select=id,keyCredentials,passwordCredentials' -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 400 | Out-Null

        if ($global:CollectorCredentialProviderSleeps.Count -ne 1 -or [int]$global:CollectorCredentialProviderSleeps[0] -ne 400) {
            throw ('Expected one 400 ms provider sleep; actual ' + ($global:CollectorCredentialProviderSleeps -join ',') + '.')
        }
    }

    It 'collects application federated identity credentials through the Stage3 relationship seam' {
        $context = New-CredentialFederationContext -RunPath $script:testRoot
        Invoke-CollectorStage1 -Context $context -Sections @('entra-apps') | Out-Null
        $stage3Results = @(Invoke-CollectorStage3 -Context $context -Sections @('entra-apps'))

        $result = @($stage3Results | Where-Object { $_.family -eq 'applicationFederatedIdentityCredentials' })[0]
        if (-not $result -or [int]$result.succeededBatches -ne 1 -or [int]$result.failedBatches -ne 0) {
            throw 'Expected successful applicationFederatedIdentityCredentials Stage3 family.'
        }

        $expectedEndpoint = '/v1.0/applications/object-1/federatedIdentityCredentials?$select=id,name,issuer,subject,audiences,description'
        if ($global:CollectorCredentialStage3Endpoints -notcontains $expectedEndpoint) {
            throw ('Expected FIC endpoint was not requested: ' + $expectedEndpoint + '.')
        }

        $artifact = Get-CredentialFederationSnapshot -RunPath $script:testRoot -Stage 'stage3' -Family 'applicationFederatedIdentityCredentials'
        $snapshot = $artifact.Snapshot
        $parent = $snapshot.items[0]
        $fic = $parent.relationships[0]

        if ([string]$parent.parentId -ne 'object-1' -or [int]$parent.relationshipCount -ne 1) {
            throw 'FIC relationship envelope did not preserve application parent identity/count.'
        }
        if ([string]$fic.id -ne 'fic-1' -or [string]$fic.name -ne 'github-main' -or [string]$fic.issuer -ne 'https://token.actions.githubusercontent.com' -or [string]$fic.subject -ne 'repo:example/repo:ref:refs/heads/main' -or [string]$fic.description -ne 'GitHub Actions main branch') {
            throw 'Expected FIC identity/issuer/subject metadata was not persisted.'
        }
        if ((@($fic.audiences) -join ',') -ne 'api://AzureADTokenExchange') {
            throw 'Expected FIC audience was not persisted.'
        }
        if ($fic.PSObject.Properties.Match('unexpectedProperty').Count -gt 0 -or $artifact.Raw.Contains('FIC_UNEXPECTED_MUST_NOT_PERSIST')) {
            throw 'Unexpected FIC response fields must not survive the allowlist transform.'
        }
        if ([string]$snapshot.apiVersion -ne 'v1.0' -or [string]$snapshot.requestContext.dependencyFamily -ne 'applications' -or [string]$snapshot.requestContext.endpointTemplate -ne '/v1.0/applications/{id}/federatedIdentityCredentials?$select=id,name,issuer,subject,audiences,description') {
            throw 'FIC provenance does not identify the v1.0 endpoint and applications dependency.'
        }
    }
}
