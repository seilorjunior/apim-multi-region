. (Join-Path $PSScriptRoot '..\scripts\ps1\Common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\ps1\Failover.ps1')
$values = @{ AZURE_SUBSCRIPTION_ID = 'test'; API_URL = 'https://test.example/demo/' }
function Get-RegionalSettings {
    param($Values)
    [pscustomobject]@{ Key = 'br'; Location = 'westus2'; AksName = 'aks1' }
    [pscustomobject]@{ Key = 'us'; Location = 'eastus'; AksName = 'aks2' }
}
function Get-DemoDeployment {
    param($Region)
    $replicas = if ($script:scenario -eq 'Unavailable' -and $Region.Key -eq 'us') { 0 } else { 3 }
    return @{ spec = @{ replicas = $replicas }; status = @{ readyReplicas = $replicas } }
}
function Set-DemoReplicas {
    param($Region, $Replicas)
    $script:changes.Add($Replicas)
    if ($script:scenario -eq 'FaultError' -and $Replicas -eq 0) { throw 'Fault command timed out.' }
    if ($script:scenario -eq 'RestoreError' -and $Replicas -gt 0) { throw 'Restore command failed.' }
}
function Get-ApiSample {
    param($Uri, $AllowedRegions)
    $script:requests++
    if ($script:scenario -eq 'SampleError' -and $script:requests -eq 2) { throw 'Unexpected response error.' }
    $success = -not ($script:scenario -eq 'BaselineError' -or ($script:scenario -eq 'Transient' -and $script:requests -eq 2))
    $region = if ($script:scenario -eq 'NoConvergence') { 'westus2' } else { 'eastus' }
    return [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o'); Status = $(if ($success) { 200 } else { 503 })
        Region = $region; LatencyMs = 12.5; Success = $success; Error = $(if ($success) { $null } else { 'HTTP 503' })
    }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "failover-tests-$([guid]::NewGuid().ToString('N')).json"
try {
    foreach ($case in @('Success', 'Transient', 'FaultError', 'SampleError', 'RestoreError', 'NoConvergence', 'Unavailable', 'BaselineError')) {
        $script:scenario = $case
        $script:changes = [System.Collections.Generic.List[int]]::new()
        $script:requests = 0
        $caught = $null
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
        try {
            $null = Invoke-MeasuredFailover -Values $values -Region region1 -OutputPath $temp `
                -TimeoutSeconds 2 -IntervalSeconds 1 -ConsecutiveSuccesses 1
        } catch { $caught = $_ }
        if ($case -in @('Success', 'Transient')) {
            if ($caught) { throw $caught }
            $report = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
            if (-not $report.Passed -or -not $report.Restored -or $report.P95LatencyMs -ne 12.5) { throw "Invalid evidence for $case." }
            if ($case -eq 'Transient' -and $report.FailedRequests -ne 1) { throw 'Transient failure was not counted.' }
        } else {
            $expected = @{
                FaultError = '*Fault command timed out*'; SampleError = '*Unexpected response error*'
                RestoreError = '*RESTORATION FAILED*'; NoConvergence = '*did not converge*'
                Unavailable = '*Both deployments must be available*'; BaselineError = '*Baseline failed*'
            }
            if (-not $caught -or $caught.Exception.Message -notlike $expected[$case]) { throw "Wrong error for ${case}: $caught" }
        }
        if ($case -in @('Unavailable', 'BaselineError')) {
            if ($script:changes.Count -ne 0) { throw 'Unsafe fault despite failed baseline.' }
        } else {
            if ($script:changes.Count -ne 2 -or $script:changes[0] -ne 0 -or $script:changes[1] -ne 3) {
                throw "Original replica count not restored for $case."
            }
            if (-not (Test-Path -LiteralPath $temp)) { throw "Missing failure evidence for $case." }
        }
    }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
}
Write-Host 'Measured failover, preconditions, timeout, evidence and restoration tests passed (8 scenarios).'
