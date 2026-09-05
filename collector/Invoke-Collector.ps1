[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$GraphToken,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [ValidateSet('All', 'Stage1', 'Stage2', 'Stage3')]
    [string[]]$Stages = @('All'),

    [ValidateSet('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo')]
    [string[]]$Sections = @('entra-apps', 'entra-pim', 'intune-core', 'onprem-ad-gpo'),

    [switch]$Resume,

    [switch]$ReprocessFailedOnly,

    [switch]$Force,

    [int]$BatchSize = 100,

    [int]$MaxRetries = 5,

    [double]$BaseBackoffSeconds = 2,

    [double]$MaxBackoffSeconds = 30,

    [int]$ThrottleMilliseconds = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$orchestratorModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules\Collector.Orchestrator.psm1'
Import-Module -Name $orchestratorModulePath -Force -ErrorAction Stop

try {
    $result = Start-CollectorRun -GraphToken $GraphToken -OutputRoot $OutputRoot -Stages $Stages -Sections $Sections -Resume:$Resume -ReprocessFailedOnly:$ReprocessFailedOnly -Force:$Force -BatchSize $BatchSize -MaxRetries $MaxRetries -BaseBackoffSeconds $BaseBackoffSeconds -MaxBackoffSeconds $MaxBackoffSeconds -ThrottleMilliseconds $ThrottleMilliseconds
    $result
}
catch {
    Write-Error -Message ('Collector run failed: {0}' -f $_.Exception.Message)
    throw
}
