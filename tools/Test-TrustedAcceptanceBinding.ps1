[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [psobject]$PullRequest,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedRepository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHeadSha,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DispatchRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DispatchRef -ne 'refs/heads/main') {
    throw "Trusted self-hosted acceptance must be dispatched from refs/heads/main; found '$DispatchRef'."
}

if ([string]$PullRequest.state -ne 'open') {
    throw "Trusted self-hosted acceptance requires an open pull request; found '$($PullRequest.state)'."
}

if ([string]$PullRequest.base.ref -ne 'main') {
    throw "Trusted self-hosted acceptance requires a pull request targeting main; found '$($PullRequest.base.ref)'."
}

$headRepository = [string]$PullRequest.head.repo.full_name
if ($headRepository -ne $ExpectedRepository) {
    throw "Trusted self-hosted acceptance requires a same-repository pull request; expected '$ExpectedRepository', found '$headRepository'."
}

$actualHeadSha = [string]$PullRequest.head.sha
if ($actualHeadSha -ne $ExpectedHeadSha) {
    throw "Trusted self-hosted acceptance head SHA mismatch; expected '$ExpectedHeadSha', found '$actualHeadSha'."
}

return $actualHeadSha
