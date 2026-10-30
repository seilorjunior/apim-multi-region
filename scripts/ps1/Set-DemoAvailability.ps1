[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('br', 'us', 'region1', 'region2')][string]$Region,
    [Parameter(Mandatory)][ValidateSet('Available', 'Unavailable')][string]$State
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$values = Get-ProjectEnvironment
$script:ProjectSubscriptionId = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$settings = @(Get-RegionalSettings $values) | Where-Object Key -EQ (Resolve-RegionKey $Region)
$replicas = if ($State -eq 'Available') { 2 } else { 0 }
$command = "kubectl -n private-poc scale deployment/regional-demo --replicas=$replicas"
if ($State -eq 'Available') {
    $command += ' && kubectl -n private-poc rollout status deployment/regional-demo --timeout=180s'
}
Invoke-AksChecked -ResourceGroup $settings.ResourceGroup -ClusterName $settings.AksName -Command $command
Write-Host "Demo in $($settings.Location): $State. No infrastructure was removed."
Write-Host 'Front Door probes take time to detect the transition.'
