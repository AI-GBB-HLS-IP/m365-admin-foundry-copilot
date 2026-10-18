#Requires -Version 7.0
<#
.SYNOPSIS
  Proves the isolation boundary: public callers are blocked, VNet callers resolve private IPs,
  and agent egress is governed by Azure Firewall.
#>
. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-PocState
Invoke-Az account set --subscription $state.subscriptionId | Out-Null

Write-Step 'Public network access settings (management plane)'
$account = Invoke-Az cognitiveservices account show --resource-group $state.resourceGroup --name $state.accountName --output json -Json
[pscustomobject]@{
    publicNetworkAccess = $account.properties.publicNetworkAccess
    defaultAction       = $account.properties.networkAcls.defaultAction
    disableLocalAuth    = $account.properties.disableLocalAuth
    agentSubnet         = ($account.properties.networkInjections | Select-Object -First 1).subnetArmId
} | Format-List

$deps = @(Invoke-Az resource list --resource-group $state.resourceGroup --query '[].{name:name,type:type,id:id}' --output json -Json) |
    Where-Object { $_.type -in 'Microsoft.DocumentDB/databaseAccounts', 'Microsoft.Search/searchServices', 'Microsoft.Storage/storageAccounts' }
$deps | ForEach-Object {
    $pna = Invoke-Az resource show --ids $_.id --query 'properties.publicNetworkAccess' --output tsv
    [pscustomobject]@{ name = $_.name; type = $_.type; publicNetworkAccess = $pna.Trim() }
} | Format-Table -AutoSize

Write-Step 'From the public internet (this workstation): expect 403 / blocked'
try {
    $token = (Invoke-Az account get-access-token --resource https://ai.azure.com --query accessToken --output tsv).Trim()
    $resp = Invoke-WebRequest -Uri "$($state.projectEndpoint)/agents?api-version=v1" -Headers @{ Authorization = "Bearer $token" } -SkipHttpErrorCheck
    Write-Host "HTTP $($resp.StatusCode): $($resp.Content.Substring(0, [Math]::Min(200, $resp.Content.Length)))"
}
catch { Write-Host "Request failed: $($_.Exception.Message)" }

Write-Step 'From inside the VNet (jumpbox)'
$hosts = @(
    "$($state.accountName).services.ai.azure.com",
    "$($state.accountName).openai.azure.com",
    "$($state.accountName).cognitiveservices.azure.com"
) + ($deps | ForEach-Object {
    $d = $_
    switch ($d.type) {
        'Microsoft.DocumentDB/databaseAccounts' { "$($d.name).documents.azure.com" }
        'Microsoft.Search/searchServices' { "$($d.name).search.windows.net" }
        'Microsoft.Storage/storageAccounts' { "$($d.name).blob.core.windows.net" }
    }
})
Invoke-JumpboxScript -State $state -ScriptPath (Join-Path $PSScriptRoot 'jumpbox/verify-network.sh') -Environment @{
    AZURE_AI_ACCOUNT_NAME     = $state.accountName
    AZURE_AI_PROJECT_ENDPOINT = $state.projectEndpoint
    PRIVATE_HOSTS             = ($hosts -join ' ')
} | Out-Null
Write-Host "Firewall public IP: $($state.firewallPublicIp)"
