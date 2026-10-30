function Get-DemoDeployment {
    param([Parameter(Mandatory)]$Region)
    $result = Invoke-AzJson @('aks', 'command', 'invoke', '--resource-group', $Region.ResourceGroup,
        '--name', $Region.AksName, '--command', 'kubectl -n private-poc get deployment regional-demo -o json')
    if (-not $result -or $result.exitCode -ne 0) { throw "Cannot inspect deployment on $($Region.AksName)." }
    return ($result.logs | ConvertFrom-Json -AsHashtable)
}

function Set-DemoReplicas {
    param([Parameter(Mandatory)]$Region, [ValidateRange(0, 100)][int]$Replicas)
    $command = "kubectl -n private-poc scale deployment/regional-demo --replicas=$Replicas"
    if ($Replicas -gt 0) {
        $command += ' && kubectl -n private-poc rollout status deployment/regional-demo --timeout=180s'
    } else {
        $command += ' && kubectl -n private-poc wait --for=delete pod -l app=regional-demo --timeout=180s'
    }
    Invoke-AksChecked -ResourceGroup $Region.ResourceGroup -ClusterName $Region.AksName -Command $command
}

function Get-ApiSample {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string[]]$AllowedRegions)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $sample = [ordered]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Status = 0
        Region = $null
        CorrelationId = $null
        LatencyMs = 0.0
        Success = $false
        Error = $null
    }
    try {
        $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
        $response = Invoke-WebRequest -Uri "$Uri${separator}request=$([guid]::NewGuid())" -TimeoutSec 10 -SkipHttpErrorCheck
        $sample.Status = [int]$response.StatusCode
        if ($sample.Status -ne 200) {
            $sample.Error = "HTTP $($sample.Status)"
        } elseif (-not (Test-Json -Json $response.Content -ErrorAction SilentlyContinue)) {
            $sample.Error = 'Response is not valid JSON.'
        } else {
            $body = $response.Content | ConvertFrom-Json -AsHashtable
            if ($body -isnot [System.Collections.IDictionary] -or -not $body.Contains('service') -or
                $body.service -ne 'regional-demo' -or -not $body.Contains('region') -or
                $body.region -notin $AllowedRegions -or $response.Headers['X-Served-Region'] -ne $body.region) {
                $sample.Error = 'Invalid response contract or regional header.'
            } else {
                $sample.Region = $body.region
                $sample.CorrelationId = [string]($response.Headers['X-Correlation-ID'] -join '')
                $sample.Success = $true
            }
        }
    } catch [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException], [System.TimeoutException] {
        $sample.Error = $_.Exception.Message
    }
    $sample.LatencyMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
    return [pscustomobject]$sample
}

function Invoke-MeasuredFailover {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][ValidateSet('br', 'us', 'region1', 'region2')][string]$Region,
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 300,
        [ValidateRange(1, 30)][int]$IntervalSeconds = 3,
        [ValidateRange(1, 100)][int]$ConsecutiveSuccesses = 5
    )
    $script:ProjectSubscriptionId = Get-RequiredValue $Values 'AZURE_SUBSCRIPTION_ID'
    $uri = Get-RequiredValue $Values 'API_URL'
    if (-not $uri.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { throw 'API_URL must use HTTPS.' }
    $regions = @(Get-RegionalSettings $Values)
    $target = $regions | Where-Object Key -EQ (Resolve-RegionKey $Region)
    $survivor = $regions | Where-Object Key -NE $target.Key
    $originalReplicas = 0
    foreach ($entry in $regions) {
        $deployment = Get-DemoDeployment $entry
        if (-not $deployment.spec.Contains('replicas') -or $deployment.spec.replicas -lt 1 -or
            $deployment.spec.replicas -gt 100 -or -not $deployment.status.Contains('readyReplicas') -or
            $deployment.status.readyReplicas -ne $deployment.spec.replicas) {
            throw "Both deployments must be available before a fault: $($entry.Location)."
        }
        if ($entry.Key -eq $target.Key) { $originalReplicas = [int]$deployment.spec.replicas }
    }
    $allowed = @($regions | ForEach-Object Location)
    $baseline = Get-ApiSample -Uri $uri -AllowedRegions $allowed
    if (-not $baseline.Success) { throw "Baseline failed; no fault injected: $($baseline.Error)" }
    $samples = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $report = [ordered]@{
        SchemaVersion = 1
        Exercise = 'backend-failover-not-regional-DR'
        TargetRegion = $target.Location
        SurvivingRegion = $survivor.Location
        OriginalReplicas = $originalReplicas
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        TimeoutSeconds = $TimeoutSeconds
        RequiredConsecutiveSuccesses = $ConsecutiveSuccesses
        Baseline = $baseline
        FaultCommandDurationSeconds = $null
        ObservedConvergenceSeconds = $null
        Restored = $false
        Passed = $false
        Samples = $samples
        Errors = $errors
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Restore even if the fault command times out after Azure accepted it.
        Set-DemoReplicas -Region $target -Replicas 0
        $report.FaultCommandDurationSeconds = $watch.Elapsed.TotalSeconds
        $streak = 0
        while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $sample = Get-ApiSample -Uri $uri -AllowedRegions $allowed
            $samples.Add($sample)
            if ($sample.Success -and $sample.Region -eq $survivor.Location) {
                $streak++
            } else {
                $streak = 0
                Write-Warning "Failover sample: HTTP $($sample.Status), region '$($sample.Region)', error '$($sample.Error)'."
            }
            if ($streak -ge $ConsecutiveSuccesses -and $watch.Elapsed.TotalSeconds -le $TimeoutSeconds) {
                $report.ObservedConvergenceSeconds = $watch.Elapsed.TotalSeconds
                $report.Passed = $true
                break
            }
            Start-Sleep -Seconds $IntervalSeconds
        }
        if (-not $report.Passed) { throw "Failover did not converge within $TimeoutSeconds seconds." }
    } catch {
        $errors.Add($_.Exception.Message)
        Write-Warning "Failover exercise failed: $($_.Exception.Message)"
    } finally {
        try {
            Set-DemoReplicas -Region $target -Replicas $originalReplicas
            $restored = Get-DemoDeployment $target
            if ($restored.spec.replicas -ne $originalReplicas -or $restored.status.readyReplicas -ne $originalReplicas) {
                throw 'Replica restoration was not confirmed.'
            }
            $recovery = Get-ApiSample -Uri $uri -AllowedRegions $allowed
            if (-not $recovery.Success) { throw "Post-restoration API check failed: $($recovery.Error)" }
            $report.Restored = $true
        } catch {
            $errors.Add("RESTORATION FAILED: $($_.Exception.Message)")
            $report.Passed = $false
            Write-Warning "RESTORATION FAILED on $($target.AksName): $($_.Exception.Message). Restore $originalReplicas replicas manually."
        }
        $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        $report.FailedRequests = @($samples | Where-Object { -not $_.Success }).Count
        $report.SampleCount = $samples.Count
        $latencies = @($samples | ForEach-Object LatencyMs | Sort-Object)
        $report.P95LatencyMs = if ($latencies.Count) { $latencies[[int][Math]::Ceiling($latencies.Count * 0.95) - 1] } else { $null }
        $fullPath = [IO.Path]::GetFullPath($OutputPath)
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
        [IO.File]::WriteAllText($fullPath, ($report | ConvertTo-Json -Depth 12))
        Write-Host "Failover evidence: $fullPath"
    }
    if ($errors.Count -gt 0) { throw ($errors -join '; ') }
    return [pscustomobject]$report
}
