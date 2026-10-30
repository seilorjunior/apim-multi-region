targetScope = 'resourceGroup'

param name string
param location string
param tags object
param tenantId string
param aksAdminGroupObjectId string
param publisherName string
param publisherEmail string
param apimPublicAccess string
param vnetPrefix string
param aksSubnetPrefix string
param apimSubnetPrefix string
param backendIp string
param nodeCount int
param nodeVmSize string
param productionMode bool = false
param availabilityZones array = []
param enableMonitoring bool = false
param enableAlerts bool = false
param alertActionGroupId string = 'none'

module logs 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'logs'
  params: {
    name: 'log-${name}'
    location: location
    tags: tags
    dataRetention: 30
    dailyQuotaGb: '1'
    enableTelemetry: false
  }
}

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: 'nsg-apim-${name}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowPrivateDemoBackend'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: apimSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: backendIp
          destinationPortRange: '80'
        }
      }
      {
        name: 'AllowKeyVaultDependency'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: 'vnet-${name}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetPrefix]
    }
    subnets: [
      {
        name: 'aks'
        properties: {
          addressPrefix: aksSubnetPrefix
        }
      }
      {
        name: 'apim-integration'
        properties: {
          addressPrefix: apimSubnetPrefix
          networkSecurityGroup: {
            id: apimNsg.id
          }
          delegations: [
            {
              name: 'standard-v2-outbound'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-aks-${name}'
  location: location
  tags: tags
}

resource aksNetworkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, aksIdentity.id, 'network-contributor')
  scope: vnet
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
    principalId: aksIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2025-07-01' = {
  name: 'aks-${name}'
  location: location
  tags: union(tags, { 'azd-service-name': 'demo' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksIdentity.id}': {}
    }
  }
  sku: {
    name: 'Base'
    tier: productionMode ? 'Standard' : 'Free'
  }
  properties: {
    dnsPrefix: 'aks-${name}'
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: tenantId
      adminGroupObjectIDs: [aksAdminGroupObjectId]
    }
    apiServerAccessProfile: {
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: false
      privateDNSZone: 'system'
      disableRunCommand: false
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: productionMode ? max(3, nodeCount) : nodeCount
        availabilityZones: productionMode ? availabilityZones : []
        vmSize: nodeVmSize
        type: 'VirtualMachineScaleSets'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vnetSubnetID: '${vnet.id}/subnets/aks'
        maxPods: 30
        enableNodePublicIP: false
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'azure'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.250.0.0/16'
      dnsServiceIP: '10.250.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    autoUpgradeProfile: {
      upgradeChannel: 'stable'
      nodeOSUpgradeChannel: 'NodeImage'
    }
    addonProfiles: enableMonitoring ? {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logs.outputs.resourceId
          useAADAuth: 'true'
        }
      }
    } : {}
  }
  dependsOn: [aksNetworkRole]
}

module apim 'br/public:avm/res/api-management/service:0.15.0' = {
  name: 'apim'
  params: {
    name: 'apim-${name}'
    location: location
    tags: tags
    publisherName: publisherName
    publisherEmail: publisherEmail
    sku: 'StandardV2'
    skuCapacity: 1
    virtualNetworkType: 'External'
    subnetResourceId: '${vnet.id}/subnets/apim-integration'
    publicNetworkAccess: apimPublicAccess
    enableTelemetry: false
  }
}

resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'regional-logs'
  scope: aks
  properties: {
    workspaceId: logs.outputs.resourceId
    logs: [
      { category: 'kube-apiserver', enabled: true }
    ]
  }
}

resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: 'apim-${name}'
}

resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableMonitoring) {
  name: 'gateway-logs'
  scope: apimService
  properties: {
    workspaceId: logs.outputs.resourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'GatewayLogs', enabled: true }
    ]
  }
  dependsOn: [apim]
}

resource containerCollection 'Microsoft.Insights/dataCollectionRules@2023-03-11' = if (enableMonitoring) {
  name: 'dcr-containers-${name}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: ['Microsoft-ContainerInsights-Group-Default']
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Off'
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'regional-workspace'
          workspaceResourceId: logs.outputs.resourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-ContainerInsights-Group-Default']
        destinations: ['regional-workspace']
      }
    ]
  }
}

resource containerCollectionAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (enableMonitoring) {
  name: 'ContainerInsightsExtension'
  scope: aks
  properties: {
    dataCollectionRuleId: containerCollection!.id
  }
}

resource containerIngestionRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableMonitoring) {
  name: guid(aks.id, 'container-insights-ingestion')
  scope: containerCollection
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: aks.properties.addonProfiles.omsagent.identity.objectId
    principalType: 'ServicePrincipal'
  }
}

resource workloadAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (enableMonitoring && enableAlerts) {
  name: 'demo-pods-${name}'
  location: location
  tags: tags
  properties: {
    displayName: 'Fewer than two running demo pods: ${name}'
    description: 'Running pod count only; readiness and end-to-end availability are covered by Front Door origin probes.'
    enabled: true
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [logs.outputs.resourceId]
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: '''
            KubePodInventory
            | where TimeGenerated > ago(5m) and Namespace == "private-poc" and Name startswith "regional-demo-"
            | summarize arg_max(TimeGenerated, *) by PodUid
            | summarize RunningPods = dcountif(PodUid, PodStatus == "Running")
            | where RunningPods < 2
            '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: [alertActionGroupId]
    }
    autoMitigate: true
  }
}

output apimId string = apim.outputs.resourceId
output apimName string = 'apim-${name}'
output apimHost string = 'apim-${name}.azure-api.net'
output aksName string = aks.name
