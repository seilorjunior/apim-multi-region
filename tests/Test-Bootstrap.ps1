. (Join-Path $PSScriptRoot '..\scripts\ps1\Common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\ps1\Bootstrap.ps1')

$values = @{
    AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000001'
    AZURE_ENV_NAME = 'test'
    FRONT_DOOR_PROFILE_NAME = 'profile'
    FRONT_DOOR_ID = 'fdid'
    AZURE_RESOURCE_GROUP = 'global'
    FRONT_DOOR_ORIGIN_GROUP_NAME = 'origins'
    API_URL = 'https://test.example/demo/'
    API_HEALTH_URL = 'https://test.example/demo/health/ready'
}
foreach ($prefix in @('BRAZIL', 'US')) {
    foreach ($item in @{
        RESOURCE_GROUP = $prefix
        APIM_NAME = "apim-$prefix"
        APIM_ID = "/apim/$prefix"
        AKS_NAME = "aks-$prefix"
        BACKEND_IP = '10.10.3.250'
        APIM_SUBNET = '10.10.4.0/24'
        LOCATION = $(if ($prefix -eq 'BRAZIL') { 'westus2' } else { 'eastus' })
    }.GetEnumerator()) { $values["${prefix}_$($item.Key)"] = $item.Value }
}

function Set-ProjectValue { param($Name, $Value) }
function Invoke-CheckedCommand {
    param($Command, $Arguments)
    if ($script:disabled.Count -ne 2) { throw 'Publication before both gateways were private.' }
    $script:publications++
}
function Invoke-AksChecked {
    param($ResourceGroup, $ClusterName, $Command, $File)
    if ($script:disabled.Count -ne 2) { throw 'Workload published before both gateways were private.' }
    $script:workloads++
}
function Invoke-AzJson {
    param([string[]]$Arguments)
    if ($Arguments[0] -eq 'network') {
        if ($Arguments[2] -eq 'approve') { $script:approvals++; return @{} }
        $id = $Arguments[-1]
        $key = if ($id.EndsWith('BRAZIL')) { 'br' } else { 'us' }
        if (-not $script:polls.ContainsKey($key)) { $script:polls[$key] = 0 }
        $script:polls[$key]++
        if ($script:scenario -eq 'Timeout') { return }
        $status = 'Approved'
        if ($script:scenario -eq 'Pending' -and $script:polls[$key] -eq 1) { $status = 'Pending' }
        if ($script:scenario -in @('Rejected', 'Disconnected') -and $key -eq 'us') { $status = $script:scenario }
        $connection = @{
            id = "/connection/$key"
            properties = @{
                privateEndpoint = @{ id = '/endpoint/test' }
                privateLinkServiceConnectionState = @{ status = $status; description = "azd:test:${key}:profile" }
            }
        }
        if ($script:scenario -eq 'Unexpected') {
            $connection.properties.privateLinkServiceConnectionState.description = 'someone-else'
        }
        $connection
        if ($script:scenario -eq 'Ambiguous') { $connection }
        return
    }
    if ($Arguments[0] -eq 'apim') {
        $name = $Arguments[3]
        $access = if ($script:scenario -eq 'Resume' -or $name -in $script:disabled) { 'Disabled' } else { 'Enabled' }
        if ($script:scenario -eq 'Resume' -and $name -notin $script:disabled) { $script:disabled.Add($name) }
        return @{ publicNetworkAccess = $access }
    }
    if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'show') {
        $key = $Arguments[3].Split('/')[-1]
        $prefix = if ($key -eq 'br') { 'BRAZIL' } else { 'US' }
        $id = if ($script:scenario -eq 'WrongOrigin') { '/wrong' } else { "/apim/$prefix" }
        return @{ properties = @{ sharedPrivateLinkResource = @{
            privateLink = @{ id = $id }; groupId = 'Gateway'; requestMessage = "azd:test:${key}:profile"
        } } }
    }
    if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'update') {
        $script:updates++
        if ($script:scenario -eq 'UpdateFailure') { throw 'Simulated ARM update failure.' }
        if ($script:scenario -ne 'StillPublic') { $script:disabled.Add("apim-$($Arguments[3].Split('/')[-1])") }
        return @{}
    }
    if ($Arguments[0] -eq 'deployment') {
        if ($script:disabled.Count -ne 2) { throw 'API publication before both gateways were private.' }
        if ($script:scenario -eq 'PublishFailure') { throw 'Simulated API publication failure.' }
        return @{}
    }
    throw "Unexpected test command: $($Arguments -join ' ')"
}

foreach ($case in @('Pending', 'Resume', 'Timeout', 'Rejected', 'Disconnected', 'Unexpected', 'Ambiguous', 'WrongOrigin', 'UpdateFailure', 'StillPublic', 'PublishFailure')) {
    $script:scenario = $case
    $script:disabled = [System.Collections.Generic.List[string]]::new()
    $script:polls = @{}
    $script:approvals = 0
    $script:updates = 0
    $script:publications = 0
    $script:workloads = 0
    $caught = $null
    try { Invoke-PrivateBootstrap -Values $values -ApprovalAttempts 2 -PollSeconds 0 } catch { $caught = $_ }
    $expectedFailure = @{
        Timeout = 'approval timed out'
        Rejected = 'connection is Rejected'
        Disconnected = 'connection is Disconnected'
        Unexpected = 'Unexpected or ambiguous'
        Ambiguous = 'Unexpected or ambiguous'
        WrongOrigin = 'origin does not match'
        UpdateFailure = 'Simulated ARM update failure'
        StillPublic = 'public access is not disabled'
        PublishFailure = 'Simulated API publication failure'
    }
    if ($expectedFailure.ContainsKey($case)) {
        if (-not $caught -or $caught.Exception.Message -notlike "*$($expectedFailure[$case])*") {
            throw "Wrong failure for ${case}: $caught"
        }
        if ($case -ne 'PublishFailure' -and ($script:publications -ne 0 -or $script:workloads -ne 0)) {
            throw "Unsafe publication during $case."
        }
    } else {
        if ($caught) { throw $caught }
        if ($script:workloads -ne 2 -or $script:publications -ne 1) { throw "Incomplete bootstrap for $case." }
    }
    if ($case -eq 'Pending' -and $script:approvals -ne 2) { throw 'Pending connections must be approved once per region.' }
    if ($case -eq 'Resume' -and ($script:approvals -ne 0 -or $script:updates -ne 0)) { throw 'Resume must preserve private gateways.' }
    if ($case -eq 'PublishFailure') {
        $previousUpdates = $script:updates
        $previousApprovals = $script:approvals
        $script:scenario = 'Resume'
        Invoke-PrivateBootstrap -Values $values -ApprovalAttempts 2 -PollSeconds 0
        if ($script:updates -ne $previousUpdates -or $script:approvals -ne $previousApprovals -or $script:workloads -ne 3) {
            throw 'Recovery after partial API publication must republish both regions without reopening or reapproving gateways.'
        }
    }
}
Write-Host 'Bootstrap state transitions, publication gates and resume tests passed (12 scenarios).'
