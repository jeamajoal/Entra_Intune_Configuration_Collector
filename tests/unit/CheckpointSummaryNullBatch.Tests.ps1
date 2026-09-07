param()

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'collector/modules/Collector.Storage.Checkpoints.psm1') -Force -ErrorAction Stop
}

Describe 'Checkpoint summary singleton null batch integrity' {
    BeforeEach {
        $script:testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('collector-summary-null-batch-' + [Guid]::NewGuid().ToString('N'))
        $script:runPath = Join-Path -Path $script:testRoot -ChildPath 'run-summary-null-batch'
        $checkpointPath = Get-CollectorCheckpointPath -RunPath $script:runPath -Stage 'stage1' -Section 'entra-apps' -Family 'applications'
        New-Item -Path (Split-Path -Path $checkpointPath -Parent) -ItemType Directory -Force | Out-Null

        $checkpointJson = @'
{
  "schemaVersion": "1.0",
  "runId": "run-summary-null-batch",
  "stage": "stage1",
  "section": "entra-apps",
  "family": "applications",
  "updatedUtc": "2026-09-07T00:00:00.0000000Z",
  "plan": null,
  "batches": [null]
}
'@
        Set-Content -LiteralPath $checkpointPath -Value $checkpointJson -Encoding UTF8
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:testRoot) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'rejects a persisted singleton null batch instead of normalizing it to an empty summary' {
        $threw = $false
        try {
            Get-CollectorCheckpointSummary -RunPath $script:runPath | Out-Null
        }
        catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'missing status') {
                throw ('Expected singleton null batch rejection; actual error: {0}' -f $_.Exception.Message)
            }
        }

        if (-not $threw) {
            throw 'Expected persisted batches=[null] to fail checkpoint summary validation.'
        }
    }
}
