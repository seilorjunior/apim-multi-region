. (Join-Path $PSScriptRoot '..\scripts\ps1\Common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\ps1\ApiOps.ps1')

$values = @{
    AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000001'
    AZURE_ENV_NAME = 'test'
    FRONT_DOOR_PROFILE_NAME = 'profile'
    FRONT_DOOR_ID = 'fdid'
    AZURE_RESOURCE_GROUP = 'global'
    FRONT_DOOR_ORIGIN_GROUP_NAME = 'origins'
}
foreach ($prefix in @('BRAZIL', 'US')) {
    $index = if ($prefix -eq 'BRAZIL') { 10 } else { 20 }
    foreach ($item in @{
        RESOURCE_GROUP = $prefix; APIM_NAME = "apim-$prefix"; APIM_ID = "/apim/$prefix"
        AKS_NAME = "aks-$prefix"; BACKEND_IP = "10.$index.3.250"; APIM_SUBNET = "10.$index.4.0/24"
        LOCATION = $(if ($prefix -eq 'BRAZIL') { 'westus2' } else { 'eastus' })
    }.GetEnumerator()) { $values["${prefix}_$($item.Key)"] = $item.Value }
}
function Invoke-AzJson {
    param([string[]]$Arguments)
    if ($Arguments[0] -eq 'apim') {
        $script:checks.Add($Arguments[3])
        return @{ publicNetworkAccess = $(if ($script:scenario -eq 'PublicUS' -and $Arguments[3] -eq 'apim-US') { 'Enabled' } else { 'Disabled' }) }
    }
    if ($Arguments[0] -eq 'network') {
        $key = if ($Arguments[-1].EndsWith('BRAZIL')) { 'br' } else { 'us' }
        $connection = @{ properties = @{ privateLinkServiceConnectionState = @{
            status = $(if ($script:scenario -eq 'PendingUS' -and $key -eq 'us') { 'Pending' } else { 'Approved' })
            description = $(if ($script:scenario -eq 'WrongMarker') { 'other' } else { "azd:test:${key}:profile" })
        } } }
        $connection
        if ($script:scenario -eq 'Ambiguous') { $connection }
        return
    }
    if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'show') {
        $key = $Arguments[3].Split('/')[-1]
        $prefix = if ($key -eq 'br') { 'BRAZIL' } else { 'US' }
        return @{ properties = @{ sharedPrivateLinkResource = @{
            privateLink = @{ id = $(if ($script:scenario -eq 'WrongOrigin') { '/wrong' } else { "/apim/$prefix" }) }
            groupId = 'Gateway'; requestMessage = "azd:test:${key}:profile"
        } } }
    }
    throw "Unexpected Azure mutation or command: $($Arguments -join ' ')"
}
function Invoke-CheckedCommand {
    param($Command, $Arguments)
    if ($Command -ne 'node' -or $Arguments[1] -ne 'publish') { throw 'Expected node APIOps publish.' }
    if ($script:checks.Count -ne 2) { throw 'Publishing before checking both APIMs.' }
    if ($env:COMMIT_ID) { throw 'Sync must not be incremental.' }
    if ($env:AZURE_API_VERSION -cne '2024-05-01') { throw 'Expected the stable APIM management API.' }
    foreach ($forbidden in @('--delete-unmatched', '--commit-id', '--client-secret')) {
        if ($forbidden -in $Arguments) { throw "Unsafe sync option: $forbidden" }
    }
    if (('--dry-run' -in $Arguments) -ne ($script:scenario -eq 'DryRun')) { throw 'Wrong dry-run mode.' }
    $script:paths.Add($Arguments[[array]::IndexOf($Arguments, '--overrides') + 1])
    $config = Get-Content $script:paths[-1] -Raw | ConvertFrom-Json
    $name = $Arguments[[array]::IndexOf($Arguments, '--service-name') + 1]
    $prefix = if ($name -eq 'apim-BRAZIL') { 'BRAZIL' } else { 'US' }
    if ($config.apis[0].name -ne 'regional-demo' -or
        $config.apis[0].properties.serviceUrl -ne "http://$($values["${prefix}_BACKEND_IP"])" -or
        @($config.namedValues | Where-Object name -EQ 'poc-region')[0].properties.value -ne $values["${prefix}_LOCATION"] -or
        @($config.namedValues | Where-Object name -EQ 'poc-front-door-id')[0].properties.value -ne 'fdid') {
        throw 'Incorrect regional overrides.'
    }
    $script:published.Add($name)
    if ($script:scenario -eq 'FailSecond' -and $name -eq 'apim-US') { throw 'Simulated APIOps exit 1.' }
}

$previousCommitId = $env:COMMIT_ID
$previousApiVersion = $env:AZURE_API_VERSION
try {
    foreach ($case in @('Success', 'DryRun', 'PublicUS', 'PendingUS', 'WrongMarker', 'Ambiguous', 'WrongOrigin', 'FailSecond', 'Success')) {
        $script:scenario = $case
        $script:checks = [System.Collections.Generic.List[string]]::new()
        $script:published = [System.Collections.Generic.List[string]]::new()
        $script:paths = [System.Collections.Generic.List[string]]::new()
        $env:COMMIT_ID = 'must-not-limit-sync'
        $env:AZURE_API_VERSION = 'must-be-restored'
        $caught = $null
        try { Invoke-ApimSync -Values $values -DryRun:($case -eq 'DryRun') } catch { $caught = $_ }
        if ($case -in @('Success', 'DryRun')) {
            if ($caught) { throw $caught }
            if (($script:published -join ',') -cne 'apim-BRAZIL,apim-US') { throw 'Both APIMs must be published.' }
        } else {
            $expected = @{
                PublicUS = 'public access is not disabled'; PendingUS = 'correlated approved'
                WrongMarker = 'correlated approved'; Ambiguous = 'correlated approved'
                WrongOrigin = 'origin does not match'; FailSecond = 'Simulated APIOps exit 1'
            }
            if (-not $caught -or $caught.Exception.Message -notlike "*$($expected[$case])*") { throw "Wrong failure for ${case}: $caught" }
            if ($case -ne 'FailSecond' -and $script:published.Count -ne 0) { throw 'Unsafe publication.' }
        }
        if ($env:COMMIT_ID -cne 'must-not-limit-sync') { throw 'COMMIT_ID was not restored.' }
        if ($env:AZURE_API_VERSION -cne 'must-be-restored') { throw 'AZURE_API_VERSION was not restored.' }
        foreach ($path in $script:paths) {
            if (Test-Path -LiteralPath (Split-Path $path)) { throw 'Temporary overrides were not cleaned up.' }
        }
    }
} finally {
    $env:COMMIT_ID = $previousCommitId
    $env:AZURE_API_VERSION = $previousApiVersion
}
Write-Host 'APIOps two-target sync, regional overrides, privacy gates, dry-run, cleanup and retry tests passed.'
