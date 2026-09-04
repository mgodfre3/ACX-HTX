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

**Blocker:** SEV-SNP CVM SKUs (`DCasv5`, `DCadsv5`, `DCasv6`, `DCadsv6`, `ECasv5`, `ECasv6`) are **not offered** on the compute hardware this subscription is assigned to in West US 2. ARM's error explicitly listed only L-family and E-family sizes as available. `DCasv6` quota is 0/0 (needs quota request), and `DCasv5` shows quota available but the deployment fails with "not available in current region."

**Unblock options:**
1. **Submit a quota + capacity request** for `standardDCasv6Family` in West US 2 via [Azure portal](https://portal.azure.com/#blade/Microsoft_Azure_Capacity/UsageAndQuota.ReactView).
2. **Deploy the CVM in a different region** (e.g., `eastus2` where DCasv5 is broadly offered) and peer the VNet back to `AC-Managment-WUS2`.
3. **Wait for capacity** — SEV-SNP capacity in West US 2 fluctuates.

Recommendation: option 2 is fastest if urgency demands. The Bicep is region-agnostic and the private endpoints work across peered VNets.

### AI Foundry hub + project
Set `deployFoundry = true` in `main.bicep` to enable.

**Blocker:** The Foundry hub deployment attempts to add its system-assigned MI to the associated Key Vault's `accessPolicies` at creation time. The ML workspaces RP first-party app does not have `Microsoft.KeyVault/vaults/accessPolicies/write` on our vault by default.

**Unblock options:**
1. Pre-create an access policy for the ML workspace RP object ID before deploying the hub.
2. Change the hub to consume a shared KV that already grants the RP permission.
3. Deploy Foundry using the newer AI Studio / Cognitive Services account pattern that doesn't require access-policy writes.

Recommendation: option 3 — modernize to the AI Studio account pattern in a follow-on iteration.

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
