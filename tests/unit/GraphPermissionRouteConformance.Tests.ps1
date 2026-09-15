BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $moduleRoot = Join-Path -Path $repoRoot -ChildPath 'collector/modules'
    $matrixPath = Join-Path -Path $repoRoot -ChildPath 'docs/permissions/permission-matrix.json'

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

    function Get-TestEnclosingFunction {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Anchor)

        $ancestor = $Anchor.Parent
        while ($null -ne $ancestor) {
            if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                return $ancestor
            }
            $ancestor = $ancestor.Parent
        }
        return $null
    }

    function Get-TestEnclosingScriptBlock {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Anchor)

        $ancestor = $Anchor.Parent
        while ($null -ne $ancestor) {
            if ($ancestor -is [System.Management.Automation.Language.ScriptBlockAst]) {
                return $ancestor
            }
            $ancestor = $ancestor.Parent
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

    function Resolve-TestVariableStringValue {
        param(
            [Parameter(Mandatory = $true)][string]$VariableName,
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Anchor,
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$RootAst,
            [int]$Depth = 0
        )

        if ($Depth -gt 8) {
            return $null
        }

        $scriptBlock = Get-TestEnclosingScriptBlock -Anchor $Anchor
        if ($null -ne $scriptBlock) {
            $leftText = ('$' + $VariableName)
            $assignments = @($scriptBlock.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                [string]$node.Left.Extent.Text -ieq $leftText
            }, $true) | Where-Object {
                $_.Extent.EndOffset -lt $Anchor.Extent.StartOffset -and [string]$_.Right.Extent.Text -ine $leftText
            } | Sort-Object { $_.Extent.EndOffset } -Descending)

            foreach ($assignment in $assignments) {
                $resolved = Resolve-TestStringExpression -Expression $assignment.Right -Anchor $assignment -RootAst $RootAst -Depth ($Depth + 1)
                if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                    return [string]$resolved
                }
            }
        }

        if ($VariableName -ieq 'section') {
            $switchValue = Get-TestEnclosingSwitchValue -Anchor $Anchor
            if (-not [string]::IsNullOrWhiteSpace([string]$switchValue)) {
                return [string]$switchValue
            }
        }

        $functionAst = Get-TestEnclosingFunction -Anchor $Anchor
        if ($null -eq $functionAst -or $null -eq $functionAst.Body.ParamBlock) {
            return $null
        }

        $parameterExists = @($functionAst.Body.ParamBlock.Parameters | Where-Object {
            [string]$_.Name.VariablePath.UserPath -ieq $VariableName
        }).Count -gt 0
        if (-not $parameterExists) {
            return $null
        }

        $callerValues = @($RootAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | Where-Object {
            [string]$_.GetCommandName() -ieq [string]$functionAst.Name -and
            ($_.Extent.StartOffset -lt $functionAst.Extent.StartOffset -or $_.Extent.EndOffset -gt $functionAst.Extent.EndOffset)
        } | ForEach-Object {
            $argumentExpression = Get-TestCommandParameterExpression -Command $_ -Name $VariableName
            if ($null -ne $argumentExpression) {
                Resolve-TestStringExpression -Expression $argumentExpression -Anchor $_ -RootAst $RootAst -Depth ($Depth + 1)
            }
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        } | Sort-Object -Unique)

        if ($callerValues.Count -eq 1) {
            return [string]$callerValues[0]
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

        $stringValues = @($Expression.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object {
            [string]$_.Value
        } | Sort-Object -Unique)
        $variables = @($Expression.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true))

        if ($stringValues -contains 'Graph {0}' -and $variables.Count -eq 1) {
            $resolved = Resolve-TestVariableStringValue -VariableName ([string]$variables[0].VariablePath.UserPath) -Anchor $Anchor -RootAst $RootAst -Depth ($Depth + 1)
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                return ('Graph {0}' -f $resolved)
            }
        }

        if ($variables.Count -eq 1 -and $stringValues.Count -eq 0) {
            return Resolve-TestVariableStringValue -VariableName ([string]$variables[0].VariablePath.UserPath) -Anchor $Anchor -RootAst $RootAst -Depth ($Depth + 1)
        }

        if ($variables.Count -eq 0 -and $stringValues.Count -eq 1) {
            return [string]$stringValues[0]
        }

        return $null
    }

    function Get-TestFileSectionValue {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast)

        $sections = @($Ast.FindAll({
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

        if ($sections.Count -eq 1) {
            return [string]$sections[0]
        }
        return $null
    }

    function Get-TestCommandStage {
        param([Parameter(Mandatory = $true)][string]$CommandName)

        if ($CommandName -ieq 'Invoke-CollectorGraphInventoryFamily' -or $CommandName -match 'Stage1') {
            return 'stage1'
        }
        if ($CommandName -match 'Stage2') {
            return 'stage2'
        }
        if ($CommandName -match 'Stage3') {
            return 'stage3'
        }
        return $null
    }

    function ConvertTo-TestGraphRoute {
        param(
            [Parameter(Mandatory = $true)][string]$Section,
            [Parameter(Mandatory = $true)][string]$Stage,
            [Parameter(Mandatory = $true)][string]$Family,
            [Parameter(Mandatory = $true)][string]$Endpoint
        )

        $normalizedEndpoint = $Endpoint
        if ($normalizedEndpoint.StartsWith('Graph ', [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalizedEndpoint = $normalizedEndpoint.Substring(6)
        }
        $normalizedEndpoint = $normalizedEndpoint.Replace('{0}', '{id}')
        if ($Section -notmatch '^(entra-|intune-)' -or $Stage -notin @('stage1', 'stage2', 'stage3') -or $normalizedEndpoint -notmatch '^/(v1\.0|beta)/') {
            return $null
        }
        return ('{0}|{1}|{2}|{3}' -f $Section, $Stage, $Family, $normalizedEndpoint)
    }

    function Get-TestGraphRoutesFromFile {
        param([Parameter(Mandatory = $true)][string]$Path)

        $ast = Get-TestParsedAst -Path $Path
        $fileSection = Get-TestFileSectionValue -Ast $ast
        $routes = @()
        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))

        foreach ($command in $commands) {
            $commandName = [string]$command.GetCommandName()
            $stage = Get-TestCommandStage -CommandName $commandName
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
            if ($null -eq $endpointExpression) {
                $endpointExpression = Get-TestCommandParameterExpression -Command $command -Name 'SourceName'
            }
            if ($null -eq $endpointExpression) {
                continue
            }
            $endpoint = Resolve-TestStringExpression -Expression $endpointExpression -Anchor $command -RootAst $ast
            if ([string]::IsNullOrWhiteSpace([string]$endpoint)) {
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

            $route = ConvertTo-TestGraphRoute -Section $section -Stage $stage -Family $family -Endpoint $endpoint
            if ($null -ne $route) {
                $routes += $route
            }
        }

        foreach ($command in $commands | Where-Object { [string]$_.GetCommandName() -ieq 'New-CollectorProvenanceSnapshot' }) {
            $sourceTypeExpression = Get-TestCommandParameterExpression -Command $command -Name 'SourceType'
            $stageExpression = Get-TestCommandParameterExpression -Command $command -Name 'Stage'
            $sectionExpression = Get-TestCommandParameterExpression -Command $command -Name 'Section'
            $familyExpression = Get-TestCommandParameterExpression -Command $command -Name 'Family'
            $sourceNameExpression = Get-TestCommandParameterExpression -Command $command -Name 'SourceName'
            if ($null -eq $sourceTypeExpression -or $null -eq $stageExpression -or $null -eq $sectionExpression -or $null -eq $familyExpression -or $null -eq $sourceNameExpression) {
                continue
            }

            $sourceType = Resolve-TestStringExpression -Expression $sourceTypeExpression -Anchor $command -RootAst $ast
            if ([string]$sourceType -ine 'Graph') {
                continue
            }
            $stage = Resolve-TestStringExpression -Expression $stageExpression -Anchor $command -RootAst $ast
            $section = Resolve-TestStringExpression -Expression $sectionExpression -Anchor $command -RootAst $ast
            $family = Resolve-TestStringExpression -Expression $familyExpression -Anchor $command -RootAst $ast
            $endpoint = Resolve-TestStringExpression -Expression $sourceNameExpression -Anchor $command -RootAst $ast
            if (
                [string]::IsNullOrWhiteSpace([string]$stage) -or
                [string]::IsNullOrWhiteSpace([string]$section) -or
                [string]::IsNullOrWhiteSpace([string]$family) -or
                [string]::IsNullOrWhiteSpace([string]$endpoint)
            ) {
                continue
            }

            $route = ConvertTo-TestGraphRoute -Section $section -Stage $stage -Family $family -Endpoint $endpoint
            if ($null -ne $route) {
                $routes += $route
            }
        }

        return @($routes | Sort-Object -Unique)
    }

    function Get-TestMatrixGraphRoutes {
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
    $script:productionRoutes = @(
        Get-ChildItem -LiteralPath $moduleRoot -Filter '*.psm1' -File | ForEach-Object {
            Get-TestGraphRoutesFromFile -Path $_.FullName
        }
    ) | Sort-Object -Unique
    $script:matrixRoutes = @(Get-TestMatrixGraphRoutes -Matrix $script:matrix)
}

Describe 'Graph permission route conformance' {
    It 'binds every matrix endpoint to its production section stage and family' {
        $script:productionRoutes.Count | Should -BeGreaterThan 0
        $script:matrixRoutes.Count | Should -BeGreaterThan 0
        Assert-TestSetEqual -Expected $script:productionRoutes -Actual $script:matrixRoutes -Label 'Graph route inventory'
    }

    It 'rejects family and stage drift even when the global endpoint set is unchanged' {
        $applicationStage1 = 'entra-apps|stage1|applications|/v1.0/applications'
        $servicePrincipalStage1 = 'entra-apps|stage1|servicePrincipals|/v1.0/servicePrincipals'

        $swappedFamilyRoutes = @($script:matrixRoutes | ForEach-Object {
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
        $wrongStageRoutes = @($script:matrixRoutes | ForEach-Object {
            if ($_ -eq $applicationStage1) {
                'entra-apps|stage2|applications|/v1.0/applications'
            }
            else {
                $_
            }
        })

        { Assert-TestSetEqual -Expected $script:productionRoutes -Actual $swappedFamilyRoutes -Label 'family swap mutation' } |
            Should -Throw '*family swap mutation mismatch*'
        { Assert-TestSetEqual -Expected $script:productionRoutes -Actual $wrongStageRoutes -Label 'stage mutation' } |
            Should -Throw '*stage mutation mismatch*'
    }
}
