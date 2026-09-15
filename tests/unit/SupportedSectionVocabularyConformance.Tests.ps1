BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $invokeCollectorPath = Join-Path -Path $repoRoot -ChildPath 'collector/Invoke-Collector.ps1'
    $orchestratorPath = Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1'
    $catalogPath = Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Catalog.psm1'
    $schemaPath = Join-Path -Path $repoRoot -ChildPath 'collector/schemas/catalog.schema.json'

    function Get-TestParsedAst {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) {
            throw ('Unable to parse {0}: {1}' -f $Path, ((@($parseErrors) | ForEach-Object { $_.Message }) -join '; '))
        }
        return $ast
    }

    function Get-TestScriptArrayAssignmentValues {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.Ast]$Ast,

            [Parameter(Mandatory = $true)]
            [string]$VariableName
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

    function Get-TestCliSectionsContract {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.ScriptBlockAst]$Ast
        )

        $sectionsParameter = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Sections' })
        if ($sectionsParameter.Count -ne 1) {
            throw ('Expected exactly one public Sections parameter, found {0}.' -f $sectionsParameter.Count)
        }

        $validateSet = @($sectionsParameter[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        if ($validateSet.Count -ne 1) {
            throw ('Expected exactly one ValidateSet on the public Sections parameter, found {0}.' -f $validateSet.Count)
        }

        $supported = @($validateSet[0].PositionalArguments | ForEach-Object { [string]$_.Value })
        $defaults = @($sectionsParameter[0].DefaultValue.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })

        return [pscustomobject]@{
            Supported = $supported
            Defaults = $defaults
        }
    }

    function Get-TestPathPatternSections {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Pattern,

            [Parameter(Mandatory = $true)]
            [string]$Label
        )

        $match = [regex]::Match($Pattern, '\(([^()]+)\)')
        if (-not $match.Success) {
            throw ('Unable to locate the section alternation in {0}.' -f $Label)
        }

        return @($match.Groups[1].Value -split '\|')
    }

    function Assert-TestSectionSetEqual {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$Expected,

            [Parameter(Mandatory = $true)]
            [string[]]$Actual,

            [Parameter(Mandatory = $true)]
            [string]$Label
        )

        $expectedSet = @($Expected | Sort-Object -Unique)
        $actualSet = @($Actual | Sort-Object -Unique)
        $missing = @($expectedSet | Where-Object { $actualSet -notcontains $_ })
        $stale = @($actualSet | Where-Object { $expectedSet -notcontains $_ })

        if ($missing.Count -gt 0 -or $stale.Count -gt 0) {
            $missingText = if ($missing.Count -gt 0) { $missing -join ', ' } else { '<none>' }
            $staleText = if ($stale.Count -gt 0) { $stale -join ', ' } else { '<none>' }
            throw ('{0} vocabulary mismatch. Missing: {1}; Stale: {2}.' -f $Label, $missingText, $staleText)
        }
    }

    $script:cliAst = Get-TestParsedAst -Path $invokeCollectorPath
    $script:orchestratorAst = Get-TestParsedAst -Path $orchestratorPath
    $script:catalogAst = Get-TestParsedAst -Path $catalogPath
    $script:cliContract = Get-TestCliSectionsContract -Ast $script:cliAst
    $script:orchestratorSupported = @(Get-TestScriptArrayAssignmentValues -Ast $script:orchestratorAst -VariableName 'SupportedSections')
    $script:orchestratorDefaults = @(Get-TestScriptArrayAssignmentValues -Ast $script:orchestratorAst -VariableName 'DefaultSections')
    $script:orchestratorGraphBacked = @(Get-TestScriptArrayAssignmentValues -Ast $script:orchestratorAst -VariableName 'GraphBackedSections')
    $script:catalogSections = @(Get-TestScriptArrayAssignmentValues -Ast $script:catalogAst -VariableName 'CollectorCatalogSections')

    $script:catalogSchema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    $script:catalogDefinitions = $script:catalogSchema.PSObject.Properties['$defs'].Value
    $script:schemaSections = @($script:catalogDefinitions.section.enum)
    $script:artifactPathSections = @(Get-TestPathPatternSections -Pattern ([string]$script:catalogDefinitions.artifact.properties.relativePath.pattern) -Label 'catalog artifact relativePath')
    $script:checkpointPathSections = @(Get-TestPathPatternSections -Pattern ([string]$script:catalogDefinitions.artifact.properties.checkpointRelativePath.pattern) -Label 'catalog checkpointRelativePath')
}

Describe 'Supported section vocabulary conformance' {
    It 'keeps CLI, orchestrator, catalog runtime, schema enum, and schema path vocabularies aligned' {
        $supported = @($script:orchestratorSupported)

        Assert-TestSectionSetEqual -Expected $supported -Actual $script:cliContract.Supported -Label 'CLI Sections ValidateSet'
        Assert-TestSectionSetEqual -Expected $supported -Actual $script:catalogSections -Label 'catalog runtime sections'
        Assert-TestSectionSetEqual -Expected $supported -Actual $script:schemaSections -Label 'catalog schema section enum'
        Assert-TestSectionSetEqual -Expected $supported -Actual $script:artifactPathSections -Label 'catalog artifact path sections'
        Assert-TestSectionSetEqual -Expected $supported -Actual $script:checkpointPathSections -Label 'catalog checkpoint path sections'
    }

    It 'pins the historical default and Graph-backed classifications without equating supported with default' {
        $expectedHistoricalDefaults = @('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo')
        $expectedGraphBacked = @('entra-apps', 'entra-pim', 'entra-ca', 'entra-governance', 'intune-core', 'intune-enrollment')

        Assert-TestSectionSetEqual -Expected $expectedHistoricalDefaults -Actual $script:orchestratorDefaults -Label 'orchestrator default sections'
        Assert-TestSectionSetEqual -Expected $expectedHistoricalDefaults -Actual $script:cliContract.Defaults -Label 'CLI default sections'
        Assert-TestSectionSetEqual -Expected $expectedGraphBacked -Actual $script:orchestratorGraphBacked -Label 'orchestrator Graph-backed sections'

        foreach ($defaultSection in $script:orchestratorDefaults) {
            $script:orchestratorSupported | Should -Contain $defaultSection
        }

        foreach ($optInSection in @('entra-ca', 'entra-governance', 'intune-enrollment')) {
            $script:orchestratorSupported | Should -Contain $optInSection
            $script:orchestratorDefaults | Should -Not -Contain $optInSection
        }
    }

    It 'proves missing and stale section mutations fail the same set-conformance guard' {
        $missingMutation = @($script:orchestratorSupported | Where-Object { $_ -ne 'intune-enrollment' })
        $staleMutation = @($script:orchestratorSupported + 'legacy-section')

        { Assert-TestSectionSetEqual -Expected $script:orchestratorSupported -Actual $missingMutation -Label 'missing mutation' } |
            Should -Throw '*Missing: intune-enrollment*'
        { Assert-TestSectionSetEqual -Expected $script:orchestratorSupported -Actual $staleMutation -Label 'stale mutation' } |
            Should -Throw '*Stale: legacy-section*'
    }
}
