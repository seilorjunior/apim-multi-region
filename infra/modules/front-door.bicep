targetScope = 'resourceGroup'

param name string
param location string
param tags object
param environmentName string
param enableAlerts bool = false
param alertActionGroupId string = 'none'
param origins {
  key: string
  apimId: string
  apimHost: string
  location: string
}[]

module logs 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'global-logs'
  params: {
    name: 'log-global-${name}'
    location: location
    tags: tags
    dataRetention: 30
    dailyQuotaGb: '1'
    enableTelemetry: false
  }
}

resource profile 'Microsoft.Cdn/profiles@2025-04-15' = {
  name: 'afd-${name}'
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2025-04-15' = {
  parent: profile
  name: 'api-${name}'
  location: 'global'
  tags: tags
  properties: {
    enabledState: 'Enabled'
  }
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2025-04-15' = {
  parent: profile
  name: 'regional-apis'
  properties: {
    sessionAffinityState: 'Disabled'
    healthProbeSettings: {
      probePath: '/demo/health/ready'
      probeProtocol: 'Https'
      probeRequestType: 'GET'
      probeIntervalInSeconds: 30
    }
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
  }
}

resource regionalOrigins 'Microsoft.Cdn/profiles/originGroups/origins@2025-04-15' = [
  for origin in origins: {
    parent: originGroup
    name: origin.key
    properties: {
      hostName: origin.apimHost
      originHostHeader: origin.apimHost
      httpPort: 80
      httpsPort: 443
      priority: 1
      weight: 1000
      enabledState: 'Enabled'
      enforceCertificateNameCheck: true
      sharedPrivateLinkResource: {
        groupId: 'Gateway'
        privateLink: {
          id: origin.apimId
        }
        privateLinkLocation: origin.location
        requestMessage: 'azd:${environmentName}:${origin.key}:${profile.name}'
      }
    }
  }
]

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2025-04-15' = {
  parent: endpoint
  name: 'api'
  properties: {
    enabledState: 'Enabled'
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: ['Https']
    patternsToMatch: ['/*']
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
  }
  dependsOn: [regionalOrigins]
}

resource waf 'Microsoft.Network/frontDoorWebApplicationFirewallPolicies@2025-03-01' = {
  name: 'waf${replace(name, '-', '')}'
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
          ruleSetAction: 'Block'
        }
      ]
    }
  }
}

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2025-04-15' = {
  parent: profile
  name: 'waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: waf.id
      }
      associations: [
        {
          domains: [
            { id: endpoint.id }
          ]
          patternsToMatch: ['/*']
        }
      ]
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'global-logs'
  scope: profile
  properties: {
    workspaceId: logs.outputs.resourceId
    logs: [
      { category: 'FrontDoorAccessLog', enabled: true }
      { category: 'FrontDoorHealthProbeLog', enabled: true }
      { category: 'FrontDoorWebApplicationFirewallLog', enabled: true }
    ]
  }
}

var alertDefinitions = [
  { name: 'origin-health', metric: 'OriginHealthPercentage', operator: 'LessThan', threshold: 90 }
  { name: 'server-errors', metric: 'Percentage5XX', operator: 'GreaterThan', threshold: 5 }
  { name: 'latency', metric: 'TotalLatency', operator: 'GreaterThan', threshold: 2000 }
]

resource alerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for alert in alertDefinitions: if (enableAlerts) {
    name: '${alert.name}-${name}'
    location: 'global'
    tags: tags
    properties: {
      description: 'Front Door ${alert.metric}; tune threshold to the agreed workload SLO.'
      severity: 1
      enabled: true
      scopes: [profile.id]
      evaluationFrequency: 'PT1M'
      windowSize: 'PT5M'
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            name: alert.name
            metricNamespace: 'Microsoft.Cdn/profiles'
            metricName: alert.metric
            operator: alert.operator
            threshold: alert.threshold
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
            dimensions: alert.metric == 'OriginHealthPercentage' ? [
              { name: 'Origin', operator: 'Include', values: ['*'] }
              { name: 'OriginGroup', operator: 'Include', values: ['*'] }
            ] : []
          }
        ]
      }
      actions: [
        { actionGroupId: alertActionGroupId }
      ]
    }
  }
]

output profileName string = profile.name
output frontDoorId string = profile.properties.frontDoorId
output endpointName string = endpoint.name
output hostName string = endpoint.properties.hostName
