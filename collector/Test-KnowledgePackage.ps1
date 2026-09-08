[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunPath,

    [string]$ExpectedRunId,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules/Collector.Validation.Package.psm1'
Import-Module -Name $validationModulePath -Force -ErrorAction Stop

$result = Invoke-CollectorKnowledgePackageValidation -RunPath $RunPath -ExpectedRunId $ExpectedRunId
if ($AsJson) {
    $result | ConvertTo-Json -Depth 6 -Compress
}
else {
    $result
}
