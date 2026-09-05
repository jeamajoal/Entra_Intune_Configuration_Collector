$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop

function New-Stage2GraphPropertyContractContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath
    )

    @{
        RunPath = $RunPath
        RunId = 'stage2-graph-property-contract-run'
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

function Get-SelectedPropertiesFromEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )

    if ($Endpoint -notmatch '\?\$select=(.+)$') {
        return @()
    }

    return @($Matches[1] -split ',')
}

function Get-Stage2GraphPropertySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunPath,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    $artifactPath = Join-Path -Path $RunPath -ChildPath (Join-Path -Path 'stage2' -ChildPath (Join-Path -Path 'entra-apps' -ChildPath (Join-Path -Path $Family -ChildPath 'batch-0001.json')))
    if (-not (Test-Path -LiteralPath $artifactPath)) {
        throw ('Expected Stage2 artifact was not created: ' + $artifactPath)
    }

    return (Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json)
}

Describe 'Stage2 Entra Graph property contract' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage2-graph-properties-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $global:CollectorStage2GraphPropertyEndpoints = New-Object 'System.Collections.Generic.List[string]'

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'object-1' })
        }

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            $global:CollectorStage2GraphPropertyEndpoints.Add([string]$Endpoint) | Out-Null

            if ($Endpoint -like '/v1.0/applications/*') {
                return [pscustomobject]@{
                    id = 'object-1'
                    authenticationBehaviors = [pscustomobject]@{
                        coopEnforcement = $true
                    }
                    requiredResourceAccess = @(
                        [pscustomobject]@{
                            resourceAppId = 'api-1'
                        }
                    )
                }
            }

            if ($Endpoint -like '/v1.0/servicePrincipals/*') {
                return [pscustomobject]@{
                    id = 'object-1'
                    appRoleAssignmentRequired = $true
                    preferredSingleSignOnMode = 'saml'
                    samlSingleSignOnSettings = [pscustomobject]@{
                        relayState = 'https://example.invalid/relay'
                    }
                }
            }

            if ($Endpoint -like '/v1.0/groups/*') {
                return [pscustomobject]@{
                    id = 'object-1'
                    isManagementRestricted = $true
                    assignedLabels = @(
                        [pscustomobject]@{
                            labelId = 'label-1'
                            displayName = 'Confidential'
                        }
                    )
                    onPremisesExtensionAttributes = [pscustomobject]@{
                        extensionAttribute1 = 'Finance'
                    }
                }
            }

            return [pscustomobject]@{ id = 'detail-object' }
        }
    }

    AfterEach {
        Remove-Variable -Name CollectorStage2GraphPropertyEndpoints -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'requests explicit v1.0 Entra properties, records provenance, and leaves unrelated Graph families unchanged' {
        $context = New-Stage2GraphPropertyContractContext -RunPath $script:testRoot
        $sections = @('entra-apps', 'entra-pim', 'intune-core')

        Invoke-CollectorStage1 -Context $context -Sections $sections | Out-Null
        Invoke-CollectorStage2 -Context $context -Sections $sections | Out-Null

        $applicationEndpoint = @($global:CollectorStage2GraphPropertyEndpoints | Where-Object { $_ -like '/v1.0/applications/*' })[0]
        $servicePrincipalEndpoint = @($global:CollectorStage2GraphPropertyEndpoints | Where-Object { $_ -like '/v1.0/servicePrincipals/*' })[0]
        $groupEndpoint = @($global:CollectorStage2GraphPropertyEndpoints | Where-Object { $_ -like '/v1.0/groups/*' })[0]

        foreach ($endpoint in @($applicationEndpoint, $servicePrincipalEndpoint, $groupEndpoint)) {
            if (-not $endpoint -or $endpoint -notmatch '\?\$select=') {
                throw ('Expected explicit $select on Entra Stage2 endpoint; actual ' + [string]$endpoint + '.')
            }
            if ($endpoint -match '\$select=\*') {
                throw ('Stage2 must not use $select=*; actual ' + $endpoint + '.')
            }
        }

        $applicationProperties = @(Get-SelectedPropertiesFromEndpoint -Endpoint $applicationEndpoint)
        $servicePrincipalProperties = @(Get-SelectedPropertiesFromEndpoint -Endpoint $servicePrincipalEndpoint)
        $groupProperties = @(Get-SelectedPropertiesFromEndpoint -Endpoint $groupEndpoint)

        foreach ($required in @('authenticationBehaviors', 'requiredResourceAccess', 'servicePrincipalLockConfiguration')) {
            if ($applicationProperties -notcontains $required) {
                throw ('Application $select is missing required property ' + $required + '.')
            }
        }
        foreach ($required in @('appRoleAssignmentRequired', 'preferredSingleSignOnMode', 'samlSingleSignOnSettings')) {
            if ($servicePrincipalProperties -notcontains $required) {
                throw ('Service principal $select is missing required property ' + $required + '.')
            }
        }
        foreach ($required in @('assignedLabels', 'isManagementRestricted', 'licenseProcessingState', 'onPremisesExtensionAttributes')) {
            if ($groupProperties -notcontains $required) {
                throw ('Group $select is missing required property ' + $required + '.')
            }
        }

        $allProperties = @($applicationProperties) + @($servicePrincipalProperties) + @($groupProperties)
        if ($allProperties -contains 'keyCredentials' -or $allProperties -contains 'passwordCredentials') {
            throw 'Credential properties owned by #45 must not be included in the ordinary Stage2 property contract.'
        }
        if (@($applicationProperties | Sort-Object -Unique).Count -ne $applicationProperties.Count) {
            throw 'Application Stage2 property contract contains duplicate property names.'
        }
        if (@($servicePrincipalProperties | Sort-Object -Unique).Count -ne $servicePrincipalProperties.Count) {
            throw 'Service principal Stage2 property contract contains duplicate property names.'
        }
        if (@($groupProperties | Sort-Object -Unique).Count -ne $groupProperties.Count) {
            throw 'Group Stage2 property contract contains duplicate property names.'
        }

        $unselectedEndpoints = @($global:CollectorStage2GraphPropertyEndpoints | Where-Object {
            $_ -like '/v1.0/roleManagement/*' -or
            $_ -like '/v1.0/deviceAppManagement/*' -or
            $_ -like '/beta/deviceManagement/*'
        })
        if ($unselectedEndpoints.Count -ne 4) {
            throw ('Expected four PIM/Intune Stage2 requests; actual ' + $unselectedEndpoints.Count + '.')
        }
        foreach ($endpoint in $unselectedEndpoints) {
            if ($endpoint -match '\?\$select=') {
                throw ('#16 must not add an unreviewed $select contract to PIM/Intune endpoint ' + $endpoint + '.')
            }
        }

        $applicationSnapshot = Get-Stage2GraphPropertySnapshot -RunPath $script:testRoot -Family 'applications'
        $servicePrincipalSnapshot = Get-Stage2GraphPropertySnapshot -RunPath $script:testRoot -Family 'servicePrincipals'
        $groupSnapshot = Get-Stage2GraphPropertySnapshot -RunPath $script:testRoot -Family 'groups'

        if ((@($applicationSnapshot.requestContext.selectedProperties) -join ',') -ne ($applicationProperties -join ',')) {
            throw 'Application provenance selectedProperties does not match the request contract.'
        }
        if ((@($servicePrincipalSnapshot.requestContext.selectedProperties) -join ',') -ne ($servicePrincipalProperties -join ',')) {
            throw 'Service principal provenance selectedProperties does not match the request contract.'
        }
        if ((@($groupSnapshot.requestContext.selectedProperties) -join ',') -ne ($groupProperties -join ',')) {
            throw 'Group provenance selectedProperties does not match the request contract.'
        }

        if (-not [bool]$applicationSnapshot.items[0].authenticationBehaviors.coopEnforcement) {
            throw 'Nested application configuration returned by Graph was not persisted unchanged.'
        }
        if ([string]$servicePrincipalSnapshot.items[0].samlSingleSignOnSettings.relayState -ne 'https://example.invalid/relay') {
            throw 'Nested service principal SAML configuration returned by Graph was not persisted unchanged.'
        }
        if ([string]$groupSnapshot.items[0].assignedLabels[0].labelId -ne 'label-1') {
            throw 'Nested group assigned-label configuration returned by Graph was not persisted unchanged.'
        }
        if ([string]$groupSnapshot.items[0].onPremisesExtensionAttributes.extensionAttribute1 -ne 'Finance') {
            throw 'Nested group on-premises extension attributes returned by Graph were not persisted unchanged.'
        }
    }
}
