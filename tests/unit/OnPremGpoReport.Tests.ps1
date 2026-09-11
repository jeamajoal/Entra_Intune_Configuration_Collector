[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global captures and command shim are test-only so the provider can exercise Get-GPOReport without requiring the GroupPolicy module in CI.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

    function global:Get-GPOReport {
        [CmdletBinding()]
        param(
            [Guid]$Guid,
            [string]$Name,
            [string]$Domain,
            [ValidateSet('Xml', 'Html')]
            [string]$ReportType,
            [string]$Path
        )

        $global:CollectorGpoReportCalls.Add([pscustomobject]@{
            Guid = $Guid
            Name = $Name
            Domain = $Domain
            ReportType = $ReportType
            Path = $Path
        }) | Out-Null

        return $global:CollectorGpoReportXml
    }

    function New-TestGpoReportXml {
        param(
            [string]$ComputerSettingValue = '14',
            [string]$PreferenceSecret = 'encrypted-secret-value',
            [string]$UserSecret = 'plain-secret-value'
        )

        return @"
<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings">
  <LinksTo>
    <SOMName>Out of scope link</SOMName>
    <SOMPath>example.com/Workstations</SOMPath>
  </LinksTo>
  <Computer>
    <ExtensionData>
      <Extension>
        <Policy name="MinimumPasswordLength" value="$ComputerSettingValue" />
        <Preference userName="EXAMPLE\svc" cpassword="$PreferenceSecret" />
      </Extension>
    </ExtensionData>
  </Computer>
  <User>
    <ExtensionData>
      <Extension>
        <Policy name="ScreenSaverTimeout" value="900" />
        <SecretText>$UserSecret</SecretText>
      </Extension>
    </ExtensionData>
  </User>
  <SecurityDescriptor>
    <Owner>EXAMPLE\Domain Admins</Owner>
  </SecurityDescriptor>
</GPO>
"@
    }

    function Get-TestGpoStage2Context {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'gpo-report-stage2'
            GraphToken = $null
            BatchSize = 100
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $false
            ReprocessFailedOnly = $false
        }
    }

    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.OnPrem.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage2.Details.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
}

Describe 'On-prem GPO report evidence' {
    BeforeEach {
        $global:CollectorGpoReportCalls = [System.Collections.Generic.List[object]]::new()
        $global:CollectorGpoReportXml = New-TestGpoReportXml
    }

    AfterAll {
        Remove-Item Function:\Get-GPOReport -ErrorAction SilentlyContinue
        Remove-Variable CollectorGpoReportCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CollectorGpoReportXml -Scope Global -ErrorAction SilentlyContinue
    }

    It 'collects by persisted GUID and domain, preserves computer/user settings, and redacts explicit credential-bearing XML' {
        $gpoId = [Guid]'11111111-2222-3333-4444-555555555555'
        $result = Invoke-CollectorOnPremDetailFamily -Family 'gpoReports' -InventoryItem ([pscustomobject]@{
            id = [string]$gpoId
            displayName = 'Workstation Policy'
            domainId = 'example.com'
        })

        if ($global:CollectorGpoReportCalls.Count -ne 1) {
            throw 'Expected exactly one Get-GPOReport call.'
        }
        $call = $global:CollectorGpoReportCalls[0]
        if ($call.Guid -ne $gpoId -or $call.Domain -ne 'example.com' -or $call.ReportType -ne 'Xml' -or $call.Name -or $call.Path) {
            throw 'Expected Get-GPOReport to use persisted GUID/domain identity, XML output, and no name/path lookup.'
        }

        if ($result.gpoId -ne [string]$gpoId -or $result.domainContext -ne 'example.com' -or $result.displayName -ne 'Workstation Policy') {
            throw 'Expected stable GPO GUID/domain binding with displayName retained only as descriptive metadata.'
        }
        if (-not $result.computer.present -or -not $result.user.present) {
            throw 'Expected explicit computer and user report-section presence.'
        }
        if ([string]$result.computer.xml -notmatch 'MinimumPasswordLength' -or [string]$result.computer.xml -notmatch 'value="14"') {
            throw 'Expected ordinary password-policy configuration values to remain reviewable.'
        }
        if ([string]$result.user.xml -notmatch 'ScreenSaverTimeout') {
            throw 'Expected user-side policy settings to remain reviewable.'
        }
        if ([string]$result.computer.xml -match 'encrypted-secret-value' -or [string]$result.user.xml -match 'plain-secret-value') {
            throw 'Expected explicit credential-bearing values to be removed from persisted evidence.'
        }
        if ([string]$result.computer.xml -notmatch '\[REDACTED\]' -or [string]$result.user.xml -notmatch '\[REDACTED\]' -or [int]$result.redactedCredentialValueCount -ne 2) {
            throw 'Expected two credential-field redactions to be represented explicitly.'
        }
        if ([string]$result.computer.xml -match 'LinksTo|SOMPath|SecurityDescriptor' -or [string]$result.user.xml -match 'LinksTo|SOMPath|SecurityDescriptor') {
            throw 'Expected #179 evidence to retain only Computer/User configuration subtrees, not #180 topology/delegation context.'
        }
    }

    It 'fails before Get-GPOReport when persisted GUID or domain identity is missing' {
        foreach ($item in @(
            [pscustomobject]@{ id = 'not-a-guid'; displayName = 'Invalid'; domainId = 'example.com' },
            [pscustomobject]@{ id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; displayName = 'No domain' }
        )) {
            $threw = $false
            try {
                Invoke-CollectorOnPremDetailFamily -Family 'gpoReports' -InventoryItem $item | Out-Null
            }
            catch {
                $threw = $true
            }
            if (-not $threw) {
                throw 'Expected invalid persisted GPO report identity to fail.'
            }
        }

        if ($global:CollectorGpoReportCalls.Count -ne 0) {
            throw 'Expected invalid identity to fail before Get-GPOReport is invoked.'
        }
    }
}

Describe 'On-prem GPO report Stage2 integration' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-gpo-report-stage2-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestGpoStage2Context -RunPath $script:testRoot
        $script:gpoIds = @(
            '11111111-2222-3333-4444-555555555555',
            'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        )

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorOnPremInventoryFamily -MockWith {
            @(
                [pscustomobject]@{ id = $script:gpoIds[0]; displayName = 'One'; domainId = 'example.com'; domainName = 'example.com' },
                [pscustomobject]@{ id = $script:gpoIds[1]; displayName = 'Two'; domainId = 'example.com'; domainName = 'example.com' }
            )
        }
        Invoke-CollectorStage1 -Context $script:context -Sections @('onprem-ad-gpo') | Out-Null

        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorOnPremDetailFamily -MockWith {
            param($Family, $InventoryItem)
            if ($Family -eq 'gpoReports') {
                return [pscustomobject]@{
                    id = [string]$InventoryItem.id
                    gpoId = [string]$InventoryItem.id
                    domainContext = [string]$InventoryItem.domainId
                    computer = [pscustomobject]@{ present = $true; xml = '<Computer />' }
                    user = [pscustomobject]@{ present = $true; xml = '<User />' }
                    redactedCredentialValueCount = 0
                }
            }
            return [pscustomobject]@{ id = [string]$InventoryItem.id }
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'uses Stage1 gpos as the dependency and persists one GPO per gpoReports artifact' {
        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('onprem-ad-gpo'))
        $reportResult = @($results | Where-Object { $_.family -eq 'gpoReports' })
        if ($reportResult.Count -ne 1 -or [int]$reportResult[0].batchCount -ne 2 -or [int]$reportResult[0].succeededBatches -ne 2 -or [int]$reportResult[0].itemCount -ne 2) {
            throw 'Expected two one-item successful gpoReports batches from the two Stage1 gpos.'
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $script:context.RunId -Stage 'stage2' -Section 'onprem-ad-gpo' -Family 'gpoReports'
        if ([int]$checkpoint.plan.batchSize -ne 1 -or [int]$checkpoint.plan.expectedBatchCount -ne 2) {
            throw 'Expected gpoReports checkpoint plan to force batch size 1.'
        }

        foreach ($batchNumber in @(1, 2)) {
            $batchId = '{0:D4}' -f $batchNumber
            $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
            if ([string]$batch.status -ne 'Succeeded' -or [int]$batch.itemCount -ne 1 -or [int]$batch.successCount -ne 1 -or [int]$batch.failedCount -ne 0) {
                throw ('Expected successful one-item gpoReports checkpoint batch {0}.' -f $batchId)
            }

            $artifactPath = Join-Path -Path $script:testRoot -ChildPath ('stage2/onprem-ad-gpo/gpoReports/batch-{0}.json' -f $batchId)
            $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
            if ([string]$snapshot.sourceName -ne 'Get-GPOReport' -or [string]$snapshot.requestContext.dependencyFamily -ne 'gpos' -or [string]$snapshot.requestContext.reportType -ne 'Xml' -or [int]$snapshot.requestContext.effectiveBatchSize -ne 1 -or @($snapshot.items).Count -ne 1) {
                throw ('Expected truthful gpoReports provenance and one item in batch {0}.' -f $batchId)
            }
        }
    }

    It 'resumes successful gpoReports batches independently without incrementing attempts' {
        Invoke-CollectorStage2 -Context $script:context -Sections @('onprem-ad-gpo') | Out-Null
        $script:context.Resume = $true

        $results = @(Invoke-CollectorStage2 -Context $script:context -Sections @('onprem-ad-gpo'))
        $reportResult = @($results | Where-Object { $_.family -eq 'gpoReports' })
        if ($reportResult.Count -ne 1 -or [int]$reportResult[0].succeededBatches -ne 0 -or [int]$reportResult[0].skippedBatches -ne 2 -or [int]$reportResult[0].failedBatches -ne 0) {
            throw 'Expected both successful gpoReports batches to be skipped on resume.'
        }

        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId $script:context.RunId -Stage 'stage2' -Section 'onprem-ad-gpo' -Family 'gpoReports'
        foreach ($batchId in @('0001', '0002')) {
            $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId $batchId
            if ([int]$batch.attempts -ne 1 -or [string]$batch.status -ne 'Succeeded') {
                throw ('Expected resumed gpoReports batch {0} to remain succeeded at attempt 1.' -f $batchId)
            }
        }
    }
}
