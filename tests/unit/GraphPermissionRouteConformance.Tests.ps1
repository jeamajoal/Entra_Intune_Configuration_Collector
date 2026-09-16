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

    function Get-TestAssignmentVariables {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.AssignmentStatementAst]$Assignment)

        if ($Assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            return @($Assignment.Left)
        }

        return @($Assignment.Left.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true))
    }

    function Get-TestAssignmentVariableName {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.AssignmentStatementAst]$Assignment)

        $variables = @(Get-TestAssignmentVariables -Assignment $Assignment)
        if ($variables.Count -eq 1) {
            return [string]$variables[0].VariablePath.UserPath
        }
        return $null
    }

    function Test-TestAssignmentWritesVariable {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.AssignmentStatementAst]$Assignment,
            [Parameter(Mandatory = $true)][string]$VariableName
        )

        return @(
            Get-TestAssignmentVariables -Assignment $Assignment | Where-Object {
                [string]$_.VariablePath.UserPath -ieq $VariableName
            }
        ).Count -gt 0
    }

    function Test-TestRouteAssignment {
        param([Parameter(Mandatory = $true)][System.Management.Automation.Language.AssignmentStatementAst]$Assignment)

        if ([string]$Assignment.Operator -ne 'Equals') {
            return $false
        }
        if (@(Get-TestAssignmentVariables -Assignment $Assignment).Count -ne 1) {
            return $false
        }

        $scriptBlock = Get-TestEnclosingScriptBlock -Anchor $Assignment
        $ancestor = $Assignment.Parent
        while ($null -ne $ancestor -and $ancestor -ne $scriptBlock) {
            if (
                $ancestor -is [System.Management.Automation.Language.IfStatementAst] -or
                $ancestor -is [System.Management.Automation.Language.SwitchStatementAst] -or
                $ancestor -is [System.Management.Automation.Language.ForStatementAst] -or
                $ancestor -is [System.Management.Automation.Language.ForEachStatementAst] -or
                $ancestor -is [System.Management.Automation.Language.WhileStatementAst] -or
                $ancestor -is [System.Management.Automation.Language.DoWhileStatementAst] -or
                $ancestor -is [System.Management.Automation.Language.DoUntilStatementAst] -or
                $ancestor -is [System.Management.Automation.Language.TryStatementAst]
            ) {
                return $false
            }
            $ancestor = $ancestor.Parent
        }
        return $true
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
            $assignments = @($scriptBlock.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $false) | Where-Object {
                (Test-TestAssignmentWritesVariable -Assignment $_ -VariableName $VariableName) -and
                $_.Extent.EndOffset -lt $Anchor.Extent.StartOffset
            } | Sort-Object { $_.Extent.EndOffset } -Descending)

            if ($assignments.Count -gt 0) {
                $latestAssignment = $assignments[0]
                if (-not (Test-TestRouteAssignment -Assignment $latestAssignment)) {
                    return $null
                }
                $resolved = Resolve-TestStringExpression -Expression $latestAssignment.Right -Anchor $latestAssignment -RootAst $RootAst -Depth ($Depth + 1)
                if ([string]::IsNullOrWhiteSpace([string]$resolved)) {
                    return $null
                }
                return [string]$resolved
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

        $callerCommands = @($RootAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) | Where-Object {
            [string]$_.GetCommandName() -ieq [string]$functionAst.Name -and
            ($_.Extent.StartOffset -lt $functionAst.Extent.StartOffset -or $_.Extent.EndOffset -gt $functionAst.Extent.EndOffset)
        })
        if ($callerCommands.Count -eq 0) {
            return $null
        }

        $callerValues = @()
        foreach ($callerCommand in $callerCommands) {
            $argumentExpression = Get-TestCommandParameterExpression -Command $callerCommand -Name $VariableName
            if ($null -eq $argumentExpression) {
                return $null
            }

            $resolvedCallerValue = Resolve-TestStringExpression -Expression $argumentExpression -Anchor $callerCommand -RootAst $RootAst -Depth ($Depth + 1)
            if ([string]::IsNullOrWhiteSpace([string]$resolvedCallerValue)) {
                return $null
            }
            $callerValues += [string]$resolvedCallerValue
        }
        $callerValues = @($callerValues | Sort-Object -Unique)

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
        if ($Expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
            return Resolve-TestVariableStringValue -VariableName ([string]$Expression.VariablePath.UserPath) -Anchor $Anchor -RootAst $RootAst -Depth ($Depth + 1)
        }
        if ($Expression -is [System.Management.Automation.Language.CommandExpressionAst]) {
            return Resolve-TestStringExpression -Expression $Expression.Expression -Anchor $Anchor -RootAst $RootAst -Depth ($Depth + 1)
        }
        if ($Expression -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $pipelineElements = @($Expression.Pipeline.PipelineElements)
            if ($pipelineElements.Count -eq 1 -and $pipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                return Resolve-TestStringExpression -Expression $pipelineElements[0].Expression -Anchor $Anchor -RootAst $RootAst -Depth ($Depth + 1)
            }
            return $null
        }
        if ($Expression -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$Expression.Operator -eq 'Format') {
            if (
                $Expression.Left -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                [string]$Expression.Left.Value -ceq 'Graph {0}'
            ) {
                $formatVariable = $null
                if ($Expression.Right -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $formatVariable = $Expression.Right
                }
                elseif ($Expression.Right -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    $elements = @($Expression.Right.Elements)
                    if ($elements.Count -eq 1 -and $elements[0] -is [System.Management.Automation.Language.VariableExpressionAst]) {
                        $formatVariable = $elements[0]
                    }
                }

                if ($null -ne $formatVariable) {
                    $resolved = Resolve-TestVariableStringValue -VariableName ([string]$formatVariable.VariablePath.UserPath) -Anchor $Anchor -RootAst $RootAst -Depth ($Depth + 1)
                    if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                        return ('Graph {0}' -f $resolved)
                    }
                }
            }
            return $null
        }

        return $null
    }

    function Resolve-TestRequiredStringExpression {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Expression,
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Anchor,
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$RootAst,
            [Parameter(Mandatory = $true)][string]$Label
        )

        $resolved = Resolve-TestStringExpression -Expression $Expression -Anchor $Anchor -RootAst $RootAst
        if ([string]::IsNullOrWhiteSpace([string]$resolved)) {
            throw ('Unable to resolve {0}: {1}' -f $Label, [string]$Expression.Extent.Text)
        }
        return [string]$resolved
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
        } | Where-Object { $_ -match '^(entra-|intune-)' } | Sort-Object -Unique)

        if ($sections.Count -eq 1) {
            return [string]$sections[0]
        }
        return $null
    }

    function Get-TestCommandStage {
        param([Parameter(Mandatory = $true)][string]$CommandName)

        if ($CommandName -ieq 'Invoke-CollectorGraphInventoryFamily' -or $CommandName -match 'Stage1') { return 'stage1' }
        if ($CommandName -match 'Stage2') { return 'stage2' }
        if ($CommandName -match 'Stage3') { return 'stage3' }
        return $null
    }

    function Assert-TestKnownGraphRouteBinding {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$Command,
            [Parameter(Mandatory = $true)][string]$CommandName
        )

        $requiredRoutingParameters = switch ($CommandName) {
            'Invoke-CollectorGraphInventoryFamily' { @('Section', 'Family', 'Endpoint') }
            'Invoke-CollectorStage2GraphFamily' { @('Section', 'Family', 'EndpointTemplate') }
            'Invoke-CollectorStage3GraphPerObjectFamily' { @('Section', 'Family', 'EndpointTemplate') }
            default { return }
        }
        $switchParameters = @('Verbose', 'Debug')

        $elements = @($Command.CommandElements)
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $parameterName = [string]$element.ParameterName
                $abbreviatedRoutingParameters = @($requiredRoutingParameters | Where-Object {
                    $_ -ine $parameterName -and $_.StartsWith($parameterName, [System.StringComparison]::OrdinalIgnoreCase)
                })
                if ($abbreviatedRoutingParameters.Count -gt 0) {
                    throw ('Unable to resolve recognized Graph route command {0}; abbreviated routing parameter -{1} is not supported.' -f $CommandName, $parameterName)
                }

                if ($null -ne $element.Argument) {
                    continue
                }

                $matchingSwitchParameters = @($switchParameters | Where-Object {
                    $_ -ieq $parameterName -or $_.StartsWith($parameterName, [System.StringComparison]::OrdinalIgnoreCase)
                })
                if ($matchingSwitchParameters.Count -eq 1) {
                    continue
                }

                if ($index + 1 -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    $index++
                }
                continue
            }

            if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) {
                continue
            }

            throw ('Unable to resolve recognized Graph route command {0}; positional arguments are not supported: {1}' -f $CommandName, [string]$element.Extent.Text)
        }

        foreach ($requiredParameterName in $requiredRoutingParameters) {
            if ($null -eq (Get-TestCommandParameterExpression -Command $Command -Name $requiredParameterName)) {
                throw ('Unable to resolve recognized Graph route command {0}; exact named routing parameter -{1} is required.' -f $CommandName, $requiredParameterName)
            }
        }
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

    function Get-TestCustomGraphRoutesFromAst {
        param(
            [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
            [Parameter(Mandatory = $true)][string]$Path
        )

        $routes = @()
        $scriptBlocks = @($Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ScriptBlockAst]
        }, $true))

        foreach ($scriptBlock in $scriptBlocks) {
            $graphCommands = @($scriptBlock.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                $name = [string]$node.GetCommandName()
                return $name -match '^Invoke-CollectorGraph(Request|Collection)$'
            }, $false))
            if ($graphCommands.Count -eq 0) { continue }

            $assignments = @($scriptBlock.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $false))
            $endpointAssignments = @($assignments | Where-Object { Test-TestAssignmentWritesVariable -Assignment $_ -VariableName 'endpointTemplate' })
            if ($endpointAssignments.Count -eq 0) { continue }

            $sectionAssignments = @($assignments | Where-Object { Test-TestAssignmentWritesVariable -Assignment $_ -VariableName 'section' })
            $familyAssignments = @($assignments | Where-Object { Test-TestAssignmentWritesVariable -Assignment $_ -VariableName 'family' })
            if ($sectionAssignments.Count -ne 1 -or $familyAssignments.Count -ne 1 -or $endpointAssignments.Count -ne 1) {
                throw ('Unable to resolve custom Graph route declaration in {0}; expected one local section, family, and endpointTemplate assignment.' -f $Path)
            }

            $routeAssignments = @($sectionAssignments[0], $familyAssignments[0], $endpointAssignments[0])
            if (@($routeAssignments | Where-Object { -not (Test-TestRouteAssignment -Assignment $_) }).Count -gt 0) {
                throw ('Unable to resolve custom Graph route declaration in {0}; routing assignments must use a single-target plain = outside conditional or loop control flow.' -f $Path)
            }

            $enclosingFunction = Get-TestEnclosingFunction -Anchor $endpointAssignments[0]
            $stage = if ($null -ne $enclosingFunction) { Get-TestCommandStage -CommandName ([string]$enclosingFunction.Name) } else { $null }
            if ($null -eq $stage) {
                throw ('Unable to resolve custom Graph route stage in {0}.' -f $Path)
            }

            $section = Resolve-TestRequiredStringExpression -Expression $sectionAssignments[0].Right -Anchor $sectionAssignments[0] -RootAst $Ast -Label 'custom Graph route Section'
            $family = Resolve-TestRequiredStringExpression -Expression $familyAssignments[0].Right -Anchor $familyAssignments[0] -RootAst $Ast -Label 'custom Graph route Family'
            $endpoint = Resolve-TestRequiredStringExpression -Expression $endpointAssignments[0].Right -Anchor $endpointAssignments[0] -RootAst $Ast -Label 'custom Graph route endpoint'
            $route = ConvertTo-TestGraphRoute -Section $section -Stage $stage -Family $family -Endpoint $endpoint
            if ($null -eq $route) {
                throw ('Resolved custom route is not a valid Graph route: section={0}; stage={1}; family={2}; endpoint={3}' -f $section, $stage, $family, $endpoint)
            }
            $routes += $route
        }

        return @($routes | Sort-Object -Unique)
    }

    function Get-TestGraphRoutesFromFile {
        param([Parameter(Mandatory = $true)][string]$Path)

        $ast = Get-TestParsedAst -Path $Path
        $fileSection = Get-TestFileSectionValue -Ast $ast
        $routes = @(Get-TestCustomGraphRoutesFromAst -Ast $ast -Path $Path)
        $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        $genericGraphWrappers = @(
            'Invoke-CollectorGraphInventoryFamily',
            'Invoke-CollectorStage2GraphFamily',
            'Invoke-CollectorStage3GraphPerObjectFamily'
        )

        foreach ($command in $commands) {
            $commandName = [string]$command.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($commandName)) { continue }
            $stage = Get-TestCommandStage -CommandName $commandName
            if ($null -eq $stage) { continue }

            $enclosingFunction = Get-TestEnclosingFunction -Anchor $command
            if (
                $null -ne $enclosingFunction -and
                $genericGraphWrappers -contains [string]$enclosingFunction.Name -and
                $commandName -notmatch 'Graph'
            ) {
                continue
            }

            $splattedArguments = @($command.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            })

            $isKnownGraphWrapper = $genericGraphWrappers -contains $commandName
            if ($isKnownGraphWrapper) {
                if ($splattedArguments.Count -gt 0) {
                    throw ('Unable to resolve recognized Graph route command {0}; splatted arguments are not supported: {1}' -f $commandName, (($splattedArguments | ForEach-Object { [string]$_.Extent.Text }) -join ', '))
                }
                Assert-TestKnownGraphRouteBinding -Command $command -CommandName $commandName
            }

            $sourceTypeExpression = Get-TestCommandParameterExpression -Command $command -Name 'SourceType'
            $endpointExpression = Get-TestCommandParameterExpression -Command $command -Name 'EndpointTemplate'
            if ($null -eq $endpointExpression) { $endpointExpression = Get-TestCommandParameterExpression -Command $command -Name 'Endpoint' }
            if ($null -eq $endpointExpression) { $endpointExpression = Get-TestCommandParameterExpression -Command $command -Name 'SourceName' }

            if (-not $isKnownGraphWrapper -and $null -ne $sourceTypeExpression) {
                $sourceType = Resolve-TestRequiredStringExpression -Expression $sourceTypeExpression -Anchor $command -RootAst $ast -Label ('route SourceType for {0}' -f $commandName)
                if ([string]$sourceType -ine 'Graph') { continue }
            }
            elseif (-not $isKnownGraphWrapper) {
                if ($null -eq $endpointExpression) {
                    if ($splattedArguments.Count -gt 0) {
                        throw ('Unable to classify route-shaped call {0}; splatted arguments prevent Graph route classification.' -f $commandName)
                    }
                    continue
                }
                $endpointProbe = Resolve-TestStringExpression -Expression $endpointExpression -Anchor $command -RootAst $ast
                if ([string]::IsNullOrWhiteSpace([string]$endpointProbe)) {
                    throw ('Unable to classify route-shaped call {0}; endpoint expression could not be resolved: {1}' -f $commandName, [string]$endpointExpression.Extent.Text)
                }
                $probe = [string]$endpointProbe
                if ($probe.StartsWith('Graph ', [System.StringComparison]::OrdinalIgnoreCase)) { $probe = $probe.Substring(6) }
                if ($probe -notmatch '^/(v1\.0|beta)/') { continue }
            }

            if ($splattedArguments.Count -gt 0) {
                throw ('Unable to resolve recognized Graph route command {0}; splatted arguments are not supported: {1}' -f $commandName, (($splattedArguments | ForEach-Object { [string]$_.Extent.Text }) -join ', '))
            }

            $familyExpression = Get-TestCommandParameterExpression -Command $command -Name 'Family'
            if ($null -eq $familyExpression) {
                throw ('Unable to resolve Graph route Family for {0} in {1}.' -f $commandName, $Path)
            }
            if ($null -eq $endpointExpression) {
                throw ('Unable to resolve Graph route endpoint for {0} in {1}.' -f $commandName, $Path)
            }

            $family = Resolve-TestRequiredStringExpression -Expression $familyExpression -Anchor $command -RootAst $ast -Label ('Graph route Family for {0}' -f $commandName)
            $endpoint = Resolve-TestRequiredStringExpression -Expression $endpointExpression -Anchor $command -RootAst $ast -Label ('Graph route endpoint for {0}' -f $commandName)
            $sectionExpression = Get-TestCommandParameterExpression -Command $command -Name 'Section'
            $section = if ($null -ne $sectionExpression) {
                Resolve-TestRequiredStringExpression -Expression $sectionExpression -Anchor $command -RootAst $ast -Label ('Graph route Section for {0}' -f $commandName)
            }
            else { $fileSection }
            if ([string]::IsNullOrWhiteSpace([string]$section)) {
                throw ('Unable to resolve Graph route Section for {0} in {1}.' -f $commandName, $Path)
            }

            $route = ConvertTo-TestGraphRoute -Section $section -Stage $stage -Family $family -Endpoint $endpoint
            if ($null -eq $route) {
                throw ('Resolved route for {0} is not a valid Graph route: section={1}; stage={2}; family={3}; endpoint={4}' -f $commandName, $section, $stage, $family, $endpoint)
            }
            $routes += $route
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
    $script:productionRoutes = @(
        Get-ChildItem -LiteralPath $moduleRoot -Filter '*.psm1' -File | ForEach-Object {
            Get-TestGraphRoutesFromFile -Path $_.FullName
        }
    ) | Sort-Object -Unique
    $script:matrixRoutes = @(Get-TestMatrixGraphRoute -Matrix $script:matrix)
}

Describe 'Graph permission route conformance' {
    It 'binds every matrix endpoint to its production section stage and family' {
        $script:productionRoutes.Count | Should -BeGreaterThan 0
        $script:matrixRoutes.Count | Should -BeGreaterThan 0
        Assert-TestSetEqual -Expected $script:productionRoutes -Actual $script:matrixRoutes -Label 'Graph route inventory'
    }

    It 'fails closed when a Graph route-shaped call contains an unresolved routing expression' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'UnresolvedGraphRoute.psm1'
        @'
$descriptor = [pscustomobject]@{ Family = 'applications' }
Invoke-CollectorStage1Synthetic -Section 'entra-apps' -Family $descriptor.Family -EndpointTemplate '/v1.0/applications'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route Family*'
    }

    It 'rejects compound routing expressions even when their literal descendants are identical' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'CompoundGraphRoute.psm1'
        @'
Invoke-CollectorStage1Synthetic -Section 'entra-apps' -Family ('applications' + 'applications') -EndpointTemplate '/v1.0/applications'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route Family*'
    }

    It 'rejects compound route assignments instead of reducing them to the right-hand literal' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'CompoundAssignmentRoute.psm1'
        @'
function Invoke-CollectorSyntheticStage1 {
    $family = 'legacy'
    $family += 'applications'
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family $family -SourceType 'Graph' -SourceName 'Graph /v1.0/applications'
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route Family*'
    }

    It 'rejects destructuring route writes instead of falling back to an older assignment' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'DestructuringAssignmentRoute.psm1'
        @'
function Invoke-CollectorSyntheticStage1 {
    $family = 'legacy'
    $family, $unused = 'applications', 'x'
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family $family -SourceType 'Graph' -SourceName 'Graph /v1.0/applications'
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route Family*'
    }

    It 'rejects positional binding on known Graph route helpers' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'PositionalGraphHelper.psm1'
        @'
Invoke-CollectorGraphInventoryFamily $null 'entra-apps' 'applications' '/v1.0/applications'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*positional arguments are not supported*'
    }

    It 'rejects positional binding after switch-style common parameters' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'VerbosePositionalGraphHelper.psm1'
        @'
Invoke-CollectorGraphInventoryFamily -Verbose $null -Section 'entra-apps' -Family 'applications' -Endpoint '/v1.0/applications'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*positional arguments are not supported*'
    }

    It 'accepts switch-style common parameters when all helper arguments remain exactly named' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'VerboseNamedGraphHelper.psm1'
        @'
Invoke-CollectorGraphInventoryFamily -Verbose -Context $null -Section 'entra-apps' -Family 'applications' -Endpoint '/v1.0/applications'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        @(Get-TestGraphRoutesFromFile -Path $fixturePath) | Should -Contain 'entra-apps|stage1|applications|/v1.0/applications'
    }

    It 'rejects abbreviated routing parameters on known Graph route helpers' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'AbbreviatedGraphHelper.psm1'
        @'
Invoke-CollectorGraphInventoryFamily -Context $null -Section 'entra-apps' -Fam 'applications' -Endpoint '/v1.0/applications'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*abbreviated routing parameter -Fam is not supported*'
    }

    It 'rejects branch-dependent route assignments' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'BranchDependentAssignment.psm1'
        @'
function Invoke-CollectorSyntheticStage1 {
    $family = 'servicePrincipals'
    if ($useApplications) {
        $family = 'applications'
    }
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family $family -SourceType 'Graph' -SourceName 'Graph /v1.0/applications'
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route Family*'
    }

    It 'rejects splatted recognized route arguments' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'SplattedGraphRoute.psm1'
        @'
$route = @{ Section = 'entra-apps'; Family = 'applications'; Endpoint = '/v1.0/applications' }
Invoke-CollectorGraphInventoryFamily @route
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*splatted arguments are not supported*'
    }

    It 'excludes explicitly Derived calls before applying generic splat rejection' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'DerivedSplattedRoute.psm1'
        @'
$common = @{ Context = $null }
Invoke-CollectorStage3BatchLoop @common -Section 'entra-ca' -Family 'conditionalAccessPolicyReferences' -SourceType 'Derived' -SourceName 'Derived Conditional Access policy references from Stage1 policy inventory'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        @(Get-TestGraphRoutesFromFile -Path $fixturePath).Count | Should -Be 0
    }

    It 'does not let nested callback assignments override the current lexical route scope' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'NestedAssignmentScope.psm1'
        @'
function Invoke-CollectorSyntheticStage1 {
    $descriptor = [pscustomobject]@{ Endpoint = '/v1.0/servicePrincipals' }
    $endpoint = $descriptor.Endpoint
    $callback = { $endpoint = '/v1.0/applications' }
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family 'applications' -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpoint)
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route endpoint*'
    }

    It 'recognizes typed route assignments before applying latest-assignment fail-closed behavior' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'TypedAssignmentMustResolve.psm1'
        @'
function Invoke-CollectorSyntheticStage1 {
    $endpoint = '/v1.0/applications'
    $descriptor = [pscustomobject]@{ Endpoint = '/v1.0/servicePrincipals' }
    [string]$endpoint = $descriptor.Endpoint
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family 'applications' -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpoint)
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route endpoint*'
    }

    It 'does not fall back past the latest unresolved route assignment' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'LatestAssignmentMustResolve.psm1'
        @'
function Invoke-CollectorSyntheticStage1 {
    $endpoint = '/v1.0/applications'
    $descriptor = [pscustomobject]@{ Endpoint = '/v1.0/servicePrincipals' }
    $endpoint = $descriptor.Endpoint
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family 'applications' -SourceType 'Graph' -SourceName ('Graph {0}' -f $endpoint)
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route endpoint*'
    }

    It 'fails closed when any helper caller cannot resolve a route parameter' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'UnresolvedHelperCaller.psm1'
        @'
function Invoke-CollectorSyntheticStage1Helper {
    param([string]$Family)
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family $Family -SourceType 'Graph' -SourceName 'Graph /v1.0/applications'
}

Invoke-CollectorSyntheticStage1Helper -Family 'applications'
$descriptor = [pscustomobject]@{ Family = 'servicePrincipals' }
Invoke-CollectorSyntheticStage1Helper -Family $descriptor.Family
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        { Get-TestGraphRoutesFromFile -Path $fixturePath } | Should -Throw '*Unable to resolve Graph route Family*'
    }

    It 'does not exclude concrete Graph-named collectors' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'ConcreteGraphNamedCollector.psm1'
        @'
function Invoke-CollectorGraphSyntheticStage1 {
    Invoke-CollectorStage1Family -Section 'entra-apps' -Family 'applications' -SourceType 'Graph' -SourceName 'Graph /v1.0/applications'
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        @(Get-TestGraphRoutesFromFile -Path $fixturePath) | Should -Contain 'entra-apps|stage1|applications|/v1.0/applications'
    }

    It 'extracts custom Graph stage routes declared by local routing assignments' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'CustomGraphStage2.psm1'
        @'
function Invoke-CollectorSyntheticStage2 {
    $section = 'intune-core'
    $family = 'configurationPolicySettings'
    $endpointTemplate = '/beta/deviceManagement/configurationPolicies/{id}/settings'
    Invoke-CollectorGraphCollection -Endpoint $endpointTemplate
}
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        @(Get-TestGraphRoutesFromFile -Path $fixturePath) | Should -Contain 'intune-core|stage2|configurationPolicySettings|/beta/deviceManagement/configurationPolicies/{id}/settings'
    }

    It 'ignores explicitly derived route-shaped batch calls' {
        $fixturePath = Join-Path -Path $TestDrive -ChildPath 'DerivedBatchRoute.psm1'
        @'
Invoke-CollectorStage3BatchLoop -Section 'entra-ca' -Family 'conditionalAccessPolicyReferences' -SourceType 'Derived' -SourceName 'Derived Conditional Access policy references from Stage1 policy inventory'
'@ | Set-Content -LiteralPath $fixturePath -Encoding UTF8

        @(Get-TestGraphRoutesFromFile -Path $fixturePath).Count | Should -Be 0
    }

    It 'rejects family stage missing and stale route drift even when endpoint membership is preserved' {
        $applicationStage1 = 'entra-apps|stage1|applications|/v1.0/applications'
        $servicePrincipalStage1 = 'entra-apps|stage1|servicePrincipals|/v1.0/servicePrincipals'

        $swappedFamilyRoutes = @($script:matrixRoutes | ForEach-Object {
            if ($_ -eq $applicationStage1) { 'entra-apps|stage1|applications|/v1.0/servicePrincipals' }
            elseif ($_ -eq $servicePrincipalStage1) { 'entra-apps|stage1|servicePrincipals|/v1.0/applications' }
            else { $_ }
        })
        $wrongStageRoutes = @($script:matrixRoutes | ForEach-Object {
            if ($_ -eq $applicationStage1) { 'entra-apps|stage2|applications|/v1.0/applications' } else { $_ }
        })
        $missingRoute = @($script:matrixRoutes | Where-Object { $_ -ne $applicationStage1 })
        $staleRoute = @($script:matrixRoutes + 'entra-apps|stage3|applications|/v1.0/stalePermissionMatrixRoute')

        { Assert-TestSetEqual -Expected $script:productionRoutes -Actual $swappedFamilyRoutes -Label 'family swap mutation' } | Should -Throw '*family swap mutation mismatch*'
        { Assert-TestSetEqual -Expected $script:productionRoutes -Actual $wrongStageRoutes -Label 'stage mutation' } | Should -Throw '*stage mutation mismatch*'
        { Assert-TestSetEqual -Expected $script:productionRoutes -Actual $missingRoute -Label 'missing route mutation' } | Should -Throw '*Missing: entra-apps|stage1|applications|/v1.0/applications*'
        { Assert-TestSetEqual -Expected $script:productionRoutes -Actual $staleRoute -Label 'stale route mutation' } | Should -Throw '*Stale: entra-apps|stage3|applications|/v1.0/stalePermissionMatrixRoute*'
    }
}
