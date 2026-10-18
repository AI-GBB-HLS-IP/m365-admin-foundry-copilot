#Requires -Version 7.0
<#
.SYNOPSIS
  Publishes the private hosted agent to Microsoft 365 Copilot and Teams.

.DESCRIPTION
  Implements https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network
    Step 1  Read the agent identity (jumpbox -> private endpoint)
    Step 2  Create the Azure Bot Service resource (workstation -> ARM management plane)
    Step 3  Enable the source-IP-filtered Activity Protocol route + Bot Service auth scheme (jumpbox)
    Step 4  Publish to Microsoft 365 (jumpbox)
  Data-plane calls use the signed-in admin's short-lived token for https://ai.azure.com, passed
  to the jumpbox as an encrypted Run Command protected parameter.
#>
param(
    [ValidateSet('Tenant', 'Shared')] [string] $PublishScope = 'Tenant',
    [string] $AppVersion = '1.0.0',
    [string] $AgentDisplayName = 'JNJ Azure Advisor',
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

function Get-UserToken {
    (Invoke-Az account get-access-token --resource https://ai.azure.com --query accessToken --output tsv).Trim()
}

$baseEnv = @{
    AZURE_AI_PROJECT_ENDPOINT = $state.projectEndpoint
    AGENT_NAME                = $state.agentName
}

Write-Step 'Step 1: reading agent identity from the private project endpoint'
$out = Invoke-JumpboxScript -State $state -ScriptPath (Join-Path $PSScriptRoot 'jumpbox/get-agent.sh') `
    -Environment $baseEnv -ProtectedEnvironment @{ USER_TOKEN = (Get-UserToken) }
$clientId = ([regex]::Match($out, 'AGENT_CLIENT_ID=([0-9a-fA-F-]{36})')).Groups[1].Value
if (-not $clientId) { throw 'Could not read instance_identity.client_id for the agent.' }
Write-Host "Agent identity client ID: $clientId"

Write-Step 'Step 2: creating Azure Bot Service (public network access disabled, Teams channel)'
$botName = "bot-$($state.agentName)-$($state.accountName)"
$activityEndpoint = "$($state.projectEndpoint)/agents/$($state.agentName)/endpoint/protocols/activityProtocol"
$bot = Invoke-Az deployment group create --resource-group $state.resourceGroup --name 'poc-bot-service' `
    --template-file (Join-Path $script:RepoRoot 'infra/bot-service.bicep') `
    --parameters botName=$botName displayName=$AgentDisplayName msaAppId=$clientId tenantId=$($state.tenantId) endpoint=$activityEndpoint `
    --query properties.outputs --output json -Json
$botId = $bot.botServiceId.value
Write-Host "Bot Service: $botId"

Write-Step "Steps 3-4: enabling the Activity Protocol route and publishing (scope=$PublishScope)"
$publishEnv = $baseEnv + @{
    BOT_SERVICE_ID     = $botId
    PUBLISH_SCOPE      = $PublishScope
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

$state.botServiceId = $botId
$state.botName = $botName
$state.publishScope = $PublishScope
$state.appVersion = $AppVersion
Save-PocState $state

if ($PublishScope -eq 'Tenant') {
    Write-Step 'Next: approve the agent in the Microsoft 365 admin center'
    Write-Host 'https://admin.cloud.microsoft/?#/agents/all/requested'
}
