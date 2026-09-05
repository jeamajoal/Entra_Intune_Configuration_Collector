$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$validationScript = Join-Path -Path $repoRoot -ChildPath 'tools/Invoke-LocalValidation.ps1'

function Import-ValidationSummaryFunction {
    $source = Get-Content -LiteralPath $validationScript -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw ('Validation script did not parse: ' + (($parseErrors | ForEach-Object Message) -join '; '))
    }

    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PesterValidationSummary'
    }, $true)

    if (-not $functionAst) {
        throw 'Get-PesterValidationSummary was not found in Invoke-LocalValidation.ps1.'
    }

    Invoke-Expression $functionAst.Extent.Text
}

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
    BeforeAll {
        Import-ValidationSummaryFunction
    }

    It 'accepts a Pester 4 style result with executed passing tests' {
        $result = [pscustomobject]@{
            FailedCount = 0
            TestResult = @(
                [pscustomobject]@{ Result = 'Passed' },
                [pscustomobject]@{ Result = 'Passed' }
            )
        }

        $summary = Get-PesterValidationSummary -PesterResults $result
        if ([int]$summary.TotalCount -ne 2 -or [int]$summary.FailedCount -ne 0) {
            throw ('Unexpected Pester 4 summary: total={0}, failed={1}.' -f $summary.TotalCount, $summary.FailedCount)
        }
    }

    It 'accepts a Pester 5 style result with explicit TotalCount and FailedCount' {
        $result = [pscustomobject]@{
            TotalCount = 3
            FailedCount = 0
        }

        $summary = Get-PesterValidationSummary -PesterResults $result
        if ([int]$summary.TotalCount -ne 3 -or [int]$summary.FailedCount -ne 0) {
            throw ('Unexpected Pester 5 summary: total={0}, failed={1}.' -f $summary.TotalCount, $summary.FailedCount)
        }
    }

    It 'fails closed when Pester reports zero tests' {
        $message = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ TotalCount = 0; FailedCount = 0 })
        if ($message -notmatch 'zero tests') {
            throw ('Expected zero-test failure; actual: ' + [string]$message)
        }
    }

    It 'fails when Pester reports failed tests' {
        $message = Get-ValidationSummaryFailure -Result ([pscustomobject]@{ TotalCount = 2; FailedCount = 1 })
        if ($message -notmatch '1 failed tests') {
            throw ('Expected failed-test error; actual: ' + [string]$message)
        }
    }

    It 'derives failures from Pester 4 TestResult when FailedCount is unavailable' {
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
