[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global command shim is test-only so the provider can exercise Get-GPOReport without requiring the GroupPolicy module in CI.')]
param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

    function global:Get-GPOReport {
        [CmdletBinding()]
        param(
            [Guid]$Guid,
            [string]$Domain,
            [ValidateSet('Xml', 'Html')]
            [string]$ReportType
        )

        if ($Guid -ne [Guid]'22222222-3333-4444-5555-666666666666') {
            throw ('Unexpected GPO GUID in structured credential test: {0}' -f $Guid)
        }
        if ($Domain -ne 'example.com') {
            throw ('Unexpected domain in structured credential test: {0}' -f $Domain)
        }
        if ($ReportType -ne 'Xml') {
            throw ('Unexpected report type in structured credential test: {0}' -f $ReportType)
        }

        return @"
<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings">
  <Computer>
    <ExtensionData>
      <Extension>
        <Policy name="MinimumPasswordLength" value="14" />
        <c:Password xmlns:c="urn:collector-test-credential" value="structured-attribute-secret" />
      </Extension>
    </ExtensionData>
  </Computer>
  <User>
    <ExtensionData>
      <Extension>
        <Secret><Value>nested-credential-secret</Value></Secret>
      </Extension>
    </ExtensionData>
  </User>
</GPO>
"@
    }

    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Provider.OnPrem.psm1') -Force -ErrorAction Stop
}

Describe 'Structured GPO credential redaction' {
    AfterAll {
        Remove-Item Function:\Get-GPOReport -ErrorAction SilentlyContinue
    }

    It 'redacts generic attributes and nested content when the containing element is credential-bearing' {
        $gpoId = [Guid]'22222222-3333-4444-5555-666666666666'
        $result = Collector.Provider.OnPrem\Invoke-CollectorOnPremDetailFamily -Family 'gpoReports' -InventoryItem ([pscustomobject]@{
            id = [string]$gpoId
            displayName = 'Structured credential policy'
            domainId = 'example.com'
        })

        $combinedXml = [string]$result.computer.xml + [string]$result.user.xml

        if ($combinedXml -match 'structured-attribute-secret|nested-credential-secret') {
            throw 'Structured credential secret text must never survive GPO report serialization.'
        }
        if ([string]$result.computer.xml -notmatch 'MinimumPasswordLength' -or [string]$result.computer.xml -notmatch 'value="14"') {
            throw 'Ordinary password-policy configuration must remain reviewable.'
        }
        if ([string]$result.computer.xml -notmatch 'xmlns:c="urn:collector-test-credential"') {
            throw 'Credential-element namespace declarations must be preserved.'
        }
        if ([string]$result.computer.xml -notmatch 'value="\[REDACTED\]"') {
            throw 'A generic value attribute on a credential-bearing element must be redacted.'
        }
        if ([string]$result.user.xml -notmatch '<Secret>\[REDACTED\]</Secret>' -or [string]$result.user.xml -match '<Value>') {
            throw 'Nested credential content must be replaced as a whole rather than traversed as generic child fields.'
        }
        if ([int]$result.redactedCredentialValueCount -ne 2) {
            throw ('Expected exactly two structured credential redactions, observed {0}.' -f $result.redactedCredentialValueCount)
        }
    }
}
