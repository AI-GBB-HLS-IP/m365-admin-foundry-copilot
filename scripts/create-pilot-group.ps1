<#
.SYNOPSIS
  Creates the Entra security group used to scope who can install/use the agent
  (M365 admin center "Publish to store" audience and Teams app availability).
#>
#Requires -Version 7.0
param(
    [string] $GroupName = 'sg-jnj-azure-advisor-pilot',
    [string[]] $MemberUpns = @()
)

. (Join-Path $PSScriptRoot 'common.ps1')

$group = Invoke-Az ad group list --display-name $GroupName --query '[0]' --output json -Json
if (-not $group) {
    Write-Step "Creating security group $GroupName"
    $group = Invoke-Az ad group create --display-name $GroupName --mail-nickname $GroupName `
        --description 'Pilot audience for the JNJ Azure Advisor agent (Foundry -> M365/Teams POC)' --output json -Json
}

if ($MemberUpns.Count -eq 0) {
    $MemberUpns = @((Invoke-Az ad signed-in-user show --query userPrincipalName --output tsv).Trim())
}
foreach ($upn in $MemberUpns) {
    $userId = (Invoke-Az ad user show --id $upn --query id --output tsv).Trim()
    $isMember = (Invoke-Az ad group member check --group $group.id --member-id $userId --query value --output tsv).Trim()
    if ($isMember -ne 'true') {
        Invoke-Az ad group member add --group $group.id --member-id $userId | Out-Null
        Write-Host "Added $upn"
    }
}

$count = @(Invoke-Az ad group member list --group $group.id --query '[].id' --output json -Json).Count
Write-Host "Group $GroupName ($($group.id)) has $count member(s)."
