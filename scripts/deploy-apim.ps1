<#
.SYNOPSIS
  Deploys the optional API Management front door (Option 2 ingress) into the POC spoke VNet.

.DESCRIPTION
  APIM Developer tier, VNet-injected in External mode (public gateway, private reach into the
  Foundry private endpoint). Takes ~45-60 minutes.

  This is the one-time prerequisite for Option 2 ingress only. Option 1 (publish-agent.ps1
  -Ingress Foundry, the default) doesn't need it. After it finishes, publish any agent through
  APIM with:
    ./scripts/publish-agent.ps1 -AgentName <agent> -Ingress Apim -PublishScope Tenant

.EXAMPLE
  ./scripts/deploy-apim.ps1
#>
#Requires -Version 7.0
param(
    [string] $PublisherEmail = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-PocState
Invoke-Az account set --subscription $state.subscriptionId | Out-Null
if (-not $PublisherEmail) {
    $PublisherEmail = (Invoke-Az ad signed-in-user show --query userPrincipalName --output tsv).Trim()
}

$paramsFile = Join-Path ([IO.Path]::GetTempPath()) "poc-apim-params-$([guid]::NewGuid()).json"
@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        location                = @{ value = $state.location }
        namePrefix              = @{ value = $state.namePrefix }
        foundryAgentsBaseUrl    = @{ value = "$($state.projectEndpoint)/agents" }
        publisherEmail          = @{ value = $PublisherEmail }
        logAnalyticsWorkspaceId = @{ value = $state.logAnalyticsId }
        tags                    = @{ value = @{ workload = 'jnj-foundry-m365-poc'; environment = 'poc'; owner = 'ai-gbb-hls' } }
    }
} | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFile -Encoding utf8

try {
    Write-Step 'Deploying API Management (Developer, External VNet) - ~45-60 minutes'
    $apim = Invoke-Az deployment group create --resource-group $state.resourceGroup --name 'poc-apim' `
        --template-file (Join-Path $script:RepoRoot 'infra/apim.bicep') --parameters "@$paramsFile" `
        --query properties.outputs --output json -Json
}
finally {
    Remove-Item $paramsFile -Force -ErrorAction SilentlyContinue
}

$state.apimName = $apim.apimName.value
$state.apimGatewayUrl = $apim.gatewayUrl.value
$state.apimApiPath = $apim.apiPath.value
$state.apimPublicIp = $apim.publicIp.value
Save-PocState $state

Write-Step 'APIM ready'
[pscustomobject]@{ name = $state.apimName; gateway = $state.apimGatewayUrl; api = "/$($state.apimApiPath)"; publicIp = $state.apimPublicIp } | Format-List
