#Requires -Version 7.0
<#
.SYNOPSIS
  Deploys the hosted agent and its Microsoft Learn MCP toolbox from the private jumpbox.

.DESCRIPTION
  The Foundry project has public network access disabled, so data-plane operations (create
  toolbox, upload source, create agent version, invoke) must originate inside the VNet. This
  script ships agent/ to the jumpbox and runs azd there with the VM's managed identity, via
  Azure Run Command. Nothing is exposed inbound on the VM.
#>
param(
    [string] $AzdEnvironment = 'poc'
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-PocState
Invoke-Az account set --subscription $state.subscriptionId | Out-Null

$envVars = @{
    AZURE_SUBSCRIPTION_ID          = $state.subscriptionId
    AZURE_TENANT_ID                = $state.tenantId
    AZURE_LOCATION                 = $state.location
    AZURE_RESOURCE_GROUP           = $state.resourceGroup
    AZURE_AI_ACCOUNT_NAME          = $state.accountName
    AZURE_AI_PROJECT_NAME          = $state.projectName
    AZURE_AI_PROJECT_ID            = $state.projectId
    AZURE_AI_PROJECT_ENDPOINT      = $state.projectEndpoint
    AZURE_AI_MODEL_DEPLOYMENT_NAME = $state.modelDeployment
    AZD_ENV_NAME                   = $AzdEnvironment
}

Write-Step "Bootstrapping tooling on $($state.jumpboxName)"
Invoke-JumpboxScript -State $state -ScriptPath (Join-Path $PSScriptRoot 'jumpbox/bootstrap.sh') -Environment $envVars | Out-Null

Write-Step 'Deploying toolbox + hosted agent with azd (from inside the VNet)'
Invoke-JumpboxScript -State $state -ScriptPath (Join-Path $PSScriptRoot 'jumpbox/deploy-agent.sh') `
    -Environment $envVars -ShipFolders @((Join-Path $script:RepoRoot 'agent')) | Out-Null
