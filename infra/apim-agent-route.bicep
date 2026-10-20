/*
  Per-agent Microsoft 365 route on the shared APIM front door (Option 2 ingress).

    POST https://<apim>.azure-api.net/m365/<agentName>/activity
      -> validate-jwt: Bot Framework channel token whose audience is the agent identity client ID
      -> rate limit per agent
      -> POST <project>/agents/<agentName>/endpoint/protocols/activityProtocol?api-version=v1
         (resolved privately; the original Authorization header is forwarded unchanged so
          Foundry still validates the token and applies BotServiceTenant)

  The Azure Bot Service messaging endpoint for the agent points at the APIM URL above.
*/
param apimName string
param apiName string = 'm365-agents'
param agentName string

@description('Agent identity client ID (instance_identity.client_id); the expected JWT audience.')
param agentClientId string

param tenantId string = subscription().tenantId

@description('Calls allowed per renewal period for this agent (APIM rate-limit policy).')
param callsPerMinute int = 120

@description('api-version for the Foundry Activity Protocol route behind APIM.')
param activityApiVersion string = 'v1'

resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = {
  parent: apimService
  name: apiName
}

resource operation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: agentName
  properties: {
    displayName: 'Activity: ${agentName}'
    method: 'POST'
    urlTemplate: '/${agentName}/activity'
    description: 'Bot Service -> ${agentName} Activity Protocol route (private endpoint)'
  }
}

// Bot Framework tokens for single-tenant bots may be issued by the Bot Framework token service
// or by Microsoft Entra ID for the bot's tenant; both configurations are accepted.
var policy = '''
<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization" require-scheme="Bearer" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: invalid Bot Framework token">
      <openid-config url="https://login.botframework.com/v1/.well-known/openidconfiguration" />
      <openid-config url="https://login.microsoftonline.com/__TENANT__/v2.0/.well-known/openid-configuration" />
      <audiences>
        <audience>__CLIENT_ID__</audience>
        <audience>api://__CLIENT_ID__</audience>
      </audiences>
      <issuers>
        <issuer>https://api.botframework.com</issuer>
        <issuer>https://sts.windows.net/__TENANT__/</issuer>
        <issuer>https://login.microsoftonline.com/__TENANT__/v2.0</issuer>
      </issuers>
    </validate-jwt>
    <rate-limit calls="__CALLS__" renewal-period="60" />
    <rewrite-uri template="/__AGENT__/endpoint/protocols/activityProtocol?api-version=__APIVER__" copy-unmatched-params="false" />
  </inbound>
  <backend>
    <forward-request timeout="120" />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''

resource operationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: operation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(replace(replace(replace(policy, '__TENANT__', tenantId), '__CLIENT_ID__', agentClientId), '__AGENT__', agentName), '__CALLS__', string(callsPerMinute)), '__APIVER__', activityApiVersion)
  }
}

output messagingEndpoint string = '${apimService.properties.gatewayUrl}/${api.properties.path}/${agentName}/activity'
