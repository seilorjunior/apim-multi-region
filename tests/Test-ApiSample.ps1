. (Join-Path $PSScriptRoot '..\scripts\ps1\Common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\ps1\Failover.ps1')
function Invoke-WebRequest {
    param($Uri, $TimeoutSec, [switch]$SkipHttpErrorCheck)
    if ($script:case -eq 'NetworkError') { throw [System.Net.Http.HttpRequestException]::new('Connection failed.') }
    $content = '{"service":"regional-demo","region":"eastus"}'
    $status = 200
    $header = 'eastus'
    switch ($script:case) {
        HttpError { $status = 503 }
        InvalidJson { $content = 'bad-json' }
        InvalidShape { $content = '[]' }
        MissingService { $content = '{"region":"eastus"}' }
        WrongRegion { $content = '{"service":"regional-demo","region":"unexpected"}' }
        WrongHeader { $header = 'westus2' }
    }
    return @{ StatusCode = $status; Content = $content; Headers = @{ 'X-Served-Region' = $header; 'X-Correlation-ID' = 'request-id' } }
}
foreach ($case in @('Success', 'HttpError', 'InvalidJson', 'InvalidShape', 'MissingService', 'WrongRegion', 'WrongHeader', 'NetworkError')) {
    $script:case = $case
    $sample = Get-ApiSample -Uri 'https://test.example/demo/' -AllowedRegions @('eastus', 'westus2')
    if ($sample.Success -ne ($case -eq 'Success')) { throw "Incorrect success classification for $case." }
    if (-not $sample.Success -and [string]::IsNullOrWhiteSpace($sample.Error)) { throw "Missing error evidence for $case." }
    if ($sample.LatencyMs -lt 0 -or -not $sample.TimestampUtc) { throw 'Invalid measurement shape.' }
}
Write-Host 'API sample status, contract, network error and timing tests passed (8 scenarios).'
