<#
.SYNOPSIS
  Creates a prompt agent (same instructions and Microsoft Learn MCP tool as the hosted agent) in
  the private project. Used for side-by-side scenarios, for example the APIM ingress option and
  the admin-approval demo, without changing the main hosted agent. Works with either ingress option.

.EXAMPLE
  ./scripts/create-prompt-agent.ps1 -AgentName jnj-advisor-apim-tenant
  ./scripts/publish-agent.ps1 -AgentName jnj-advisor-apim-tenant -Ingress Apim -PublishScope Tenant
#>
#Requires -Version 7.0
param(
    [Parameter(Mandatory)] [string] $AgentName,
    [string] $Description = 'JNJ Azure Advisor (prompt agent) with the Microsoft Learn MCP tool'
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-PocState
Invoke-Az account set --subscription $state.subscriptionId | Out-Null

$mainPy = Get-Content -Raw (Join-Path $script:RepoRoot 'agent/src/jnj-azure-advisor/main.py')
$instructions = [regex]::Match($mainPy, 'INSTRUCTIONS = """(.*?)"""', 'Singleline').Groups[1].Value
$token = (Invoke-Az account get-access-token --resource https://ai.azure.com --query accessToken --output tsv).Trim()

Write-Step "Creating prompt agent $AgentName (inside the VNet)"
Invoke-JumpboxScript -State $state -ScriptPath (Join-Path $PSScriptRoot 'jumpbox/create-prompt-agent.sh') -Environment @{
    AZURE_AI_PROJECT_ENDPOINT = $state.projectEndpoint
    AGENT_NAME                = $AgentName
    MODEL                     = $state.modelDeployment
    INSTRUCTIONS              = $instructions
    DESCRIPTION               = $Description
} -ProtectedEnvironment @{ USER_TOKEN = $token } | Out-Null
