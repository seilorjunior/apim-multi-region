function Invoke-PrivateBootstrap {
param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
    [ValidateRange(1, 120)][int]$ApprovalAttempts = 120,
    [ValidateRange(0, 60)][int]$PollSeconds = 15
)
$script:ProjectSubscriptionId = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$environmentName = Get-RequiredValue $values 'AZURE_ENV_NAME'
$profileName = Get-RequiredValue $values 'FRONT_DOOR_PROFILE_NAME'
$frontDoorId = Get-RequiredValue $values 'FRONT_DOOR_ID'
$globalResourceGroup = Get-RequiredValue $values 'AZURE_RESOURCE_GROUP'
$originGroup = Get-RequiredValue $values 'FRONT_DOOR_ORIGIN_GROUP_NAME'
$regions = @(Get-RegionalSettings $values)

foreach ($region in $regions) {
    $marker = "azd:${environmentName}:$($region.Key):${profileName}"
    $approved = $false
    for ($attempt = 0; $attempt -lt $ApprovalAttempts; $attempt++) {
        $connections = @(Invoke-AzJson -Arguments @('network', 'private-endpoint-connection', 'list', '--id', $region.ApimId))
        $matches = @($connections | Where-Object { $_.properties.privateLinkServiceConnectionState.description -eq $marker })
        $unexpectedApproved = @($connections | Where-Object {
            $_.properties.privateLinkServiceConnectionState.status -eq 'Approved' -and
            $_.properties.privateLinkServiceConnectionState.description -ne $marker
        })
        if ($unexpectedApproved.Count -gt 0 -or $matches.Count -gt 1) {
            throw "Unexpected or ambiguous private connections on $($region.ApimName). Review them before continuing."
        }
        if ($matches.Count -eq 1) {
            $connection = $matches[0]
            $status = $connection.properties.privateLinkServiceConnectionState.status
            if ($status -eq 'Pending') {
                Write-Host "Approving correlated Private Link request $($connection.id)"
                Write-Host "Private endpoint: $($connection.properties.privateEndpoint.id)"
                Invoke-AzJson -Arguments @(
                    'network', 'private-endpoint-connection', 'approve',
                    '--id', $connection.id, '--description', $marker
                ) | Out-Null
            } elseif ($status -in @('Rejected', 'Disconnected')) {
                throw "Private Link connection is $status on $($region.ApimName)."
            } elseif ($status -ne 'Approved') {
                throw "Unsupported Private Link state: $status"
            }
            $originId = "/subscriptions/$script:ProjectSubscriptionId/resourceGroups/$globalResourceGroup/providers/Microsoft.Cdn/profiles/$profileName/originGroups/$originGroup/origins/$($region.Key)"
            $origin = Invoke-AzJson -Arguments @('resource', 'show', '--ids', $originId, '--api-version', '2025-04-15')
            Assert-FrontDoorPrivateOrigin -Origin $origin -ApimId $region.ApimId -Marker $marker
            if ($status -eq 'Approved') {
                $approved = $true
                break
            }
        }
        Write-Host "Waiting for Private Link on $($region.ApimName)..."
        if ($attempt -lt $ApprovalAttempts - 1) { Start-Sleep -Seconds $PollSeconds }
    }
    if (-not $approved) {
        throw "Private Link approval timed out on $($region.ApimName). No demo API will be published."
    }
    $instance = Invoke-AzJson -Arguments @('apim', 'show', '--name', $region.ApimName, '--resource-group', $region.ResourceGroup)
    if ($instance.publicNetworkAccess -ne 'Disabled') {
        Invoke-AzJson -Arguments @(
            'resource', 'update', '--ids', $region.ApimId, '--api-version', '2024-05-01',
            '--set', 'properties.publicNetworkAccess=Disabled'
        ) | Out-Null
    }
    $verified = Invoke-AzJson -Arguments @('apim', 'show', '--name', $region.ApimName, '--resource-group', $region.ResourceGroup)
    if ($verified.publicNetworkAccess -ne 'Disabled') {
        throw "Gateway public access is not disabled on $($region.ApimName)."
    }
    Set-ProjectValue "APIM_PUBLIC_ACCESS_$($region.Key.ToUpperInvariant())" 'Disabled'
}

# Publish only after both gateways are private.
$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "apim-poc-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $tempDirectory
$manifestPath = Join-Path $tempDirectory 'demo.yaml'
$parametersPath = Join-Path $tempDirectory 'gateway.parameters.json'
$templatePath = Join-Path $tempDirectory 'gateway.json'
try {
    Invoke-CheckedCommand bicep @('build', (Join-Path $script:ProjectRoot 'infra\gateway.bicep'), '--outfile', $templatePath) | Out-Null
    foreach ($region in $regions) {
        $image = if ($values.Contains('DEMO_IMAGE')) { [string]$values.DEMO_IMAGE } else { '' }
        $manifest = New-DemoManifest -Region $region.Location -BackendIp $region.BackendIp -ApimSubnet $region.ApimSubnet -Image $image
        [System.IO.File]::WriteAllText($manifestPath, $manifest)
        $command = "kubectl apply -f demo.yaml && kubectl -n private-poc rollout restart deployment/regional-demo && kubectl -n private-poc rollout status deployment/regional-demo --timeout=180s && kubectl -n private-poc wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}'=$($region.BackendIp) service/regional-demo --timeout=300s"
        Invoke-AksChecked -ResourceGroup $region.ResourceGroup -ClusterName $region.AksName -Command $command -File $manifestPath
        $parameters = @{
            '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters = @{
                apimName = @{ value = $region.ApimName }
                backendIp = @{ value = $region.BackendIp }
                region = @{ value = $region.Location }
                frontDoorId = @{ value = $frontDoorId }
            }
        }
        [System.IO.File]::WriteAllText($parametersPath, ($parameters | ConvertTo-Json -Depth 10))
        Invoke-AzJson -Arguments @(
            'deployment', 'group', 'create', '--resource-group', $region.ResourceGroup,
            '--name', 'private-demo-gateway', '--template-file', $templatePath,
            '--parameters', "@$parametersPath"
        ) | Out-Null
    }
} finally {
    foreach ($file in @($manifestPath, $parametersPath, $templatePath)) {
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file
        }
    }
    Remove-Item -LiteralPath $tempDirectory
}
Write-Host "Demo published at $(Get-RequiredValue $values 'API_URL')"
Write-Host "Health endpoint: $(Get-RequiredValue $values 'API_HEALTH_URL')"
Write-Host 'Allow Front Door health probes/configuration to propagate, then run scripts\ps1\Test-EndToEnd.ps1.'
}
