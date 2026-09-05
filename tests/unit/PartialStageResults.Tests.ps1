BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Orchestrator.psm1') -Force -ErrorAction Stop
}

Describe 'Partial Stage2 and Stage3 manifest results' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-partial-stage-test-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'seed-object' })
        }
        Mock -ModuleName 'Collector.Stage2.Details' -CommandName Invoke-CollectorGraphRequest -MockWith {
            [pscustomobject]@{ id = 'detail-object' }
        }
        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @()
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'keeps earlier Stage2 family results when a later section inventory gate fails' {
        $initial = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps')

        $threw = $false
        try {
            Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage2') -Sections @('entra-apps','onprem-ad-gpo') -Resume | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) { throw 'Expected later on-prem Stage2 inventory gate to abort the invocation.' }

        $manifest = Get-Content -LiteralPath $initial.manifestPath -Raw | ConvertFrom-Json
        $latest = @($manifest.invocations)[-1]
        $stage2Results = @($latest.stageResults | Where-Object { $_.stage -eq 'stage2' })
        $actualStage2Families = @($stage2Results.family | Sort-Object)
        $expectedStage2Families = @('applicationCredentials','applications','groups','servicePrincipalCredentials','servicePrincipals') | Sort-Object
        if (($actualStage2Families -join ',') -ne ($expectedStage2Families -join ',')) {
            throw ('Expected all completed entra-apps Stage2 families to survive later gate failure; actual ' + ($actualStage2Families -join ','))
        }

        $failure = @($latest.failures)[-1]
        if ([string]$failure.stage -ne 'stage2' -or [string]$failure.section -ne 'onprem-ad-gpo' -or [string]$failure.family -ne 'domains') {
            throw ('Expected attributable Stage2 gate failure; actual {0}/{1}/{2}.' -f $failure.stage,$failure.section,$failure.family)
        }

        $applicationArtifact = Join-Path -Path $initial.runPath -ChildPath 'stage2/entra-apps/applications/batch-0001.json'
        if (-not (Test-Path -LiteralPath $applicationArtifact)) {
            throw 'Expected completed Stage2 artifact from earlier section to remain on disk.'
        }
        if (Test-Path -LiteralPath (Join-Path -Path $initial.runPath -ChildPath 'stage2/onprem-ad-gpo/domains/batch-0001.json')) {
            throw 'Inventory-first gate must prevent the affected on-prem Stage2 family from running.'
        }
        if ([string]$latest.status -ne 'Failed') { throw 'Expected invocation status Failed after hard inventory gate abort.' }
    }

    It 'keeps earlier Stage3 family results when a later section inventory gate fails' {
        $initial = Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage1') -Sections @('entra-apps')

        $threw = $false
        try {
            Start-CollectorRun -GraphToken 'token' -OutputRoot $script:testRoot -Stages @('Stage3') -Sections @('entra-apps','onprem-ad-gpo') -Resume | Out-Null
        }
        catch {
            $threw = $true
        }
        if (-not $threw) { throw 'Expected later on-prem Stage3 inventory gate to abort the invocation.' }

        $manifest = Get-Content -LiteralPath $initial.manifestPath -Raw | ConvertFrom-Json
        $latest = @($manifest.invocations)[-1]
        $stage3Results = @($latest.stageResults | Where-Object { $_.stage -eq 'stage3' })
        $actualStage3Families = @($stage3Results.family | Sort-Object)
        $expectedStage3Families = @('applicationFederatedIdentityCredentials','delegatedGrants','groupMembers','servicePrincipalAppRoleAssignedTo') | Sort-Object
        if (($actualStage3Families -join ',') -ne ($expectedStage3Families -join ',')) {
            throw ('Expected all completed entra-apps Stage3 families to survive later gate failure; actual ' + ($actualStage3Families -join ','))
        }

        $failure = @($latest.failures)[-1]
        if ([string]$failure.stage -ne 'stage3' -or [string]$failure.section -ne 'onprem-ad-gpo' -or [string]$failure.family -ne 'domains') {
            throw ('Expected attributable Stage3 gate failure; actual {0}/{1}/{2}.' -f $failure.stage,$failure.section,$failure.family)
        }

        $relationshipArtifact = Join-Path -Path $initial.runPath -ChildPath 'stage3/entra-apps/groupMembers/batch-0001.json'
        if (-not (Test-Path -LiteralPath $relationshipArtifact)) {
            throw 'Expected completed Stage3 artifact from earlier section to remain on disk.'
        }
        if (Test-Path -LiteralPath (Join-Path -Path $initial.runPath -ChildPath 'stage3/onprem-ad-gpo/domainRootAcl/batch-0001.json')) {
            throw 'Inventory-first gate must prevent the affected on-prem Stage3 family from running.'
        }
        if ([string]$latest.status -ne 'Failed') { throw 'Expected invocation status Failed after hard inventory gate abort.' }
    }
}
