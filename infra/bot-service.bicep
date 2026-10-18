// Azure Bot Service resource that proxies Microsoft 365 / Teams channel traffic to the
// Foundry hosted agent's Activity Protocol endpoint.
// Source: https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network
param botName string
param displayName string

@description('Agent identity client ID (instance_identity.client_id from GET /agents/{name}).')
param msaAppId string

@description('Microsoft Entra tenant ID.')
param tenantId string

@description('https://<account>.services.ai.azure.com/api/projects/<project>/agents/<agent>/endpoint/protocols/activityProtocol?api-version=v1 (api-version is required for the private-network Activity route)')
param endpoint string

param botServiceSku string = 'F0'

param tags object = {}

resource botService 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botName
  kind: 'azurebot'
  location: 'global'
  tags: tags
  sku: {
    name: botServiceSku
  }
  properties: {
    displayName: displayName
    endpoint: endpoint
    msaAppId: msaAppId
    msaAppTenantId: tenantId
    msaAppType: 'SingleTenant'
    publicNetworkAccess: 'Disabled'
  }
}

resource botServiceMsTeamsChannel 'Microsoft.BotService/botServices/channels@2021-03-01' = {
  parent: botService
  location: 'global'
  name: 'MsTeamsChannel'
  properties: {
    channelName: 'MsTeamsChannel'
  }
}

output botServiceId string = botService.id
