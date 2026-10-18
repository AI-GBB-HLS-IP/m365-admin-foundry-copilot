#Requires -Version 7.0
<#
.SYNOPSIS
  Deploys the private-network infrastructure for the JNJ Foundry -> M365/Teams POC.

.DESCRIPTION
  1. Creates the resource group.
  2. Deploys infra/network.bicep (VNet, NSGs, Azure Firewall Basic, forced-tunnel UDR, jumpbox).
  3. Deploys the vendored template 15 (infra/foundry/main.bicep) into the existing VNet:
     Foundry account + project (public network access disabled, agent subnet injection),
     gpt-5.4-mini deployment, Cosmos DB, AI Search, Storage, App Insights + AMPLS,
     private endpoints and private DNS zones, project capability host (Standard Agent Setup).
  4. Grants data-plane roles to the jumpbox managed identity and to the signed-in user.
  5. Writes resolved names to .poc/state.json for the agent and publish scripts.
#>
param(
    [string] $SubscriptionId = '92c57fed-c529-4815-97fc-ebabdc63137c',
    [string] $ResourceGroup = 'rg-jnj-foundry-m365-poc',
    [string] $Location = 'eastus2',
    [string] $NamePrefix = 'jnjm365',
    [string] $SshPublicKeyPath = (Join-Path $HOME '.ssh/jnjm365_jumpbox.pub'),
    # Optional existing Azure AI Search (any region) when the deployment region lacks capacity.
    [string] $AiSearchResourceId = '',
    [switch] $WhatIf,
    # Reuse the existing network deployment outputs (for resuming after the network layer succeeded).
    [switch] $SkipNetwork,
    # Skip the ARM deployments and only resolve names, grant roles, and write .poc/state.json.
    [switch] $PostDeployOnly
)

. (Join-Path $PSScriptRoot 'common.ps1')

$infra = Join-Path $script:RepoRoot 'infra'
$tags = @{ workload = 'jnj-foundry-m365-poc'; environment = 'poc'; owner = 'ai-gbb-hls' }
$tagArgs = $tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }

Write-Step "Selecting subscription $SubscriptionId"
Invoke-Az account set --subscription $SubscriptionId | Out-Null
$account = Invoke-Az account show --output json -Json
$tenantId = $account.tenantId
$userObjectId = (Invoke-Az ad signed-in-user show --query id --output tsv).Trim()
Write-Host "Tenant $tenantId, signed-in user $($account.user.name)"

if (-not (Test-Path $SshPublicKeyPath)) {
    Write-Step "Generating jumpbox SSH key at $SshPublicKeyPath (break-glass only; the VM has no public IP)"
    $privateKey = $SshPublicKeyPath -replace '\.pub$', ''
    New-Item -ItemType Directory -Force (Split-Path $privateKey) | Out-Null
    & ssh-keygen -t ed25519 -f $privateKey -N '""' -C 'jnjm365-jumpbox' -q
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed.' }
}
$sshPublicKey = (Get-Content -Raw $SshPublicKeyPath).Trim()

Write-Step "Creating resource group $ResourceGroup in $Location"
Invoke-Az group create --name $ResourceGroup --location $Location --tags @tagArgs --output none | Out-Null

$networkParamsFile = Join-Path ([IO.Path]::GetTempPath()) "poc-network-params-$([guid]::NewGuid()).json"
@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        location            = @{ value = $Location }
        namePrefix          = @{ value = $NamePrefix }
        jumpboxSshPublicKey = @{ value = $sshPublicKey }
        tags                = @{ value = $tags }
    }
} | ConvertTo-Json -Depth 10 | Set-Content -Path $networkParamsFile -Encoding utf8

try {
    if ($WhatIf) {
        Write-Step 'What-if: network'
        & az deployment group what-if --resource-group $ResourceGroup --template-file (Join-Path $infra 'network.bicep') `
            --parameters "@$networkParamsFile" --result-format ResourceIdOnly
        return
    }

    if ($PostDeployOnly -or $SkipNetwork) {
        $network = Invoke-Az deployment group show --resource-group $ResourceGroup --name 'poc-network' `
            --query properties.outputs --output json -Json
    }
    else {
        Write-Step 'Deploying network layer (VNet, firewall, UDR, jumpbox) - ~10 minutes'
        $network = Invoke-Az deployment group create --resource-group $ResourceGroup --name 'poc-network' `
            --template-file (Join-Path $infra 'network.bicep') --parameters "@$networkParamsFile" `
            --query properties.outputs --output json -Json
    }
}
finally {
    Remove-Item $networkParamsFile -Force -ErrorAction SilentlyContinue
}

# Generic resource query: avoids the optional azure-firewall CLI extension.
$firewallIp = (Invoke-Az resource show --resource-group $ResourceGroup --name $network.firewallName.value `
    --resource-type Microsoft.Network/azureFirewalls --query 'properties.ipConfigurations[0].properties.privateIPAddress' --output tsv).Trim()
if ($firewallIp -ne $network.firewallPrivateIp.value) {
    throw "Firewall private IP $firewallIp does not match the UDR next hop $($network.firewallPrivateIp.value)."
}
Write-Host "Firewall private IP $firewallIp matches the UDR next hop."

if (-not $PostDeployOnly) {
    Write-Step 'Deploying Foundry Standard Agent Setup into the existing VNet (template 15) - ~20-30 minutes'
    $env:AZURE_LOCATION = $Location
    $env:EXISTING_VNET_ID = $network.vnetId.value
    $env:AI_SEARCH_RESOURCE_ID = $AiSearchResourceId
    Invoke-Az deployment group create --resource-group $ResourceGroup --name 'poc-foundry' `
        --parameters (Join-Path $infra 'foundry.bicepparam') --output none | Out-Null
}

Write-Step 'Resolving Foundry account and project'
# Note: avoid '|' and '()' in --query on Windows; az.cmd passes arguments through cmd.exe.
$foundry = @(Invoke-Az cognitiveservices account list --resource-group $ResourceGroup `
    --query "[?kind=='AIServices']" --output json -Json)[0]
$accountId = $foundry.id
$projects = Invoke-Az rest --method get `
    --url "https://management.azure.com$accountId/projects?api-version=2025-06-01" --output json -Json
$project = $projects.value | Select-Object -First 1
$projectName = ($project.name -split '/')[-1]
$projectEndpoint = "https://$($foundry.name).services.ai.azure.com/api/projects/$projectName"
$modelDeployment = (Invoke-Az cognitiveservices account deployment list --resource-group $ResourceGroup `
    --name $foundry.name --query '[0].name' --output tsv).Trim()

Write-Step 'Granting data-plane roles'
$foundryUser = '53ca6127-db72-4b80-b1b0-d745d6d5456d'           # Foundry User (formerly Azure AI User)
$foundryProjectManager = 'eadc314b-1a2d-4efa-be10-5d325db5065e' # Foundry Project Manager (formerly Azure AI Project Manager)
$reader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
$assignments = @(
    # Jumpbox MI deploys the hosted agent and toolbox with azd from inside the VNet. Project
    # Manager lets it grant Foundry User to the new agent identity without broad RBAC rights.
    @{ principal = $network.jumpboxPrincipalId.value; type = 'ServicePrincipal'; role = $foundryUser; scope = $accountId },
    @{ principal = $network.jumpboxPrincipalId.value; type = 'ServicePrincipal'; role = $foundryProjectManager; scope = $accountId },
    @{ principal = $network.jumpboxPrincipalId.value; type = 'ServicePrincipal'; role = $reader; scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" },
    # Signed-in admin publishes the agent to Microsoft 365 (Owner has no Foundry data actions).
    @{ principal = $userObjectId; type = 'User'; role = $foundryUser; scope = $accountId }
)
foreach ($a in $assignments) {
    $existing = @(Invoke-Az role assignment list --assignee $a.principal --role $a.role --scope $a.scope --query '[].id' --output json -Json)
    if ($existing.Count -eq 0) {
        Invoke-Az role assignment create --assignee-object-id $a.principal --assignee-principal-type $a.type `
            --role $a.role --scope $a.scope --output none | Out-Null
        Write-Host "Assigned '$($a.role)' to $($a.principal)"
    }
}

Write-Step 'Sending Foundry edge diagnostics (Audit, RequestResponse, Trace) to the POC workspace'
# RequestResponse shows every call at the Foundry edge with caller IP and status. This is how you
# see M365/Teams Activity Protocol calls (Teams source ranges 52.112.0.0/14, 52.122.0.0/15) and
# any 403s from the public-network-access block.
$diagLogs = Join-Path ([IO.Path]::GetTempPath()) "poc-diag-$([guid]::NewGuid()).json"
'[{"category":"Audit","enabled":true},{"category":"RequestResponse","enabled":true},{"category":"Trace","enabled":true}]' |
    Set-Content -Path $diagLogs -Encoding utf8
try {
    Invoke-Az monitor diagnostic-settings create --name 'to-poc-log-analytics' --resource $accountId `
        --workspace $network.logAnalyticsWorkspaceId.value --logs "@$diagLogs" --output none | Out-Null
}
finally {
    Remove-Item $diagLogs -Force -ErrorAction SilentlyContinue
}

$state = @{
    subscriptionId   = $SubscriptionId
    tenantId         = $tenantId
    resourceGroup    = $ResourceGroup
    location         = $Location
    namePrefix       = $NamePrefix
    vnetId           = $network.vnetId.value
    firewallName     = $network.firewallName.value
    firewallPublicIp = $network.firewallPublicIp.value
    logAnalyticsId   = $network.logAnalyticsWorkspaceId.value
    jumpboxName      = $network.jumpboxName.value
    jumpboxPrincipal = $network.jumpboxPrincipalId.value
    accountName      = $foundry.name
    accountId        = $accountId
    projectName      = $projectName
    projectId        = "$accountId/projects/$projectName"
    projectEndpoint  = $projectEndpoint
    modelDeployment  = $modelDeployment
    agentName        = 'jnj-azure-advisor'
}
Save-PocState $state

Write-Step 'Infrastructure ready'
$state | ConvertTo-Json | Write-Host
