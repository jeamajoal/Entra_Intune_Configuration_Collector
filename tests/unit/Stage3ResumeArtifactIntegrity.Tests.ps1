BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage1.Inventory.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Stage3.Relationships.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Artifacts.psm1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop

    function Get-TestStage3ResumeContext {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath
        )

        return @{
            RunPath = $RunPath
            RunId = 'stage3-resume-integrity'
            GraphToken = 'test-token'
            BatchSize = 100
            MaxRetries = 0
            BaseBackoffSeconds = 0
            MaxBackoffSeconds = 0
            ThrottleMilliseconds = 0
            Resume = $false
            ReprocessFailedOnly = $false
        }
    }

    function Get-TestStage3ArtifactPath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Section,

            [Parameter(Mandatory = $true)]
            [string]$Family
        )

        return [System.IO.Path]::GetFullPath((Join-Path -Path $RunPath -ChildPath ('stage3/{0}/{1}/batch-0001.json' -f $Section, $Family)))
    }

    function Get-TestStage3Batch {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [string]$Section,

            [Parameter(Mandatory = $true)]
            [string]$Family
        )

        $checkpoint = Get-CollectorCheckpoint -RunPath $RunPath -RunId 'stage3-resume-integrity' -Stage 'stage3' -Section $Section -Family $Family
        return Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
    }

    function Assert-TestGraphStage3Repair {
        param(
            [Parameter(Mandatory = $true)]
            [string]$RunPath,

            [Parameter(Mandatory = $true)]
            [object[]]$Results
        )

        $target = @($Results | Where-Object { $_.family -eq 'groupMembers' })
        if ($target.Count -ne 1 -or [int]$target[0].succeededBatches -ne 1 -or [int]$target[0].skippedBatches -ne 0 -or [int]$target[0].failedBatches -ne 0) {
            throw 'Expected only the invalid groupMembers Stage3 batch to be reprocessed successfully.'
        }

        foreach ($family in @('servicePrincipalAppRoleAssignedTo', 'applicationFederatedIdentityCredentials', 'delegatedGrants')) {
            $familyResult = @($Results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid sibling Stage3 family {0} to remain skipped.' -f $family)
            }

            $siblingBatch = Get-TestStage3Batch -RunPath $RunPath -Section 'entra-apps' -Family $family
            if ([string]$siblingBatch.status -ne 'Succeeded' -or [int]$siblingBatch.attempts -ne 1) {
                throw ('Expected sibling Stage3 family {0} to remain on attempt 1.' -f $family)
            }
        }

        $targetBatch = Get-TestStage3Batch -RunPath $RunPath -Section 'entra-apps' -Family 'groupMembers'
        if ([string]$targetBatch.status -ne 'Succeeded' -or [int]$targetBatch.attempts -ne 2 -or [int]$targetBatch.itemCount -ne 1 -or [int]$targetBatch.successCount -ne 1 -or [int]$targetBatch.failedCount -ne 0) {
            throw 'Expected repaired groupMembers Stage3 batch to be a second-attempt successful one-item batch.'
        }

        $snapshot = Get-Content -LiteralPath (Get-TestStage3ArtifactPath -RunPath $RunPath -Section 'entra-apps' -Family 'groupMembers') -Raw | ConvertFrom-Json
        if ([string]$snapshot.runId -ne 'stage3-resume-integrity' -or [string]$snapshot.stage -ne 'stage3' -or [string]$snapshot.section -ne 'entra-apps' -or [string]$snapshot.family -ne 'groupMembers' -or [string]$snapshot.batchId -ne '0001' -or [int]$snapshot.itemCount -ne 1 -or @($snapshot.items).Count -ne 1) {
            throw 'Expected groupMembers Stage3 snapshot to be repaired with current identity and cardinality.'
        }
    }
}

Describe 'Stage3 Graph resume artifact integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage3-graph-resume-integrity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestStage3ResumeContext -RunPath $script:testRoot

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorGraphCollection -MockWith {
            @([pscustomobject]@{ id = 'source-item' })
        }
        Invoke-CollectorStage1 -Context $script:context -Sections @('entra-apps') | Out-Null

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorGraphCollection -MockWith {
            param($Endpoint)

            if ($Endpoint -eq '/v1.0/oauth2PermissionGrants') {
                return @([pscustomobject]@{ id = 'grant-1' })
            }

            return @([pscustomobject]@{
                id = 'relationship-1'
                name = 'relationship-1'
                issuer = 'https://issuer.example'
                subject = 'subject-1'
                audiences = @('api://AzureADTokenExchange')
                description = 'test relationship'
            })
        }
        Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps') | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'reprocesses and repairs a malformed prior successful Graph Stage3 snapshot while valid siblings remain skipped' {
        $artifactPath = Get-TestStage3ArtifactPath -RunPath $script:testRoot -Section 'entra-apps' -Family 'groupMembers'
        '{not-json' | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage3Repair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses and repairs an identity-mismatched prior successful Graph Stage3 snapshot' {
        $artifactPath = Get-TestStage3ArtifactPath -RunPath $script:testRoot -Section 'entra-apps' -Family 'groupMembers'
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        $snapshot.runId = 'other-run'
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage3Repair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses and repairs a snapshot-cardinality-invalid prior successful Graph Stage3 snapshot' {
        $artifactPath = Get-TestStage3ArtifactPath -RunPath $script:testRoot -Section 'entra-apps' -Family 'groupMembers'
        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        $snapshot.itemCount = 2
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage3Repair -RunPath $script:testRoot -Results $results
    }

    It 'reprocesses a prior successful Graph Stage3 batch whose checkpoint output cardinality is inconsistent' {
        $checkpoint = Get-CollectorCheckpoint -RunPath $script:testRoot -RunId 'stage3-resume-integrity' -Stage 'stage3' -Section 'entra-apps' -Family 'groupMembers'
        $batch = Get-CollectorCheckpointBatch -Checkpoint $checkpoint -BatchId '0001'
        $batch.successCount = 0
        Save-CollectorCheckpoint -RunPath $script:testRoot -Checkpoint $checkpoint | Out-Null

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps'))

        Assert-TestGraphStage3Repair -RunPath $script:testRoot -Results $results
    }

    It 'keeps valid prior successful Graph Stage3 artifacts skipped without incrementing attempts' {
        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('entra-apps'))

        foreach ($family in @('servicePrincipalAppRoleAssignedTo', 'groupMembers', 'applicationFederatedIdentityCredentials', 'delegatedGrants')) {
            $familyResult = @($results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid prior successful Stage3 family {0} to remain skipped.' -f $family)
            }

            $batch = Get-TestStage3Batch -RunPath $script:testRoot -Section 'entra-apps' -Family $family
            if ([string]$batch.status -ne 'Succeeded' -or [int]$batch.attempts -ne 1) {
                throw ('Expected valid prior successful Stage3 family {0} attempts to remain unchanged.' -f $family)
            }
        }
    }
}

Describe 'Stage3 on-prem resume artifact integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-stage3-onprem-resume-integrity-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $script:context = Get-TestStage3ResumeContext -RunPath $script:testRoot

        Mock -ModuleName 'Collector.Stage1.Inventory' -CommandName Invoke-CollectorOnPremInventoryFamily -MockWith {
            @([pscustomobject]@{
                name = 'source-item'
                distinguishedName = 'CN=source-item,DC=example,DC=com'
                domain = 'example.com'
            })
        }
        Invoke-CollectorStage1 -Context $script:context -Sections @('onprem-ad-gpo') | Out-Null

        Mock -ModuleName 'Collector.Stage3.Relationships' -CommandName Invoke-CollectorOnPremRelationshipFamily -MockWith {
            @(
                [pscustomobject]@{ relationship = 'one' },
                [pscustomobject]@{ relationship = 'two' }
            )
        }
        Invoke-CollectorStage3 -Context $script:context -Sections @('onprem-ad-gpo') | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'keeps a valid prior Stage3 relationship output reusable when output cardinality differs from source batch cardinality' {
        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('onprem-ad-gpo'))

        foreach ($family in @('domainRootAcl', 'ouAcl', 'gpoPermissions', 'groupMembersOnPrem')) {
            $familyResult = @($results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid on-prem Stage3 family {0} to remain skipped.' -f $family)
            }

            $batch = Get-TestStage3Batch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family $family
            if ([string]$batch.status -ne 'Succeeded' -or [int]$batch.attempts -ne 1 -or [int]$batch.itemCount -ne 2 -or [int]$batch.successCount -ne 2 -or [int]$batch.failedCount -ne 0) {
                throw ('Expected valid on-prem Stage3 family {0} to retain two output rows from one source input without reprocessing.' -f $family)
            }
        }
    }

    It 'reprocesses and repairs a malformed prior successful on-prem Stage3 snapshot while valid siblings remain skipped' {
        $artifactPath = Get-TestStage3ArtifactPath -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family 'domainRootAcl'
        '{not-json' | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $script:context.Resume = $true
        $results = @(Invoke-CollectorStage3 -Context $script:context -Sections @('onprem-ad-gpo'))

        $target = @($results | Where-Object { $_.family -eq 'domainRootAcl' })
        if ($target.Count -ne 1 -or [int]$target[0].succeededBatches -ne 1 -or [int]$target[0].skippedBatches -ne 0 -or [int]$target[0].failedBatches -ne 0) {
            throw 'Expected invalid domainRootAcl Stage3 batch to be reprocessed successfully.'
        }

        $targetBatch = Get-TestStage3Batch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family 'domainRootAcl'
        if ([string]$targetBatch.status -ne 'Succeeded' -or [int]$targetBatch.attempts -ne 2 -or [int]$targetBatch.itemCount -ne 2 -or [int]$targetBatch.successCount -ne 2 -or [int]$targetBatch.failedCount -ne 0) {
            throw 'Expected repaired domainRootAcl Stage3 batch to be a second-attempt successful two-output-row batch.'
        }

        foreach ($family in @('ouAcl', 'gpoPermissions', 'groupMembersOnPrem')) {
            $familyResult = @($results | Where-Object { $_.family -eq $family })
            if ($familyResult.Count -ne 1 -or [int]$familyResult[0].succeededBatches -ne 0 -or [int]$familyResult[0].skippedBatches -ne 1 -or [int]$familyResult[0].failedBatches -ne 0) {
                throw ('Expected valid on-prem Stage3 sibling {0} to remain skipped.' -f $family)
            }

            $siblingBatch = Get-TestStage3Batch -RunPath $script:testRoot -Section 'onprem-ad-gpo' -Family $family
            if ([string]$siblingBatch.status -ne 'Succeeded' -or [int]$siblingBatch.attempts -ne 1) {
                throw ('Expected valid on-prem Stage3 sibling {0} to remain on attempt 1.' -f $family)
            }
        }

        $snapshot = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json
        if ([string]$snapshot.runId -ne 'stage3-resume-integrity' -or [string]$snapshot.stage -ne 'stage3' -or [string]$snapshot.section -ne 'onprem-ad-gpo' -or [string]$snapshot.family -ne 'domainRootAcl' -or [string]$snapshot.batchId -ne '0001' -or [int]$snapshot.itemCount -ne 2 -or @($snapshot.items).Count -ne 2) {
            throw 'Expected domainRootAcl Stage3 snapshot to be repaired with current identity and two relationship outputs.'
        }
    }
}
