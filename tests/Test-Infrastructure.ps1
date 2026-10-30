Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\ps1\Common.ps1')

function Find-TemplateResources {
    param([System.Collections.IDictionary]$Template)
    if (-not $Template.Contains('resources')) { return }
    $resources = if ($Template.resources -is [System.Collections.IDictionary]) {
        @($Template.resources.Values)
    } else {
        @($Template.resources)
    }
    foreach ($resource in $resources) {
        if (-not $resource.Contains('existing') -or -not $resource.existing) {
            $resource
        }
        if ($resource.type -eq 'Microsoft.Resources/deployments' -and
            $resource.properties.Contains('template')) {
            Find-TemplateResources $resource.properties.template
        }
    }
}

$mainJson = Invoke-CheckedCommand bicep @('build', (Join-Path $root 'infra\main.bicep'), '--stdout')
$main = $mainJson -join "`n" | ConvertFrom-Json -AsHashtable
if (-not $main.outputs.API_URL.value.Contains('https://{0}/demo/') -or
    $main.outputs.API_HEALTH_URL.value -cne $main.outputs.API_URL.value.Replace('/demo/', '/demo/health/ready')) {
    throw 'API and health outputs must use the same HTTPS Front Door hostname and demo routes.'
}
$resources = @(Find-TemplateResources $main)
$apim = @($resources | Where-Object type -EQ 'Microsoft.ApiManagement/service')
if ($apim.Count -ne 2 -or @($apim | Where-Object { $_.sku.name -notmatch 'sku' -and $_.sku.name -ne 'StandardV2' }).Count -gt 0) {
    throw 'Expected two APIM deployments with parameterized StandardV2 SKU.'
}
$apimDeployments = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Resources/deployments' -and
    $_.properties.Contains('parameters') -and $_.properties.parameters.Contains('sku')
})
if ($apimDeployments.Count -ne 2 -or
    @($apimDeployments | Where-Object { $_.properties.parameters.sku.value -ne 'StandardV2' }).Count -gt 0) {
    throw 'Both regional APIM modules must explicitly select StandardV2.'
}
$aks = @($resources | Where-Object type -EQ 'Microsoft.ContainerService/managedClusters')
if ($aks.Count -ne 2) { throw 'Expected two AKS deployments.' }
foreach ($cluster in $aks) {
    if (-not $cluster.properties.apiServerAccessProfile.enablePrivateCluster -or
        $cluster.properties.apiServerAccessProfile.enablePrivateClusterPublicFQDN -or
        -not $cluster.properties.disableLocalAccounts -or
        -not $cluster.properties.aadProfile.enableAzureRBAC -or
        $cluster.properties.agentPoolProfiles[0].enableNodePublicIP) {
        throw 'AKS private configuration was weakened.'
    }
}
$origins = @($resources | Where-Object type -EQ 'Microsoft.Cdn/profiles/originGroups/origins')
if ($origins.Count -ne 1 -or
    $origins[0].properties.sharedPrivateLinkResource.groupId -ne 'Gateway' -or
    -not $origins[0].properties.enforceCertificateNameCheck) {
    throw 'Origin loop must enforce direct APIM Private Link and TLS validation.'
}
$route = @($resources | Where-Object type -EQ 'Microsoft.Cdn/profiles/afdEndpoints/routes')
if ($route.Count -ne 1 -or $route[0].properties.forwardingProtocol -ne 'HttpsOnly') {
    throw 'Front Door must use HTTPS to the gateways.'
}
$forbidden = @($resources | Where-Object {
    $_.type -in @('Microsoft.Network/privateLinkServices', 'Microsoft.Compute/virtualMachineScaleSets')
})
if ($forbidden.Count -gt 0) {
    throw 'Unexpected intermediary proxy infrastructure.'
}
$parameters = Get-Content -LiteralPath (Join-Path $root 'infra\main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
foreach ($parameter in $parameters.parameters.Keys) {
    if (-not $main.parameters.Contains($parameter)) {
        throw "Unknown azd parameter: $parameter"
    }
}
$gatewayJson = Invoke-CheckedCommand bicep @('build', (Join-Path $root 'infra\gateway.bicep'), '--stdout')
$gateway = $gatewayJson -join "`n" | ConvertFrom-Json -AsHashtable
$gatewayResources = @(Find-TemplateResources $gateway)
$api = @($gatewayResources | Where-Object type -EQ 'Microsoft.ApiManagement/service/apis')
if ($api.Count -ne 1 -or $api[0].properties.path -ne 'demo' -or
    $api[0].properties.subscriptionRequired -ne $false -or
    $api[0].properties.protocols[0] -ne 'https' -or
    $api[0].properties.serviceUrl -notlike '*http://*') {
    throw 'Expected HTTPS gateway with explicitly private HTTP PoC backend.'
}
$operations = @($gatewayResources | Where-Object type -EQ 'Microsoft.ApiManagement/service/apis/operations')
foreach ($path in @('/', '/health/ready')) {
    if (@($operations | Where-Object {
        $_.properties.method -eq 'GET' -and $_.properties.urlTemplate -eq $path
    }).Count -ne 1) {
        throw "Expected a GET operation for $path on the demo API."
    }
}
$policy = @($gatewayResources | Where-Object type -EQ 'Microsoft.ApiManagement/service/apis/policies')
if ($policy.Count -ne 1 -or $policy[0].properties.value -notlike "*parameters('frontDoorId')*" -or
    $policy[0].properties.value -notlike "*parameters('region')*") {
    throw 'Gateway policy must substitute the actual Front Door ID and region.'
}
if ($main.parameters.deploymentProfile.defaultValue -ne 'poc' -or
    $main.parameters.monitoringMode.defaultValue -ne 'Disabled' -or
    $main.parameters.alertsMode.defaultValue -ne 'Disabled') {
    throw 'Production costs and monitoring must remain explicit opt-ins.'
}
foreach ($cluster in $aks) {
    if ($cluster.sku.tier -cne "[if(parameters('productionMode'), 'Standard', 'Free')]" -or
        $cluster.properties.agentPoolProfiles[0].count -cne "[if(parameters('productionMode'), max(3, parameters('nodeCount')), parameters('nodeCount'))]" -or
        $cluster.properties.agentPoolProfiles[0].availabilityZones -cne "[if(parameters('productionMode'), parameters('availabilityZones'), createArray())]") {
        throw 'Production must use Standard tier, at least three nodes and explicit zones without changing PoC defaults.'
    }
}
$apimLogs = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Insights/diagnosticSettings' -and $_.name -eq 'gateway-logs'
})
if ($apimLogs.Count -ne 2 -or @($apimLogs | Where-Object {
    $_.condition -ne "[parameters('enableMonitoring')]" -or $_.properties.logs[0].category -ne 'GatewayLogs' -or
    $_.properties.logAnalyticsDestinationType -ne 'Dedicated'
}).Count -gt 0) { throw 'Opt-in APIM gateway diagnostics are required in each region.' }
$podAlerts = @($resources | Where-Object type -EQ 'Microsoft.Insights/scheduledQueryRules')
$collectionRules = @($resources | Where-Object type -EQ 'Microsoft.Insights/dataCollectionRules')
$collectionAssociations = @($resources | Where-Object type -EQ 'Microsoft.Insights/dataCollectionRuleAssociations')
if ($collectionRules.Count -ne 2 -or $collectionAssociations.Count -ne 2 -or @($collectionRules | Where-Object {
    $_.condition -ne "[parameters('enableMonitoring')]" -or
    $_.properties.dataSources.extensions[0].streams[0] -ne 'Microsoft-ContainerInsights-Group-Default' -or
    -not $_.properties.dataSources.extensions[0].extensionSettings.dataCollectionSettings.enableContainerLogV2
}).Count -gt 0) { throw 'Container Insights requires explicit collection rules and AKS associations.' }
$ingestionRoles = @($resources | Where-Object {
    $_.type -eq 'Microsoft.Authorization/roleAssignments' -and
    $_.properties.roleDefinitionId -like '*3913510d-42f4-4e42-8a64-420c390055eb*'
})
if ($ingestionRoles.Count -ne 2 -or @($ingestionRoles | Where-Object {
    $_.scope -notlike '*Microsoft.Insights/dataCollectionRules*' -or
    $_.properties.principalId -notlike '*omsagent.identity.objectId*'
}).Count -gt 0) { throw 'Monitoring ingestion must use the addon identity with DCR-scoped permissions.' }
if ($podAlerts.Count -ne 2 -or @($podAlerts | Where-Object {
    $_.properties.criteria.allOf[0].threshold -ne 0 -or
    $_.properties.criteria.allOf[0].query -notlike '*RunningPods < 2*' -or
    $_.properties.actions.actionGroups[0] -ne "[parameters('alertActionGroupId')]"
}).Count -gt 0) { throw 'Regional workload alerts must count missing running pods and route to an action group.' }
$frontDoorDeployment = $resources | Where-Object {
    $_.type -eq 'Microsoft.Resources/deployments' -and $_.properties.Contains('template') -and
    $_.properties.template.Contains('variables') -and $_.properties.template.variables.Contains('alertDefinitions')
} | Select-Object -First 1
$definitions = $frontDoorDeployment.properties.template.variables.alertDefinitions
foreach ($expected in @(
    @{ Metric = 'OriginHealthPercentage'; Threshold = 90; Operator = 'LessThan' },
    @{ Metric = 'Percentage5XX'; Threshold = 5; Operator = 'GreaterThan' },
    @{ Metric = 'TotalLatency'; Threshold = 2000; Operator = 'GreaterThan' }
)) {
    if (@($definitions | Where-Object {
        $_.metric -eq $expected.Metric -and $_.threshold -eq $expected.Threshold -and $_.operator -eq $expected.Operator
    }).Count -ne 1) { throw "Missing or incorrect Front Door SLO threshold: $($expected.Metric)" }
}
if ($policy[0].properties.value -notlike '*context.RequestId.ToString()*' -or
    $policy[0].properties.value -notlike '*X-Correlation-ID*') { throw 'Gateway request correlation is required.' }
foreach ($output in @('REGION1_LOCATION', 'REGION2_LOCATION', 'REGION1_APIM_ID', 'REGION2_APIM_ID')) {
    if (-not $main.outputs.Contains($output)) { throw "Missing neutral alias: $output" }
}
Write-Host 'Compiled ARM contracts passed: private topology, PoC defaults, production profile, monitoring, alerts and correlation.'
