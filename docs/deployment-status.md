# Deployment Status

**Last deploy:** `acx-htx-cmkvm-retry-20260904-2131`  
**RG:** `ACX-HTX` in West US 2  
**Repo:** https://github.com/mgodfre3/ACX-HTX

## Deployed and working

| Resource | Name | State |
|---|---|---|
| Key Vault Premium (HSM-backed) | `acxhtx-kv-aguuve6oq6by6` | ✅ RBAC, firewall Deny + AzureServices bypass, private endpoint |
| KEK (RSA-HSM 3072) | `htx-kek` | ✅ Backs both storage CMK and disk CMK |
| Storage Account | `acxhtxstgaguuve6oq6by6` | ✅ CMK active, public access Disabled, private endpoint |
| Blob container | `sovereign-cold` | ✅ Ready for encrypted envelope drops |
| User-assigned MI | `acxhtx-mi-storage` | ✅ `Key Vault Crypto Service Encryption User` on the vault |
| **Disk Encryption Set** | `acxhtx-des` | ✅ System-assigned MI, KEK-rotation enabled |
| **VM (Trusted Launch)** | `acxhtx-vm` (`Standard_D2as_v5`, Windows Server 2022) | ✅ Running, OS disk **CMK-encrypted via customer KEK**, no public IP |

## Key custody proof

The VM's OS disk `acxhtx-vm_OsDisk_1_*` shows:
```json
"encryption": {
  "type": "EncryptionAtRestWithCustomerKey",
  "diskEncryptionSetId": ".../diskEncryptionSets/acxhtx-des"
}
```
The DES pulls the key from `htx-kek` in the HSM-backed Key Vault. **Revoke the KEK → the VM's disks become unreadable.** That's the sovereign-key demo, provable in three CLI commands.

## Confidential VM (SEV-SNP) — Deferred

Set `deployCvm = true` in `main.bicepparam` when capacity returns.

**Blocker:** SEV-SNP CVM SKUs (`DCasv5`, `DCadsv5`, `DCasv6`, `DCadsv6`, `ECasv5`, `ECasv6`) are **not offered on any hardware cluster this subscription is currently assigned to**. Direct real-create probes in eastus, eastus2, westus2, westus3, centralus, southcentralus, swedencentral, and uksouth all returned `"not available in the current region"`. `DCasv6` quota is 0/0 fleet-wide.

`az vm list-skus` and `az vm create --validate` do NOT catch this — both incorrectly reported the SKU as deployable. Only a real `az vm create` (with allocation) exposes the capacity gap.

**Design note:** Per the demo goal ("show the art of the possible, closest solution — actual deployment planned in years, not months"), the CMK-encrypted Trusted Launch VM (`acxhtx-vm`) stands in for the CVM. Same customer-key custody story; SEV-SNP memory encryption + attestation swap in when capacity returns.

## Network Topology

- **VNet:** `AC-Managment-WUS2` (RG `AdaptiveCloud-Management`, region West US 2)
- **Subnet:** `Default` (10.255.250.0/28) — holds the KV + Storage private endpoints and the VM NIC
- **Peered to:** `AC-HubGW-EUS` (hub in East US) via Azure Virtual Network Manager, `useRemoteGateways=true`
- **ExpressRoute path:** hub uses `AC-VNGW-EUS` gateway → ExpressRoute → on-prem
- **On-prem reachability:** routed via the hub's ER — Azure Local ALDO stamp will consume this same routing plane once ready

All private endpoints resolve on the peered spine; no public internet path exists for KV or Storage data plane.

## Tag verification

All resources + the RG carry:
- `Project = HTX`
- `Created By = Michael Godfrey`

## AI Foundry — Deferred

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
- ✅ Disk Encryption Set works (same bypass)
- ✅ VM system-assigned MI works from inside the VNet
- ❌ Direct CLI access from your laptop is blocked

To read/manage the vault from a laptop, either:
- Access through an existing shared Bastion in the peered network, then run `az` from a jumpbox
- Temporarily add your IP to the KV firewall (against the "no public path" pattern — do only for debugging)

Role assignments already granted:
- `acxhtx-mi-storage` → **Key Vault Crypto Service Encryption User**
- `acxhtx-des` (system MI) → **Key Vault Crypto Service Encryption User**
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

