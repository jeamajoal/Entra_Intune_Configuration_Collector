BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    $script:bindingScript = Join-Path -Path $repoRoot -ChildPath 'tools/Test-TrustedAcceptanceBinding.ps1'
    $script:expectedRepository = 'jeamajoal/Entra_Intune_Configuration_Collector'
    $script:expectedSha = '0123456789abcdef0123456789abcdef01234567'
}

Describe 'Trusted self-hosted acceptance binding' {
    BeforeEach {
        $script:pullRequest = [pscustomobject]@{
            state = 'open'
            base = [pscustomobject]@{
                ref = 'main'
            }
            head = [pscustomobject]@{
                sha = $script:expectedSha
                repo = [pscustomobject]@{
                    full_name = $script:expectedRepository
                }
            }
        }
    }

    It 'accepts an open main-targeted same-repository pull request at the exact head SHA' {
        $result = & $script:bindingScript `
            -PullRequest $script:pullRequest `
            -ExpectedRepository $script:expectedRepository `
            -ExpectedHeadSha $script:expectedSha `
            -DispatchRef 'refs/heads/main'

        $result | Should -Be $script:expectedSha
    }

    It 'rejects a mismatched head SHA' {
        {
            & $script:bindingScript `
                -PullRequest $script:pullRequest `
                -ExpectedRepository $script:expectedRepository `
                -ExpectedHeadSha 'fedcba9876543210fedcba9876543210fedcba98' `
                -DispatchRef 'refs/heads/main'
        } | Should -Throw '*head SHA mismatch*'
    }

    It 'rejects a pull request from a fork repository' {
        $script:pullRequest.head.repo.full_name = 'example/fork'

        {
            & $script:bindingScript `
                -PullRequest $script:pullRequest `
                -ExpectedRepository $script:expectedRepository `
                -ExpectedHeadSha $script:expectedSha `
                -DispatchRef 'refs/heads/main'
        } | Should -Throw '*same-repository pull request*'
    }

    It 'rejects a pull request that does not target main' {
        $script:pullRequest.base.ref = 'develop'

        {
            & $script:bindingScript `
                -PullRequest $script:pullRequest `
                -ExpectedRepository $script:expectedRepository `
                -ExpectedHeadSha $script:expectedSha `
                -DispatchRef 'refs/heads/main'
        } | Should -Throw '*targeting main*'
    }

    It 'rejects a closed pull request' {
        $script:pullRequest.state = 'closed'

        {
            & $script:bindingScript `
                -PullRequest $script:pullRequest `
                -ExpectedRepository $script:expectedRepository `
                -ExpectedHeadSha $script:expectedSha `
                -DispatchRef 'refs/heads/main'
        } | Should -Throw '*open pull request*'
    }

    It 'rejects a dispatch that is not running from main' {
        {
            & $script:bindingScript `
                -PullRequest $script:pullRequest `
                -ExpectedRepository $script:expectedRepository `
                -ExpectedHeadSha $script:expectedSha `
                -DispatchRef 'refs/heads/security/79-trusted-self-hosted-acceptance'
        } | Should -Throw '*dispatched from refs/heads/main*'
    }
}
