[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunPath,

    [string]$ExpectedRunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules\Collector.Storage.Catalog.psm1'
Import-Module -Name $catalogModulePath -Force -ErrorAction Stop

try {
    Export-CollectorKnowledgeCatalog -RunPath $RunPath -ExpectedRunId $ExpectedRunId
}
catch {
    Write-Error -Message ('Knowledge catalog generation failed: {0}' -f $_.Exception.Message)
    throw
}
