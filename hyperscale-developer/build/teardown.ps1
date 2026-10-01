#requires -Version 7.0
<#
    Ward General — tear down the LOCAL demo footprint on this machine.

    Does (local only):
      1. shutdown.ps1  — stop the app + DAB.
      2. Remove .NET build artifacts (bin/ obj/ under src/, and any publish/).
      3. (opt-in) -RemoveDabTool  — uninstall the global DAB CLI.

    By default does NOT touch Azure or the database. The `wardgeneral` Hyperscale database
    is provisioned separately (deploy-wardgeneral-db skill) and is SHARED with
    the book — a demo teardown must never drop it. To remove the Azure resources
    you must do it deliberately and by hand (e.g. `az group delete -n rg-collierhealth`),
    knowing it also destroys the book's database.

    -Azure (opt-in, destructive) deletes the WHOLE resource group ($env:RG or
    rg-collierhealth): server, databases + named replica, Foundry/Azure OpenAI,
    APIM gateway, Content Safety, Key Vault, VNet/private endpoint, NSP, Log
    Analytics. It asks you to type the resource-group name to confirm (or pass
    -Force). The soft-deleted Key Vault / Cognitive Services accounts are purged
    only with -Purge (Key Vault purge protection, if enabled, blocks purge until
    the retention period ends).

    Usage:
      ./teardown.ps1                 # stop + clean build artifacts
      ./teardown.ps1 -RemoveDabTool  # also uninstall the global DAB CLI
      ./teardown.ps1 -KeepArtifacts  # stop only, leave bin/obj in place
      ./teardown.ps1 -Azure          # ALSO delete every Azure resource (resource group)
      ./teardown.ps1 -Azure -Purge   # ...and purge soft-deleted KV / AI accounts
#>
[CmdletBinding()]
param(
    [switch]$RemoveDabTool,
    [switch]$KeepArtifacts,
    [switch]$Azure,
    [switch]$Purge,
    [switch]$Force,
    [string]$ResourceGroup = ($env:RG ?? 'rg-collierhealth'),
    [string]$SubscriptionId = ($env:SUBSCRIPTION_ID ?? '88a1feda-07e6-4bf9-9d09-6ea5ec00b3bf')
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# 1. Stop everything.
& (Join-Path $root 'shutdown.ps1')

# 2. Remove build artifacts.
if (-not $KeepArtifacts) {
    Write-Host "Removing build artifacts (bin/ obj/ publish/) ..." -ForegroundColor Cyan
    $targets = Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('bin', 'obj') }
    $targets += Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Directory -Filter 'publish' -ErrorAction SilentlyContinue
    foreach ($t in $targets) {
        Remove-Item -LiteralPath $t.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  removed $($targets.Count) folder(s)." -ForegroundColor DarkGray
}

# 3. Optionally uninstall the DAB global tool.
if ($RemoveDabTool) {
    if (Get-Command dab -ErrorAction SilentlyContinue) {
        Write-Host "Uninstalling the DAB CLI (Microsoft.DataApiBuilder) ..." -ForegroundColor Cyan
        dotnet tool uninstall --global Microsoft.DataApiBuilder
    }
    else {
        Write-Host "DAB CLI not installed; nothing to uninstall." -ForegroundColor DarkGray
    }
}

# 4. Optionally delete the Azure environment.
if ($Azure) {
    az account set -s $SubscriptionId | Out-Null
    $exists = az group exists -n $ResourceGroup
    if ($exists -ne 'true') {
        Write-Host "Resource group $ResourceGroup not found; nothing to delete." -ForegroundColor DarkGray
    }
    else {
        $kvs = @(az keyvault list -g $ResourceGroup --query "[].name" -o tsv)
        $ais = @(az cognitiveservices account list -g $ResourceGroup --query "[].{n:name,l:location}" -o json | ConvertFrom-Json)
        Write-Host "About to DELETE resource group $ResourceGroup and everything in it:" -ForegroundColor Yellow
        az resource list -g $ResourceGroup --query "[].{name:name, type:type}" -o table
        if (-not $Force) {
            $answer = Read-Host "Type the resource group name ($ResourceGroup) to confirm"
            if ($answer -ne $ResourceGroup) { Write-Warning "Confirmation did not match; Azure resources kept."; return }
        }
        Write-Host "Deleting $ResourceGroup (several minutes) ..." -ForegroundColor Cyan
        az group delete -n $ResourceGroup --yes
        if ($Purge) {
            foreach ($kv in $kvs | Where-Object { $_ }) {
                az keyvault purge -n $kv 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Warning "Could not purge Key Vault $kv (purge protection?). It expires on its own after the retention period." }
            }
            foreach ($ai in $ais) {
                az cognitiveservices account purge -n $ai.n -g $ResourceGroup -l $ai.l 2>&1 | Out-Null
            }
        }
        Write-Host "Azure resource group $ResourceGroup deleted." -ForegroundColor Green
    }
    Write-Host "Rebuild from scratch: see MY-ENVIRONMENT.md / README.md (deploy/provision-hyperscale.ps1 ...)." -ForegroundColor DarkGray
    return
}

Write-Host ""
Write-Host "Local teardown complete. Azure / the wardgeneral database were NOT touched." -ForegroundColor Green
Write-Host "Rebuild with ./build.ps1, run with ./run.ps1." -ForegroundColor DarkGray
