# Deployment Status

**Last deploy:** `acx-htx-core-20260904-1931`  
**RG:** `ACX-HTX` in West US 2  
**Repo:** https://github.com/mgodfre3/ACX-HTX

## Deployed and working

| Resource | Name | State |
|---|---|---|
| Key Vault Premium (HSM-backed) | `acxhtx-kv-aguuve6oq6by6` | ✅ Provisioned, RBAC mode, public firewall Deny + AzureServices bypass |
| KEK (RSA-HSM 3072) | `htx-kek` | ✅ Created, wrapKey/unwrapKey/encrypt/decrypt enabled |
| Storage Account | `acxhtxstgaguuve6oq6by6` | ✅ CMK active, pointing at `htx-kek`, public access Disabled |
| Blob container | `sovereign-cold` | ✅ Ready to receive encrypted envelopes |
| User-assigned MI | `acxhtx-mi-storage` | ✅ Has `Key Vault Crypto Service Encryption User` on the vault |
| Private endpoint — KV | `acxhtx-kv-aguuve6oq6by6-pe` | ✅ In `AC-Managment-WUS2/Default` |
| Private endpoint — Storage blob | `acxhtxstgaguuve6oq6by6-blob-pe` | ✅ In `AC-Managment-WUS2/Default` |

## Tag verification

All resources + the RG carry:
- `Project = HTX`
- `Created By = Michael Godfrey`

## Not deployed (feature-flagged off)

### Confidential VM
Set `deployCvm = true` in `main.bicep` to enable.

**Blocker:** SEV-SNP CVM SKUs (`DCasv5`, `DCadsv5`, `DCasv6`, `DCadsv6`, `ECasv5`, `ECasv6`) are **not offered on any hardware cluster this subscription is currently assigned to**. Direct real-create probes in eastus, eastus2, westus2, westus3, centralus, southcentralus, swedencentral, and uksouth all returned `"not available in the current region"`. `DCasv6` quota is 0/0 fleet-wide.

`az vm list-skus` and `az vm create --validate` do NOT catch this — both incorrectly reported the SKU as deployable. Only a real `az vm create` (with allocation) exposes the capacity gap.

**Additional constraint:** The demo VNet must be **peered to `AC-HubGW-EUS` and routed through the ExpressRoute gateway** (`AC-VNGW-EUS` in East US). `AC-Managment-WUS2` is already on this spine via Azure Virtual Network Manager peering with `useRemoteGateways=true`. Any CVM VNet must join the same routed topology.

**Unblock options (ranked):**
1. **File an Azure capacity request** for `standardDCASv5Family` (or `standardDCasv6Family`) in a region that hosts the AC hub or is peered to it — East US or West US 2 preferred. This is the correct long-term fix. Path: [Azure portal → Support → New Request → Service and subscription limits (quotas) → Compute](https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade/newsupportrequest).
2. **Deploy CVM in a region with confirmed capacity (North Europe / West Europe)** and create a new VNet peering to `AC-HubGW-EUS`. Cross-continent peering works but adds ~100 ms latency to on-prem calls.
3. **Wait for capacity** — SEV-SNP hardware allocation shifts weekly.

The Bicep already supports both approaches — `main.bicepparam` toggles region and CVM flag independently.

### AI Foundry hub + project
Set `deployFoundry = true` in `main.bicep` to enable.

**Blocker:** The Foundry hub deployment attempts to add its system-assigned MI to the associated Key Vault's `accessPolicies` at creation time. The ML workspaces RP first-party app does not have `Microsoft.KeyVault/vaults/accessPolicies/write` on our vault by default.

**Unblock options:**
1. Pre-create an access policy for the ML workspace RP object ID before deploying the hub.
2. Change the hub to consume a shared KV that already grants the RP permission.
3. Deploy Foundry using the newer AI Studio / Cognitive Services account pattern that doesn't require access-policy writes.

Recommendation: option 3 — modernize to the AI Studio account pattern in a follow-on iteration.

## Network Topology

- **VNet:** `AC-Managment-WUS2` (RG `AdaptiveCloud-Management`, region West US 2)
- **Subnet:** `Default` (10.255.250.0/28) — holds the KV + Storage private endpoints
- **Peered to:** `AC-HubGW-EUS` (hub in East US) via Azure Virtual Network Manager, `useRemoteGateways=true`
- **ExpressRoute path:** hub uses `AC-VNGW-EUS` gateway → ExpressRoute → on-prem
- **On-prem reachability:** routed via the hub's ER — Azure Local ALDO stamp will consume this same routing plane once ready

All private endpoints resolve on the peered spine; no public internet path exists for KV or Storage data plane.

## Accessing the vault

The vault firewall is `defaultAction: Deny` with `bypass: AzureServices`. This means:
- ✅ Azure Storage CMK works (via `AzureServices` trusted-services bypass)
- ✅ CVM system-assigned MI works from inside the VNet
- ❌ Direct CLI access from your laptop is blocked

To read/manage the vault from a laptop, either:
- RDP through Azure Bastion into a jumpbox in the VNet, then run `az` commands there
- Temporarily add your IP to the KV firewall (against the "no public path" pattern — do only for debugging)

Role assignments already granted:
- `acxhtx-mi-storage` → **Key Vault Crypto Service Encryption User**
- `migodfre_microsoft` (deployer) → **Key Vault Administrator** (RBAC granted post-deploy)

## Redeploy

```powershell
cd C:\path\to\ACX-HTX
./scripts/deploy.ps1 -SubscriptionId <sub> -CvmAdminPassword (Read-Host -AsSecureString)
```

## Cleanup

```powershell
az group delete --name ACX-HTX --yes --no-wait
# Purge soft-deleted KV (mandatory for redeploy with same name)
az keyvault purge --name acxhtx-kv-aguuve6oq6by6 --location westus2
```
