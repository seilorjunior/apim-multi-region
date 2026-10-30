targetScope = 'resourceGroup'

param apimName string
param backendIp string
param region string
param frontDoorId string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'regional-demo'
  properties: {
    displayName: 'Private regional PoC'
    apiRevision: '1'
    path: 'demo'
    protocols: ['https']
    serviceUrl: 'http://${backendIp}'
    subscriptionRequired: false
  }
}

resource regionOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'region'
  properties: {
    displayName: 'Serving region'
    method: 'GET'
    urlTemplate: '/'
    responses: [
      { statusCode: 200 }
    ]
  }
}

resource readyOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'ready'
  properties: {
    displayName: 'Backend readiness'
    method: 'GET'
    urlTemplate: '/health/ready'
    responses: [
      { statusCode: 200 }
    ]
  }
}

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace('''
      <policies>
        <inbound>
          <base />
          <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Front Door required" ignore-case="true">
            <value>__FRONT_DOOR_ID__</value>
          </check-header>
          <set-header name="X-Correlation-ID" exists-action="override">
            <value>@(context.RequestId.ToString())</value>
          </set-header>
        </inbound>
        <backend>
          <base />
        </backend>
        <outbound>
          <base />
          <set-header name="X-Served-Region" exists-action="override">
            <value>__REGION__</value>
          </set-header>
          <set-header name="Cache-Control" exists-action="override">
            <value>no-store</value>
          </set-header>
          <set-header name="X-Correlation-ID" exists-action="override">
            <value>@(context.RequestId.ToString())</value>
          </set-header>
        </outbound>
        <on-error>
          <base />
          <set-header name="X-Correlation-ID" exists-action="override">
            <value>@(context.RequestId.ToString())</value>
          </set-header>
        </on-error>
      </policies>
      ''', '__FRONT_DOOR_ID__', frontDoorId), '__REGION__', region)
  }
}
