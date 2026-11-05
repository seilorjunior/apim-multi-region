function Invoke-ApimSync {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [ValidateSet('Sync', 'Export', 'Drift')][string]$Action = 'Sync',
        [switch]$DryRun,
        [string]$Revision,
        [string]$PlanPath,
        [string]$ReportPath,
        [string]$OutputPath,
        [string]$DeletionManifest,
        [switch]$AllowDelete
    )
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot 'node_modules\@azure-tools\apiops-cli\dist\clients\apim-client.js'))) {
        throw 'APIOps dependency is missing. Install Node.js 22+ and run npm ci --ignore-scripts from the repository root.'
    }
    $engine = Join-Path $script:ProjectRoot 'scripts\apiops.mjs'
    $mode = if ($Action -eq 'Export') { 'export' } elseif ($Action -eq 'Drift') { 'drift' } elseif ($DryRun) { 'plan' } else { 'publish' }
    if ($mode -eq 'plan' -and -not $PlanPath) { $PlanPath = Join-Path $script:ProjectRoot 'TestResults\apiops-plan.json' }
    $arguments = @($engine, '--config', '-', '--action', $mode)
    foreach ($option in @(
        @('--revision', $Revision), @('--plan', $PlanPath), @('--report', $ReportPath),
        @('--output', $OutputPath), @('--deletions', $DeletionManifest)
    )) {
        if ($option[1]) { $arguments += $option }
    }
    if ($AllowDelete) { $arguments += '--allow-delete' }
    # Stream configuration instead of writing credentials or environment files to disk.
    ($Values | ConvertTo-Json -Depth 10 -Compress) | & node @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "APIOps lifecycle failed with exit code $LASTEXITCODE. Inspect the sanitized report." }
}
