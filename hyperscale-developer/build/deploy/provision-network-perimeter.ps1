<#
    Ward General Hospital — Hyperscale developer demo
    provision-network-perimeter.ps1 : put the Collier Health logical server (and,
                                      optionally, the TDE Key Vault) inside an Azure
                                      NETWORK SECURITY PERIMETER (NSP) so a laptop
                                      can reach it on a governed subscription.

    WHY THIS EXISTS (environment-specific, not in Bob's original kit):
      Some governed subscriptions (e.g. MCAPS "AzureSQL_PublicNetwork_Modify" /
      "KeyVault_PublicNetwork_Modify") FORCE publicNetworkAccess=Disabled on every SQL
      server / Key Vault write, so classic server firewall rules can't be used. The
      policy treats publicNetworkAccess=SecuredByPerimeter as compliant: public
      inbound is then governed by the NSP's access rules instead of server firewall
      rules. This script:
        1. creates an NSP + profile,
        2. adds an INBOUND rule for this client's public IP (or -Cidr),
        3. adds OUTBOUND FQDN rules so the database can still call Azure OpenAI and
           the APIM AI gateway (in-engine AI_GENERATE_EMBEDDINGS /
           sp_invoke_external_rest_endpoint),
        4. associates the SQL server (and -KeyVault) with the profile,
        5. sets the server's publicNetworkAccess = SecuredByPerimeter.
      Private Link (provision-private-link.ps1) still works alongside it.

    Re-run any time (idempotent). With -InboundOnly it only ensures the inbound rule
    for the current client IP/CIDR — that's what preflight-firewall.ps1 calls at a new
    venue. Error 42118 at login = the NSP denied this client IP.

    Learn: "Network security perimeter for Azure SQL Database (preview)" and
    "Network security perimeter concepts" (access modes, access rules).
#>
[CmdletBinding()]
param(
    [string]   $SubscriptionId = ($env:SUBSCRIPTION_ID ?? '88a1feda-07e6-4bf9-9d09-6ea5ec00b3bf'),
    [string]   $Rg          = ($env:RG ?? 'rg-collierhealth'),
    [string]   $Loc         = ($env:LOC ?? 'centralus'),
    [string]   $Server      = ($env:SRV ?? 'collierhealth-49889'),
    [string]   $Nsp         = 'nsp-collierhealth',
    [string]   $NspProfile  = 'wardgeneral',
    [string]   $KeyVault    = '',                                     # optional: also associate the TDE vault
    [string[]] $OutboundFqdns = @(
        'collierhealth-49889-ai.openai.azure.com',
        'collierhealth-49889-ai-gateway.azure-api.net'),
    [string]   $Cidr        = '',                                     # default: this client's /32
    [string]   $RuleName    = '',
    [ValidateSet('Enforced','Learning')]
    [string]   $AccessMode  = 'Enforced',
    [switch]   $InboundOnly
)

$ErrorActionPreference = 'Stop'
$api    = '2024-07-01'
$nspId  = "/subscriptions/$SubscriptionId/resourceGroups/$Rg/providers/Microsoft.Network/networkSecurityPerimeters/$Nsp"
$profId = "$nspId/profiles/$NspProfile"

function Invoke-Arm([string]$Method, [string]$Id, $Body = $null, [string]$ApiVersion = $api) {
    $url = "https://management.azure.com$Id`?api-version=$ApiVersion"
    if ($null -ne $Body) {
        $f = Join-Path $env:TEMP ("nsp-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        [IO.File]::WriteAllText($f, ($Body | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
        try { $out = az rest --method $Method --url $url --body "@$f" -o json 2>&1 }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
    } else {
        $out = az rest --method $Method --url $url -o json 2>&1
    }
    if ($LASTEXITCODE -ne 0) { throw "ARM $Method $Id failed: $out" }
    if ($out) { return ($out | Out-String | ConvertFrom-Json) }
}

# ---- Inbound address prefix (client IP or a CIDR for rotating corpnet egress) ----
if (-not $Cidr) {
    $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim()
    $null = [System.Net.IPAddress]::Parse($ip)
    $Cidr = "$ip/32"
}
if (-not $RuleName) { $RuleName = 'client-' + ($Cidr -replace '[./]', '-') }

if (-not $InboundOnly) {
    Write-Host "=== Network security perimeter for $Server ($Loc) ==="
    Write-Host "--- 1/5  NSP $Nsp + profile $NspProfile ---"
    Invoke-Arm PUT $nspId @{ location = $Loc; tags = @{ application = 'ward-general-ehr'; environment = 'sandbox' } } | Out-Null
    Invoke-Arm PUT $profId @{ properties = @{} } | Out-Null
}

Write-Host "--- Inbound access rule $RuleName -> $Cidr ---"
Invoke-Arm PUT "$profId/accessRules/$RuleName" @{
    properties = @{ direction = 'Inbound'; addressPrefixes = @($Cidr) }
} | Out-Null
if ($InboundOnly) { Write-Host "Inbound rule ensured: $Cidr on $Nsp/$NspProfile." -ForegroundColor Green; return }

Write-Host "--- 3/5  Outbound FQDN rule (Azure OpenAI + APIM gateway) ---"
Invoke-Arm PUT "$profId/accessRules/allow-ai-outbound" @{
    properties = @{ direction = 'Outbound'; fullyQualifiedDomainNames = $OutboundFqdns }
} | Out-Null

Write-Host "--- 4/5  Associate resources ($AccessMode) ---"
$targets = @(az sql server show -g $Rg -n $Server --query id -o tsv)
if ($KeyVault) { $targets += (az keyvault show -g $Rg -n $KeyVault --query id -o tsv) }
foreach ($id in $targets) {
    $assoc = 'assoc-' + ($id -split '/')[-1]
    Invoke-Arm PUT "$nspId/resourceAssociations/$assoc" @{
        properties = @{
            privateLinkResource = @{ id = $id }
            profile             = @{ id = $profId }
            accessMode          = $AccessMode
        }
    } | Out-Null
    Write-Host "  associated $(($id -split '/')[-1])"
}

Write-Host "--- 5/5  publicNetworkAccess = SecuredByPerimeter ---"
$srvId = $targets[0]
Invoke-Arm PATCH $srvId @{ properties = @{ publicNetworkAccess = 'SecuredByPerimeter' } } -ApiVersion '2024-05-01-preview' | Out-Null
if ($KeyVault) {
    Invoke-Arm PATCH $targets[1] @{ properties = @{ publicNetworkAccess = 'SecuredByPerimeter' } } -ApiVersion '2023-07-01' | Out-Null
}

Write-Host ""
$pna = az sql server show -g $Rg -n $Server --query publicNetworkAccess -o tsv
Write-Host "  $Server publicNetworkAccess = $pna"
Write-Host "  inbound: $Cidr   outbound: $($OutboundFqdns -join ', ')   mode: $AccessMode"
Write-Host "New venue IP? ./preflight-firewall.ps1 (calls this with -InboundOnly)."
Write-Host "Teardown: az resource delete --ids $nspId  (and set publicNetworkAccess back)"
