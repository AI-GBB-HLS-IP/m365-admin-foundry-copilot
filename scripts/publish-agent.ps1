<#
.SYNOPSIS
  Publishes a private Foundry agent to Microsoft 365 Copilot and Teams, either directly from
  Foundry (-Ingress Foundry, Option 1) or through Azure API Management (-Ingress Apim, Option 2).

.DESCRIPTION
  Implements https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network
    Step 1  Read the agent identity (jumpbox -> private endpoint)
    Step 2  Create the Azure Bot Service resource (workstation -> ARM management plane)
    Step 3  Configure the Activity Protocol route + Bot Service auth scheme (jumpbox)
    Step 4  Publish to Microsoft 365 (jumpbox)
  Data-plane calls use the signed-in admin's short-lived token for https://ai.azure.com, passed
  to the jumpbox as an encrypted Run Command protected parameter.

  CHOOSE AN INGRESS OPTION (-Ingress). This is the only difference between the two paths:
    -Ingress Foundry  (Option 1, default) Teams -> Bot Service -> Foundry's source-IP-filtered
                      public Activity route (enable_m365_public_endpoint = true). No extra
                      infrastructure. The documented Microsoft path.
    -Ingress Apim     (Option 2) Teams -> Bot Service -> APIM gateway -> Foundry private endpoint.
                      APIM validates the Bot Framework JWT per agent and rate-limits; Foundry keeps
                      no public route (enable_m365_public_endpoint = false).
                      Prerequisite: run scripts/deploy-apim.ps1 once per environment.

  Admin approval (Tenant scope) is identical for both options. See README "Two ingress options".

.PARAMETER AgentName
  Foundry agent to publish. Defaults to the POC hosted agent (jnj-azure-advisor).

.PARAMETER Ingress
  Foundry (Option 1, default) or Apim (Option 2). See the description above.

.PARAMETER PublishScope
  Tenant: submits to the Microsoft 365 admin center for approval (BotServiceTenant).
  Shared: no approval; callers also need Foundry RBAC on the project (BotServiceRbac). Use for dev/test.

.PARAMETER AppVersion
  Teams app version. Increase it when you republish changed metadata (shows as Pending update).

.PARAMETER AgentDisplayName
  Name users see in Teams and Copilot. Defaults to 'JNJ Azure Advisor' for the main agent and to
  -AgentName for any other agent, so two agents never share a store name by accident.

.EXAMPLE
  ./scripts/publish-agent.ps1 -PublishScope Tenant
  Option 1: publish the main hosted agent directly from Foundry to Teams and Microsoft 365 Copilot.

.EXAMPLE
  ./scripts/deploy-apim.ps1
  ./scripts/publish-agent.ps1 -AgentName jnj-advisor-apim-tenant -Ingress Apim -PublishScope Tenant -AgentDisplayName 'JNJ Azure Advisor - APIM'
  Option 2: deploy APIM once, then publish an agent through it.

.EXAMPLE
  ./scripts/publish-agent.ps1 -AgentName my-test-agent -Ingress Apim -PublishScope Shared
  Developer test through APIM without admin approval.
#>
#Requires -Version 7.0
param(
    [string] $AgentName = '',
    [ValidateSet('Foundry', 'Apim')] [string] $Ingress = 'Foundry',
    [ValidateSet('Tenant', 'Shared')] [string] $PublishScope = 'Tenant',
    [string] $AppVersion = '1.0.0',
    [string] $AgentDisplayName = '',
    [string] $ShortDescription = 'Private Foundry agent grounded in Microsoft Learn',
    [string] $FullDescription = 'POC: a Microsoft Foundry hosted agent running in a private network that answers Azure, Foundry, and Microsoft 365 questions using the Microsoft Learn MCP server.',
    [string] $DeveloperName = 'JNJ AI Platform (POC)',
    [string] $DeveloperUrl = 'https://azure.microsoft.com',
    [string] $PrivacyUrl = 'https://privacy.microsoft.com',
    [string] $TermsUrl = 'https://www.microsoft.com/legal/terms-of-use'
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-PocState
Invoke-Az account set --subscription $state.subscriptionId | Out-Null
$isMainAgent = [string]::IsNullOrEmpty($AgentName) -or $AgentName -eq $state.agentName
if ([string]::IsNullOrEmpty($AgentName)) { $AgentName = $state.agentName }
if ([string]::IsNullOrEmpty($AgentDisplayName)) {
    $AgentDisplayName = if ($isMainAgent) { 'JNJ Azure Advisor' } else { $AgentName }
}
if ($Ingress -eq 'Apim' -and -not $state.ContainsKey('apimName')) {
    throw 'Option 2 (-Ingress Apim) needs API Management. Run ./scripts/deploy-apim.ps1 first, or use -Ingress Foundry.'
}

$ingressText = if ($Ingress -eq 'Apim') {
    'Option 2: Teams -> Bot Service -> APIM -> Foundry private endpoint (Foundry public route OFF)'
} else {
    'Option 1: Teams -> Bot Service -> Foundry filtered public Activity route (Foundry public route ON)'
}
Write-Host "Publishing '$AgentDisplayName' (agent $AgentName, scope $PublishScope)" -ForegroundColor Green
Write-Host "Ingress: $ingressText" -ForegroundColor Green

function Get-UserToken {
    (Invoke-Az account get-access-token --resource https://ai.azure.com --query accessToken --output tsv).Trim()
}

$baseEnv = @{
    AZURE_AI_PROJECT_ENDPOINT = $state.projectEndpoint
    AGENT_NAME                = $AgentName
}

Write-Step 'Step 1: reading agent identity from the private project endpoint'
$out = Invoke-JumpboxScript -State $state -ScriptPath (Join-Path $PSScriptRoot 'jumpbox/get-agent.sh') `
    -Environment $baseEnv -ProtectedEnvironment @{ USER_TOKEN = (Get-UserToken) }
$clientId = ([regex]::Match($out, 'AGENT_CLIENT_ID=([0-9a-fA-F-]{36})')).Groups[1].Value
if (-not $clientId) { throw 'Could not read instance_identity.client_id for the agent.' }
Write-Host "Agent identity client ID: $clientId"

Write-Step "Step 2: creating Azure Bot Service (public network access disabled, Teams channel; ingress=$Ingress)"
$botName = "bot-$AgentName-$($state.accountName)"
if ($Ingress -eq 'Apim') {
    Write-Host "Adding APIM route for $AgentName (JWT audience $clientId)"
    $route = Invoke-Az deployment group create --resource-group $state.resourceGroup --name "poc-apim-route-$AgentName" `
        --template-file (Join-Path $script:RepoRoot 'infra/apim-agent-route.bicep') `
        --parameters apimName=$($state.apimName) agentName=$AgentName agentClientId=$clientId tenantId=$($state.tenantId) `
        --query properties.outputs --output json -Json
    $activityEndpoint = $route.messagingEndpoint.value
}
else {
    # api-version is required: without it the request doesn't match the source-IP-filtered Activity
    # route and is rejected by the account's public-network-access block (generic 403).
    $activityEndpoint = "$($state.projectEndpoint)/agents/$AgentName/endpoint/protocols/activityProtocol?api-version=v1"
}
Write-Host "Bot messaging endpoint: $activityEndpoint"
$bot = Invoke-Az deployment group create --resource-group $state.resourceGroup --name "poc-bot-$AgentName" `
    --template-file (Join-Path $script:RepoRoot 'infra/bot-service.bicep') `
    --parameters botName=$botName displayName=$AgentDisplayName msaAppId=$clientId tenantId=$($state.tenantId) endpoint=$activityEndpoint `
    --query properties.outputs --output json -Json
$botId = $bot.botServiceId.value
Write-Host "Bot Service: $botId"

Write-Step "Steps 3-4: enabling the Activity Protocol route and publishing (scope=$PublishScope)"
$publishEnv = $baseEnv + @{
    BOT_SERVICE_ID     = $botId
    PUBLISH_SCOPE      = $PublishScope
    M365_PUBLIC_ENDPOINT = $(if ($Ingress -eq 'Apim') { 'false' } else { 'true' })
    APP_VERSION        = $AppVersion
    AGENT_DISPLAY_NAME = $AgentDisplayName
    SHORT_DESCRIPTION  = $ShortDescription
    FULL_DESCRIPTION   = $FullDescription
    DEVELOPER_NAME     = $DeveloperName
    DEVELOPER_URL      = $DeveloperUrl
    PRIVACY_URL        = $PrivacyUrl
    TERMS_URL          = $TermsUrl
}
Invoke-JumpboxScript -State $state -ScriptPath (Join-Path $PSScriptRoot 'jumpbox/publish-agent.sh') `
    -Environment $publishEnv -ProtectedEnvironment @{ USER_TOKEN = (Get-UserToken) } | Out-Null

if ($isMainAgent) {
    $state.botServiceId = $botId
    $state.botName = $botName
    $state.publishScope = $PublishScope
    $state.appVersion = $AppVersion
    Save-PocState $state
}

if ($PublishScope -eq 'Tenant') {
    Write-Step 'Next: approve the agent in the Microsoft 365 admin center'
    Write-Host 'https://admin.cloud.microsoft/?#/agents/all/requested'
    Write-Host "Approve '$AgentDisplayName' for a group as 'Available to' (avoid pre-installing while testing),"
    Write-Host 'then allow the same group in Teams admin center > Teams apps > Manage apps > Users and groups.'
}
