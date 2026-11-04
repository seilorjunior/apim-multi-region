function Invoke-ApimSync {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [switch]$DryRun
    )
    $script:ProjectSubscriptionId = Get-RequiredValue $Values 'AZURE_SUBSCRIPTION_ID'
    $environmentName = Get-RequiredValue $Values 'AZURE_ENV_NAME'
    $profile = Get-RequiredValue $Values 'FRONT_DOOR_PROFILE_NAME'
    $frontDoorId = Get-RequiredValue $Values 'FRONT_DOOR_ID'
    $globalGroup = Get-RequiredValue $Values 'AZURE_RESOURCE_GROUP'
    $originGroup = Get-RequiredValue $Values 'FRONT_DOOR_ORIGIN_GROUP_NAME'
    $regions = @(Get-RegionalSettings $Values)
    foreach ($region in $regions) {
        $instance = Invoke-AzJson @('apim', 'show', '--name', $region.ApimName, '--resource-group', $region.ResourceGroup)
        if ($instance.publicNetworkAccess -ne 'Disabled') {
            throw "Gateway public access is not disabled on $($region.ApimName). Run postprovision first."
        }
        $marker = "azd:${environmentName}:$($region.Key):${profile}"
        $connections = @(Invoke-AzJson @('network', 'private-endpoint-connection', 'list', '--id', $region.ApimId))
        $approved = @($connections | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq 'Approved' })
        if ($approved.Count -ne 1 -or $approved[0].properties.privateLinkServiceConnectionState.description -cne $marker) {
            throw "Expected one correlated approved Private Link connection on $($region.ApimName)."
        }
        $originId = "/subscriptions/$script:ProjectSubscriptionId/resourceGroups/$globalGroup/providers/Microsoft.Cdn/profiles/$profile/originGroups/$originGroup/origins/$($region.Key)"
        $origin = Invoke-AzJson @('resource', 'show', '--ids', $originId, '--api-version', '2025-04-15')
        Assert-FrontDoorPrivateOrigin -Origin $origin -ApimId $region.ApimId -Marker $marker
    }

    $cli = Join-Path $script:ProjectRoot 'node_modules\@azure-tools\apiops-cli\dist\cli\index.js'
    if (-not (Test-Path -LiteralPath $cli)) { throw 'APIOps CLI is missing. Install Node.js 22+ and run npm ci from the repository root.' }
    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "apiops-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $tempDirectory
    $overridePath = Join-Path $tempDirectory 'configuration.json'
    $previousCommitId = $env:COMMIT_ID
    $previousApiVersion = $env:AZURE_API_VERSION
    try {
        # Always reconcile the complete artifact set, including when a CI host sets COMMIT_ID.
        $env:COMMIT_ID = ''
        $env:AZURE_API_VERSION = '2024-05-01'
        foreach ($region in $regions) {
            $overrides = @{
                namedValues = @(
                    @{ name = 'poc-front-door-id'; properties = @{ value = $frontDoorId } }
                    @{ name = 'poc-region'; properties = @{ value = $region.Location } }
                )
                apis = @(@{ name = 'regional-demo'; properties = @{ serviceUrl = "http://$($region.BackendIp)" } })
            }
            [System.IO.File]::WriteAllText($overridePath, ($overrides | ConvertTo-Json -Depth 10))
            $arguments = @($cli, 'publish', '--subscription-id', $script:ProjectSubscriptionId,
                '--resource-group', $region.ResourceGroup, '--service-name', $region.ApimName,
                '--source', (Join-Path $script:ProjectRoot 'apim-artifacts'), '--overrides', $overridePath)
            if ($DryRun) { $arguments += '--dry-run' }
            Write-Host "APIOps sync: $($region.ApimName) ($($region.Location)); dry-run=$DryRun"
            Invoke-CheckedCommand node $arguments | Out-Host
        }
    } finally {
        $env:COMMIT_ID = $previousCommitId
        $env:AZURE_API_VERSION = $previousApiVersion
        if (Test-Path -LiteralPath $overridePath) { Remove-Item -LiteralPath $overridePath }
        Remove-Item -LiteralPath $tempDirectory
    }
}
