BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:securityContextModulePath = Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.SecurityContext.OnPrem.psm1'
    $script:orchestratorModulePath = Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1'
    $script:entryPointPath = Join-Path -Path $repoRoot -ChildPath 'collector/Invoke-Collector.ps1'

    Import-Module -Name $script:securityContextModulePath -Force -ErrorAction Stop
    Import-Module -Name $script:orchestratorModulePath -Force -ErrorAction Stop

    function Get-TestADCredential {
        param(
            [string]$UserName = 'EXAMPLE\collector-reader'
        )

        $securePassword = [System.Security.SecureString]::new()
        foreach ($character in [char[]]'unit-test-secret-218') {
            $securePassword.AppendChar($character)
        }
        $securePassword.MakeReadOnly()
        return [System.Management.Automation.PSCredential]::new($UserName, $securePassword)
    }
}

Describe 'Alternate AD credential security context' {
    It 'preserves process-identity behavior when no ADCredential is supplied' {
        $result = @(Invoke-CollectorWithADCredential -ADCredential $null -ScriptBlock { 'alpha'; 'beta' })
        if (($result -join ',') -ne 'alpha,beta') {
            throw ('Expected direct scriptblock output when ADCredential is null; actual: {0}' -f ($result -join ','))
        }
    }

    It 'parses DOMAIN user names without persisting or transforming the password' {
        $testCredential = Get-TestADCredential
        InModuleScope 'Collector.SecurityContext.OnPrem' -Parameters @{ TestCredential = $testCredential } {
            param([System.Management.Automation.PSCredential]$TestCredential)
            $resolved = Resolve-CollectorADCredentialLogonName -ADCredential $TestCredential

            if ([string]$resolved.domain -ne 'EXAMPLE') {
                throw ('Expected parsed domain EXAMPLE; actual: {0}' -f [string]$resolved.domain)
            }
            if ([string]$resolved.userName -ne 'collector-reader') {
                throw ('Expected parsed user collector-reader; actual: {0}' -f [string]$resolved.userName)
            }
        }
    }

    It 'passes UPN user names to LogonUser without inventing a domain' {
        $testCredential = Get-TestADCredential -UserName 'collector-reader@example.com'
        InModuleScope 'Collector.SecurityContext.OnPrem' -Parameters @{ TestCredential = $testCredential } {
            param([System.Management.Automation.PSCredential]$TestCredential)
            $resolved = Resolve-CollectorADCredentialLogonName -ADCredential $TestCredential

            if ([string]$resolved.userName -ne 'collector-reader@example.com') {
                throw ('Expected UPN to remain intact; actual: {0}' -f [string]$resolved.userName)
            }
            if ($null -ne $resolved.domain) {
                throw ('Expected UPN domain argument to remain null; actual: {0}' -f [string]$resolved.domain)
            }
        }
    }

    It 'fails clearly on a non-Windows platform before native token creation' {
        $testCredential = Get-TestADCredential
        InModuleScope 'Collector.SecurityContext.OnPrem' -Parameters @{ TestCredential = $testCredential } {
            param([System.Management.Automation.PSCredential]$TestCredential)
            Mock -CommandName Test-CollectorWindowsPlatform -MockWith { $false }

            $threw = $false
            try {
                New-CollectorADCredentialToken -ADCredential $TestCredential | Out-Null
            }
            catch {
                $threw = $true
                if ($_.Exception.Message -notmatch 'supported only on Windows') {
                    throw
                }
            }

            if (-not $threw) {
                throw 'Expected alternate AD credential token creation to fail on a non-Windows platform.'
            }
        }
    }

    It 'disposes the native token after impersonated execution' {
        $testCredential = Get-TestADCredential
        InModuleScope 'Collector.SecurityContext.OnPrem' -Parameters @{ TestCredential = $testCredential } {
            param([System.Management.Automation.PSCredential]$TestCredential)
            $script:fakeToken = [Microsoft.Win32.SafeHandles.SafeAccessTokenHandle]::new([IntPtr]::Zero)
            Mock -CommandName New-CollectorADCredentialToken -MockWith { $script:fakeToken }
            Mock -CommandName Invoke-CollectorWindowsImpersonated -MockWith {
                param(
                    [Microsoft.Win32.SafeHandles.SafeAccessTokenHandle]$Token,
                    [scriptblock]$ScriptBlock
                )
                $null = $Token
                return @(& $ScriptBlock)
            }

            $result = @(Invoke-CollectorWithADCredential -ADCredential $TestCredential -ScriptBlock { 'impersonated-result' })

            if (($result -join ',') -ne 'impersonated-result') {
                throw ('Unexpected impersonated result: {0}' -f ($result -join ','))
            }
            if (-not $script:fakeToken.IsClosed) {
                throw 'Expected the alternate credential token to be disposed after execution.'
            }

            Assert-MockCalled -CommandName New-CollectorADCredentialToken -Times 1 -Exactly -Scope It
            Assert-MockCalled -CommandName Invoke-CollectorWindowsImpersonated -Times 1 -Exactly -Scope It
        }
    }

    It 'never converts the secure password through a managed plaintext helper' {
        $source = Get-Content -LiteralPath $script:securityContextModulePath -Raw
        foreach ($forbiddenPattern in @('GetNetworkCredential\s*\(', 'PtrToString', 'ConvertFrom-SecureString')) {
            if ($source -match $forbiddenPattern) {
                throw ('Credential security-context source contains forbidden plaintext conversion pattern: {0}' -f $forbiddenPattern)
            }
        }
        if ($source -notmatch 'SecureStringToGlobalAllocUnicode' -or $source -notmatch 'ZeroFreeGlobalAllocUnicode') {
            throw 'Expected native password marshaling to use a zeroed transient unmanaged buffer.'
        }
    }
}

Describe 'Orchestrator alternate AD credential routing' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-adcredential-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            $null = $Context
            $null = $Sections
            @()
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            $null = $Context
            $null = $Sections
            @()
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -MockWith {
            param([hashtable]$Context, [string[]]$Sections)
            $null = $Context
            $null = $Sections
            @()
        }
        Mock -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorWithADCredential -MockWith {
            param(
                [System.Management.Automation.PSCredential]$ADCredential,
                [scriptblock]$ScriptBlock
            )
            $null = $ADCredential
            return @(& $ScriptBlock)
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'routes all three on-prem stages through the supplied credential context' {
        $credential = Get-TestADCredential
        $result = Start-CollectorRun -ADCredential $credential -OutputRoot $script:testRoot -Stages @('Stage1', 'Stage2', 'Stage3') -Sections @('onprem-ad-gpo')

        if ($result.status -ne 'Completed') {
            throw ('Expected mocked on-prem credential run to complete; actual: {0}' -f $result.status)
        }

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorWithADCredential -Times 3 -Exactly -Scope It -ParameterFilter {
            $null -ne $ADCredential -and $ADCredential.UserName -eq 'EXAMPLE\collector-reader'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 1 -Exactly -Scope It -ParameterFilter { @($Sections) -join ',' -eq 'onprem-ad-gpo' }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage2 -Times 1 -Exactly -Scope It -ParameterFilter { @($Sections) -join ',' -eq 'onprem-ad-gpo' }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage3 -Times 1 -Exactly -Scope It -ParameterFilter { @($Sections) -join ',' -eq 'onprem-ad-gpo' }

        $manifestRaw = Get-Content -LiteralPath $result.manifestPath -Raw
        if ($manifestRaw -match 'unit-test-secret-218' -or $manifestRaw -match 'collector-reader') {
            throw 'Run manifest persisted AD credential identity or password material.'
        }
        $manifest = $manifestRaw | ConvertFrom-Json
        if (-not [bool]$manifest.parameters.adCredentialSupplied) {
            throw 'Expected manifest to record adCredentialSupplied=true without serializing the credential.'
        }
        if ($manifest.parameters.PSObject.Properties.Match('ADCredential').Count -ne 0) {
            throw 'Manifest parameters must not contain an ADCredential property.'
        }
    }

    It 'keeps Graph-backed stage work outside the alternate AD credential wrapper' {
        $credential = Get-TestADCredential
        Start-CollectorRun -GraphToken 'graph-test-token' -ADCredential $credential -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps', 'onprem-ad-gpo') | Out-Null

        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 1 -Exactly -Scope It -ParameterFilter {
            @($Sections) -join ',' -eq 'entra-apps'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorStage1 -Times 1 -Exactly -Scope It -ParameterFilter {
            @($Sections) -join ',' -eq 'onprem-ad-gpo'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorWithADCredential -Times 1 -Exactly -Scope It
    }

    It 'records false and preserves pass-through behavior when ADCredential is omitted' {
        $result = Start-CollectorRun -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('onprem-ad-gpo')
        $manifest = Get-Content -LiteralPath $result.manifestPath -Raw | ConvertFrom-Json

        if ([bool]$manifest.parameters.adCredentialSupplied) {
            throw 'Expected manifest to record adCredentialSupplied=false when no alternate credential is supplied.'
        }
        Assert-MockCalled -ModuleName 'Collector.Orchestrator' -CommandName Invoke-CollectorWithADCredential -Times 1 -Exactly -Scope It -ParameterFilter {
            $null -eq $ADCredential
        }
    }

    It 'declares and forwards ADCredential at the script entry point' {
        $source = Get-Content -LiteralPath $script:entryPointPath -Raw
        if ($source -notmatch '\[System\.Management\.Automation\.PSCredential\]\$ADCredential') {
            throw 'Collector entry point does not declare ADCredential as PSCredential.'
        }
        if ($source -notmatch 'ADCredential\s*=\s*\$ADCredential') {
            throw 'Collector entry point does not forward ADCredential to Start-CollectorRun.'
        }
    }
}
