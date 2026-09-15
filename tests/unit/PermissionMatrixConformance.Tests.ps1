BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    $orchestratorPath = Join-Path -Path $moduleRoot -ChildPath 'Collector.Orchestrator.psm1'
    $onPremProviderPath = Join-Path -Path $moduleRoot -ChildPath 'Collector.Provider.OnPrem.psm1'
    $matrixPath = Join-Path -Path $repoRoot -ChildPath 'docs/permissions/permission-matrix.json'
    $script:guidePath = Join-Path -Path $repoRoot -ChildPath 'docs/permissions.md'
    $script:readmePath = Join-Path -Path $repoRoot -ChildPath 'README.md'
    $script:agentsPath = Join-Path -Path $repoRoot -ChildPath 'AGENTS.md'

    function Get-TestParsedAst {
        param([Parameter(Mandatory = $true)][string]$Path)

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) {
            throw ('Unable to parse {0}: {1}' -f $Path, ((@($parseErrors) | ForEach-Object { $_.Message }) -join '; '))
        }
        return $ast
    }

    function Get-TestScriptArrayAssignmentValue {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
            [Parameter(Mandatory = $true)][string]$VariableName
        )

        $assignments = @($Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            [string]$node.Left.Extent.Text -eq ('$script:{0}' -f $VariableName)
        }, $true))
        if ($assignments.Count -ne 1) {
            throw ('Expected exactly one $script:{0} assignment, found {1}.' -f $VariableName, $assignments.Count)
        }

        return @($assignments[0].Right.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })
    }

    function Get-TestGraphEndpoint {
        param([Parameter(Mandatory = $true)][string]$Path)

        $ast = Get-TestParsedAst -Path $Path
        return @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            [string]$node.Value -match '^/(v1\.0|beta)/'
        }, $true) | ForEach-Object {
            ([string]$_.Value).Replace('{0}', '{id}')
        } | Sort-Object -Unique)
    }

    function Get-TestExternalCommand {
        param([Parameter(Mandatory = $true)][string]$Path)

        $ast = Get-TestParsedAst -Path $Path
        return @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object {
            [string]$_.GetCommandName()
        } | Where-Object {
            $_ -match '^Get-AD' -or
            $_ -match '^Get-GP' -or
            $_ -in @('Get-Acl', 'New-PSDrive', 'Remove-PSDrive')
        } | Sort-Object -Unique)
    }

    function Get-TestOptionalPropertyValue {
        param(
            [Parameter(Mandatory = $true)][object]$InputObject,
            [Parameter(Mandatory = $true)][string]$Name
        )

        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) {
            return @()
        }
        return @($property.Value)
    }

    function Get-TestCommandParameterExpression {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$Command,
            [Parameter(Mandatory = $true)][string]$Name
        )

        $elements = @($Command.CommandElements)
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or [string]$element.ParameterName -ine $Name) {
                continue
            }

            if ($null -ne $element.Argument) {
                return $element.Argument
            }
            if ($index + 1 -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                return $elements[$index + 1]
            }
            return $null
        }

        return $null
    }

    function Get-TestEnclosingSwitchValue {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Anchor)

        $ancestor = $Anchor.Parent
        while ($null -ne $ancestor) {
            if ($ancestor -is [System.Management.Automation.Language.SwitchStatementAst]) {
                foreach ($clause in @($ancestor.Clauses)) {
                    $labelAst = $clause.Item1
                    $bodyAst = $clause.Item2
                    if (
                        $Anchor.Extent.StartOffset -ge $bodyAst.Extent.StartOffset -and
                        $Anchor.Extent.EndOffset -le $bodyAst.Extent.EndOffset -and
                        $labelAst -is [System.Management.Automation.Language.StringConstantExpressionAst]
                    ) {
                        return [string]$labelAst.Value
                    }
                }
            }
            $ancestor = $ancestor.Parent
        }

        return $null
    }

    function Resolve-TestStringExpression {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Expression,
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Anchor,
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$RootAst,
            [int]$Depth = 0
        )

        if ($Depth -gt 8) {
            return $null
        }

        if ($Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return [string]$Expression.Value
        }
        if ($Expression -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and @($Expression.NestedExpressions).Count -eq 0) {
            return [string]$Expression.Value
        }

        $expressionText = [string]$Expression.Extent.Text
        if ($expressionText -match '^\(\s*[\x27\x22]Graph \{0\}[\x27\x22]\s*-f\s*\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\)$') {
            $variableName = [string]$Matches.name
            $syntheticVariable = $RootAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$node.VariablePath.UserPath -ieq $variableName
            }, $true)
            if ($null -ne $syntheticVariable) {
                $resolvedValue = Resolve-TestStringExpression -Expression $syntheticVariable -Anchor $Anchor -RootAst $RootAst -Depth ($Depth + 1)
                if (-not [string]::IsNullOrWhiteSpace([string]$resolvedValue)) {
                    return ('Graph {0}' -f $resolvedValue)
                }
            }
        }

        if ($Expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $variableName = [string]$Expression.VariablePath.UserPath
            $scope = $Anchor
            while ($null -ne $scope -and $scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $scope = $scope.Parent
            }
            if ($null -eq $scope) {
                $scope = $RootAst
            }

            $leftText = ('$' + $variableName)
            $assignments = @($scope.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                [string]$node.Left.Extent.Text -ieq $leftText
            }, $true) | Where-Object {
                $_.Extent.EndOffset -lt $Anchor.Extent.StartOffset -and [string]$_.Right.Extent.Text -ine $leftText
            } | Sort-Object { $_.Extent.EndOffset } -Descending)

            foreach ($assignment in $assignments) {
                $resolvedValue = Resolve-TestStringExpression -Expression $assignment.Right -Anchor $assignment -RootAst $RootAst -Depth ($Depth + 1)
                if (-not [string]::IsNullOrWhiteSpace([string]$resolvedValue)) {
                    return [string]$resolvedValue
                }
            }

            if ($variableName -ieq 'section') {
                return Get-TestEnclosingSwitchValue -Anchor $Anchor
            }
        }

        return $null
    }

    function Get-TestFileSectionValue {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast)

        $sectionValues = @($Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object {
            $sectionExpression = Get-TestCommandParameterExpression -Command $_ -Name 'Section'
            if ($sectionExpression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                [string]$sectionExpression.Value
            }
        } | Where-Object {
            $_ -match '^(entra-|intune-)'
        } | Sort-Object -Unique)

        if ($sectionValues.Count -eq 1) {
            return [string]$sectionValues[0]
        }
        return $null
    }

    function Get-TestGraphRoute {
        param([Parameter(Mandatory = $true)][string]$Path)

        $ast = Get-TestParsedAst -Path $Path
        $fileSection = Get-TestFileSectionValue -Ast $ast
        $routes = @()

        foreach ($command in @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))) {
            $commandName = [string]$command.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($commandName)) {
                continue
            }

            $stage = $null
            if ($commandName -ieq 'Invoke-CollectorGraphInventoryFamily') {
                $stage = 'stage1'
            }
            elseif ($commandName -match 'Stage1') {
                $stage = 'stage1'
            }
            elseif ($commandName -match 'Stage2') {
                $stage = 'stage2'
            }
            elseif ($commandName -match 'Stage3') {
                $stage = 'stage3'
            }
            if ($null -eq $stage) {
                continue
            }

            $familyExpression = Get-TestCommandParameterExpression -Command $command -Name 'Family'
            if ($null -eq $familyExpression) {
                continue
            }
            $family = Resolve-TestStringExpression -Expression $familyExpression -Anchor $command -RootAst $ast
            if ([string]::IsNullOrWhiteSpace([string]$family)) {
                continue
            }

            $endpointExpression = Get-TestCommandParameterExpression -Command $command -Name 'EndpointTemplate'
            if ($null -eq $endpointExpression) {
                $endpointExpression = Get-TestCommandParameterExpression -Command $command -Name 'Endpoint'
            }
            $endpointFromSourceName = $false
            if ($null -eq $endpointExpression) {
                $endpointExpression = Get-TestCommandParameterExpression -Command $command -Name 'SourceName'
                $endpointFromSourceName = $null -ne $endpointExpression
            }
            if ($null -eq $endpointExpression) {
                continue
            }

            $endpoint = Resolve-TestStringExpression -Expression $endpointExpression -Anchor $command -RootAst $ast
            if ([string]::IsNullOrWhiteSpace([string]$endpoint)) {
                continue
            }
            if ($endpointFromSourceName -and $endpoint.StartsWith('Graph ', [System.StringComparison]::OrdinalIgnoreCase)) {
                $endpoint = $endpoint.Substring(6)
            }
            $endpoint = ([string]$endpoint).Replace('{0}', '{id}')
            if ($endpoint -notmatch '^/(v1\.0|beta)/') {
                continue
            }

            $sectionExpression = Get-TestCommandParameterExpression -Command $command -Name 'Section'
            $section = if ($null -ne $sectionExpression) {
                Resolve-TestStringExpression -Expression $sectionExpression -Anchor $command -RootAst $ast
            }
            else {
                $null
            }
            if ([string]::IsNullOrWhiteSpace([string]$section)) {
                $section = $fileSection
            }
            if ([string]::IsNullOrWhiteSpace([string]$section)) {
                continue
            }

            $routes += ('{0}|{1}|{2}|{3}' -f $section, $stage, $family, $endpoint)
        }

        return @($routes | Sort-Object -Unique)
    }

    function Get-TestMatrixGraphRoute {
        param([Parameter(Mandatory = $true)][object]$Matrix)

        $routes = @()
        foreach ($family in @($Matrix.graphFamilies)) {
            foreach ($stageProperty in @($family.requests.PSObject.Properties)) {
                foreach ($endpoint in @($stageProperty.Value)) {
                    $routes += ('{0}|{1}|{2}|{3}' -f [string]$family.section, [string]$stageProperty.Name, [string]$family.family, [string]$endpoint)
                }
            }
        }
        return @($routes | Sort-Object -Unique)
    }

    function Assert-TestSetEqual {
        param(
            [Parameter(Mandatory = $true)][string[]]$Expected,
            [Parameter(Mandatory = $true)][string[]]$Actual,
            [Parameter(Mandatory = $true)][string]$Label
        )

        $expectedSet = @($Expected | Sort-Object -Unique)
        $actualSet = @($Actual | Sort-Object -Unique)
        $missing = @($expectedSet | Where-Object { $actualSet -notcontains $_ })
        $stale = @($actualSet | Where-Object { $expectedSet -notcontains $_ })
        if ($missing.Count -gt 0 -or $stale.Count -gt 0) {
            $missingText = if ($missing.Count -gt 0) { $missing -join ', ' } else { '<none>' }
            $staleText = if ($stale.Count -gt 0) { $stale -join ', ' } else { '<none>' }
            throw ('{0} mismatch. Missing: {1}; Stale: {2}.' -f $Label, $missingText, $staleText)
        }
    }

    $script:matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
    $orchestratorAst = Get-TestParsedAst -Path $orchestratorPath
    $script:supportedSections = @(Get-TestScriptArrayAssignmentValue -Ast $orchestratorAst -VariableName 'SupportedSections')
    $script:graphBackedSections = @(Get-TestScriptArrayAssignmentValue -Ast $orchestratorAst -VariableName 'GraphBackedSections')
    $script:productionGraphEndpoints = @(
        Get-ChildItem -LiteralPath $moduleRoot -Filter '*.psm1' -File | ForEach-Object {
            Get-TestGraphEndpoint -Path $_.FullName
        }
    ) | Sort-Object -Unique
    $script:matrixGraphEndpoints = @(
        foreach ($family in @($script:matrix.graphFamilies)) {
            foreach ($stageProperty in @($family.requests.PSObject.Properties)) {
                foreach ($endpoint in @($stageProperty.Value)) {
                    [string]$endpoint
                }
            }
        }
    ) | Sort-Object -Unique
    $script:productionGraphRoutes = @(
        Get-ChildItem -LiteralPath $moduleRoot -Filter '*.psm1' -File | ForEach-Object {
            Get-TestGraphRoute -Path $_.FullName
        }
    ) | Sort-Object -Unique
    $script:matrixGraphRoutes = @(Get-TestMatrixGraphRoute -Matrix $script:matrix)
    $script:productionOnPremCommands = @(Get-TestExternalCommand -Path $onPremProviderPath)
    $script:matrixOnPremCommands = @(
        foreach ($module in @($script:matrix.onPrem.modules)) {
            foreach ($command in @($module.commands)) {
                [string]$command
            }
        }
    ) | Sort-Object -Unique

    Import-Module -Name $onPremProviderPath -Force -ErrorAction Stop
}

Describe 'Permission matrix conformance' {
    It 'pins the current matrix contract and section vocabulary' {
        [string]$script:matrix.schemaVersion | Should -Be '1.0'
        [string]$script:matrix.lastReviewedUtc | Should -Be '2026-09-15'
        [string]$script:matrix.recommendedTokenMode | Should -Be 'application'
        Assert-TestSetEqual -Expected $script:supportedSections -Actual @($script:matrix.sections) -Label 'matrix supported sections'
        Assert-TestSetEqual -Expected $script:graphBackedSections -Actual @($script:matrix.graphBackedSections) -Label 'matrix Graph-backed sections'
        [string]$script:matrix.onPrem.section | Should -Be 'onprem-ad-gpo'
    }

    It 'covers every production Graph endpoint at the set boundary' {
        $script:productionGraphEndpoints.Count | Should -BeGreaterThan 0
        $script:matrixGraphEndpoints.Count | Should -BeGreaterThan 0
        Assert-TestSetEqual -Expected $script:productionGraphEndpoints -Actual $script:matrixGraphEndpoints -Label 'Graph endpoint inventory'
    }

    It 'binds every Graph endpoint to its production section stage and family' {
        $script:productionGraphRoutes.Count | Should -BeGreaterThan 0
        $script:matrixGraphRoutes.Count | Should -BeGreaterThan 0
        Assert-TestSetEqual -Expected $script:productionGraphRoutes -Actual $script:matrixGraphRoutes -Label 'Graph route inventory'
    }

    It 'covers every on-prem external command dependency at the set boundary' {
        $script:productionOnPremCommands.Count | Should -BeGreaterThan 0
        $script:matrixOnPremCommands.Count | Should -BeGreaterThan 0
        Assert-TestSetEqual -Expected $script:productionOnPremCommands -Actual $script:matrixOnPremCommands -Label 'on-prem command inventory'
    }

    It 'keeps Graph permission profiles read-only, source-backed, and referenced by every family' {
        $profileNames = @($script:matrix.permissionProfiles.PSObject.Properties.Name)
        $profileNames.Count | Should -BeGreaterThan 0

        foreach ($profileProperty in @($script:matrix.permissionProfiles.PSObject.Properties)) {
            $permissionProfileEntry = $profileProperty.Value
            @($permissionProfileEntry.applicationPermissions).Count | Should -BeGreaterThan 0
            @($permissionProfileEntry.delegatedPermissions).Count | Should -BeGreaterThan 0
            @($permissionProfileEntry.sourceUrls).Count | Should -BeGreaterThan 0

            $allPermissions = @()
            $allPermissions += @($permissionProfileEntry.applicationPermissions)
            $allPermissions += @($permissionProfileEntry.delegatedPermissions)
            $allPermissions += @(Get-TestOptionalPropertyValue -InputObject $permissionProfileEntry -Name 'optionalApplicationPermissions')
            $allPermissions += @(Get-TestOptionalPropertyValue -InputObject $permissionProfileEntry -Name 'optionalDelegatedPermissions')
            foreach ($permission in $allPermissions) {
                if (-not [string]::IsNullOrWhiteSpace([string]$permission)) {
                    [string]$permission | Should -Not -Match 'ReadWrite'
                }
            }
            foreach ($sourceUrl in @($permissionProfileEntry.sourceUrls)) {
                [string]$sourceUrl | Should -Match '^https://learn\.microsoft\.com/'
            }
        }

        foreach ($family in @($script:matrix.graphFamilies)) {
            $script:graphBackedSections | Should -Contain ([string]$family.section)
            $profileNames | Should -Contain ([string]$family.permissionProfile)
            @($family.requests.PSObject.Properties).Count | Should -BeGreaterThan 0
            foreach ($stageProperty in @($family.requests.PSObject.Properties)) {
                [string]$stageProperty.Name | Should -BeIn @('stage1', 'stage2', 'stage3')
                foreach ($endpoint in @($stageProperty.Value)) {
                    [string]$endpoint | Should -Match '^/(v1\.0|beta)/'
                }
            }
        }
    }

    It 'keeps on-prem modules, family dependencies, and source documentation explicit' {
        [string]$script:matrix.onPrem.identityAssumption | Should -Not -BeNullOrEmpty
        @($script:matrix.onPrem.modules).Count | Should -BeGreaterThan 0
        @($script:matrix.onPrem.families).Count | Should -BeGreaterThan 0

        foreach ($module in @($script:matrix.onPrem.modules)) {
            [string]$module.name | Should -Not -BeNullOrEmpty
            @($module.commands).Count | Should -BeGreaterThan 0
            foreach ($sourceUrl in @($module.sourceUrls)) {
                [string]$sourceUrl | Should -Match '^https://learn\.microsoft\.com/'
            }
        }

        foreach ($family in @($script:matrix.onPrem.families)) {
            [string]$family.stage | Should -BeIn @('stage1', 'stage2', 'stage3')
            [string]$family.family | Should -Not -BeNullOrEmpty
            @($family.commands).Count | Should -BeGreaterThan 0
            foreach ($command in @($family.commands)) {
                $script:matrixOnPremCommands | Should -Contain ([string]$command)
            }

            $phase = switch ([string]$family.stage) {
                'stage1' { 'Inventory' }
                'stage2' { 'Details' }
                'stage3' { 'Relationships' }
            }
            $providerProfile = Get-CollectorOnPremProvenanceProfile -Phase $phase -Family ([string]$family.family)
            foreach ($providerCommand in @($providerProfile.CmdletNames)) {
                @($family.commands) | Should -Contain ([string]$providerCommand)
            }
        }
    }

    It 'requires durable operator and agent guidance to point to the canonical matrix' {
        $guide = Get-Content -LiteralPath $script:guidePath -Raw
        $readme = Get-Content -LiteralPath $script:readmePath -Raw
        $agents = Get-Content -LiteralPath $script:agentsPath -Raw

        $guide | Should -Match 'docs/permissions/permission-matrix\.json'
        $guide | Should -Match '403 Forbidden'
        $readme | Should -Match 'docs/permissions/permission-matrix\.json'
        $agents | Should -Match 'docs/permissions/permission-matrix\.json'
        $agents | Should -Match 'same PR'
    }

    It 'proves missing and stale endpoint and command mutations fail the same guards' {
        $missingEndpoint = @($script:matrixGraphEndpoints | Where-Object { $_ -ne '/v1.0/applications' })
        $staleEndpoint = @($script:matrixGraphEndpoints + '/v1.0/stalePermissionMatrixEndpoint')
        $missingCommand = @($script:matrixOnPremCommands | Where-Object { $_ -ne 'Get-ADForest' })
        $staleCommand = @($script:matrixOnPremCommands + 'Get-ADStalePermissionMatrixCommand')

        { Assert-TestSetEqual -Expected $script:productionGraphEndpoints -Actual $missingEndpoint -Label 'missing endpoint mutation' } |
            Should -Throw '*Missing: /v1.0/applications*'
        { Assert-TestSetEqual -Expected $script:productionGraphEndpoints -Actual $staleEndpoint -Label 'stale endpoint mutation' } |
            Should -Throw '*Stale: /v1.0/stalePermissionMatrixEndpoint*'
        { Assert-TestSetEqual -Expected $script:productionOnPremCommands -Actual $missingCommand -Label 'missing command mutation' } |
            Should -Throw '*Missing: Get-ADForest*'
        { Assert-TestSetEqual -Expected $script:productionOnPremCommands -Actual $staleCommand -Label 'stale command mutation' } |
            Should -Throw '*Stale: Get-ADStalePermissionMatrixCommand*'
    }

    It 'proves family and stage route mutations fail even when endpoint membership is preserved' {
        $applicationStage1 = 'entra-apps|stage1|applications|/v1.0/applications'
        $servicePrincipalStage1 = 'entra-apps|stage1|servicePrincipals|/v1.0/servicePrincipals'
        $swappedFamilyRoutes = @($script:matrixGraphRoutes | ForEach-Object {
            if ($_ -eq $applicationStage1) {
                'entra-apps|stage1|applications|/v1.0/servicePrincipals'
            }
            elseif ($_ -eq $servicePrincipalStage1) {
                'entra-apps|stage1|servicePrincipals|/v1.0/applications'
            }
            else {
                $_
            }
        })
        $wrongStageRoutes = @($script:matrixGraphRoutes | ForEach-Object {
            if ($_ -eq $applicationStage1) {
                'entra-apps|stage2|applications|/v1.0/applications'
            }
            else {
                $_
            }
        })
        $staleRoute = @($script:matrixGraphRoutes + 'entra-apps|stage3|applications|/v1.0/stalePermissionMatrixRoute')

        { Assert-TestSetEqual -Expected $script:productionGraphRoutes -Actual $swappedFamilyRoutes -Label 'family swap mutation' } |
            Should -Throw '*Graph route*'
        { Assert-TestSetEqual -Expected $script:productionGraphRoutes -Actual $wrongStageRoutes -Label 'stage mutation' } |
            Should -Throw '*Graph route*'
        { Assert-TestSetEqual -Expected $script:productionGraphRoutes -Actual $staleRoute -Label 'stale route mutation' } |
            Should -Throw '*Stale: entra-apps|stage3|applications|/v1.0/stalePermissionMatrixRoute*'
    }
}
