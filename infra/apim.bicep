/*
  Option 2 ingress: Azure API Management as the governed front door for Microsoft 365 / Teams.

    Teams / M365 Copilot -> Azure Bot Service -> APIM (public gateway, VNet-injected)
      -> Foundry private endpoint (10.50.1.x) -> agent Activity Protocol route -> hosted agent

  APIM runs in the spoke (External VNet mode), so it resolves Foundry through the VNet-linked
  private DNS zones and reaches the Activity route over the private endpoint. The agent therefore
  does NOT need enable_m365_public_endpoint; every Foundry API stays private and APIM becomes the
  single, policy-governed public entry point (JWT validation, rate limits, logging).

  Per-agent routes are added by apim-agent-route.bicep (called from scripts/publish-agent.ps1).
  The apim-subnet (with its NSG) is created by network.bicep.
*/
param location string = resourceGroup().location
param namePrefix string = 'jnjm365'
param vnetName string = 'vnet-${namePrefix}'

@description('Foundry project agents base URL: https://<account>.services.ai.azure.com/api/projects/<project>/agents')
param foundryAgentsBaseUrl string

param publisherEmail string
param publisherName string = 'JNJ AI Platform (POC)'
param logAnalyticsWorkspaceId string
param tags object = {}

var apimName = 'apim-${namePrefix}'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

// apim-subnet and its NSG (API Management External-mode rules) are defined in network.bicep.
resource apimSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'apim-subnet'
}

resource apimPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${namePrefix}-apim'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${apimName}-${uniqueString(resourceGroup().id)}'
    }
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'Developer'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnet.id
    }
    publicIpAddressId: apimPip.id
  }
}

// One API for all Microsoft 365 agent routes. Bot Service can't send an APIM subscription key,
// so the API is keyless and each operation validates the Bot Framework JWT instead.
resource m365Api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'm365-agents'
  properties: {
    displayName: 'Microsoft 365 agent channel (Bot Service -> Foundry Activity Protocol)'
    path: 'm365'
    protocols: [
      'https'
    ]
    serviceUrl: foundryAgentsBaseUrl
    subscriptionRequired: false
  }
}

resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output apimName string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output apiPath string = m365Api.properties.path
output publicIp string = apimPip.properties.ipAddress
