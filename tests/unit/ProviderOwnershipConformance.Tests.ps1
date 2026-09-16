BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $matrixPath = Join-Path -Path $repoRoot -ChildPath 'docs/permissions/permission-matrix.json'
    $routeConformancePath = Join-Path -Path $PSScriptRoot -ChildPath 'GraphPermissionRouteConformance.Tests.ps1'

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

    function Get-TestProvider {
        param(
            [Parameter(Mandatory = $true)][object]$Matrix,
            [Parameter(Mandatory = $true)][string]$ProviderId
        )

        $matches = @($Matrix.providers | Where-Object { [string]$_.id -ceq $ProviderId })
        if ($matches.Count -ne 1) {
            throw ('Provider {0} must resolve exactly once; found {1}.' -f $ProviderId, $matches.Count)
        }
        return $matches[0]
    }

    function Assert-TestProviderContract {
        param([Parameter(Mandatory = $true)][object]$Matrix)

        [string]$Matrix.schemaVersion | Should -Be '1.1'
        @($Matrix.providers).Count | Should -Be 2

        $providerIds = @($Matrix.providers | ForEach-Object { [string]$_.id })
        $providerIds.Count | Should -Be (@($providerIds | Sort-Object -CaseSensitive -Unique).Count)

        foreach ($provider in @($Matrix.providers)) {
            [string]$provider.id | Should -Not -BeNullOrEmpty
            [string]$provider.displayName | Should -Not -BeNullOrEmpty
            [string]$provider.kind | Should -Not -BeNullOrEmpty
            [string]$provider.sourceType | Should -Not -BeNullOrEmpty
            [string]$provider.authentication | Should -Not -BeNullOrEmpty
        }

        $graphProvider = Get-TestProvider -Matrix $Matrix -ProviderId 'microsoft-graph'
        [string]$graphProvider.sourceType | Should -BeExactly 'Graph'
        [string]$graphProvider.authentication | Should -BeExactly 'oauth2-bearer'
        [string]$graphProvider.resourceAudience | Should -BeExactly 'https://graph.microsoft.com/'
        @($graphProvider.allowedOrigins) | Should -HaveCount 1
        [string]$graphProvider.allowedOrigins[0] | Should -BeExactly 'https://graph.microsoft.com'

        $onPremProvider = Get-TestProvider -Matrix $Matrix -ProviderId 'onprem-windows'
        [string]$onPremProvider.sourceType | Should -BeExactly 'OnPrem'
        [string]$onPremProvider.authentication | Should -BeExactly 'execution-identity'
        $onPremProvider.resourceAudience | Should -BeNullOrEmpty
        @($onPremProvider.allowedOrigins) | Should -HaveCount 0

        foreach ($profileProperty in @($Matrix.permissionProfiles.PSObject.Properties)) {
            $profile = $profileProperty.Value
            $provider = Get-TestProvider -Matrix $Matrix -ProviderId ([string]$profile.providerId)
            [string]$provider.authentication | Should -Not -BeExactly 'execution-identity'
            [string]$profile.resourceAudience | Should -Not -BeNullOrEmpty
            [string]$profile.resourceAudience | Should -BeExactly ([string]$provider.resourceAudience)
        }

        foreach ($family in @($Matrix.graphFamilies)) {
            $provider = Get-TestProvider -Matrix $Matrix -ProviderId ([string]$family.providerId)
            [string]$provider.id | Should -BeExactly 'microsoft-graph'
            [string]$provider.sourceType | Should -BeExactly 'Graph'

            $profileProperty = $Matrix.permissionProfiles.PSObject.Properties[[string]$family.permissionProfile]
            $profileProperty | Should -Not -BeNullOrEmpty
            [string]$profileProperty.Value.providerId | Should -BeExactly ([string]$family.providerId)
        }

        [string]$Matrix.onPrem.providerId | Should -BeExactly 'onprem-windows'
        foreach ($family in @($Matrix.onPrem.families)) {
            [string]$family.providerId | Should -BeExactly ([string]$Matrix.onPrem.providerId)
            [void](Get-TestProvider -Matrix $Matrix -ProviderId ([string]$family.providerId))
        }

        @($Matrix.providers | Where-Object { [string]$_.id -match '(?i)defender|mde' }) | Should -HaveCount 0
    }

    function Get-TestMatrixProviderRoute {
        param([Parameter(Mandatory = $true)][object]$Matrix)

        $routes = @()
        foreach ($family in @($Matrix.graphFamilies)) {
            foreach ($stageProperty in @($family.requests.PSObject.Properties)) {
                foreach ($endpoint in @($stageProperty.Value)) {
                    $routes += ('{0}|{1}|{2}|{3}|{4}' -f [string]$family.providerId, [string]$family.section, [string]$stageProperty.Name, [string]$family.family, [string]$endpoint)
                }
            }
        }
        return @($routes | Sort-Object -CaseSensitive -Unique)
    }

    function Assert-TestOrdinalSetEqual {
        param(
            [Parameter(Mandatory = $true)][string[]]$Expected,
            [Parameter(Mandatory = $true)][string[]]$Actual,
            [Parameter(Mandatory = $true)][string]$Label
        )

        $expectedSet = @($Expected | Sort-Object -CaseSensitive -Unique)
        $actualSet = @($Actual | Sort-Object -CaseSensitive -Unique)
        $missing = @($expectedSet | Where-Object { $actualSet -cnotcontains $_ })
        $stale = @($actualSet | Where-Object { $expectedSet -cnotcontains $_ })
        if ($missing.Count -gt 0 -or $stale.Count -gt 0) {
            $missingText = if ($missing.Count -gt 0) { $missing -join ', ' } else { '<none>' }
            $staleText = if ($stale.Count -gt 0) { $stale -join ', ' } else { '<none>' }
            throw ('{0} mismatch. Missing: {1}; Stale: {2}.' -f $Label, $missingText, $staleText)
        }
    }

    function Copy-TestMatrix {
        param([Parameter(Mandatory = $true)][object]$Matrix)
        return ($Matrix | ConvertTo-Json -Depth 100 | ConvertFrom-Json)
    }

    $script:matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json

    # Reuse Issue #201's exact production route extractor instead of maintaining a second route parser/table.
    $routeAst = Get-TestParsedAst -Path $routeConformancePath
    $beforeAllCommands = @($routeAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -ceq 'BeforeAll'
    }, $true))
    if ($beforeAllCommands.Count -ne 1) {
        throw ('Expected exactly one BeforeAll block in {0}; found {1}.' -f $routeConformancePath, $beforeAllCommands.Count)
    }

    $setupExpression = @($beforeAllCommands[0].CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
    })
    if ($setupExpression.Count -ne 1) {
        throw ('Expected exactly one setup script block in {0}; found {1}.' -f $routeConformancePath, $setupExpression.Count)
    }

    . $setupExpression[0].ScriptBlock.GetScriptBlock()
    $script:issue201ProductionRoutes = @($script:productionRoutes)
    $script:productionProviderRoutes = @($script:issue201ProductionRoutes | ForEach-Object { 'microsoft-graph|{0}' -f [string]$_ }) | Sort-Object -CaseSensitive -Unique
    $script:matrixProviderRoutes = @(Get-TestMatrixProviderRoute -Matrix $script:matrix)
}

Describe 'Provider ownership and audience conformance' {
    It 'pins current provider resource and execution-identity boundaries' {
        Assert-TestProviderContract -Matrix $script:matrix
    }

    It 'extends Issue 201 exact production routes with provider ownership' {
        $script:issue201ProductionRoutes.Count | Should -BeGreaterThan 0
        $script:productionProviderRoutes.Count | Should -Be $script:issue201ProductionRoutes.Count
        $script:matrixProviderRoutes.Count | Should -BeGreaterThan 0
        Assert-TestOrdinalSetEqual -Expected $script:productionProviderRoutes -Actual $script:matrixProviderRoutes -Label 'provider-aware Graph route inventory'
    }

    It 'fails when a Graph family is reassigned to the local provider' {
        $mutated = Copy-TestMatrix -Matrix $script:matrix
        $mutated.graphFamilies[0].providerId = 'onprem-windows'
        $mutatedRoutes = @(Get-TestMatrixProviderRoute -Matrix $mutated)

        { Assert-TestOrdinalSetEqual -Expected $script:productionProviderRoutes -Actual $mutatedRoutes -Label 'provider mutation' } |
            Should -Throw '*provider mutation mismatch*'
    }

    It 'fails when a permission profile audience drifts from its provider' {
        $mutated = Copy-TestMatrix -Matrix $script:matrix
        $mutated.permissionProfiles.'application-read'.resourceAudience = 'https://example.invalid/'

        { Assert-TestProviderContract -Matrix $mutated } | Should -Throw
    }

    It 'fails when a provider origin drifts from the Graph origin contract' {
        $mutated = Copy-TestMatrix -Matrix $script:matrix
        $mutated.providers[0].allowedOrigins = @('https://example.invalid')

        { Assert-TestProviderContract -Matrix $mutated } | Should -Throw
    }

    It 'fails when an on-prem family is assigned to the Graph provider' {
        $mutated = Copy-TestMatrix -Matrix $script:matrix
        $mutated.onPrem.families[0].providerId = 'microsoft-graph'

        { Assert-TestProviderContract -Matrix $mutated } | Should -Throw
    }

    It 'fails when a family references an unknown provider' {
        $mutated = Copy-TestMatrix -Matrix $script:matrix
        $mutated.graphFamilies[0].providerId = 'unknown-provider'

        { Assert-TestProviderContract -Matrix $mutated } | Should -Throw '*must resolve exactly once*'
    }
}
