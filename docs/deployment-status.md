# Deployment Status

**Last deploy:** `acx-htx-foundry-rbac-20260904-2207`  
**RG:** `ACX-HTX` in West US 2  
**Repo:** https://github.com/mgodfre3/ACX-HTX

## Deployed and working

| Resource | Name | State |
|---|---|---|
| Key Vault Premium (HSM-backed) | `acxhtx-kv-aguuve6oq6by6` | ✅ RBAC, firewall Deny + AzureServices bypass, private endpoint |
| KEK (RSA-HSM 3072) | `htx-kek` | ✅ Backs storage CMK + disk CMK + ACR CMK |
| Storage Account | `acxhtxstgaguuve6oq6by6` | ✅ CMK active, public access Disabled, private endpoint |
| Blob container | `sovereign-cold` | ✅ Ready for encrypted envelope drops |
| User-assigned MI (storage) | `acxhtx-mi-storage` | ✅ Key Vault Crypto Service Encryption User on the sovereign vault |
| User-assigned MI (ACR) | `acxhtx-acr-mi` | ✅ Key Vault Crypto Service Encryption User on the sovereign vault |
| Disk Encryption Set | `acxhtx-des` | ✅ System-assigned MI, KEK-rotation enabled |
| **VM (Trusted Launch)** | `acxhtx-vm` (`Standard_D2as_v5`, Windows Server 2022) | ✅ Running, OS disk **CMK-encrypted via customer KEK**, no public IP |
| **ACR (Premium, CMK-encrypted)** | `acxhtxacraguuve6o` | ✅ Encryption enabled, key `htx-kek`, model registry |
| **Foundry hub** | `acxhtx-foundry-hub` | ✅ Kind=Hub, wired to storage + KV + ACR + AppInsights |
| **Foundry project** | `acxhtx-foundry-proj` | ✅ Kind=Project, child of hub |
| Foundry associated KV | `acxhtx-fdy-kv-aguuve` | ✅ RBAC-authorized (Foundry uses role assignments, not access policies) |
| Foundry associated storage | `acxhtxfdystgaguuve6o` | ✅ StorageV2 |
| Foundry App Insights | `acxhtx-fdy-ai-aguuve` | ✅ Web kind |

## Key custody proof (three levels, one key)

Every encryption relationship in the RG points at the same customer KEK:

```
htx-kek (RSA-HSM 3072, in acxhtx-kv-aguuve6oq6by6)
    │
    ├── acxhtxstgaguuve6oq6by6 (Storage CMK) ──► sovereign-cold blobs
    │
    ├── acxhtx-des (Disk Encryption Set) ──► acxhtx-vm OS disk
    │
    └── acxhtxacraguuve6o (ACR CMK) ──► model artifacts + container images
```

Revoke the KEK once → **VM disks unreadable, storage blobs unreadable, ACR images unreadable — simultaneously.** That's the sovereign-key demo, provable in one CLI command.

## The ML lifecycle path (new)

The Foundry hub + project + CMK-encrypted ACR give us the complete customer-key-controlled training + distribution pipeline:

1. **Training data** — uploaded to Foundry storage (CMK)
2. **Compute** — GPU cluster attached to the hub, disks CMK-encrypted
3. **Training job** — `training/train-job.yml` runs YOLOv8 fine-tune on cell-antenna imagery
4. **Model artifact** — pushed to CMK-encrypted ACR as an OCI image via ORAS
5. **Distribution** — Arc-AKS clusters on ALDO stamps pull via ACR Connected Registry
6. **Serving** — Foundry Local on the ALDO GPU node loads and serves

See `training/README.md` and `arc-aks/README.md` for the pipeline details.

## Network Topology

- **VNet:** `AC-Managment-WUS2` (RG `AdaptiveCloud-Management`, region West US 2)
- **Subnet:** `Default` (10.255.250.0/28) — holds the KV + Storage private endpoints and the VM NIC
- **Peered to:** `AC-HubGW-EUS` (hub in East US) via Azure Virtual Network Manager, `useRemoteGateways=true`
- **ExpressRoute path:** hub uses `AC-VNGW-EUS` gateway → ExpressRoute → on-prem
- **On-prem reachability:** routed via the hub's ER — Azure Local ALDO stamp will consume this same routing plane

Private endpoints resolve inside the Azure workload VNet; no public internet
path exists for KV or Storage data plane. ALDO DNS did not resolve the Storage
private endpoint during validation, so the Foundry guest temporarily maps it in
the hosts file.

## On-prem side

The sovereign data pipeline was deployed and validated end to end on
2026-09-09:

| Component | Location | Observed state |
|---|---|---|
| Vault VM | `htxaldo-vault` / `172.22.218.200` | Vault 2.1.0 initialized and unsealed; Transit key `htx-kek` is RSA-3072 |
| Unwrap service | `/opt/htx-unwrap` on the Vault VM | `htx-unwrap.service` active; private endpoint `http://172.22.218.200:8443/unwrap` |
| Producer | `C:\HTX\producer` on `htxaldo-foundry` / `172.22.218.201` | Windows Server 2025 CPU-only fallback; generated and Vault-wrapped a 292-byte telemetry payload |
| Consumer | `C:\HTX\consumer` on `acxhtx-vm` / `10.255.250.9` | System-assigned identity has Storage Blob Data Reader; decrypted the payload successfully |

The validated envelope is
`sovereign-encrypted/htxaldo-foundry/2026/09/09/80df8661-b6d2-44f6-b5c9-7d9110649bc8.envelope.json`.
The unwrap audit showed a request from `10.255.250.9`, the Trusted Launch demo
attestation decision, and HTTP 200. Disabling the Azure Key Vault copy of
`htx-kek` did not disable the separate Vault Transit key: a cached wrapped
envelope still unwrapped and decrypted while the Azure key was disabled.

## Tag verification

All resources + the RG carry:
- `Project = HTX`
- `Created By = Michael Godfrey`

## Confidential VM (SEV-SNP) — Deferred

Set `deployCvm = true` in `main.bicepparam` when capacity returns.

**Blocker:** SEV-SNP CVM SKUs (`DCasv5`, `DCadsv5`, `DCasv6`, `DCadsv6`, `ECasv5`, `ECasv6`) are **not offered on any hardware cluster this subscription is currently assigned to**. Real-create probes across 8 US + EU regions all returned `"not available"`.

**Design note:** Per the demo goal ("show the art of the possible, closest solution — actual deployment planned in years, not months"), the CMK-encrypted Trusted Launch VM (`acxhtx-vm`) stands in for the CVM. Same customer-key custody story; SEV-SNP memory encryption + attestation swap in when capacity returns.

## Accessing the vault

The vault firewall is `defaultAction: Deny` with `bypass: AzureServices`. This means:
- ✅ Storage CMK, DES, ACR CMK all work (via AzureServices trusted-services bypass)
- ✅ VM system-assigned MI works from inside the VNet
- ❌ Direct CLI access from your laptop is blocked

Role assignments granted:
- `acxhtx-mi-storage` → **Key Vault Crypto Service Encryption User**
- `acxhtx-acr-mi` → **Key Vault Crypto Service Encryption User**
- `acxhtx-des` (system MI) → **Key Vault Crypto Service Encryption User**
- `migodfre_microsoft` (deployer) → **Key Vault Administrator** (granted post-deploy)

## Redeploy

```powershell
cd C:\path\to\ACX-HTX
./scripts/deploy.ps1 -SubscriptionId <sub> -CvmAdminPassword (Read-Host -AsSecureString)
```

## Cleanup

```powershell
az group delete --name ACX-HTX --yes --no-wait
# Purge soft-deleted KVs (mandatory for redeploy with same names)
az keyvault purge --name acxhtx-kv-aguuve6oq6by6 --location westus2
az keyvault purge --name acxhtx-fdy-kv-aguuve --location westus2
```
