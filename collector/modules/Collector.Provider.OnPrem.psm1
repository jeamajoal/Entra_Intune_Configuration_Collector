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

function Test-CollectorGpoCredentialFieldName {
    [CmdletBinding()]
    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return $Name -match '^(?i:cpassword|password|passwordvalue|passwordtext|passwd|secret|secretvalue|secrettext|privatekey|privatekeyvalue|privatekeymaterial|clientsecret)$'
}

function Protect-CollectorGpoReportXmlNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlNode]$Node
    )

    $redactionCount = 0
    $isCredentialElement = (
        $Node.NodeType -eq [System.Xml.XmlNodeType]::Element -and
        (Test-CollectorGpoCredentialFieldName -Name $Node.LocalName)
    )

    if ($isCredentialElement) {
        foreach ($attribute in @($Node.Attributes)) {
            if ($null -eq $attribute) {
                continue
            }

            $isNamespaceDeclaration = (
                [string]$attribute.NamespaceURI -eq 'http://www.w3.org/2000/xmlns/' -or
                [string]$attribute.Prefix -eq 'xmlns' -or
                [string]$attribute.Name -eq 'xmlns'
            )
            if ($isNamespaceDeclaration) {
                continue
            }

            if ([string]$attribute.Value -ne '[REDACTED]') {
                $attribute.Value = '[REDACTED]'
                $redactionCount++
            }
        }

        if ($Node.HasChildNodes -or -not [string]::IsNullOrEmpty([string]$Node.InnerText)) {
            if ([string]$Node.InnerText -ne '[REDACTED]') {
                $Node.InnerText = '[REDACTED]'
                $redactionCount++
            }
        }

        return $redactionCount
    }

    foreach ($attribute in @($Node.Attributes)) {
        if ($null -eq $attribute) {
            continue
        }

        $isNamespaceDeclaration = (
            [string]$attribute.NamespaceURI -eq 'http://www.w3.org/2000/xmlns/' -or
            [string]$attribute.Prefix -eq 'xmlns' -or
            [string]$attribute.Name -eq 'xmlns'
        )
        if ($isNamespaceDeclaration) {
            continue
        }

        if (Test-CollectorGpoCredentialFieldName -Name $attribute.LocalName) {
            if ([string]$attribute.Value -ne '[REDACTED]') {
                $attribute.Value = '[REDACTED]'
                $redactionCount++
            }
        }
    }

    $elementChildren = @($Node.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
    foreach ($child in $elementChildren) {
        $redactionCount += [int](Protect-CollectorGpoReportXmlNode -Node $child)
    }

    return $redactionCount
}

function ConvertTo-CollectorGpoReportEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportXml,

        [Parameter(Mandatory = $true)]
        [Guid]$GpoId,

        [Parameter(Mandatory = $true)]
        [string]$DomainContext,

        [string]$DisplayName
    )

    $document = [System.Xml.XmlDocument]::new()
    try {
        $document.LoadXml($ReportXml)
    }
    catch {
        throw ('Get-GPOReport returned invalid XML for GPO {0} in domain {1}: {2}' -f $GpoId, $DomainContext, $_.Exception.Message)
    }

    if ($null -eq $document.DocumentElement -or [string]$document.DocumentElement.LocalName -ne 'GPO') {
        throw ('Get-GPOReport returned an unexpected XML root for GPO {0} in domain {1}.' -f $GpoId, $DomainContext)
    }

    $computerNode = $document.SelectSingleNode("/*[local-name()='GPO']/*[local-name()='Computer']")
    $userNode = $document.SelectSingleNode("/*[local-name()='GPO']/*[local-name()='User']")
    $redactionCount = 0

    if ($null -ne $computerNode) {
        $redactionCount += [int](Protect-CollectorGpoReportXmlNode -Node $computerNode)
    }
    if ($null -ne $userNode) {
        $redactionCount += [int](Protect-CollectorGpoReportXmlNode -Node $userNode)
    }

    return [pscustomobject]@{
        id = [string]$GpoId
        gpoId = [string]$GpoId
        displayName = $DisplayName
        domainContext = $DomainContext
        reportType = 'Xml'
        computer = [pscustomobject]@{
            present = ($null -ne $computerNode)
            xml = if ($null -ne $computerNode) { [string]$computerNode.OuterXml } else { $null }
        }
        user = [pscustomobject]@{
            present = ($null -ne $userNode)
            xml = if ($null -ne $userNode) { [string]$userNode.OuterXml } else { $null }
        }
        redactedCredentialValueCount = $redactionCount
    }
}

function ConvertTo-CollectorOnPremBoolean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    switch -Regex ([string]$Value) {
        '^(?i:true|yes)$' { return $true }
        '^(?i:false|no)$' { return $false }
        default { throw ('Unable to interpret {0} as a Boolean value: {1}' -f $Label, $Value) }
    }
}

function Get-CollectorXmlChildText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlNode]$Node,

        [Parameter(Mandatory = $true)]
        [string]$LocalName
    )

    $child = $Node.SelectSingleNode("./*[local-name()='$LocalName']")
    if ($null -eq $child) {
        return $null
    }

    return [string]$child.InnerText
}

function ConvertTo-CollectorGpoScopeLinkEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportXml,

        [Parameter(Mandatory = $true)]
        [Guid]$GpoId,

        [Parameter(Mandatory = $true)]
        [string]$DomainContext,

        [string]$DisplayName
    )

    $document = [System.Xml.XmlDocument]::new()
    try {
        $document.LoadXml($ReportXml)
    }
    catch {
        throw ('Get-GPOReport returned invalid XML for GPO scope links {0} in domain {1}: {2}' -f $GpoId, $DomainContext, $_.Exception.Message)
    }

    if ($null -eq $document.DocumentElement -or [string]$document.DocumentElement.LocalName -ne 'GPO') {
        throw ('Get-GPOReport returned an unexpected XML root for GPO scope links {0} in domain {1}.' -f $GpoId, $DomainContext)
    }

    $links = @()
    foreach ($linkNode in @($document.SelectNodes("/*[local-name()='GPO']/*[local-name()='LinksTo']"))) {
        $enabledText = Get-CollectorXmlChildText -Node $linkNode -LocalName 'Enabled'
        $enforcedText = Get-CollectorXmlChildText -Node $linkNode -LocalName 'NoOverride'
        if ([string]::IsNullOrWhiteSpace($enabledText) -or [string]::IsNullOrWhiteSpace($enforcedText)) {
            throw ('Get-GPOReport link evidence is missing Enabled or NoOverride for GPO {0} in domain {1}.' -f $GpoId, $DomainContext)
        }

        $targetName = Get-CollectorXmlChildText -Node $linkNode -LocalName 'SOMName'
        $targetPath = Get-CollectorXmlChildText -Node $linkNode -LocalName 'SOMPath'
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            throw ('Get-GPOReport link evidence is missing SOMPath for GPO {0} in domain {1}.' -f $GpoId, $DomainContext)
        }

        $links += [pscustomobject]@{
            targetId = [string]$targetPath
            targetName = $targetName
            targetPath = [string]$targetPath
            enabled = ConvertTo-CollectorOnPremBoolean -Value $enabledText -Label 'GPO link Enabled'
            enforced = ConvertTo-CollectorOnPremBoolean -Value $enforcedText -Label 'GPO link NoOverride'
        }
    }

    return [pscustomobject]@{
        gpoId = [string]$GpoId
        gpoDisplayName = $DisplayName
        domainContext = $DomainContext
        linkCount = $links.Count
        links = @($links)
    }
}

function ConvertTo-CollectorGpoLinkRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Link
    )

    $gpoId = Get-CollectorFirstPropertyValue -Item $Link -PropertyNames @('GpoId', 'Id')
    $displayName = Get-CollectorFirstPropertyValue -Item $Link -PropertyNames @('DisplayName', 'Name')
    $domainName = Get-CollectorFirstPropertyValue -Item $Link -PropertyNames @('GpoDomainName', 'DomainName')
    $target = Get-CollectorFirstPropertyValue -Item $Link -PropertyNames @('Target')
    $orderValue = Get-CollectorFirstPropertyValue -Item $Link -PropertyNames @('Order')
    $enabledValue = Get-CollectorFirstPropertyValue -Item $Link -PropertyNames @('Enabled')
    $enforcedValue = Get-CollectorFirstPropertyValue -Item $Link -PropertyNames @('Enforced')

    if (-not $gpoId) {
        throw 'Get-GPInheritance returned a GPO link without a stable GpoId.'
    }
    if ($null -eq $enabledValue -or $null -eq $enforcedValue) {
        throw ('Get-GPInheritance returned incomplete enabled/enforced state for GPO link {0}.' -f $gpoId)
    }

    $order = 0
    if ($null -ne $orderValue -and -not [int]::TryParse([string]$orderValue, [ref]$order)) {
        throw ('Get-GPInheritance returned an invalid link order for GPO {0}: {1}' -f $gpoId, $orderValue)
    }

    return [pscustomobject]@{
        gpoId = [string]$gpoId
        displayName = $displayName
        domainName = $domainName
        target = $target
        order = if ($null -ne $orderValue) { [int]$order } else { $null }
        enabled = ConvertTo-CollectorOnPremBoolean -Value $enabledValue -Label 'GPO link Enabled'
        enforced = ConvertTo-CollectorOnPremBoolean -Value $enforcedValue -Label 'GPO link Enforced'
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

                'gpoReports' {
                    return [pscustomobject]@{
                        SourceName = 'Get-GPOReport'
                        CmdletNames = @('Get-GPOReport')
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

                'gpoScopeLinks' {
                    return [pscustomobject]@{
                        SourceName = 'Get-GPOReport'
                        CmdletNames = @('Get-GPOReport')
                    }
                }

                'gpoScopeInheritance' {
                    return [pscustomobject]@{
                        SourceName = 'Get-ADDomain, Get-GPInheritance'
                        CmdletNames = @('Get-ADDomain', 'Get-GPInheritance')
                    }
                }

                'gpoWmiFilterAssociations' {
                    return [pscustomobject]@{
                        SourceName = 'Get-GPO'
                        CmdletNames = @('Get-GPO')
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
        [ValidateSet('domains', 'organizationalUnits', 'groups', 'gpos', 'gpoReports')]
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

        'gpoReports' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-GPOReport')
            $gpoId = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('id', 'Id')
            $parsedGpoId = [Guid]::Empty
            if (-not $gpoId -or -not [Guid]::TryParse([string]$gpoId, [ref]$parsedGpoId)) {
                throw 'Unable to resolve a valid persisted GPO GUID for report collection.'
            }

            $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $InventoryItem
            if ([string]::IsNullOrWhiteSpace([string]$domainContext)) {
                throw 'Unable to resolve persisted domain context for GPO report collection.'
            }

            $displayName = Get-CollectorFirstPropertyValue -Item $InventoryItem -PropertyNames @('displayName', 'name')
            $report = Get-GPOReport -Guid $parsedGpoId -Domain $domainContext -ReportType Xml
            if ($null -eq $report) {
                throw ('Get-GPOReport returned no XML for GPO {0} in domain {1}.' -f $parsedGpoId, $domainContext)
            }

            $reportXml = if ($report -is [System.Xml.XmlDocument]) { [string]$report.OuterXml } else { [string]$report }
            if ([string]::IsNullOrWhiteSpace($reportXml)) {
                throw ('Get-GPOReport returned empty XML for GPO {0} in domain {1}.' -f $parsedGpoId, $domainContext)
            }

            return ConvertTo-CollectorGpoReportEvidence -ReportXml $reportXml -GpoId $parsedGpoId -DomainContext ([string]$domainContext) -DisplayName $displayName
        }
    }
}

function Invoke-CollectorOnPremRelationshipFamily {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('domainRootAcl', 'ouAcl', 'gpoPermissions', 'groupMembersOnPrem', 'gpoScopeLinks', 'gpoScopeInheritance', 'gpoWmiFilterAssociations')]
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

        'gpoScopeLinks' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-GPOReport')
            foreach ($gpoItem in @($InventoryItems)) {
                $gpoId = Get-CollectorFirstPropertyValue -Item $gpoItem -PropertyNames @('id', 'Id')
                $gpoName = Get-CollectorFirstPropertyValue -Item $gpoItem -PropertyNames @('displayName', 'name')
                $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $gpoItem
                $parsedGpoId = [Guid]::Empty

                if (-not $gpoId -or -not [Guid]::TryParse([string]$gpoId, [ref]$parsedGpoId)) {
                    $results += [pscustomobject]@{ gpoId = if ($gpoId) { [string]$gpoId } else { $null }; gpoDisplayName = $gpoName; domainContext = $domainContext; _collectorError = 'Unable to resolve a valid persisted GPO GUID for scope-link collection.' }
                    continue
                }
                if ([string]::IsNullOrWhiteSpace([string]$domainContext)) {
                    $results += [pscustomobject]@{ gpoId = [string]$parsedGpoId; gpoDisplayName = $gpoName; domainContext = $null; _collectorError = 'Unable to resolve persisted domain context for GPO scope-link collection.' }
                    continue
                }

                try {
                    $report = Get-GPOReport -Guid $parsedGpoId -Domain $domainContext -ReportType Xml
                    $reportXml = if ($report -is [System.Xml.XmlDocument]) { [string]$report.OuterXml } else { [string]$report }
                    if ([string]::IsNullOrWhiteSpace($reportXml)) {
                        throw ('Get-GPOReport returned empty XML for GPO scope links {0} in domain {1}.' -f $parsedGpoId, $domainContext)
                    }
                    $results += ConvertTo-CollectorGpoScopeLinkEvidence -ReportXml $reportXml -GpoId $parsedGpoId -DomainContext ([string]$domainContext) -DisplayName $gpoName
                }
                catch {
                    $results += [pscustomobject]@{ gpoId = [string]$parsedGpoId; gpoDisplayName = $gpoName; domainContext = [string]$domainContext; _collectorError = $_.Exception.Message }
                }
            }
        }

        'gpoScopeInheritance' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-ADDomain', 'Get-GPInheritance')
            foreach ($scopeEnvelope in @($InventoryItems)) {
                $dependencyFamily = Get-CollectorFirstPropertyValue -Item $scopeEnvelope -PropertyNames @('dependencyFamily')
                $scopeItem = if ($scopeEnvelope.PSObject.Properties.Match('inventoryItem').Count -gt 0) { $scopeEnvelope.inventoryItem } else { $scopeEnvelope }
                if (-not $dependencyFamily) {
                    $dependencyFamily = if ($scopeItem.PSObject.Properties.Match('distinguishedName').Count -gt 0) { 'organizationalUnits' } else { 'domains' }
                }

                $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $scopeItem
                if ([string]::IsNullOrWhiteSpace([string]$domainContext)) {
                    $results += [pscustomobject]@{ scopeType = $dependencyFamily; domainContext = $null; _collectorError = 'Unable to resolve persisted domain context for GPO inheritance collection.' }
                    continue
                }

                try {
                    $scopeType = $null
                    $scopeId = $null
                    $targetDn = $null
                    if ($dependencyFamily -eq 'domains') {
                        $scopeType = 'domain'
                        $scopeId = Get-CollectorFirstPropertyValue -Item $scopeItem -PropertyNames @('id', 'name')
                        if (-not $scopeId) {
                            throw 'Unable to resolve domain identity for GPO inheritance collection.'
                        }
                        $domain = Get-ADDomain -Identity $scopeId -Server $domainContext
                        $targetDn = [string]$domain.DistinguishedName
                    }
                    elseif ($dependencyFamily -eq 'organizationalUnits') {
                        $scopeType = 'organizationalUnit'
                        $targetDn = Get-CollectorFirstPropertyValue -Item $scopeItem -PropertyNames @('id', 'distinguishedName')
                        $scopeId = $targetDn
                    }
                    else {
                        throw ('Unsupported GPO inheritance dependency family: {0}' -f $dependencyFamily)
                    }

                    if ([string]::IsNullOrWhiteSpace([string]$targetDn)) {
                        throw 'Unable to resolve domain/OU distinguished name for GPO inheritance collection.'
                    }

                    $inheritance = Get-GPInheritance -Target $targetDn -Domain $domainContext
                    if ($null -eq $inheritance) {
                        throw ('Get-GPInheritance returned no result for {0}.' -f $targetDn)
                    }

                    $directLinks = @()
                    foreach ($link in @($inheritance.GpoLinks)) {
                        if ($null -ne $link) { $directLinks += ConvertTo-CollectorGpoLinkRecord -Link $link }
                    }
                    $effectiveLinks = @()
                    foreach ($link in @($inheritance.InheritedGpoLinks)) {
                        if ($null -ne $link) { $effectiveLinks += ConvertTo-CollectorGpoLinkRecord -Link $link }
                    }

                    $results += [pscustomobject]@{
                        scopeId = [string]$scopeId
                        scopeType = $scopeType
                        domainContext = [string]$domainContext
                        targetDistinguishedName = [string]$targetDn
                        inheritanceBlocked = ConvertTo-CollectorOnPremBoolean -Value $inheritance.GpoInheritanceBlocked -Label 'GpoInheritanceBlocked'
                        directLinkCount = $directLinks.Count
                        directLinks = @($directLinks)
                        effectiveLinkCount = $effectiveLinks.Count
                        effectiveLinks = @($effectiveLinks)
                    }
                }
                catch {
                    $results += [pscustomobject]@{ scopeType = $dependencyFamily; domainContext = [string]$domainContext; _collectorError = $_.Exception.Message }
                }
            }
        }

        'gpoWmiFilterAssociations' {
            Assert-CollectorOnPremCommand -CommandNames @('Get-GPO')
            foreach ($gpoItem in @($InventoryItems)) {
                $gpoId = Get-CollectorFirstPropertyValue -Item $gpoItem -PropertyNames @('id', 'Id')
                $gpoName = Get-CollectorFirstPropertyValue -Item $gpoItem -PropertyNames @('displayName', 'name')
                $domainContext = Resolve-CollectorOnPremDomainContext -InventoryItem $gpoItem
                $parsedGpoId = [Guid]::Empty

                if (-not $gpoId -or -not [Guid]::TryParse([string]$gpoId, [ref]$parsedGpoId)) {
                    $results += [pscustomobject]@{ gpoId = if ($gpoId) { [string]$gpoId } else { $null }; gpoDisplayName = $gpoName; domainContext = $domainContext; _collectorError = 'Unable to resolve a valid persisted GPO GUID for WMI-filter collection.' }
                    continue
                }
                if ([string]::IsNullOrWhiteSpace([string]$domainContext)) {
                    $results += [pscustomobject]@{ gpoId = [string]$parsedGpoId; gpoDisplayName = $gpoName; domainContext = $null; _collectorError = 'Unable to resolve persisted domain context for GPO WMI-filter collection.' }
                    continue
                }

                try {
                    $gpo = Get-GPO -Guid $parsedGpoId -Domain $domainContext
                    $filter = if ($gpo -and $gpo.PSObject.Properties.Match('WmiFilter').Count -gt 0) { $gpo.WmiFilter } else { $null }
                    if ($null -eq $filter) {
                        $results += [pscustomobject]@{
                            gpoId = [string]$parsedGpoId
                            gpoDisplayName = $gpoName
                            domainContext = [string]$domainContext
                            hasWmiFilter = $false
                            wmiFilter = $null
                        }
                        continue
                    }

                    $filterPath = Get-CollectorFirstPropertyValue -Item $filter -PropertyNames @('Path')
                    if ([string]::IsNullOrWhiteSpace([string]$filterPath)) {
                        throw ('GPO {0} has a WMI filter without a stable provider Path.' -f $parsedGpoId)
                    }
                    $results += [pscustomobject]@{
                        gpoId = [string]$parsedGpoId
                        gpoDisplayName = $gpoName
                        domainContext = [string]$domainContext
                        hasWmiFilter = $true
                        wmiFilter = [pscustomobject]@{
                            path = [string]$filterPath
                            name = Get-CollectorFirstPropertyValue -Item $filter -PropertyNames @('Name')
                            description = Get-CollectorFirstPropertyValue -Item $filter -PropertyNames @('Description')
                        }
                    }
                }
                catch {
                    $results += [pscustomobject]@{ gpoId = [string]$parsedGpoId; gpoDisplayName = $gpoName; domainContext = [string]$domainContext; _collectorError = $_.Exception.Message }
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