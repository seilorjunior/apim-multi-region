[CmdletBinding()]
param(
    [ValidateRange(1, 100)][int]$Samples = 10,
    [string]$ExpectedRegion,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 3
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$values = Get-ProjectEnvironment
$script:ProjectSubscriptionId = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$apiUrl = Get-RequiredValue $values 'API_URL'
$healthUrl = Get-RequiredValue $values 'API_HEALTH_URL'
$regions = @(Get-RegionalSettings $values)
$allowedRegions = @($regions | ForEach-Object Location)
if ($ExpectedRegion -and $ExpectedRegion -notin $allowedRegions) {
    throw "ExpectedRegion must be one of: $($allowedRegions -join ', ')"
}
foreach ($region in $regions) {
    $apim = Invoke-AzJson -Arguments @('apim', 'show', '--name', $region.ApimName, '--resource-group', $region.ResourceGroup)
    if ($apim.publicNetworkAccess -ne 'Disabled') {
        throw "Public gateway access is enabled: $($region.ApimName)"
    }
    $cluster = Invoke-AzJson -Arguments @('aks', 'show', '--name', $region.AksName, '--resource-group', $region.ResourceGroup)
    if (-not $cluster.apiServerAccessProfile.enablePrivateCluster -or -not $cluster.disableLocalAccounts) {
        throw "AKS private/admin configuration is invalid: $($region.AksName)"
    }
    $direct = Invoke-WebRequest -Uri "https://$($region.ApimName).azure-api.net/demo/" `
        -Headers @{ 'X-Azure-FDID' = (Get-RequiredValue $values 'FRONT_DOOR_ID') } `
        -SkipHttpErrorCheck -TimeoutSec 30
    Assert-ApimPublicAccessBlocked -StatusCode $direct.StatusCode -Content $direct.Content -ApimName $region.ApimName
    Write-Host "Verified private gateway and AKS configuration: $($region.Location); direct public HTTP $($direct.StatusCode)."
}
$results = for ($index = 0; $index -lt $Samples; $index++) {
    $response = Invoke-WebRequest -Uri "$($apiUrl)?request=$([guid]::NewGuid())" -TimeoutSec 30
    $body = $response.Content | ConvertFrom-Json
    $region = $body.region
    if ($response.StatusCode -ne 200 -or $body.service -ne 'regional-demo' -or
        $region -notin $allowedRegions -or $response.Headers['X-Served-Region'] -ne $region) {
        throw 'Invalid response shape or mismatched regional header.'
    }
    Assert-Guid ([string]($response.Headers['X-Correlation-ID'] -join '')) 'X-Correlation-ID'
    if ($ExpectedRegion -and $region -ne $ExpectedRegion) {
        throw "Expected $ExpectedRegion; received $region. Wait for health convergence and retry."
    }
    [pscustomobject]@{ Sample = $index + 1; Status = $response.StatusCode; Region = $region }
    if ($index -lt $Samples - 1) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}
$health = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 30
$healthBody = $health.Content | ConvertFrom-Json
if ($health.StatusCode -ne 200 -or $healthBody.status -ne 'ok' -or $healthBody.region -notin $allowedRegions -or
    $health.Headers['X-Served-Region'] -ne $healthBody.region -or
    ($ExpectedRegion -and $healthBody.region -ne $ExpectedRegion)) {
    throw 'Invalid Front Door health response.'
}
$results | Format-Table -AutoSize
Write-Host 'Samples passed. Seeing one region in active-active mode is not proof of failure; Front Door considers latency.'
