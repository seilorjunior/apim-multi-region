[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$PublisherEmail,
    [string]$EnvironmentName = 'poc-apim-private',
    [string]$PublisherName = 'PoC multi-regiao',
    [string]$AksAdminGroupObjectId,
    [Alias('Region1Location')][string]$BrazilLocation = 'brazilsouth',
    [Alias('Region2Location')][string]$UsLocation = 'eastus'
)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Guid $SubscriptionId 'SubscriptionId'
Assert-Guid $TenantId 'TenantId'
if ($EnvironmentName -notmatch '^[a-z][a-z0-9-]{2,23}$') {
    throw 'EnvironmentName must contain 3-24 lowercase letters, digits or hyphens and start with a letter.'
}
if ($AksAdminGroupObjectId) {
    Assert-Guid $AksAdminGroupObjectId 'AksAdminGroupObjectId'
}
$null = [System.Net.Mail.MailAddress]::new($PublisherEmail)
$script:ProjectSubscriptionId = $SubscriptionId
$account = Invoke-AzJson -Arguments @('account', 'show')
if ($account.tenantId -ne $TenantId) {
    throw 'The authenticated subscription does not belong to the supplied tenant.'
}
Push-Location $script:ProjectRoot
try {
    $envPath = Join-Path $script:ProjectRoot ".azure\$EnvironmentName\.env"
    if (Test-Path -LiteralPath $envPath) {
        Invoke-CheckedCommand azd @('env', 'select', $EnvironmentName) | Out-Null
    } else {
        Invoke-CheckedCommand azd @('env', 'new', $EnvironmentName, '--subscription', $SubscriptionId, '--location', $BrazilLocation, '--no-prompt') | Out-Null
    }
    foreach ($item in @{
        AZURE_SUBSCRIPTION_ID = $SubscriptionId
        AZURE_TENANT_ID = $TenantId
        AZURE_LOCATION = $BrazilLocation
        BRAZIL_LOCATION = $BrazilLocation
        US_LOCATION = $UsLocation
        APIM_PUBLISHER_NAME = $PublisherName
        APIM_PUBLISHER_EMAIL = $PublisherEmail
    }.GetEnumerator()) {
        Set-ProjectValue $item.Key $item.Value
    }
    if ($AksAdminGroupObjectId) {
        Set-ProjectValue 'AKS_ADMIN_GROUP_OBJECT_ID' $AksAdminGroupObjectId
    }
    Write-Host "Local azd environment '$EnvironmentName' configured. No Azure resource was provisioned."
    if (-not $AksAdminGroupObjectId) {
        Write-Warning 'AKS_ADMIN_GROUP_OBJECT_ID is still required before azd provision.'
    }
} finally {
    Pop-Location
}
