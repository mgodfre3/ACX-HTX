# ALDO-Side Sovereign Compute + AI Stack

Bicep templates for the Azure Local Disconnected Operations (ALDO) Tokyo-WKLD stamp. Deploys the on-prem side of the sovereign hybrid demo, following the same **Microsoft.Foundry Arc extension** pattern used by the Adaptive Cloud Lab MWC26 demo.

## What this deploys

| # | Resource | Provider | Notes |
|---|---|---|---|
| 1 | Ubuntu 24.04 VM running HashiCorp Vault | `Microsoft.AzureStackHCI/virtualMachineInstances@2025-02-01-preview` | Sovereign local key vault. Holds on-prem mirror of `htx-kek`. Stand-in for Luna HSM. Sized 4 vCPU / 8 GB via `hardwareProfile.processors + memoryMB`. |
| 2 | Arc-AKS provisioned cluster | `Microsoft.HybridContainerService/provisionedClusterInstances@2024-01-01` | System nodepool (3 nodes) + GPU nodepool (2 × A100). Node OS = Mariner Linux 3 (baked into extension). |
| 3 | AKS extensions | `Microsoft.KubernetesConfiguration/extensions@2024-11-01` | In install order: `Microsoft.CertManagement` → NVIDIA GPU Operator → KV Secrets Store CSI → Azure Monitor → **`Microsoft.Foundry`** → Flux |
| 4 | Flux GitOps binding | `Microsoft.KubernetesConfiguration/fluxConfigurations` | Watches `github.com/mgodfre3/ACX-HTX`, path `./arc-aks/foundry-local`. Delivers ModelDeployment CRs. |
| 5 | Windows Server 2025 jumpbox (optional) | `Microsoft.AzureStackHCI/virtualMachineInstances` | Off by default (`deployJumpbox=false`) |

## Azure Local vs Azure — Key ARM differences

This stack uses **`Microsoft.AzureStackHCI`** for VMs, not `Microsoft.Compute`. Notable differences from Azure VMs:

- **Sizing:** `hardwareProfile.processors` (vCPU count) + `hardwareProfile.memoryMB`, **not** `vmSize` strings like `Standard_D2as_v5`
- **API version:** `2025-02-01-preview` (or newer) — the API surface evolves quickly
- **Extended location:** every VM/NIC has an `extendedLocation` pointing at the ALDO stamp's Custom Location
- **Two resources per VM:** an `Microsoft.HybridCompute/machines` (Arc projection) + a child `virtualMachineInstances` (the actual VM)
- **No `userData` / cloud-init** on Linux — bootstrap is done post-boot via SSH
- **Storage:** `imageReference.id` points at a `galleryImages` resource on the stamp, not a marketplace URN

Reference: [Microsoft.AzureStackHCI/virtualMachineInstances](https://learn.microsoft.com/en-us/azure/templates/microsoft.azurestackhci/virtualmachineinstances?pivots=deployment-language-bicep)

## VM Images Expected

**Baked into AKS-Arc — nothing to pre-stage:**
- **Mariner Linux 3 (CBL-Mariner)** — control plane + all nodepool nodes. Pulled by the arc-appliance from the AKS-Arc extension.

**Pre-staged on the ALDO Tokyo-WKLD stamp (confirmed):**

| Image | Purpose | Resource ID (Tokyo-WKLD stamp) |
|---|---|---|
| **Ubuntu Server 24.04 LTS Gen2** | Vault VM (sovereign local key vault) | `/subscriptions/ef23bab2-.../resourceGroups/Tokyo-WKLD/providers/microsoft.azurestackhci/galleryimages/Ubuntu2404` |
| **Windows Server 2025 Datacenter Gen2** | Optional jumpbox | `/subscriptions/ef23bab2-.../resourceGroups/Tokyo-WKLD/providers/microsoft.azurestackhci/galleryimages/WS2025` |

## Foundry Local — Following the MWC26 pattern

This deploys Foundry Local via the public-preview **`Microsoft.Foundry` Arc extension**, matching the pattern in the Adaptive Cloud Lab MWC26 demo (`adaptivecloudlab-mwc26-demo/docs/foundry-arc-extension-migration.md`).

The extension:
1. Creates namespace `foundry-local-operator`
2. Installs the Foundry Local operator + CRDs (`Model`, `StoreModel`, `ModelDeployment`)
3. Wires up the `foundry-local-catalog` ConfigMap
4. Handles Entra ID JWT auth for model endpoints

Model workloads are declared via CRs in `arc-aks/foundry-local/model.yaml`, delivered by Flux:
- **Phi-4 mini** (catalog ref) — general-purpose on-prem AI
- **HTX cell-antenna detector** (BYO OCI from ACR mirror) — sovereign YOLOv8 fine-tune

## Prereqs

1. **RP registrations** on the subscription:
   ```powershell
   Register-AzResourceProvider -ProviderNamespace Microsoft.AzureStackHCI
   Register-AzResourceProvider -ProviderNamespace Microsoft.HybridContainerService
   Register-AzResourceProvider -ProviderNamespace Microsoft.HybridCompute
   Register-AzResourceProvider -ProviderNamespace Microsoft.KubernetesConfiguration
   ```

2. **Entra App Registration** for Foundry JWT auth. Create once in the customer tenant:
   ```powershell
   $app = New-AzADApplication -DisplayName 'HTX-Foundry-Local'
   # Note the AppId - set it in ALDO_FOUNDRY_ENTRA_CLIENT_ID
   $app.AppId
   ```

3. **SSH keypair** for the Vault VM admin. Public key is baked into `main.bicepparam`; private key lives outside the repo.

## Deploy

**Region:** ALDO stamps always use the special `Autonomous` region name.

**Subscription context:** ALDO ARM lives on the stamp's own Autonomous ARM plane — separate from public Azure Cloud. Run from a workstation signed into the Autonomous subscription (`ef23bab2-5bd7-afa3-3013-d5116a941684` for Tokyo-WKLD).

```powershell
# Sign into the Autonomous plane
Connect-AzAccount
Set-AzContext -Subscription 'ef23bab2-5bd7-afa3-3013-d5116a941684'

# Populate the Foundry client ID
$env:ALDO_FOUNDRY_ENTRA_CLIENT_ID = '<app-registration-app-id>'

# Preview (What-If may fail on Autonomous ARM plane for preview types)
./aldo/scripts/deploy.ps1 -WhatIf

# Static validation (skips What-If simulator)
./aldo/scripts/deploy.ps1 -Validate

# Real deploy
./aldo/scripts/deploy.ps1
```

## Post-deploy checklist

1. **Bootstrap the Vault VM.** Discover its private IP from the arc-appliance, then:
   ```powershell
   scp -i ~/.ssh/htx-vault-ed25519 aldo/scripts/init-vault.sh htxadmin@<vault-ip>:/tmp/
   ssh -i ~/.ssh/htx-vault-ed25519 htxadmin@<vault-ip> "sudo apt-get update && sudo apt-get install -y unzip jq curl && \
     curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
     echo 'deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main' | sudo tee /etc/apt/sources.list.d/hashicorp.list && \
     sudo apt-get update && sudo apt-get install -y vault && \
     sudo mkdir -p /etc/vault.d /opt/vault/data && \
     sudo bash /tmp/init-vault.sh"
   ```

2. **Enable etcd KMS on the AKS-Arc cluster** (post-Vault):
   ```powershell
   az aksarc update -g ACX-HTX-ALDO -n htxaldo-aks `
     --enable-azure-keyvault-kms `
     --azure-keyvault-kms-key-id "http://<vault-vm-ip>:8200/v1/transit/keys/htx-kek"
   ```

3. **Install ACR Connected Registry mirror** on the AKS cluster:
   ```powershell
   az acr connected-registry install info --registry acxhtxacraguuve6o --name aldo-tokyo-wkld
   # Follow the returned helm install instructions
   ```

4. **Verify Flux picked up the manifests**:
   ```bash
   kubectl get gitrepositories -A
   kubectl get kustomizations -A
   kubectl get modeldeployment -n foundry-local-operator -w
   ```
   First pull of `phi-4-mini` from the catalog takes 3-5 min on GPU nodes.

5. **Test end-to-end**: hit the Phi-4 endpoint from inside the cluster, then the antenna detector.

## What's still speculative

- **Foundry extension availability on Autonomous ARM** — `Microsoft.Foundry` is public preview in 18 regions; verify it's registered on the ALDO ARM plane's extensions catalog. If not, install path is manual helm chart deploy.
- **AKS-Arc `provisionedClusterInstances` API version** — templates target `2024-01-01`; verify against the ALDO stamp's installed extension.
- **A100 VM size string on Azure Local** — currently `Standard_NC24ads_A100_v4` in `aks-arc.bicep` (Arc-AKS agent pools use vmSize strings unlike the standalone VMs). Azure Local may use different naming.
- **KMS wire format** — HashiCorp Vault Transit engine speaks Vault gRPC, not the Azure Key Vault KMS plugin format. Real KMS integration needs either a Vault-KMS-shim pod or replacing Vault with an Azure Key Vault reachable over ExpressRoute.

None block the demo narrative — implementation details resolved once the stamp is up.
