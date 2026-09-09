BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Conditional Access offline collection' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-ca-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param([string]$Endpoint)

            switch ($Endpoint) {
                '/v1.0/identity/conditionalAccess/policies' {
                    return @([pscustomobject]@{
                        id = 'policy-1'
                        displayName = 'Require strong access'
                        state = 'enabled'
                        templateId = 'template-1'
                        conditions = [pscustomobject]@{
                            users = [pscustomobject]@{
                                includeUsers = @('All', 'user-1')
                                excludeUsers = @('user-2')
                                includeGroups = @('group-1')
                                excludeGroups = @('group-2')
                                includeRoles = @('role-template-1')
                                excludeRoles = @()
                                includeGuestsOrExternalUsers = [pscustomobject]@{
                                    guestOrExternalUserTypes = 'b2bCollaborationGuest'
                                    externalTenants = [pscustomobject]@{ membershipKind = 'enumerated'; members = @('tenant-1') }
                                }
                                excludeGuestsOrExternalUsers = $null
                            }
                            applications = [pscustomobject]@{
                                includeApplications = @('All', 'app-client-1')
                                excludeApplications = @('MicrosoftAdminPortals')
                                includeUserActions = @('urn:user:registersecurityinfo')
                                includeAuthenticationContextClassReferences = @('c1')
                            }
                            clientApplications = [pscustomobject]@{
                                includeServicePrincipals = @('ServicePrincipalsInMyTenant', 'sp-1')
                                excludeServicePrincipals = @('sp-2')
                            }
                            locations = [pscustomobject]@{
                                includeLocations = @('AllTrusted', 'location-1')
                                excludeLocations = @('location-2')
                            }
                        }
                        grantControls = [pscustomobject]@{
                            operator = 'AND'
                            builtInControls = @('mfa')
                            authenticationStrength = [pscustomobject]@{ id = 'strength-1'; displayName = 'Phishing resistant MFA' }
                            termsOfUse = @('tou-1')
                            customAuthenticationFactors = @('factor-1')
                        }
                        sessionControls = [pscustomobject]@{ signInFrequency = [pscustomobject]@{ isEnabled = $true; value = 8; type = 'hours' } }
                    })
                }
                '/v1.0/identity/conditionalAccess/namedLocations' {
                    return @([pscustomobject]@{ id = 'location-1'; displayName = 'Trusted HQ'; isTrusted = $true })
                }
                '/v1.0/policies/authenticationStrengthPolicies' {
                    return @([pscustomobject]@{ id = 'strength-1'; displayName = 'Phishing resistant MFA'; policyType = 'custom'; requirementsSatisfied = 'mfa' })
                }
                '/v1.0/identity/conditionalAccess/authenticationContextClassReferences' {
                    return @([pscustomobject]@{ id = 'c1'; displayName = 'Sensitive data'; description = 'Step-up context'; isAvailable = $true })
                }
                default { throw ('Unexpected Stage1 Graph endpoint: {0}' -f $Endpoint) }
            }
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            param([string]$Endpoint)

            if ($Endpoint -eq '/v1.0/identity/conditionalAccess/policies/policy-1') {
                return [pscustomobject]@{ id = 'policy-1'; displayName = 'Require strong access'; state = 'enabled'; conditions = [pscustomobject]@{ locations = [pscustomobject]@{ includeLocations = @('location-1') } }; grantControls = [pscustomobject]@{ authenticationStrength = [pscustomobject]@{ id = 'strength-1' } } }
            }
            if ($Endpoint -eq '/v1.0/identity/conditionalAccess/namedLocations/location-1') {
                return [pscustomobject]@{ id = 'location-1'; displayName = 'Trusted HQ'; isTrusted = $true; ipRanges = @([pscustomobject]@{ cidrAddress = '10.0.0.0/8' }) }
            }
            if ($Endpoint -eq '/v1.0/policies/authenticationStrengthPolicies/strength-1') {
                return [pscustomobject]@{ id = 'strength-1'; displayName = 'Phishing resistant MFA'; policyType = 'custom'; requirementsSatisfied = 'mfa'; allowedCombinations = @('fido2') }
            }
            if ($Endpoint -eq '/v1.0/identity/conditionalAccess/authenticationContextClassReferences/c1') {
                return [pscustomobject]@{ id = 'c1'; displayName = 'Sensitive data'; description = 'Step-up context'; isAvailable = $true }
            }
            throw ('Unexpected Stage2 Graph endpoint: {0}' -f $Endpoint)
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'keeps entra-ca opt-in while accepting it as a Graph-backed section' {
        $defaults = @(Resolve-CollectorSections)
        if ($defaults -contains 'entra-ca') {
            throw 'Conditional Access must remain opt-in so the legacy default permission contract does not silently expand.'
        }

        $resolved = @(Resolve-CollectorSections -Sections @('entra-ca'))
        if ($resolved.Count -ne 1 -or [string]$resolved[0] -ne 'entra-ca') {
            throw 'Expected entra-ca to resolve as a supported section.'
        }

        { Start-CollectorRun -GraphToken '' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-ca') } | Should -Throw '*GraphToken is required*entra-ca*'
    }

    It 'collects Stage1 and Stage2 Conditional Access configuration and derives explicit policy references' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-ca') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        if ([string]$result.status -ne 'Completed') {
            throw ('Expected completed Conditional Access collection; actual {0}.' -f $result.status)
        }

        foreach ($family in @('conditionalAccessPolicies', 'namedLocations', 'authenticationStrengthPolicies', 'authenticationContextClassReferences')) {
            $stage1Path = Join-Path -Path $result.runPath -ChildPath ('stage1/entra-ca/{0}/batch-0001.json' -f $family)
            $stage2Path = Join-Path -Path $result.runPath -ChildPath ('stage2/entra-ca/{0}/batch-0001.json' -f $family)
            if (-not (Test-Path -LiteralPath $stage1Path -PathType Leaf) -or -not (Test-Path -LiteralPath $stage2Path -PathType Leaf)) {
                throw ('Expected Stage1 and Stage2 evidence for Conditional Access family {0}.' -f $family)
            }
        }

        $policyDetail = Get-Content -LiteralPath (Join-Path $result.runPath 'stage2/entra-ca/conditionalAccessPolicies/batch-0001.json') -Raw | ConvertFrom-Json
        if ([string]$policyDetail.apiVersion -ne 'v1.0' -or [bool]$policyDetail.isBeta) {
            throw 'Conditional Access policy detail provenance must truthfully identify Microsoft Graph v1.0.'
        }

        $referenceSnapshot = Get-Content -LiteralPath (Join-Path $result.runPath 'stage3/entra-ca/conditionalAccessPolicyReferences/batch-0001.json') -Raw | ConvertFrom-Json
        $references = @($referenceSnapshot.items)
        foreach ($expected in @(
            @{ Type = 'group'; Id = 'group-1'; Domain = 'entra.group' },
            @{ Type = 'application'; Id = 'app-client-1'; Domain = 'entra.application-app-id' },
            @{ Type = 'servicePrincipal'; Id = 'sp-1'; Domain = 'entra.service-principal' },
            @{ Type = 'namedLocation'; Id = 'location-1'; Domain = 'entra.named-location' },
            @{ Type = 'authenticationContext'; Id = 'c1'; Domain = 'entra.authentication-context' },
            @{ Type = 'authenticationStrength'; Id = 'strength-1'; Domain = 'entra.authentication-strength-policy' },
            @{ Type = 'termsOfUse'; Id = 'tou-1'; Domain = 'entra.terms-of-use' },
            @{ Type = 'externalTenant'; Id = 'tenant-1'; Domain = 'entra.tenant' }
        )) {
            $match = @($references | Where-Object { [string]$_.referenceType -eq $expected.Type -and [string]$_.targetId -eq $expected.Id -and [string]$_.targetIdentityDomain -eq $expected.Domain })
            if ($match.Count -ne 1) {
                throw ('Expected one explicit Conditional Access reference {0}/{1}/{2}.' -f $expected.Type, $expected.Id, $expected.Domain)
            }
        }

        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw | ConvertFrom-Json
        $manifest.status | Should -Be 'Completed'
        @($manifest.checkpointSummary | Where-Object { $_.section -eq 'entra-ca' }).Count | Should -Be 9
    }

    It 'emits and validates catalog contracts for the Conditional Access section' {
        $result = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-ca') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0

        Import-Module -Name (Join-Path -Path $moduleRoot -ChildPath 'Collector.Storage.Catalog.psm1') -Force -ErrorAction Stop
        $catalogResult = Collector.Storage.Catalog\Export-CollectorKnowledgeCatalog -RunPath $result.runPath -ExpectedRunId $result.runId
        $catalog = Get-Content -LiteralPath $catalogResult.catalogPath -Raw | ConvertFrom-Json

        @($catalog.artifacts | Where-Object { $_.section -eq 'entra-ca' }).Count | Should -Be 9
        @($catalog.dependencies | Where-Object { $_.consumer.section -eq 'entra-ca' }).Count | Should -Be 5
        $relationship = @($catalog.relationships | Where-Object { $_.section -eq 'entra-ca' -and $_.family -eq 'conditionalAccessPolicyReferences' })
        $relationship.Count | Should -Be 1
        $relationship[0].relationshipType | Should -Be 'policy-reference'
        @($relationship[0].targetIdentityDomains) | Should -Contain 'entra.named-location'
        @($relationship[0].targetIdentityDomains) | Should -Contain 'entra.authentication-strength-policy'
        @($relationship[0].targetIdentityDomains) | Should -Contain 'entra.terms-of-use'
    }

    It 'preserves zero-item and resume behavior through the reused stage machinery' {
        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith { @() }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith { throw 'Stage2 must not call Graph when the Stage1 inventory family is empty.' }

        $initial = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-ca') -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        if ([string]$initial.status -ne 'Completed') {
            throw 'Zero-item Conditional Access collection must complete successfully.'
        }

        foreach ($family in @('conditionalAccessPolicies', 'namedLocations', 'authenticationStrengthPolicies', 'authenticationContextClassReferences')) {
            $snapshot = Get-Content -LiteralPath (Join-Path $initial.runPath ('stage1/entra-ca/{0}/batch-0001.json' -f $family)) -Raw | ConvertFrom-Json
            if ([int]$snapshot.itemCount -ne 0 -or @($snapshot.items).Count -ne 0) {
                throw ('Expected explicit zero-item Stage1 snapshot for {0}.' -f $family)
            }
        }
        $stage3Snapshot = Get-Content -LiteralPath (Join-Path $initial.runPath 'stage3/entra-ca/conditionalAccessPolicyReferences/batch-0001.json') -Raw | ConvertFrom-Json
        [int]$stage3Snapshot.itemCount | Should -Be 0
        Assert-MockCalled -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -Times 0 -Exactly

        $resumed = Start-CollectorRun -GraphToken 'test-token' -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('entra-ca') -Resume -BatchSize 25 -MaxRetries 0 -BaseBackoffSeconds 0 -MaxBackoffSeconds 0 -ThrottleMilliseconds 0
        $resumed.runId | Should -Be $initial.runId
        $resumed.status | Should -Be 'Completed'
    }
}
