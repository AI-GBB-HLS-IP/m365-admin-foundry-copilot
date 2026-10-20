<#
.SYNOPSIS
  Gives a developer laptop private access to the Foundry portal / data plane via P2S VPN.

.DESCRIPTION
  1. Deploys infra/vpn.bicep (VPN Gateway with Entra ID auth + DNS Private Resolver) - ~30-45 min.
  2. Downloads the Azure VPN Client profile and injects the resolver as DNS server, plus NRPT
     suffixes for the Foundry and dependency private-link names.
  3. Writes the profile to .poc/vpn/azurevpnconfig.xml for import into the Azure VPN Client.
#>
#Requires -Version 7.0
param(
    [switch] $ProfileOnly,
    [ValidateSet('VpnGw1AZ', 'VpnGw2AZ', 'VpnGw3AZ')] [string] $GatewaySku = 'VpnGw1AZ',
    [ValidateSet('Generation1', 'Generation2')] [string] $GatewayGeneration = 'Generation1'
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-PocState
Invoke-Az account set --subscription $state.subscriptionId | Out-Null

if (-not $ProfileOnly) {
    Write-Step 'Deploying P2S VPN Gateway + DNS Private Resolver (~30-45 minutes)'
    $tags = @{ workload = 'jnj-foundry-m365-poc'; environment = 'poc'; owner = 'ai-gbb-hls' }
    $paramsFile = Join-Path ([IO.Path]::GetTempPath()) "poc-vpn-params-$([guid]::NewGuid()).json"
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            location   = @{ value = $state.location }
            namePrefix = @{ value = $state.namePrefix }
            tenantId   = @{ value = $state.tenantId }
            gatewaySku = @{ value = $GatewaySku }
            gatewayGeneration = @{ value = $GatewayGeneration }
            tags       = @{ value = $tags }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFile -Encoding utf8
    try {
        $vpn = Invoke-Az deployment group create --resource-group $state.resourceGroup --name 'poc-vpn' `
            --template-file (Join-Path $script:RepoRoot 'infra/vpn.bicep') --parameters "@$paramsFile" `
            --query properties.outputs --output json -Json
    }
    finally {
        Remove-Item $paramsFile -Force -ErrorAction SilentlyContinue
    }
}
else {
    $vpn = Invoke-Az deployment group show --resource-group $state.resourceGroup --name 'poc-vpn' `
        --query properties.outputs --output json -Json
}
$dnsIp = $vpn.dnsResolverInboundIp.value
$gatewayName = $vpn.vpnGatewayName.value
Write-Host "Gateway: $gatewayName  DNS resolver inbound IP: $dnsIp"

Write-Step 'Generating the Azure VPN Client profile'
$url = (Invoke-Az network vnet-gateway vpn-client generate --resource-group $state.resourceGroup --name $gatewayName `
        --output tsv).Trim().Trim('"')
$work = Join-Path ([IO.Path]::GetTempPath()) "poc-vpn-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force $work | Out-Null
try {
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $work 'profile.zip')
    Expand-Archive -Path (Join-Path $work 'profile.zip') -DestinationPath $work -Force
    $source = Get-ChildItem $work -Recurse -Filter 'azurevpnconfig.xml' | Select-Object -First 1
    if (-not $source) { throw 'azurevpnconfig.xml not found in the VPN client package.' }

    # Private-link names that must resolve through the VNet (NRPT rules on the client).
    $suffixes = @(
        '.services.ai.azure.com', '.openai.azure.com', '.cognitiveservices.azure.com',
        '.search.windows.net', '.documents.azure.com', '.blob.core.windows.net'
    )
    $clientConfig = "<clientconfig><dnsservers><dnsserver>$dnsIp</dnsserver></dnsservers><dnssuffixes>" +
        (($suffixes | ForEach-Object { "<dnssuffix>$_</dnssuffix>" }) -join '') + '</dnssuffixes></clientconfig>'

    $xml = Get-Content -Raw $source.FullName
    $pattern = '<clientconfig[^>]*/>|<clientconfig[^>]*>.*?</clientconfig>'
    if ($xml -notmatch $pattern) { throw 'Unexpected profile format: <clientconfig> element not found.' }
    $xml = [regex]::Replace($xml, $pattern, $clientConfig, 'Singleline')
    $xml = [regex]::Replace($xml, '<name>[^<]*</name>', '<name>jnj-foundry-poc</name>', 1)

    $outDir = Join-Path $script:StateDir 'vpn'
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $profilePath = Join-Path $outDir 'azurevpnconfig.xml'
    Set-Content -Path $profilePath -Value $xml -Encoding utf8
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$state.vpnGatewayName = $gatewayName
$state.dnsResolverInboundIp = $dnsIp
Save-PocState $state

Write-Step 'Profile ready'
Write-Host "Profile: $profilePath"
if (-not (Get-AppxPackage -Name '*AzureVpn*' -ErrorAction SilentlyContinue)) {
    Write-Host 'Azure VPN Client not found. Install it with:' -ForegroundColor Yellow
    Write-Host '  winget install --id 9NP355QT2SQB --source msstore --accept-package-agreements --accept-source-agreements'
}
Write-Host @"
Next:
  1. Azure VPN Client > + > Import > $profilePath
  2. Connect and sign in as a user in tenant $($state.tenantId)
  3. Verify: Resolve-DnsName $($state.accountName).services.ai.azure.com   (expect 10.50.1.x)
  4. Open https://ai.azure.com and select project $($state.projectName)
"@
