#Requires -Version 7.0
# Shared helpers for the POC scripts. Dot-source this file.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:StateDir = Join-Path $script:RepoRoot '.poc'
$script:StatePath = Join-Path $script:StateDir 'state.json'

function Invoke-Az {
    # Runs az and throws on failure. Returns parsed JSON when -Json is set.
    param(
        [Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Arguments,
        [switch] $Json
    )
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($output | Out-String)"
    }
    $text = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ($Json) { return ($text | ConvertFrom-Json -Depth 50) }
    return $text
}

function Get-PocState {
    if (-not (Test-Path $script:StatePath)) {
        throw "State file not found at $script:StatePath. Run scripts/deploy-infra.ps1 first."
    }
    return Get-Content -Raw $script:StatePath | ConvertFrom-Json -AsHashtable
}

function Save-PocState([hashtable] $State) {
    New-Item -ItemType Directory -Force $script:StateDir | Out-Null
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $script:StatePath -Encoding utf8
}

function Write-Step([string] $Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-JumpboxScript {
    <#
      Runs a bash script on the private jumpbox through Azure Run Command (management plane),
      so no inbound SSH/RDP or public IP is needed. Optional folders are shipped inline as a
      base64 tar.gz and extracted to /opt/poc before the script runs.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [string] $ScriptPath,
        [hashtable] $Environment = @{},
        [hashtable] $ProtectedEnvironment = @{},
        [string[]] $ShipFolders = @(),
        [int] $TimeoutSeconds = 3600
    )

    $payload = ''
    if ($ShipFolders.Count -gt 0) {
        $tarPath = Join-Path ([IO.Path]::GetTempPath()) "poc-payload-$([guid]::NewGuid()).tar.gz"
        $relative = @($ShipFolders | ForEach-Object { [IO.Path]::GetRelativePath($script:RepoRoot, $_) -replace '\\', '/' })
        & tar -czf $tarPath -C $script:RepoRoot --exclude '.venv' --exclude '__pycache__' --exclude '.azure' --exclude '.env' @relative
        if ($LASTEXITCODE -ne 0) { throw 'Failed to package payload.' }
        $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tarPath))
        Remove-Item $tarPath -Force
    }

    $exports = foreach ($key in $Environment.Keys) {
        $value = [string] $Environment[$key] -replace "'", "'\''"
        "export $key='$value'"
    }

    $body = Get-Content -Raw $ScriptPath
    $wrapper = @"
#!/bin/bash
set -euo pipefail
export HOME=/root
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/bin:/usr/bin:/bin:/root/.azd/bin:`$PATH
mkdir -p /opt/poc /var/log/poc
$($exports -join "`n")
if [ -n "$payload" ]; then
  echo "$payload" | base64 -d | tar -xzf - -C /opt/poc
fi
cd /opt/poc
$body
"@
    $wrapper = $wrapper -replace "`r`n", "`n"

    $runName = 'poc-' + [IO.Path]::GetFileNameWithoutExtension($ScriptPath) + '-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $scriptFile = Join-Path ([IO.Path]::GetTempPath()) "$runName.sh"
    [IO.File]::WriteAllText($scriptFile, $wrapper, [Text.UTF8Encoding]::new($false))

    $rcArgs = @(
        'vm', 'run-command', 'create',
        '--resource-group', $State.resourceGroup,
        '--vm-name', $State.jumpboxName,
        '--run-command-name', $runName,
        '--script', "@$scriptFile",
        '--async-execution', 'false',
        '--timeout-in-seconds', "$TimeoutSeconds",
        '--only-show-errors', '--output', 'none'
    )
    if ($ProtectedEnvironment.Count -gt 0) {
        # Protected parameters are delivered encrypted as environment variables and are not
        # returned by the instance view.
        $rcArgs += '--protected-parameters'
        $rcArgs += ($ProtectedEnvironment.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    }

    try {
        & az @rcArgs 2>&1 | Out-Null
        $view = Invoke-Az vm run-command show --resource-group $State.resourceGroup --vm-name $State.jumpboxName `
            --run-command-name $runName --instance-view --output json -Json
        $iv = $view.instanceView
        if ($iv.output) { Write-Host $iv.output }
        if ($iv.error) { Write-Host $iv.error -ForegroundColor Yellow }
        if ($iv.executionState -ne 'Succeeded' -or $iv.exitCode -ne 0) {
            throw "Jumpbox script '$ScriptPath' failed (state=$($iv.executionState), exit=$($iv.exitCode))."
        }
        return $iv.output
    }
    finally {
        Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue
        & az vm run-command delete --resource-group $State.resourceGroup --vm-name $State.jumpboxName `
            --run-command-name $runName --yes --no-wait --only-show-errors 2>&1 | Out-Null
    }
}
