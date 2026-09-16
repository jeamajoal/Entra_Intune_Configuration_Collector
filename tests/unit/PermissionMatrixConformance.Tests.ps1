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
        [string]$script:matrix.schemaVersion | Should -Be '1.1'
        [string]$script:matrix.lastReviewedUtc | Should -Be '2026-09-16'
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
}
