. (Join-Path $PSScriptRoot 'Common.ps1')
foreach ($command in @('az', 'azd', 'bicep')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $command"
    }
}
$values = Get-ProjectEnvironment
foreach ($item in @{
    DEPLOYMENT_PROFILE = 'poc'
    MONITORING_MODE = 'Disabled'
    ALERTS_MODE = 'Disabled'
    REGION1_ZONES = 'none'
    REGION2_ZONES = 'none'
    ALERT_ACTION_GROUP_ID = 'none'
}.GetEnumerator()) {
    if (-not $values.Contains($item.Key) -or [string]::IsNullOrWhiteSpace([string]$values[$item.Key])) {
        $values[$item.Key] = $item.Value
        Set-ProjectValue $item.Key $item.Value
    }
}
Assert-OperationsSettings $values
$subscription = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$tenant = Get-RequiredValue $values 'AZURE_TENANT_ID'
$adminGroup = Get-RequiredValue $values 'AKS_ADMIN_GROUP_OBJECT_ID'
$environmentName = Get-RequiredValue $values 'AZURE_ENV_NAME'
Assert-Guid $subscription 'AZURE_SUBSCRIPTION_ID'
Assert-Guid $tenant 'AZURE_TENANT_ID'
Assert-Guid $adminGroup 'AKS_ADMIN_GROUP_OBJECT_ID'
if ($environmentName -notmatch '^[a-z][a-z0-9-]{2,23}$') {
    throw 'Invalid AZURE_ENV_NAME: use 3-24 lowercase letters, digits or hyphens, starting with a letter.'
}
foreach ($required in @('APIM_PUBLISHER_NAME', 'APIM_PUBLISHER_EMAIL', 'BRAZIL_LOCATION', 'US_LOCATION', 'AZURE_LOCATION')) {
    $null = Get-RequiredValue $values $required
}
$null = [System.Net.Mail.MailAddress]::new($values.APIM_PUBLISHER_EMAIL)
if ($values.BRAZIL_LOCATION -eq $values.US_LOCATION) {
    throw 'Brazil and US must use different regions.'
}
$script:ProjectSubscriptionId = $subscription
$account = Invoke-AzJson -Arguments @('account', 'show')
if ($account.tenantId -ne $tenant -or $account.state -ne 'Enabled') {
    throw 'Subscription tenant/state does not match the project configuration.'
}
$group = Invoke-AzJson -Arguments @('ad', 'group', 'show', '--group', $adminGroup)
if (-not $group.securityEnabled) {
    throw 'AKS_ADMIN_GROUP_OBJECT_ID must identify an Entra security group.'
}
foreach ($provider in @(
    'Microsoft.ApiManagement', 'Microsoft.Cdn', 'Microsoft.Network',
    'Microsoft.ContainerService', 'Microsoft.Compute', 'Microsoft.ManagedIdentity',
    'Microsoft.OperationalInsights', 'Microsoft.Insights'
)) {
    $registration = Invoke-AzJson -Arguments @('provider', 'show', '--namespace', $provider, '--query', 'registrationState')
    if ($registration -ne 'Registered') {
        throw "Register $provider before provisioning: az provider register --namespace $provider --subscription $subscription --wait"
    }
}
foreach ($key in @('br', 'us')) {
    $resourceGroup = "rg-$environmentName-$key"
    $exists = Invoke-AzJson -Arguments @('group', 'exists', '--name', $resourceGroup)
    $access = 'Enabled'
    if ($exists) {
        if ($values.DEPLOYMENT_PROFILE -eq 'production') {
            $zoneKey = if ($key -eq 'br') { 'REGION1_ZONES' } else { 'REGION2_ZONES' }
            $expectedZones = ($values[$zoneKey].Split(',') | Sort-Object) -join ','
            $clusters = @(Invoke-AzJson -Arguments @('aks', 'list', '--resource-group', $resourceGroup))
            foreach ($cluster in $clusters) {
                if (-not $cluster.Contains('sku') -or -not $cluster.Contains('agentPoolProfiles') -or
                    $cluster.agentPoolProfiles.Count -eq 0 -or
                    -not $cluster.agentPoolProfiles[0].Contains('availabilityZones') -or
                    $cluster.sku.tier -ne 'Standard' -or
                    (($cluster.agentPoolProfiles[0].availabilityZones | Sort-Object) -join ',') -ne $expectedZones) {
                    throw 'Existing clusters need a separately planned zonal node-pool migration. Use a new environment for the production profile.'
                }
            }
        }
        $instances = @(Invoke-AzJson -Arguments @('apim', 'list', '--resource-group', $resourceGroup))
        if ($instances.Count -gt 1) {
            throw "Expected at most one APIM in $resourceGroup."
        }
        if ($instances.Count -eq 1) {
            $access = [string]$instances[0].publicNetworkAccess
            if ($access -notin @('Enabled', 'Disabled')) {
                throw "Cannot determine current public access for APIM in $resourceGroup."
            }
        }
    }
    Set-ProjectValue "APIM_PUBLIC_ACCESS_$($key.ToUpperInvariant())" $access
}
Write-Host 'Preflight complete. Existing Disabled gateway access will be preserved.'
