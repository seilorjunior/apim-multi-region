Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'scripts\ps1') -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "$($file.Name): $($errors.Message -join '; ')"
    }
}
. (Join-Path $root 'scripts\ps1\Common.ps1')
if ((Get-RequiredValue @{ TEST_VALUE = 'value' } 'TEST_VALUE') -ne 'value') {
    throw 'Required-value lookup failed.'
}
$failedAsExpected = $false
try { Get-RequiredValue @{} 'MISSING_VALUE' | Out-Null } catch { $failedAsExpected = $_.Exception.Message -like '*Missing MISSING_VALUE*' }
if (-not $failedAsExpected) { throw 'Missing environment values must fail.' }
Assert-Guid '00000000-0000-0000-0000-000000000001' 'test'
$failedAsExpected = $false
try { Assert-Guid 'someone@example.com' 'test' } catch { $failedAsExpected = $_.Exception.Message -like '*GUID*' }
if (-not $failedAsExpected) { throw 'Email must not be accepted as GUID.' }
$origin = @{
    properties = @{
        sharedPrivateLinkResource = @{
            privateLink = @{ id = '/subscriptions/test/resourceGroups/poc/providers/Microsoft.ApiManagement/service/demo' }
            groupId = 'Gateway'
            requestMessage = 'azd:poc:br:profile'
            status = $null
        }
    }
}
Assert-FrontDoorPrivateOrigin $origin $origin.properties.sharedPrivateLinkResource.privateLink.id 'azd:poc:br:profile'
foreach ($case in @(
    @{ Id = '/unexpected/apim'; Marker = 'azd:poc:br:profile' },
    @{ Id = $origin.properties.sharedPrivateLinkResource.privateLink.id; Marker = 'unexpected-marker' }
)) {
    $failedAsExpected = $false
    try { Assert-FrontDoorPrivateOrigin $origin $case.Id $case.Marker } catch {
        $failedAsExpected = $_.Exception.Message -like '*does not match*'
    }
    if (-not $failedAsExpected) { throw 'Unexpected Front Door private origins must fail.' }
}
$origin.properties.sharedPrivateLinkResource.groupId = 'blob'
$failedAsExpected = $false
try { Assert-FrontDoorPrivateOrigin $origin $origin.properties.sharedPrivateLinkResource.privateLink.id 'azd:poc:br:profile' } catch {
    $failedAsExpected = $_.Exception.Message -like '*does not match*'
}
if (-not $failedAsExpected) { throw 'A non-Gateway Private Link group must fail.' }
$deniedBody = '{"statusCode":403,"message":"public network access on apim-test is disabled"}'
Assert-ApimPublicAccessBlocked -StatusCode 403 -Content $deniedBody -ApimName 'apim-test'
Assert-ApimPublicAccessBlocked -StatusCode 404 -Content $deniedBody -ApimName 'apim-test'
foreach ($case in @(
    @{ Status = 200; Body = $deniedBody; Name = 'apim-test' },
    @{ Status = 403; Body = 'Forbidden'; Name = 'apim-test' },
    @{ Status = 403; Body = '{"statusCode":403,"message":"Invalid Front Door header"}'; Name = 'apim-test' },
    @{ Status = 403; Body = $deniedBody; Name = 'other-apim' },
    @{ Status = 404; Body = '{"statusCode":404,"message":"Resource not found"}'; Name = 'apim-test' },
    @{ Status = 404; Body = '{"statusCode":403,"message":"Invalid Front Door header"}'; Name = 'apim-test' },
    @{ Status = 404; Body = $deniedBody; Name = 'other-apim' }
)) {
    $failedAsExpected = $false
    try { Assert-ApimPublicAccessBlocked -StatusCode $case.Status -Content $case.Body -ApimName $case.Name } catch {
        $failedAsExpected = $_.Exception.Message -like '*not confirmed blocked*'
    }
    if (-not $failedAsExpected) { throw 'Only an explicit public network denial may pass the direct APIM test.' }
}
$commonManifest = $null
foreach ($region in @('brazilsouth', 'eastus', 'westus2')) {
    $manifest = New-DemoManifest -Region $region -BackendIp '10.10.3.250' -ApimSubnet '10.10.4.0/24'
    if ($manifest -cmatch '__[A-Z_]+__' -or
        -not $manifest.Contains("value: `"$region`"") -or
        -not $manifest.Contains('azure-load-balancer-internal: "true"') -or
        -not $manifest.Contains('loadBalancerSourceRanges:') -or
        -not $manifest.Contains('    import json')) {
        throw "Manifest rendering failed for $region."
    }
    $normalizedManifest = $manifest.Replace("value: `"$region`"", 'value: "__REGION__"')
    if ($null -ne $commonManifest -and $normalizedManifest -cne $commonManifest) {
        throw 'Both clusters must receive the same demo code and workload configuration, apart from the region.'
    }
    $commonManifest = $normalizedManifest
}
$failedAsExpected = $false
try { New-DemoManifest -Region 'eastus;invalid' -BackendIp '10.10.3.250' -ApimSubnet '10.10.4.0/24' | Out-Null } catch { $failedAsExpected = $_.Exception.Message -eq 'Invalid region name.' }
if (-not $failedAsExpected) { throw 'Invalid region must fail before shell execution.' }
foreach ($cidr in @('999.999.999.999/24', '10.10.4.1/24', '10.10.4.0/33', '10.10.4.0/-1', '10.10.4/24', '::1/24', '10.10.4.0/19', '10.10.4.0/24/1')) {
    $failedAsExpected = $false
    try { New-DemoManifest -Region eastus -BackendIp '10.10.3.250' -ApimSubnet $cidr | Out-Null } catch {
        $failedAsExpected = $_.Exception.Message -like 'Invalid APIM subnet CIDR*'
    }
    if (-not $failedAsExpected) { throw "Invalid CIDR accepted: $cidr" }
}
foreach ($cidr in @('10.10.0.0/20', '10.10.4.0/24', '10.10.4.0/32')) {
    $null = New-DemoManifest -Region eastus -BackendIp '10.10.3.250' -ApimSubnet $cidr
}
$digestImage = 'ghcr.io/example/demo@sha256:' + ('a' * 64)
$manifest = New-DemoManifest -Region eastus -BackendIp '10.10.3.250' -ApimSubnet '10.10.4.0/24' -Image $digestImage
if (-not $manifest.Contains($digestImage) -or $manifest.Contains('ConfigMap') -or $manifest.Contains('mountPath: /app') -or $manifest -cmatch '__[A-Z_]+__') {
    throw 'Immutable image must not be overridden by ConfigMap source or unresolved placeholders.'
}
$failedAsExpected = $false
try { New-DemoManifest -Region eastus -BackendIp '10.10.3.250' -ApimSubnet '10.10.4.0/24' -Image 'ghcr.io/example/demo:latest' | Out-Null } catch {
    $failedAsExpected = $_.Exception.Message -like '*pinned by sha256*'
}
if (-not $failedAsExpected) { throw 'Mutable application image must fail.' }
if ((Resolve-RegionKey region1) -ne 'br' -or (Resolve-RegionKey region2) -ne 'us') { throw 'Neutral aliases must preserve resource identity.' }
$operations = @{
    DEPLOYMENT_PROFILE = 'poc'; MONITORING_MODE = 'Disabled'; ALERTS_MODE = 'Disabled'
    REGION1_ZONES = 'none'; REGION2_ZONES = 'none'; ALERT_ACTION_GROUP_ID = 'none'
}
Assert-OperationsSettings $operations
$production = @{
    DEPLOYMENT_PROFILE = 'production'; MONITORING_MODE = 'Enabled'; ALERTS_MODE = 'Enabled'
    REGION1_ZONES = '1,2'; REGION2_ZONES = '1,2,3'; DEMO_IMAGE = $digestImage
    ALERT_ACTION_GROUP_ID = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Insights/actionGroups/operations'
}
Assert-OperationsSettings $production
foreach ($change in @(
    @{ DEPLOYMENT_PROFILE = 'typo' }, @{ REGION1_ZONES = 'none' }, @{ REGION2_ZONES = '1,1' },
    @{ REGION1_ZONES = '1,4' }, @{ MONITORING_MODE = 'Disabled' }, @{ ALERTS_MODE = 'Disabled' },
    @{ ALERT_ACTION_GROUP_ID = 'none' }, @{ DEMO_IMAGE = 'example:latest' }
)) {
    $invalid = $production.Clone()
    foreach ($key in $change.Keys) { $invalid[$key] = $change[$key] }
    $failedAsExpected = $false
    try { Assert-OperationsSettings $invalid } catch { $failedAsExpected = $true }
    if (-not $failedAsExpected) { throw "Invalid production configuration accepted: $($change.Keys -join ', ')" }
}
$originalCommand = (Get-Command Invoke-CheckedCommand).ScriptBlock
$originalSubscription = $script:ProjectSubscriptionId
try {
    function Invoke-CheckedCommand {
        param([string]$Command, [string[]]$Arguments)
        $script:capturedArguments = $Arguments
        return '{}'
    }
    $script:ProjectSubscriptionId = '00000000-0000-0000-0000-000000000001'
    Invoke-AzJson @('ad', 'group', 'show', '--group', 'test') | Out-Null
    if ('--subscription' -in $script:capturedArguments) {
        throw 'Tenant-scoped Entra commands must not receive a subscription argument.'
    }
    Invoke-AzJson @('provider', 'list') | Out-Null
    if ('--subscription' -notin $script:capturedArguments -or
        $script:ProjectSubscriptionId -notin $script:capturedArguments) {
        throw 'ARM commands must retain the explicit subscription.'
    }
} finally {
    Set-Item -Path Function:\Invoke-CheckedCommand -Value $originalCommand
    $script:ProjectSubscriptionId = $originalSubscription
}
$failedAsExpected = $false
try { Invoke-CheckedCommand pwsh @('-NoProfile', '-Command', 'exit 9') | Out-Null } catch [System.InvalidOperationException] { $failedAsExpected = $_.Exception.Message -like '*exit code 9*' }
if (-not $failedAsExpected) { throw 'Native command failure must propagate.' }
Write-Host 'PowerShell syntax, input validation, native failure handling and manifest rendering passed.'
