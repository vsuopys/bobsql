# My Ward General environment (vsuopys fork)

This file describes the Azure environment I built for Bob Ward's Hyperscale developer demo,
in subscription **ME-MngEnvMCAP976054-demo-dev** (`88a1feda-07e6-4bf9-9d09-6ea5ec00b3bf`,
tenant `e71d46fa-628e-4058-9b01-ed89333c0ae8`). All scripts in `build/` default to these names.
Run the demo with [DEMO-RUNBOOK.md](DEMO-RUNBOOK.md).

> **No secrets in this file. There is no usable SQL login.** The server is **Entra-only**
> (required by an MCAPS policy). Sign in as `admin@mngenvmcap976054.onmicrosoft.com` with
> Microsoft Entra MFA / `az login`. Azure created the server with an auto-generated, disabled
> SQL admin (`CloudSA7688890b`). The `SQL_ADMIN_USER` / `SQL_ADMIN_PASSWORD` values in the
> git-ignored `build/.env.local` were **never applied** to the server.

## Resources

Resource group **`rg-collierhealth`**. Every resource carries Bob's tags
(`application=ward-general-ehr`, `environment=sandbox`, `criticality=low`, `dataClassification=nonproduction`, `owner`) and **`SecurityControl=Ignore`**.
Without that tag, MCAPS policy forces public network access off on SQL and Key Vault.

| Resource | Name | Region | SKU / shape |
|---|---|---|---|
| Logical SQL server | `collierhealth-49889` (`collierhealth-49889.database.windows.net`) | centralus | Entra-only auth. Admin = System Administrator (`4db5c918-…`). System MI `3822a590-…`. Public network access **Enabled** |
| Hyperscale DB (primary) | `wardgeneral` | centralus | **HS_Gen5_2**, **1 HA replica**, **zone redundant**, backup GeoZone. ~12.7 GB used, 20 GB allocated. TDE with CMK |
| Hyperscale named replica | `wardgeneral-research` | centralus | **HS_Gen5_2** provisioned, 0 HA replicas (research / vector search) |
| Azure AI Foundry (AIServices) | `collierhealth-49889-ai` | **eastus2** | S0. Deployments: `gpt-5` (2025-08-07, GlobalStandard, 100K TPM) and `text-embedding-3-large` (v1, GlobalStandard, 500K TPM) |
| API Management (AI gateway) | `collierhealth-49889-ai-gateway` (`https://collierhealth-49889-ai-gateway.azure-api.net`) | centralus | **StandardV2**, 1 unit, system MI |
| Content Safety | `collierhealth-49889-contentsafety` | centralus | F0 (free) |
| Key Vault | `kv-collierhealth-49889` | centralus | Standard, access-policy auth, purge protection. Key `wardgeneral-tde-key` (RSA) is the TDE protector, with auto-rotation |
| Virtual network | `vnet-collierhealth` (10.42.0.0/16, subnet `snet-sql` 10.42.1.0/24) | centralus | — |
| Private endpoint | `pe-collierhealth-sql` (+ NIC) → SQL server, private IP **10.42.1.4** | centralus | Standard PE |
| Private DNS zone | `privatelink.database.windows.net` + link `vnet-collierhealth-link` | global | — |

Role assignments the scripts created:
- **SQL server MI:** *Cognitive Services OpenAI User* on Foundry, plus a Key Vault access policy with get / wrapKey / unwrapKey.
- **APIM MI:** *Cognitive Services OpenAI User* on Foundry and *Cognitive Services User* on Content Safety.
- **Signed-in admin user:** *Cognitive Services OpenAI User* (needed by the app's agent through `DefaultAzureCredential`) and a Key Vault access policy with all key permissions.

### SQL firewall rules

| Rule | Range | Why |
|---|---|---|
| `client-home` | *(home /32, not recorded here)* | The IP that `ipify` reports for this laptop |
| `gsa-egress-4-194-122` | 4.194.122.0–255 | **Global Secure Access** egress that SQL actually sees |
| `gsa-egress-52-172-102` | 52.172.102.0–255 | Same — GSA egress pool (it rotates) |

With the GSA client running, `*.database.windows.net` traffic leaves through Microsoft's GSA egress,
not your home IP. If a login fails with **40615**, read the IP from the error and add a rule.
For example: `./build/preflight-firewall.ps1 -Cidr <a.b.c.0/24> -Yes`.

Logins to `master` exit through other, scattered GSA IPs and may be rejected. The demo only
connects to `wardgeneral` and `wardgeneral-research`.

## Deviations from Bob's defaults

| Area | Bob | Here | Why |
|---|---|---|---|
| SQL region | eastus2 | **centralus** | Hyperscale provisioning is restricted for this subscription in eastus2. Foundry stays in eastus2 |
| SLO | HS_Gen5_8 | **HS_Gen5_2**, HA 1, ZR on | Your choice (cost) |
| Named replica | serverless | **HS_Gen5_2 provisioned** | Your choice. `provision-research-replica.ps1 -ServiceObjective` / `$env:REPLICA_SLO` |
| SQL auth | SQL + Entra | **Entra-only** (`ENTRA_ONLY=true`) | A MCAPS *Deny* policy requires Entra-only auth |
| Public access | firewall | firewall + `SecurityControl=Ignore` tag | A MCAPS *Modify* policy otherwise disables public access. `provision-network-perimeter.ps1` (NSP) is an optional fallback; not deployed |
| Private Link | sole path | **extra** endpoint | The app and DAB run on this laptop, so public access stays on. The Private Link beat still shows the PE, private IP and DNS zone |
| DAB install | `dotnet tool install` | x64 dotnet host on Windows Arm64 | DAB has no win-arm64 RID. `build.ps1` now retries with `C:\Program Files\dotnet\x64\dotnet.exe` |
| Embeddings | single process | `generate-embeddings.ps1 -Shards 16 -BatchSize 250` (~60 min total) | Faster on a 2-vCore DB. The batch is staged in `#batch` before `AI_GENERATE_EMBEDDINGS`; inline, some shard plans evaluated the model call for rows already embedded and stalled. The DiskANN index is built once all shards finish |

## Start / stop the demo

```powershell
cd hyperscale-developer/build
az account set -s 88a1feda-07e6-4bf9-9d09-6ea5ec00b3bf
./preflight-firewall.ps1 -Yes          # optional; run.ps1 calls it (adds ipify /32 rule)
./run.ps1                              # DAB on http://localhost:5000, app on https://localhost:7170
#   -NoBrowser  -NoDab  -SkipFirewall  are available
./dab/probe-mcp.ps1                    # DAB MCP endpoint check
./shutdown.ps1                         # stop app + DAB
```

Common rebuild steps (all idempotent):
- `./build.ps1` (dotnet build, plus DAB tool install)
- `./deploy/deploy-sql.ps1 -Scripts connect-and-verify,verify-data`
- `./deploy/run-ai-gateway-e2e.ps1 -SkipSetup`
- `./diagnostics/test-ai-assistance.ps1`

## Estimated monthly cost (always-on)

Prices come from the [Azure Retail Prices API](https://prices.azure.com/api/retail/prices): USD, pay-as-you-go, centralus (Foundry in eastus2), 730 h/month.

| Item | Meter / basis | ≈ USD / month |
|---|---|---:|
| Hyperscale compute – primary (2 vCores) | $0.22 / vCore-h | 321.20 |
| Hyperscale compute – HA secondary (2 vCores) | $0.22 / vCore-h | 321.20 |
| Hyperscale compute – named replica `wardgeneral-research` (2 vCores) | $0.22 / vCore-h | 321.20 |
| Hyperscale data storage (~20 GB allocated) | $0.12 / GB-mo | 2.40 |
| Backup storage (GeoZone / RA-GZRS, ~20 GB) | $0.25 / GB-mo | ~5 |
| APIM StandardV2 (1 unit) | $0.96 / h | 700.80 |
| Private endpoint | ~$0.01 / h + $0.01 / GB (not returned by the API; list price) | ~7.30 |
| Private DNS zone | $0.50 / zone | 0.50 |
| Key Vault (Standard) | $0.03 / 10K ops (+$1 per automated rotation) | < 1 |
| Content Safety F0 | free tier | 0 |
| Foundry – gpt-5 (Global) | $1.25 / 1M input, $10 / 1M output tokens | usage (≈ 0 idle) |
| Foundry – text-embedding-3-large | $0.13 / 1M tokens | usage. The one-time 60K-note embedding run was ≈ $1–3 |
| VNet | free | 0 |
| **Total (idle run-rate)** | | **≈ $1,680 / month (≈ $2.30 / hour)** |

SQL compute (~$964) and APIM (~$701) make up about 99% of the cost. No separate
zone-redundancy meter is listed for Hyperscale.

## Cost controls

```powershell
$rg='rg-collierhealth'; $srv='collierhealth-49889'

# 1) Drop the named research replica (-$321/mo). Recreate later with
#    ./deploy/provision-research-replica.ps1 -ServiceObjective HS_Gen5_2
az sql db delete -g $rg -s $srv -n wardgeneral-research --yes

# 2) Make the replica serverless instead (pay per use; min 0.5 vCore when active)
az sql db update -g $rg -s $srv -n wardgeneral-research --compute-model Serverless -e Hyperscale -f Gen5 -c 2 --min-capacity 0.5

# 3) Primary: HS_Gen5_2 is already the smallest provisioned size. To drop the HA replica
#    (-$321/mo) you must also turn zone redundancy off, because ZR Hyperscale needs >= 1 HA replica
az sql db update -g $rg -s $srv -n wardgeneral --zone-redundant false --ha-replicas 0
#    ...and to restore the demo shape:
az sql db update -g $rg -s $srv -n wardgeneral --service-objective HS_Gen5_2 --ha-replicas 1 --zone-redundant true

# 4) Delete the APIM AI gateway (-$701/mo). Recreate with
#    ./deploy/azureaideploy.ps1 -SkipModels -Gateway -ContentSafety  (~5-45 min)
az apim delete -n collierhealth-49889-ai-gateway -g $rg --yes --no-wait

# 5) Full teardown: deletes the resource group (SQL, AI, APIM, KV, network)
./build/teardown.ps1 -Azure            # prompts; -Force skips the prompt
./build/teardown.ps1 -Azure -Purge     # also purges soft-deleted AI account (KV purge protection blocks KV purge for 90 days)
```

After deleting APIM, the gateway beat (`09-ai-gateway`, `run-ai-gateway-e2e.ps1`) won't work.
The direct Foundry path (`07`, `08`, the app agent) keeps working.

## Verification (at build time)

Checked on 2026-10-01:

| Check | Result |
|---|---|
| `az sql db show` wardgeneral | HS_Gen5_2, HA replicas 1, zone redundant, GeoZone backup, Online ✅ |
| `az sql db show` wardgeneral-research | Named replica, HS_Gen5_2, Online ✅ |
| TDE | DB encryption Enabled; protector `AzureKeyVault` with auto-rotation ✅ |
| Private endpoint | `pe-collierhealth-sql` Approved, 10.42.1.4 ✅ |
| `deploy-sql.ps1 -Scripts connect-and-verify,verify-data` | PASS (16 base tables, ~12.7 GB, 108M observations) ✅ |
| `deploy/verify-embeddings.sql` | 60000 / 60000 embedded, 0 NULL; `VIX_ClinicalNoteEmbeddings_Embedding` (VECTOR index) present ✅ |
| `diagnostics/verify-rls.sql` | Without session context: 40000 rows; attending 3: 45 encounters; "census mine": 11 ✅ |
| `diagnostics/test-ai-assistance.ps1` | PASS: gpt-5 triage plus RAG over 5 similar notes; audit row appended ✅ |
| `deploy/run-ai-gateway-e2e.ps1 -SkipSetup` | PASS: DB → APIM (MI token) → gpt-5. Policy includes validate-azure-ad-token, llm-content-safety, token limit and token metrics ✅ |
| `clinical.SearchSimilarNotes` on `wardgeneral-research` | READ_ONLY replica returns vector results ✅ |
| `build.ps1` | dotnet build plus DAB 2.1.5 ✅ |
| `run.ps1` | DAB :5000 healthy; `/`, `/chart/137` and `/research` return 200 with data; DAB REST `SearchSimilarNotes` works ✅ |
| `dab/probe-mcp.ps1` | MCP session established, 12 tools ✅ |
| `shutdown.ps1` | Both processes stopped ✅ |
