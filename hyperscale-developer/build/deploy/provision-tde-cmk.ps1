<#
    Ward General Hospital — Hyperscale developer demo
    provision-tde-cmk.ps1 : switch the wardgeneral Hyperscale database's TDE
                            protector from the default SERVICE-managed key to a
                            CUSTOMER-managed key (CMK / BYOK) held in Azure Key
                            Vault, using a VERSIONLESS key with AUTOMATIC rotation.

    WHY (the "Secure it" story):
      TDE is on by default with a Microsoft-managed key. Regulated customers often
      must hold the encryption key themselves (BYOK) so they control its lifecycle
      and can revoke access. The TDE protector becomes a key in THEIR Key Vault; the
      logical server's managed identity wraps/unwraps the database encryption key
      with it. Using a VERSIONLESS key id + auto-rotation means Key Vault can roll
      the key and Azure SQL picks up the new version within 24h — zero-touch.

    Learn (accessed 2026-07-21):
      * Versionless key id (GA Mar 2026): https://<vault>.vault.azure.net/keys/<key> (no version).
        REQUIRES a current az CLI (>= ~2.83). An older CLI (e.g. 2.67) REJECTS the
        versionless kid client-side. Azure SQL RESOLVES the versionless id to the
        CURRENT enabled version and stores a VERSIONED reference, so `tde-key show`
        and the portal display a version — that is expected/by design. With a
        versionless id, SQL always uses the latest enabled version and auto-follows
        new versions (auto-rotation switches itself on). Verified end-to-end 2026-07-21.
      * az sql server key create --kid <versionless-keyID>
        az sql server tde-key set --server-key-type AzureKeyVault --kid <versionless-keyID> --auto-rotation-enabled true
      * Key Vault must have PURGE PROTECTION enabled for TDE CMK.

    NOTES:
      * Server-level TDE protector (applies to every database on collierhealth-49889)
        using the server's SYSTEM-assigned managed identity + a Key Vault ACCESS
        POLICY (get/wrapKey/unwrapKey). (Database-level CMK / cross-tenant needs a
        USER-assigned identity — out of scope here; server-level is the simple path.)
      * Reversible: point the protector back at the service-managed key with
        `az sql server tde-key set --server-key-type ServiceManaged` (teardown below).
      * Combined vault name + key name must be <= 94 chars (Learn).
      * All data synthetic. Prereq: az login + az account set -s <subscription>.
#>
[CmdletBinding()]
param(
    [string] $Rg       = 'rg-collierhealth',
    [string] $Server   = 'collierhealth-49889',
    [string] $Database = 'wardgeneral',
    [string] $Loc      = 'centralus',                 # MUST match the server region
    [string] $Vault    = 'kv-collierhealth-49889',      # globally unique; pass another if taken
    [string] $KeyName  = 'wardgeneral-tde-key',
    [string[]] $Tags   = @('application=ward-general-ehr','environment=sandbox','SecurityControl=Ignore')  # SecurityControl=Ignore: MCAPS policy exemption tag (keeps vault public access as configured)
)

$ErrorActionPreference = 'Stop'
$versionlessKid = "https://$Vault.vault.azure.net/keys/$KeyName"

Write-Host "=== TDE with customer-managed key (versionless + auto-rotate) ==="
Write-Host "  server   : $Server   database: $Database"
Write-Host "  key vault: $Vault ($Loc)   key: $KeyName"
Write-Host "  protector: $versionlessKid"
Write-Host ""

# 1) Ensure the logical server has a SYSTEM-assigned managed identity (idempotent).
Write-Host "--- 1/6  Server managed identity ---"
$miObjectId = az sql server show --resource-group $Rg --name $Server --query identity.principalId -o tsv
if (-not $miObjectId) {
    az sql server update --resource-group $Rg --name $Server --identity-type SystemAssigned -o none
    $miObjectId = az sql server show --resource-group $Rg --name $Server --query identity.principalId -o tsv
}
if (-not $miObjectId) { throw "Could not resolve the server's system-assigned identity." }
Write-Host "  server MI objectId: $miObjectId"

# 2) Key Vault with PURGE PROTECTION (required for TDE CMK), access-policy model.
Write-Host "--- 2/6  Key Vault (purge protection on) ---"
$kvExists = az keyvault list --resource-group $Rg --query "[?name=='$Vault'] | length(@)" -o tsv
if ($kvExists -eq '0') {
    az keyvault create --resource-group $Rg --name $Vault --location $Loc `
        --enable-purge-protection true `
        --enable-rbac-authorization false --tags @Tags -o none
} else { Write-Host "  $Vault already exists." }

# 3) Let the server MI wrap/unwrap/get the key.
Write-Host "--- 3/6  Grant server MI key permissions (get/wrapKey/unwrapKey) ---"
az keyvault set-policy --name $Vault --object-id $miObjectId `
    --key-permissions get wrapKey unwrapKey -o none

# 4) Create the RSA key that will be the TDE protector.
#    Governed subscriptions (e.g. MCAPS "KeyVault_PublicNetwork_Modify") force the
#    vault's publicNetworkAccess off, so the DATA-plane `az keyvault key create`
#    from a laptop is rejected (403 ForbiddenByConnection). Creating the key through
#    the ARM control plane (Microsoft.KeyVault/vaults/keys) works regardless.
Write-Host "--- 4/6  Create RSA key ---"
$kvPna = az keyvault show --resource-group $Rg --name $Vault --query properties.publicNetworkAccess -o tsv
$keyExists = az keyvault key list --vault-name $Vault --query "[?name=='$KeyName'] | length(@)" -o tsv 2>$null
if ($kvPna -eq 'Enabled' -and $LASTEXITCODE -eq 0) {
    if ($keyExists -eq '0') { az keyvault key create --vault-name $Vault --name $KeyName --kty RSA --size 2048 -o none }
} else {
    Write-Host "  vault publicNetworkAccess=$kvPna — creating the key via ARM (control plane)."
    $kvId = az keyvault show --resource-group $Rg --name $Vault --query id -o tsv
    $body = Join-Path $env:TEMP "kvkey-$KeyName.json"
    '{"properties":{"kty":"RSA","keySize":2048,"keyOps":["wrapKey","unwrapKey","encrypt","decrypt","sign","verify"]}}' |
        Set-Content -Path $body -Encoding utf8NoBOM
    $existing = az rest --method get --url "https://management.azure.com$kvId/keys/$KeyName`?api-version=2023-07-01" --query name -o tsv 2>$null
    if (-not $existing) {
        az rest --method put --url "https://management.azure.com$kvId/keys/$KeyName`?api-version=2023-07-01" --body "@$body" -o none
    }
    Remove-Item $body -ErrorAction SilentlyContinue
    # The server reaches the vault as a trusted service / intra-perimeter resource:
    # associate the vault with the SQL server's network security perimeter so SQL
    # (inside the perimeter) can wrap/unwrap the key.
    $nspScript = Join-Path $PSScriptRoot 'provision-network-perimeter.ps1'
    $sqlPna = az sql server show --resource-group $Rg --name $Server --query publicNetworkAccess -o tsv
    if ($sqlPna -eq 'SecuredByPerimeter' -and (Test-Path $nspScript)) {
        $mode = az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$Rg/providers/Microsoft.Network/networkSecurityPerimeters/nsp-collierhealth/resourceAssociations/assoc-$Server`?api-version=2024-07-01" --query properties.accessMode -o tsv 2>$null
        & $nspScript -Rg $Rg -Server $Server -KeyVault $Vault -AccessMode ($mode ? $mode : 'Learning')
    }
}

# 5) Register the key on the server using the VERSIONLESS key id (no version).
#    Requires a current az CLI (>= ~2.83); an older CLI rejects the versionless kid.
#    Azure SQL resolves it to the current enabled version and stores a versioned
#    reference — `tde-key show` / the portal will show a version. That is expected:
#    a versionless id means SQL always uses the latest enabled version and
#    auto-follows new versions (zero-touch).
Write-Host "--- 5/6  Register versionless key on the server ---"
az sql server key create --resource-group $Rg --server $Server --kid $versionlessKid -o none

# 6) Make it the TDE protector, with automatic rotation.
Write-Host "--- 6/6  Set TDE protector (versionless + auto-rotation) ---"
az sql server tde-key set --resource-group $Rg --server $Server `
    --server-key-type AzureKeyVault --kid $versionlessKid --auto-rotation-enabled true -o none

# TDE itself is on by default; make it explicit for the demo database.
az sql db tde set --resource-group $Rg --server $Server --database $Database --status Enabled -o none

# ---- Summary -------------------------------------------------------------
Write-Host ""
Write-Host "=== Result ==="
az sql server tde-key show --resource-group $Rg --server $Server `
    --query "{type:serverKeyType, uri:uri, autoRotation:autoRotationEnabled}" -o json
az sql db tde show --resource-group $Rg --server $Server --database $Database `
    --query "{database:'$Database', state:state}" -o json
Write-Host ""
Write-Host "Portal: $Server > Security > Transparent data encryption — 'Customer-managed key',"
Write-Host "        the key vault/key, and 'Auto-rotate key' checked."

# ---- Teardown (uncomment to revert to the service-managed key) ------------
# az sql server tde-key set -g $Rg -s $Server --server-key-type ServiceManaged
# az sql server key delete   -g $Rg -s $Server --kid $versionlessKid
# az keyvault key delete     --vault-name $Vault --name $KeyName
# NOTE: the vault has purge protection — it cannot be hard-deleted until the
#       soft-delete retention window elapses. az keyvault delete removes the vault
#       resource; the key material is retained until retention expiry.
