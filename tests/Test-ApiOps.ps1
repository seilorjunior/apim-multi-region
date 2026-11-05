. (Join-Path $PSScriptRoot '..\scripts\ps1\Common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\ps1\ApiOps.ps1')

function node {
    begin { $text = ''; $script:arguments = $args }
    process { $text += $_ }
    end {
        $script:received = $text | ConvertFrom-Json
        $global:LASTEXITCODE = if ($script:fail) { 3 } else { 0 }
    }
}
$values = @{ AZURE_ENV_NAME = 'test'; unicode = 'eastus' }
foreach ($case in @('Plan', 'Publish', 'Export', 'Drift', 'Failure')) {
    $script:fail = $case -eq 'Failure'
    $options = @{ Values = $values; ReportPath = 'report.json' }
    if ($case -eq 'Plan') { $options.DryRun = $true }
    if ($case -eq 'Export') { $options.Action = 'Export'; $options.OutputPath = 'config.json' }
    if ($case -eq 'Drift') { $options.Action = 'Drift' }
    if ($case -eq 'Publish') {
        $options.Revision = 'a' * 40; $options.PlanPath = 'plan.json'
        $options.DeletionManifest = 'deletions.json'; $options.AllowDelete = $true
    }
    $caught = $null
    try { Invoke-ApimSync @options } catch { $caught = $_ }
    if ($case -eq 'Failure') {
        if (-not $caught -or $caught.Exception.Message -notlike '*exit code 3*') { throw 'Lifecycle failure must propagate.' }
    } elseif ($caught) { throw $caught }
    if ($script:received.AZURE_ENV_NAME -ne 'test' -or
        $script:arguments[1] -ne '--config' -or $script:arguments[2] -ne '-') { throw 'Expected streamed environment JSON.' }
    $mode = $script:arguments[[array]::IndexOf($script:arguments, '--action') + 1]
    $expected = switch ($case) { Plan { 'plan' }; Export { 'export' }; Drift { 'drift' }; default { 'publish' } }
    if ($mode -ne $expected) { throw "Incorrect lifecycle action: $case" }
    if ($case -eq 'Plan' -and '--plan' -notin $script:arguments) { throw 'Dry-run must persist a preview.' }
    if ($case -eq 'Publish' -and @('--allow-delete', '--revision', '--plan', '--deletions' | Where-Object { $_ -notin $script:arguments }).Count) {
        throw 'Lifecycle options must pass through unchanged.'
    }
}
Write-Host 'PowerShell lifecycle actions, streamed configuration, preview receipts and failure propagation passed.'
