$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$validationScript = Join-Path -Path $repoRoot -ChildPath 'tools/Invoke-LocalValidation.ps1'

$validationSource = Get-Content -LiteralPath $validationScript -Raw
$tokens = $null
$parseErrors = $null
$validationAst = [System.Management.Automation.Language.Parser]::ParseInput($validationSource, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw ('Validation script did not parse: ' + (($parseErrors | ForEach-Object Message) -join '; '))
}

$summaryFunctionAst = $validationAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PesterValidationSummary'
}, $true)
if (-not $summaryFunctionAst) {
    throw 'Get-PesterValidationSummary was not found in Invoke-LocalValidation.ps1.'
}
Invoke-Expression $summaryFunctionAst.Extent.Text

function Get-ValidationSummaryFailure {
    param(
        [AllowNull()]
        [object]$Result
    )

    try {
        Get-PesterValidationSummary -PesterResults $Result | Out-Null
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

Describe 'Local validation Pester result contract' {
    It 'accepts a Pester 4 style result with executed passing tests' {
        $result = [pscustomobject]@{
            FailedCount = 0
            TestResult = @(
                [pscustomobject]@{ Result = 'Passed' },
                [pscustomobject]@{ Result = 'Passed' }
            )
        }

        $summary = Get-PesterValidationSummary -PesterResults $result
        if ([int]$summary.TotalCount -ne 2 -or [int]$summary.PassedCount -ne 2 -or [int]$summary.FailedCount -ne 0 -or [int]$summary.ExecutedCount -ne 2) {
            throw ('Unexpected Pester 4 summary: total={0}, passed={1}, failed={2}, executed={3}.' -f $summary.TotalCount, $summary.PassedCount, $summary.FailedCount, $summary.ExecutedCount)
        }
    }

    It 'accepts a Pester 5 style result with explicit TotalCount PassedCount and FailedCount' {
        $result = [pscustomobject]@{
            TotalCount = 3
            PassedCount = 3
            FailedCount = 0
        }

        $summary = Get-PesterValidationSummary -PesterResults $result
        if ([int]$summary.TotalCount -ne 3 -or [int]$summary.PassedCount -ne 3 -or [int]$summary.FailedCount -ne 0 -or [int]$summary.ExecutedCount -ne 3) {
            throw ('Unexpected Pester 5 summary: total={0}, passed={1}, failed={2}, executed={3}.' -f $summary.TotalCount, $summary.PassedCount, $summary.FailedCount, $summary.ExecutedCount)
        }
    }

    It 'fails closed when Pester discovers zero tests' {
        $message = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ TotalCount = 0; PassedCount = 0; FailedCount = 0 })
        if ($message -notmatch 'zero discovered tests') {
            throw ('Expected zero-test failure; actual: ' + [string]$message)
        }
    }

    It 'fails closed when tests are discovered but none pass or fail' {
        $message = Get-ValidationSummaryFailure -Result ([pscustomobject]@{
            TotalCount = 2
            PassedCount = 0
            FailedCount = 0
            SkippedCount = 2
        })
        if ($message -notmatch 'no passed or failed tests executed') {
            throw ('Expected no-executed-test failure; actual: ' + [string]$message)
        }
    }

    It 'fails when Pester reports failed tests' {
        $message = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ TotalCount = 2; PassedCount = 1; FailedCount = 1 })
        if ($message -notmatch '1 failed tests') {
            throw ('Expected failed-test error; actual: ' + [string]$message)
        }
    }

    It 'derives passed and failed execution state from Pester 4 TestResult when count properties are unavailable' {
        $result = [pscustomobject]@{
            TestResult = @(
                [pscustomobject]@{ Result = 'Passed' },
                [pscustomobject]@{ Result = 'Failed' }
            )
        }

        $message = Get-ValidationSummaryFailure -Result $result
        if ($message -notmatch '1 failed tests') {
            throw ('Expected TestResult-derived failure; actual: ' + [string]$message)
        }
    }

    It 'fails closed for null and unsupported result shapes' {
        $nullMessage = Get-ValidationSummaryFailure -Result $null
        if ($nullMessage -notmatch 'no result object') {
            throw ('Expected null-result failure; actual: ' + [string]$nullMessage)
        }

        $unknownMessage = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ SomethingElse = 1 })
        if ($unknownMessage -notmatch 'Unsupported Pester result shape') {
            throw ('Expected unsupported-shape failure; actual: ' + [string]$unknownMessage)
        }
    }

    It 'fails closed when a supported count property is present but null' {
        $totalMessage = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ TotalCount = $null; PassedCount = 0; FailedCount = 0 })
        if ($totalMessage -notmatch 'TotalCount is null') {
            throw ('Expected null TotalCount failure; actual: ' + [string]$totalMessage)
        }

        $failedMessage = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ TotalCount = 1; PassedCount = 1; FailedCount = $null })
        if ($failedMessage -notmatch 'FailedCount is null') {
            throw ('Expected null FailedCount failure; actual: ' + [string]$failedMessage)
        }

        $passedMessage = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ TotalCount = 1; PassedCount = $null; FailedCount = 0 })
        if ($passedMessage -notmatch 'PassedCount is null') {
            throw ('Expected null PassedCount failure; actual: ' + [string]$passedMessage)
        }
    }

    It 'keeps explicit SkipPester as a skipped state rather than a pass' {
        $output = (& $validationScript -SkipScriptAnalyzer -SkipPester 6>&1 | Out-String)
        if ($output -notmatch 'Pester step skipped by request') {
            throw 'Expected explicit Pester skipped message.'
        }
        if ($output -match 'Pester validation passed') {
            throw 'SkipPester must not emit a Pester pass message.'
        }
    }
}
