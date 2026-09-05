Set-StrictMode -Version Latest

function Assert-CollectorOnPremCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CommandNames
    )

    foreach ($commandName in $CommandNames) {
        if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw ('Required on-prem command is not available: {0}' -f $commandName)
        }
    }
}

function Get-CollectorFirstPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Item,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        if ($Item.PSObject.Properties.Match($propertyName).Count -gt 0) {
            $value = $Item.$propertyName
            if ($null -ne $value -and [string]$value -ne '') {
                return $value
            }
        }
    }

    return $null
}

function Get-CollectorOnPremForestDomains {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'This private helper intentionally returns the forest domain collection and the plural name matches that result contract.')]
    param()

    Assert-CollectorOnPremCommand -CommandNames @('Get-ADForest')
    $forest = Get-ADForest
    $domains = @()

    foreach ($domain in @($forest.Domains)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$domain)) {
            $domains += [string]$domain
        }
    }

    return @($domains | Select-Object -Unique)
}

function Get-CollectorDomainFromDistinguishedName {
    [CmdletBinding()]
    param(
        [string]$DistinguishedName
    )

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return $null
    }

    $dnMatches = [System.Text.RegularExpressions.Regex]::Matches($DistinguishedName, 'DC=([^,]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($dnMatches.Count -eq 0) {
        return $null
    }

    $labels = @()
    foreach ($match in $dnMatches) {
        $labels += [string]$match.Groups[1].Value
    }

    if ($labels.Count -eq 0) {
        return $null
    }

    return ($labels -join '.')
}

function Resolve-CollectorOnPremDomainContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$InventoryItem
    )

    $domainFromItem = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('domainId', 'domainName', 'domain')
    if ($domainFromItem) {
        return [string]$domainFromItem
    }

    $distinguishedName = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('distinguishedName', 'DistinguishedName', 'id', 'Id')
    $domainFromDn = Get-CollectorDomainFromDistinguishedName -DistinguishedName $distinguishedName
    if ($domainFromDn) {
        return [string]$domainFromDn
    }

    return $null
}

function Get-CollectorDomainAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DomainContext,

        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    if ([string]::IsNullOrWhiteSpace($DomainContext)) {
        throw 'Unable to resolve persisted domain context for ACL collection.'
    }

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        throw 'Unable to resolve distinguished name for ACL collection.'
    }

    $driveName = 'CollectorAD' + [Guid]::NewGuid().ToString('N')
    try {
        New-PSDrive -Name $driveName -PSProvider ActiveDirectory -Root '//RootDSE/' -Server $DomainContext -Scope Local -ErrorAction Stop | Out-Null
        $providerPath = '{0}:\{1}' -f $driveName, $DistinguishedName
        $acl = Get-Acl -LiteralPath $providerPath -ErrorAction Stop

        [pscustomobject]@{
            Path = 'AD:\{0}' -f $DistinguishedName
            Acl = $acl
        }
    }
    finally {
        Remove-PSDrive -Name $driveName -Scope Local -Force -ErrorAction SilentlyContinue
    }
}

function Get-CollectorOnPremProvenanceProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Inventory', 'Details', 'Relationships')]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [string]$Family
    )

    switch ($Phase) {
        'Inventory' {
            switch ($Family) {
                'domains' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADForest'
                        CmdletNames = @('Get-ADForest')
                    }
                }

                'organizationalUnits' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADForest, Get-ADOrganizationalUnit'
                        CmdletNames = @('Get-ADForest', 'Get-ADOrganizationalUnit')
                    }
                }

                'groups' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADForest, Get-ADGroup'
                        CmdletNames = @('Get-ADForest', 'Get-ADGroup')
                    }
                }

                'gpos' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADForest, Get-GPO'
                        CmdletNames = @('Get-ADForest', 'Get-GPO')
                    }
                }
            }
        }

        'Details' {
            switch ($Family) {
                'domains' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADDomain'
                        CmdletNames = @('Get-ADDomain')
                    }
                }

                'organizationalUnits' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADOrganizationalUnit'
                        CmdletNames = @('Get-ADOrganizationalUnit')
                    }
                }

                'groups' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADGroup'
                        CmdletNames = @('Get-ADGroup')
                    }
                }

                'gpos' {
                    return [pscustomobject]@{
                        SourceName = 'Get-GPO'
                        CmdletNames = @('Get-GPO')
                    }
                }
            }
        }

        'Relationships' {
            switch ($Family) {
                'domainRootAcl' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADDomain, Get-Acl'
                        CmdletNames = @('Get-ADDomain', 'Get-Acl')
                    }
                }

                'ouAcl' {
                    return [pscustomobject]@{
                        SourceName = 'Get-Acl'
                        CmdletNames = @('Get-Acl')
                    }
                }

                'gpoPermissions' {
                    return [pscustomobject]@{
                        SourceName = 'Get-GPPermission'
                        CmdletNames = @('Get-GPPermission')
                    }
                }

                'groupMembersOnPrem' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADGroupMember'
                        CmdletNames = @('Get-ADGroupMember')
                    }
                }
            }
        }
    }

    throw ('Unsupported on-prem provenance profile for phase {0}, family {1}.' -f $Phase, $Family)
}

function Invoke-CollectorOnPremInventoryFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('domains', 'organizationalUnits', 'groups', 'gpos')]
        [string]$Family
    )

    switch ($Family) {
        'domains' {
            $forestDomains = Get-CollectorOnPremForestDomains
            $domains = @()
            foreach ($domain in @($forestDomains)) {
                $domains += [pscustomobject]@{
                    id = [string]$domain
                    name = [string]$domain
                    domainId = [string]$domain
                    domainName = [string]$domain
                }
            }
            return $domains
        }

        'organizationalUnits' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADForest', 'Get-ADOrganizationalUnit')
            $forestDomains = Get-CollectorOnPremForestDomains
            $result = @()
            foreach ($domain in @($forestDomains)) {
                $ous = Get-ADOrganizationalUnit -Filter * -Server $domain -Properties DistinguishedName, Name
                foreach ($ou in @($ous)) {
                    $resolvedDomain = Get-CollectorDomainFromDistinguishedName -DistinguishedName ([string]$ou.DistinguishedName)
                    if (-not $resolvedDomain) {
                        $resolvedDomain = [string]$domain
                    }

                    $result += [pscustomobject]@{
                        id = [string]$ou.DistinguishedName
                        distinguishedName = [string]$ou.DistinguishedName
                        name = [string]$ou.Name
                        domainId = [string]$resolvedDomain
                        domainName = [string]$resolvedDomain
                    }
                }
            }
            return $result
        }

        'groups' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADForest', 'Get-ADGroup')
            $forestDomains = Get-CollectorOnPremForestDomains
            $result = @()
            foreach ($domain in @($forestDomains)) {
                $groups = Get-ADGroup -Filter * -Server $domain -Properties DistinguishedName, Name, SamAccountName
                foreach ($group in @($groups)) {
                    $resolvedDomain = Get-CollectorDomainFromDistinguishedName -DistinguishedName ([string]$group.DistinguishedName)
                    if (-not $resolvedDomain) {
                        $resolvedDomain = [string]$domain
                    }

                    $result += [pscustomobject]@{
                        id = [string]$group.DistinguishedName
                        distinguishedName = [string]$group.DistinguishedName
                        name = [string]$group.Name
                        samAccountName = [string]$group.SamAccountName
                        domainId = [string]$resolvedDomain
                        domainName = [string]$resolvedDomain
                    }
                }
            }
            return $result
        }

        'gpos' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADForest', 'Get-GPO')
            $forestDomains = Get-CollectorOnPremForestDomains
            $result = @()
            foreach ($domain in @($forestDomains)) {
                $gpos = Get-GPO -All -Domain $domain
                foreach ($gpo in @($gpos)) {
                    $resolvedDomain = if ($gpo.DomainName) { [string]$gpo.DomainName } else { [string]$domain }
                    $result += [pscustomobject]@{
                        id = [string]$gpo.Id
                        displayName = [string]$gpo.DisplayName
                        domainName = [string]$resolvedDomain
                        domainId = [string]$resolvedDomain
                    }
                }
            }
            return $result
        }
    }
}

function Invoke-CollectorOnPremDetailFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('domains', 'organizationalUnits', 'groups', 'gpos')]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$InventoryItem
    )

    switch ($Family) {
        'domains' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADDomain')
            $domainId = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('id', 'name')
            if (-not $domainId) {
                throw 'Unable to resolve domain identity for Stage2 detail collection.'
            }

            $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $InventoryItem
            if ($domainContext) {
                return Get-ADDomain -Identity $domainId -Server $domainContext
            }

            return Get-ADDomain -Identity $domainId
        }

        'organizationalUnits' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADOrganizationalUnit')
            $ouDn = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('id', 'distinguishedName')
            if (-not $ouDn) {
                throw 'Unable to resolve OU identity for Stage2 detail collection.'
            }

            $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $InventoryItem
            if ($domainContext) {
                return Get-ADOrganizationalUnit -Identity $ouDn -Server $domainContext -Properties *
            }

            return Get-ADOrganizationalUnit -Identity $ouDn -Properties *
        }

        'groups' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADGroup')
            $groupIdentity = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('id', 'distinguishedName', 'samAccountName', 'name')
            if (-not $groupIdentity) {
                throw 'Unable to resolve group identity for Stage2 detail collection.'
            }

            $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $InventoryItem
            if ($domainContext) {
                return Get-ADGroup -Identity $groupIdentity -Server $domainContext -Properties *
            }

            return Get-ADGroup -Identity $groupIdentity -Properties *
        }

        'gpos' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-GPO')
            $gpoId = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('id')
            if (-not $gpoId) {
                throw 'Unable to resolve GPO identity for Stage2 detail collection.'
            }

            $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $InventoryItem
            if ($domainContext) {
                return Get-GPO -Guid ([Guid]$gpoId) -Domain $domainContext
            }

            return Get-GPO -Guid ([Guid]$gpoId)
        }
    }
}

function Invoke-CollectorOnPremRelationshipFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('domainRootAcl', 'ouAcl', 'gpoPermissions', 'groupMembersOnPrem')]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [object[]]$InventoryItems
    )

    $results = @()

    switch ($Family) {
        'domainRootAcl' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADDomain', 'Get-Acl')
            foreach ($domainItem in @($InventoryItems)) {
                $domainName = Get-CollectorFirstPropertyValue -Item $domainItem -PropertyNames @('id', 'name')
                if (-not $domainName) {
                    $results += [pscustomobject]@{ _collectorError = 'Unable to resolve domain identity for ACL collection.' }
                    continue
                }

                $domainContext = $null
                try {
                    $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $domainItem
                    if (-not $domainContext) {
                        $domainContext = [string]$domainName
                    }
                    $domain = Get-ADDomain -Identity $domainName -Server $domainContext
                    $aclRead = Get-CollectorDomainAcl -DomainContext $domainContext -DistinguishedName ([string]$domain.DistinguishedName)
                    $results += [pscustomobject]@{
                        domain = $domainName
                        domainContext = [string]$domainContext
                        path = $aclRead.Path
                        owner = $aclRead.Acl.Owner
                        access = @($aclRead.Acl.Access)
                    }
                }
                catch {
                    $results += [pscustomobject]@{
                        domain = $domainName
                        domainContext = if ($domainContext) { [string]$domainContext } else { [string]$domainName }
                        _collectorError = $_.Exception.Message
                    }
                }
            }
        }

        'ouAcl' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-Acl')
            foreach ($ouItem in @($InventoryItems)) {
                $ouDn = Get-CollectorFirstPropertyValue -Item $ouItem -PropertyNames @('id', 'distinguishedName')
                if (-not $ouDn) {
                    $results += [pscustomobject]@{ _collectorError = 'Unable to resolve OU identity for ACL collection.' }
                    continue
                }

                $domainContext = $null
                try {
                    $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $ouItem
                    if (-not $domainContext) {
                        throw 'Unable to resolve persisted domain context for OU ACL collection.'
                    }
                    $aclRead = Get-CollectorDomainAcl -DomainContext $domainContext -DistinguishedName ([string]$ouDn)
                    $results += [pscustomobject]@{
                        distinguishedName = $ouDn
                        domainContext = [string]$domainContext
                        path = $aclRead.Path
                        owner = $aclRead.Acl.Owner
                        access = @($aclRead.Acl.Access)
                    }
                }
                catch {
                    $results += [pscustomobject]@{
                        distinguishedName = $ouDn
                        domainContext = $domainContext
                        _collectorError = $_.Exception.Message
                    }
                }
            }
        }

        'gpoPermissions' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-GPPermission')
            foreach ($gpoItem in @($InventoryItems)) {
                $gpoId = Get-CollectorFirstPropertyValue -Item $gpoItem -PropertyNames @('id', 'Id')
                $gpoName = Get-CollectorFirstPropertyValue -Item $gpoItem -PropertyNames @('displayName', 'name')
                $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $gpoItem

                $parsedGpoId = [Guid]::Empty
                if (-not $gpoId -or -not [Guid]::TryParse([string]$gpoId, [ref]$parsedGpoId)) {
                    $results += [pscustomobject]@{
                        gpo = $gpoName
                        gpoId = if ($gpoId) { [string]$gpoId } else { $null }
                        domainContext = $domainContext
                        _collectorError = 'Unable to resolve a valid persisted GPO GUID for permission collection.'
                    }
                    continue
                }

                try {
                    if ($domainContext) {
                        $permissions = Get-GPPermission -Guid $parsedGpoId -All -DomainName $domainContext
                    }
                    else {
                        $permissions = Get-GPPermission -Guid $parsedGpoId -All
                    }

                    $results += [pscustomobject]@{
                        gpo = $gpoName
                        gpoId = [string]$parsedGpoId
                        domainContext = $domainContext
                        permissions = @($permissions)
                    }
                }
                catch {
                    $results += [pscustomobject]@{
                        gpo = $gpoName
                        gpoId = [string]$parsedGpoId
                        domainContext = $domainContext
                        _collectorError = $_.Exception.Message
                    }
                }
            }
        }

        'groupMembersOnPrem' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADGroupMember')
            foreach ($groupItem in @($InventoryItems)) {
                $groupIdentity = Get-CollectorFirstPropertyValue -Item $groupItem -PropertyNames @('id', 'distinguishedName', 'samAccountName', 'name')
                if (-not $groupIdentity) {
                    $results += [pscustomobject]@{ _collectorError = 'Unable to resolve group identity for membership collection.' }
                    continue
                }

                $domainContext = $null
                try {
                    $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $groupItem
                    if ($domainContext) {
                        $members = Get-ADGroupMember -Identity $groupIdentity -Server $domainContext
                    }
                    else {
                        $members = Get-ADGroupMember -Identity $groupIdentity
                    }

                    $results += [pscustomobject]@{
                        group = $groupIdentity
                        domainContext = $domainContext
                        members = @($members)
                    }
                }
                catch {
                    $results += [pscustomobject]@{
                        group = $groupIdentity
                        domainContext = $domainContext
                        _collectorError = $_.Exception.Message
                    }
                }
            }
        }
    }

    return $results
}

Export-ModuleMember -Function @(
    'Get-CollectorOnPremProvenanceProfile',
    'Invoke-CollectorOnPremInventoryFamily',
    'Invoke-CollectorOnPremDetailFamily',
    'Invoke-CollectorOnPremRelationshipFamily'
)