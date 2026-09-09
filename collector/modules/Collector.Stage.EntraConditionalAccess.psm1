Set-StrictMode -Version Latest

$stage1ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage1.Inventory.psm1'
$stage2ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage2.Details.psm1'
$stage3ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Stage3.Relationships.psm1'
$artifactModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collector.Storage.Artifacts.psm1'

function Get-CollectorConditionalAccessModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $loaded = @(Get-Module -Name $Name | Where-Object { $_.Path -and [System.IO.Path]::GetFullPath($_.Path) -eq $fullPath })
    if ($loaded.Count -gt 0) {
        return $loaded[0]
    }

    $imported = @(Import-Module -Name $fullPath -PassThru -ErrorAction Stop)
    if ($imported.Count -lt 1) {
        throw ('Conditional Access collection could not load module {0}.' -f $Name)
    }
    return $imported[0]
}

$script:CollectorConditionalAccessStage1Module = Get-CollectorConditionalAccessModule -Name 'Collector.Stage1.Inventory' -Path $stage1ModulePath
$script:CollectorConditionalAccessStage2Module = Get-CollectorConditionalAccessModule -Name 'Collector.Stage2.Details' -Path $stage2ModulePath
$script:CollectorConditionalAccessStage3Module = Get-CollectorConditionalAccessModule -Name 'Collector.Stage3.Relationships' -Path $stage3ModulePath
$script:CollectorConditionalAccessArtifactModule = Get-CollectorConditionalAccessModule -Name 'Collector.Storage.Artifacts' -Path $artifactModulePath

function Get-CollectorConditionalAccessProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject -or $InputObject.PSObject.Properties.Match($Name).Count -eq 0) {
        return $null
    }
    return $InputObject.$Name
}

function Get-CollectorConditionalAccessReferenceRecordSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Policies
    )

    $records = [System.Collections.Generic.List[object]]::new()
    $append = {
        param(
            [string]$PolicyId,
            [string]$ReferenceType,
            [string]$Direction,
            [string]$SourcePath,
            [AllowNull()][object]$TargetId,
            [string]$TargetIdentityDomain
        )

        if ($null -eq $TargetId -or [string]::IsNullOrWhiteSpace([string]$TargetId)) {
            return
        }
        $records.Add([pscustomobject][ordered]@{
            policyId = $PolicyId
            referenceType = $ReferenceType
            direction = $Direction
            sourcePath = $SourcePath
            targetId = [string]$TargetId
            targetIdentityDomain = $TargetIdentityDomain
        }) | Out-Null
    }

    foreach ($policy in @($Policies)) {
        if ($null -eq $policy) {
            continue
        }
        $policyId = [string](Get-CollectorConditionalAccessProperty -InputObject $policy -Name 'id')
        if ([string]::IsNullOrWhiteSpace($policyId)) {
            throw 'Conditional Access policy reference derivation requires every policy to have a non-empty id.'
        }

        $templateId = Get-CollectorConditionalAccessProperty -InputObject $policy -Name 'templateId'
        if ($templateId) {
            & $append $policyId 'template' 'reference' 'templateId' $templateId 'entra.conditional-access-template'
        }

        $conditions = Get-CollectorConditionalAccessProperty -InputObject $policy -Name 'conditions'
        $users = Get-CollectorConditionalAccessProperty -InputObject $conditions -Name 'users'
        foreach ($direction in @('include', 'exclude')) {
            $prefix = if ($direction -eq 'include') { 'include' } else { 'exclude' }
            $userProperty = $prefix + 'Users'
            foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $users -Name $userProperty)) {
                $domain = if (@('All', 'None', 'GuestsOrExternalUsers') -contains [string]$target) { 'entra.conditional-access-selector' } else { 'entra.user' }
                & $append $policyId 'user' $direction ('conditions.users.{0}' -f $userProperty) $target $domain
            }

            $groupProperty = $prefix + 'Groups'
            foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $users -Name $groupProperty)) {
                & $append $policyId 'group' $direction ('conditions.users.{0}' -f $groupProperty) $target 'entra.group'
            }

            $roleProperty = $prefix + 'Roles'
            foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $users -Name $roleProperty)) {
                & $append $policyId 'role' $direction ('conditions.users.{0}' -f $roleProperty) $target 'entra.directory-role-template'
            }

            $guestProperty = $prefix + 'GuestsOrExternalUsers'
            $guestScope = Get-CollectorConditionalAccessProperty -InputObject $users -Name $guestProperty
            if ($guestScope) {
                $guestTypes = Get-CollectorConditionalAccessProperty -InputObject $guestScope -Name 'guestOrExternalUserTypes'
                if ($guestTypes) {
                    & $append $policyId 'guestOrExternalUserType' $direction ('conditions.users.{0}.guestOrExternalUserTypes' -f $guestProperty) $guestTypes 'entra.conditional-access-selector'
                }
                $externalTenants = Get-CollectorConditionalAccessProperty -InputObject $guestScope -Name 'externalTenants'
                $membershipKind = Get-CollectorConditionalAccessProperty -InputObject $externalTenants -Name 'membershipKind'
                if ([string]$membershipKind -eq 'all') {
                    & $append $policyId 'externalTenant' $direction ('conditions.users.{0}.externalTenants' -f $guestProperty) 'AllExternalTenants' 'entra.conditional-access-selector'
                }
                foreach ($tenantId in @(Get-CollectorConditionalAccessProperty -InputObject $externalTenants -Name 'members')) {
                    & $append $policyId 'externalTenant' $direction ('conditions.users.{0}.externalTenants.members' -f $guestProperty) $tenantId 'entra.tenant'
                }
            }
        }

        $applications = Get-CollectorConditionalAccessProperty -InputObject $conditions -Name 'applications'
        foreach ($direction in @('include', 'exclude')) {
            $propertyName = if ($direction -eq 'include') { 'includeApplications' } else { 'excludeApplications' }
            foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $applications -Name $propertyName)) {
                $domain = if (@('All', 'Office365', 'MicrosoftAdminPortals') -contains [string]$target) { 'entra.conditional-access-selector' } else { 'entra.application-app-id' }
                & $append $policyId 'application' $direction ('conditions.applications.{0}' -f $propertyName) $target $domain
            }
        }
        foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $applications -Name 'includeUserActions')) {
            & $append $policyId 'userAction' 'include' 'conditions.applications.includeUserActions' $target 'entra.conditional-access-user-action'
        }
        foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $applications -Name 'includeAuthenticationContextClassReferences')) {
            & $append $policyId 'authenticationContext' 'include' 'conditions.applications.includeAuthenticationContextClassReferences' $target 'entra.authentication-context'
        }

        $clientApplications = Get-CollectorConditionalAccessProperty -InputObject $conditions -Name 'clientApplications'
        foreach ($direction in @('include', 'exclude')) {
            $propertyName = if ($direction -eq 'include') { 'includeServicePrincipals' } else { 'excludeServicePrincipals' }
            foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $clientApplications -Name $propertyName)) {
                $domain = if ([string]$target -eq 'ServicePrincipalsInMyTenant') { 'entra.conditional-access-selector' } else { 'entra.service-principal' }
                & $append $policyId 'servicePrincipal' $direction ('conditions.clientApplications.{0}' -f $propertyName) $target $domain
            }
        }

        $locations = Get-CollectorConditionalAccessProperty -InputObject $conditions -Name 'locations'
        foreach ($direction in @('include', 'exclude')) {
            $propertyName = if ($direction -eq 'include') { 'includeLocations' } else { 'excludeLocations' }
            foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $locations -Name $propertyName)) {
                $domain = if (@('All', 'AllTrusted') -contains [string]$target) { 'entra.conditional-access-selector' } else { 'entra.named-location' }
                & $append $policyId 'namedLocation' $direction ('conditions.locations.{0}' -f $propertyName) $target $domain
            }
        }

        $grantControls = Get-CollectorConditionalAccessProperty -InputObject $policy -Name 'grantControls'
        $authenticationStrength = Get-CollectorConditionalAccessProperty -InputObject $grantControls -Name 'authenticationStrength'
        $authenticationStrengthId = Get-CollectorConditionalAccessProperty -InputObject $authenticationStrength -Name 'id'
        if ($authenticationStrengthId) {
            & $append $policyId 'authenticationStrength' 'control' 'grantControls.authenticationStrength.id' $authenticationStrengthId 'entra.authentication-strength-policy'
        }
        foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $grantControls -Name 'termsOfUse')) {
            & $append $policyId 'termsOfUse' 'control' 'grantControls.termsOfUse' $target 'entra.terms-of-use'
        }
        foreach ($target in @(Get-CollectorConditionalAccessProperty -InputObject $grantControls -Name 'customAuthenticationFactors')) {
            & $append $policyId 'customAuthenticationFactor' 'control' 'grantControls.customAuthenticationFactors' $target 'entra.custom-authentication-factor'
        }
    }

    return @($records | Sort-Object policyId, referenceType, direction, sourcePath, targetIdentityDomain, targetId)
}

function Invoke-CollectorConditionalAccessStage1 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-ca' -Family 'conditionalAccessPolicies' -Endpoint '/v1.0/identity/conditionalAccess/policies'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-ca' -Family 'namedLocations' -Endpoint '/v1.0/identity/conditionalAccess/namedLocations'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-ca' -Family 'authenticationStrengthPolicies' -Endpoint '/v1.0/policies/authenticationStrengthPolicies'
            Invoke-CollectorGraphInventoryFamily -Context $InnerContext -Section 'entra-ca' -Family 'authenticationContextClassReferences' -Endpoint '/v1.0/identity/conditionalAccess/authenticationContextClassReferences'
        )
    }
    return @($script:CollectorConditionalAccessStage1Module.Invoke($runner, [object[]]@($Context)))
}

function Invoke-CollectorConditionalAccessStage2 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $runner = {
        param($InnerContext)
        @(
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-ca' -Family 'conditionalAccessPolicies' -EndpointTemplate '/v1.0/identity/conditionalAccess/policies/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-ca' -Family 'namedLocations' -EndpointTemplate '/v1.0/identity/conditionalAccess/namedLocations/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-ca' -Family 'authenticationStrengthPolicies' -EndpointTemplate '/v1.0/policies/authenticationStrengthPolicies/{id}')
            Publish-CollectorStage2Result -Context $InnerContext -Result (Invoke-CollectorStage2GraphFamily -Context $InnerContext -Section 'entra-ca' -Family 'authenticationContextClassReferences' -EndpointTemplate '/v1.0/identity/conditionalAccess/authenticationContextClassReferences/{id}')
        )
    }
    return @($script:CollectorConditionalAccessStage2Module.Invoke($runner, [object[]]@($Context)))
}

function Invoke-CollectorConditionalAccessStage3 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $readinessCheck = {
        param($InnerRunPath, $InnerRunId)
        Assert-CollectorInventoryFirstForStage3 -RunPath $InnerRunPath -Section 'entra-ca' -Families @('conditionalAccessPolicies') -RunId $InnerRunId
    }
    $script:CollectorConditionalAccessStage3Module.Invoke($readinessCheck, [object[]]@($Context.RunPath, $Context.RunId)) | Out-Null

    $inventoryReader = {
        param($InnerRunPath, $InnerRunId)
        return @(Get-CollectorSnapshotItems -RunPath $InnerRunPath -Stage 'stage1' -Section 'entra-ca' -Family 'conditionalAccessPolicies' -ExpectedRunId $InnerRunId)
    }
    $policies = @($script:CollectorConditionalAccessArtifactModule.Invoke($inventoryReader, [object[]]@($Context.RunPath, $Context.RunId)))
    $edges = @(Get-CollectorConditionalAccessReferenceRecordSet -Policies $policies)

    $runner = {
        param($InnerContext, $InnerEdges)
        $batches = Split-CollectorItems -Items @($InnerEdges) -BatchSize $InnerContext.BatchSize
        $result = Invoke-CollectorStage3BatchLoop -Context $InnerContext -Section 'entra-ca' -Family 'conditionalAccessPolicyReferences' -Batches $batches -SourceType 'Derived' -SourceName 'Derived Conditional Access policy references from Stage1 policy inventory' -ApiVersion 'v1.0' -IsBeta:$false -RequestContext @{ dependencyFamily = 'conditionalAccessPolicies'; transform = 'conditional-access-policy-to-reference' } -BatchCollector {
            param([object[]]$batchItems)
            [pscustomobject]@{
                Items = @($batchItems)
                FailedCount = 0
                Errors = @()
            }
        }
        return Publish-CollectorStage3Result -Context $InnerContext -Result $result
    }

    return @($script:CollectorConditionalAccessStage3Module.Invoke($runner, [object[]]@($Context, $edges)))
}

Export-ModuleMember -Function @(
    'Invoke-CollectorConditionalAccessStage1',
    'Invoke-CollectorConditionalAccessStage2',
    'Invoke-CollectorConditionalAccessStage3'
)
