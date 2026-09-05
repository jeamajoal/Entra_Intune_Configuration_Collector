[CmdletBinding()]
param(
    [switch]$SkipScriptAnalyzer,
    [switch]$SkipPester
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PesterValidationSummary {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$PesterResults
    )

    if ($null -eq $PesterResults) {
        throw 'Pester returned no result object; unable to prove test execution.'
    }

    $propertyNames = @($PesterResults.PSObject.Properties.Name)
    $totalCount = $null
    $failedCount = $null

    if ($propertyNames -contains 'TotalCount') {
        if ($null -eq $PesterResults.TotalCount) {
            throw 'Pester TotalCount is null; unable to prove test execution.'
        }

        try {
            $totalCount = [long]$PesterResults.TotalCount
        }
        catch {
            throw 'Pester TotalCount is not a supported numeric value.'
        }
    }
    elseif ($propertyNames -contains 'TestResult') {
        $totalCount = @($PesterResults.TestResult).Count
    }
    else {
        throw 'Unsupported Pester result shape: unable to resolve total test count from TotalCount or TestResult.'
    }

    if ($propertyNames -contains 'FailedCount') {
        if ($null -eq $PesterResults.FailedCount) {
            throw 'Pester FailedCount is null; unable to prove failure state.'
        }

        try {
            $failedCount = [long]$PesterResults.FailedCount
        }
        catch {
            throw 'Pester FailedCount is not a supported numeric value.'
        }
    }
    elseif ($propertyNames -contains 'TestResult') {
        $failedCount = @($PesterResults.TestResult | Where-Object { $_.Result -ne 'Passed' }).Count
    }
    else {
        throw 'Unsupported Pester result shape: unable to resolve failed test count from FailedCount or TestResult.'
    }

    if ($totalCount -lt 0 -or $failedCount -lt 0) {
        throw 'Pester returned an invalid negative test count.'
    }

    if ($totalCount -eq 0) {
        throw 'Pester reported zero tests; validation cannot pass without executed tests.'
    }

    if ($failedCount -gt 0) {
        throw ('Pester reported {0} failed tests.' -f $failedCount)
    }

    [pscustomobject]@{
        TotalCount = $totalCount
        FailedCount = $failedCount
    }
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$collectorPath = Join-Path -Path $repoRoot -ChildPath 'collector'
$testsPath = Join-Path -Path $repoRoot -ChildPath 'tests'
$toolsPath = Join-Path -Path $repoRoot -ChildPath 'tools'

$scriptFiles = @(Get-ChildItem -Path $collectorPath, $testsPath, $toolsPath -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
$parseFailures = @()

foreach ($scriptFile in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            $parseFailures += '{0}: {1}' -f $scriptFile.FullName, $parseError.Message
        }
    }
}

if ($parseFailures.Count -gt 0) {
    throw ('Parser validation failed:' + [Environment]::NewLine + ($parseFailures -join [Environment]::NewLine))
}

Write-Host 'Parser validation passed.'

if (-not $SkipScriptAnalyzer) {
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $analyzerFindings = @()
        foreach ($analysisPath in @($collectorPath, $testsPath, $toolsPath)) {
            $analyzerFindings += @(Invoke-ScriptAnalyzer -Path $analysisPath -Recurse -Severity Error, Warning)
        }

        if ($analyzerFindings -and $analyzerFindings.Count -gt 0) {
            $analyzerFindings | Format-Table -AutoSize
            throw ('PSScriptAnalyzer returned {0} findings.' -f $analyzerFindings.Count)
        }

        Write-Host 'PSScriptAnalyzer validation passed.'
    }
    else {
        Write-Host 'PSScriptAnalyzer is not installed; analyzer step skipped.'
    }
}
else {
    Write-Host 'PSScriptAnalyzer step skipped by request.'
}

if (-not $SkipPester) {
    if (Get-Module -ListAvailable -Name Pester) {
        Import-Module Pester -ErrorAction Stop
        $unitTestsPath = Join-Path -Path $testsPath -ChildPath 'unit'
        $invokePester = Get-Command -Name Invoke-Pester -ErrorAction Stop

        if ($invokePester.Parameters.ContainsKey('Path')) {
            $pesterResults = Invoke-Pester -Path $unitTestsPath -PassThru
        }
        elseif ($invokePester.Parameters.ContainsKey('Script')) {
            $pesterResults = Invoke-Pester -Script $unitTestsPath -PassThru
        }
        else {
            $pesterResults = Invoke-Pester $unitTestsPath -PassThru
        }

        Get-PesterValidationSummary -PesterResults $pesterResults | Out-Null
        Write-Host 'Pester validation passed.'
    }
    else {
        Write-Host 'Pester is not installed; test step skipped.'
    }
}
else {
    Write-Host 'Pester step skipped by request.'
}

Write-Host 'Local validation completed.'
