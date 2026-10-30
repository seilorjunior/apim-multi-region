targetScope = 'subscription'

@minLength(3)
@maxLength(24)
@description('Lowercase azd environment name: letters, digits and hyphens.')
param environmentName string

param location string
param brazilLocation string = 'brazilsouth'
param usLocation string = 'eastus'

@minLength(36)
@maxLength(36)
param tenantId string

@minLength(36)
@maxLength(36)
param aksAdminGroupObjectId string

@minLength(1)
param publisherName string

@minLength(3)
param publisherEmail string

@allowed(['Enabled', 'Disabled'])
@description('Bootstrap only. The preprovision hook preserves Disabled on existing gateways.')
param brazilApimPublicAccess string = 'Enabled'

@allowed(['Enabled', 'Disabled'])
param usApimPublicAccess string = 'Enabled'

@minValue(2)
@maxValue(5)
param aksNodeCount int = 2

param aksNodeVmSize string = 'Standard_D2s_v4'

@allowed(['poc', 'production'])
param deploymentProfile string = 'poc'

@allowed(['Enabled', 'Disabled'])
param monitoringMode string = 'Disabled'

@allowed(['Enabled', 'Disabled'])
param alertsMode string = 'Disabled'

@description('Comma-separated supported zones for a new production cluster; none for the PoC.')
param region1Zones string = 'none'
param region2Zones string = 'none'
param alertActionGroupId string = 'none'

var suffix = take(uniqueString(subscription().id, environmentName), 10)
var tags = {
  'azd-env-name': environmentName
  workload: 'private-apim-poc'
  lifecycle: 'poc'
}

resource globalRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}-global'
  location: location
  tags: tags
}

resource brazilRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}-br'
  location: brazilLocation
  tags: tags
}

resource usRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${environmentName}-us'
  location: usLocation
  tags: tags
}

module brazil './modules/region.bicep' = {
  name: 'region-br'
  scope: brazilRg
  params: {
    name: '${suffix}-br'
    location: brazilLocation
    tags: tags
    tenantId: tenantId
    aksAdminGroupObjectId: aksAdminGroupObjectId
    publisherName: publisherName
    publisherEmail: publisherEmail
    apimPublicAccess: brazilApimPublicAccess
    vnetPrefix: '10.10.0.0/16'
    aksSubnetPrefix: '10.10.0.0/22'
    apimSubnetPrefix: '10.10.4.0/24'
    backendIp: '10.10.3.250'
    nodeCount: aksNodeCount
    nodeVmSize: aksNodeVmSize
    productionMode: deploymentProfile == 'production'
    availabilityZones: region1Zones == 'none' ? [] : split(region1Zones, ',')
    enableMonitoring: monitoringMode == 'Enabled'
    enableAlerts: alertsMode == 'Enabled'
    alertActionGroupId: alertActionGroupId
  }
}

module unitedStates './modules/region.bicep' = {
  name: 'region-us'
  scope: usRg
  params: {
    name: '${suffix}-us'
    location: usLocation
    tags: tags
    tenantId: tenantId
    aksAdminGroupObjectId: aksAdminGroupObjectId
    publisherName: publisherName
    publisherEmail: publisherEmail
    apimPublicAccess: usApimPublicAccess
    vnetPrefix: '10.20.0.0/16'
    aksSubnetPrefix: '10.20.0.0/22'
    apimSubnetPrefix: '10.20.4.0/24'
    backendIp: '10.20.3.250'
    nodeCount: aksNodeCount
    nodeVmSize: aksNodeVmSize
    productionMode: deploymentProfile == 'production'
    availabilityZones: region2Zones == 'none' ? [] : split(region2Zones, ',')
    enableMonitoring: monitoringMode == 'Enabled'
    enableAlerts: alertsMode == 'Enabled'
    alertActionGroupId: alertActionGroupId
  }
}

module frontDoor './modules/front-door.bicep' = {
  name: 'global-entry'
  scope: globalRg
  params: {
    name: suffix
    location: location
    tags: tags
    environmentName: environmentName
    enableAlerts: alertsMode == 'Enabled'
    alertActionGroupId: alertActionGroupId
    origins: [
      {
        key: 'br'
        apimId: brazil.outputs.apimId
        apimHost: brazil.outputs.apimHost
        location: brazilLocation
      }
      {
        key: 'us'
        apimId: unitedStates.outputs.apimId
        apimHost: unitedStates.outputs.apimHost
        location: usLocation
      }
    ]
  }
}

output AZURE_RESOURCE_GROUP string = globalRg.name
output FRONT_DOOR_PROFILE_NAME string = frontDoor.outputs.profileName
output FRONT_DOOR_ID string = frontDoor.outputs.frontDoorId
output FRONT_DOOR_ENDPOINT_NAME string = frontDoor.outputs.endpointName
output FRONT_DOOR_ORIGIN_GROUP_NAME string = 'regional-apis'
output API_URL string = 'https://${frontDoor.outputs.hostName}/demo/'
output API_HEALTH_URL string = 'https://${frontDoor.outputs.hostName}/demo/health/ready'
output BRAZIL_RESOURCE_GROUP string = brazilRg.name
output BRAZIL_APIM_NAME string = brazil.outputs.apimName
output BRAZIL_APIM_ID string = brazil.outputs.apimId
output BRAZIL_AKS_NAME string = brazil.outputs.aksName
output BRAZIL_BACKEND_IP string = '10.10.3.250'
output BRAZIL_APIM_SUBNET string = '10.10.4.0/24'
output US_RESOURCE_GROUP string = usRg.name
output US_APIM_NAME string = unitedStates.outputs.apimName
output US_APIM_ID string = unitedStates.outputs.apimId
output US_AKS_NAME string = unitedStates.outputs.aksName
output US_BACKEND_IP string = '10.20.3.250'
output US_APIM_SUBNET string = '10.20.4.0/24'
output REGION1_LOCATION string = brazilLocation
output REGION2_LOCATION string = usLocation
output REGION1_RESOURCE_GROUP string = brazilRg.name
output REGION2_RESOURCE_GROUP string = usRg.name
output REGION1_AKS_NAME string = brazil.outputs.aksName
output REGION2_AKS_NAME string = unitedStates.outputs.aksName
output REGION1_APIM_NAME string = brazil.outputs.apimName
output REGION2_APIM_NAME string = unitedStates.outputs.apimName
output REGION1_APIM_ID string = brazil.outputs.apimId
output REGION2_APIM_ID string = unitedStates.outputs.apimId
output REGION1_BACKEND_IP string = '10.10.3.250'
output REGION2_BACKEND_IP string = '10.20.3.250'
output REGION1_APIM_SUBNET string = '10.10.4.0/24'
output REGION2_APIM_SUBNET string = '10.20.4.0/24'
