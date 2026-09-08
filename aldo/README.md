# ALDO-Side Sovereign Compute + AI Stack

Bicep templates for the Azure Local Disconnected Operations (ALDO) Tokyo WKLD stamp. These are **draft templates ready to run once the stamp is up**; they cannot be `what-if`'d against Azure directly because they target `Microsoft.AzureStackHCI` + `Microsoft.HybridContainerService` providers, which require an existing custom location on an Azure Local cluster.

## What this deploys

| # | Resource | Provider | Notes |
|---|---|---|---|
| 1 | Ubuntu 22.04 VM running HashiCorp Vault | `Microsoft.AzureStackHCI/virtualMachineInstances` | Sovereign local key vault. Holds on-prem mirror of `htx-kek`. Stand-in for Luna HSM. |
| 2 | Arc-AKS provisioned cluster | `Microsoft.HybridContainerService/provisionedClusterInstances` | System nodepool + GPU nodepool with A100 passthrough. Node OS = Mariner Linux 3. |
| 3 | AKS extensions | `Microsoft.KubernetesConfiguration/extensions` | NVIDIA GPU Operator, KV Secrets Store CSI, Azure Monitor, Flux |
| 4 | Flux GitOps binding | `Microsoft.KubernetesConfiguration/fluxConfigurations` | Points at `github.com/mgodfre3/ACX-HTX` — new model version = new commit = automated rollout |
| 5 | Windows Server 2022 jumpbox (optional) | `Microsoft.AzureStackHCI/virtualMachineInstances` | Off by default (`deployJumpbox=false`) |

**Not in Bicep** (done post-deploy via `az` CLI):
- **ACR Connected Registry mirror** — activated with `az acr connected-registry install info` then installed onto the AKS cluster as a helm chart. Sync token + scope map are in the Azure-side `arc-aks/connected-registry.bicep`.
- **AKS-Arc etcd KMS** — enabled with `az aksarc update --enable-azure-keyvault-kms` once the Vault VM is reachable.

## VM Images Expected

**Baked into AKS-Arc — nothing to pre-stage:**
- **Mariner Linux 3 (CBL-Mariner)** — control plane + all nodepool nodes. Pulled by the arc-appliance from the AKS-Arc extension.

**Pre-staged on the ALDO Tokyo WKLD stamp (confirmed):**

| Image | Purpose | Source |
|---|---|---|
| **Ubuntu Server 22.04 LTS Gen2** | Vault VM (sovereign local key vault) | Canonical marketplace VHD |
| **Windows Server 2025 Datacenter Gen2** | Optional jumpbox | Microsoft marketplace VHD (2025 is newer than the original 2022 spec — same architecture, cleaner OS) |

Pass their **full resource IDs** as parameters (`ubuntuGalleryImageId`, `windowsGalleryImageId`).

**Container images** (pulled through the Connected Registry mirror once activated):
- `mcr.microsoft.com/foundry-local:<version>` (Microsoft container)
- `mcr.microsoft.com/oss/kubernetes/kubernetes-node-problem-detector`
- `mcr.microsoft.com/oss/nvidia/k8s-device-plugin` (via GPU operator extension)
- `acxhtxacraguuve6o.azurecr.io/models/htx-antenna-detector:v1` (CMK-encrypted, published from Azure Foundry)

## Prereqs the ALDO admin provides

Before running the Bicep, gather these and populate `main.bicepparam` (or export as env vars):

1. **Custom Location resource ID**:
   ```powershell
   az customlocation list --query "[?contains(tolower(name), 'aldo') || contains(tolower(name), 'tokyo')]" -o table
   ```

2. **Logical Network name + resource group**:
   ```powershell
   az stack-hci logical-network list --query "[]" -o table
   ```

3. **Gallery Image IDs** (Ubuntu 22.04 + optionally Windows Server 2022):
   ```powershell
   az stack-hci gallery-image list -g <hci-gallery-rg> --query "[].{name:name, id:id}" -o table
   ```

4. **SSH public key** for the Vault VM admin:
   ```powershell
   ssh-keygen -t ed25519 -f ~/.ssh/htx-vault -C "htxadmin@bootstrap"
   Get-Content ~/.ssh/htx-vault.pub
   ```

5. **RP registrations**:
   ```powershell
   az provider register --namespace Microsoft.AzureStackHCI
   az provider register --namespace Microsoft.HybridContainerService
   az provider register --namespace Microsoft.HybridCompute
   az provider register --namespace Microsoft.KubernetesConfiguration
   ```

## Deploy

**Region:** ALDO stamps always use the special `Autonomous` region name. This is the ARM location value for both the RG and all resources.

**Subscription context:** ALDO ARM lives on the stamp's own Autonomous ARM plane — separate from public Azure Cloud. Run the deploy from a workstation that is signed into the Autonomous subscription (`ef23bab2-5bd7-afa3-3013-d5116a941684` for Tokyo-WKLD).

Concrete stamp IDs are pinned in `main.bicepparam`. To deploy:

```powershell
# From a workstation signed into the Autonomous ARM plane
Connect-AzAccount -Environment AzureCloud   # or the appropriate cloud entry for ALDO
Set-AzContext -Subscription 'ef23bab2-5bd7-afa3-3013-d5116a941684'

# Preview
./aldo/scripts/deploy.ps1 -WhatIf

# Deploy
./aldo/scripts/deploy.ps1

# With jumpbox
./aldo/scripts/deploy.ps1 -DeployJumpbox
```

If you prefer raw `New-AzSubscriptionDeployment`:

```powershell
New-AzSubscriptionDeployment `
  -Location 'Autonomous' `
  -TemplateFile 'aldo/main.bicep' `
  -TemplateParameterFile 'aldo/main.bicepparam' `
  -Name "aldo-htx-$(Get-Date -Format yyyyMMdd-HHmm)"
```

## Post-deploy checklist

1. **Bootstrap the Vault VM.** SSH in and run the init script:
   ```powershell
   $vaultIp = az deployment sub show --name aldo-htx-<date> --query "properties.outputs.vaultVmPrivateIp.value" -o tsv
   scp aldo/scripts/init-vault.sh htxadmin@$vaultIp:/tmp/
   ssh htxadmin@$vaultIp "sudo apt-get update && sudo apt-get install -y unzip jq curl && \
     curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
     echo 'deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main' | sudo tee /etc/apt/sources.list.d/hashicorp.list && \
     sudo apt-get update && sudo apt-get install -y vault && \
     sudo mkdir -p /etc/vault.d /opt/vault/data && \
     sudo bash /tmp/init-vault.sh"
   ```
   This installs Vault, configures single-node file storage, initializes/unseals, enables Transit engine, and creates `htx-kek`. In production this is a BYOK ceremony from the customer HSM.

2. **Enable etcd KMS on the AKS-Arc cluster**:
   ```powershell
   az aksarc update -g ACX-HTX-ALDO -n htxaldo-aks `
     --enable-azure-keyvault-kms `
     --azure-keyvault-kms-key-id "http://<vault-vm-ip>:8200/v1/transit/keys/htx-kek"
   ```

3. **Install ACR Connected Registry mirror**:
   ```powershell
   az acr connected-registry install info --registry acxhtxacraguuve6o --name aldo-tokyo-wkld
   # Follow the returned helm install instructions
   ```

4. **Verify Flux picked up the manifests** in `arc-aks/`:
   ```bash
   kubectl get gitrepositories -A
   kubectl get kustomizations -A
   kubectl get pods -n htx-foundry-local
   ```

5. **Test end-to-end**: pull the antenna model, watch it deploy to the GPU nodepool, hit inference.

## What's still speculative

Details to confirm once the stamp is up:

- **AKS-Arc Bicep API versions** — templates target `2024-01-01`; verify against ALDO stamp's installed AKS-Arc extension version.
- **A100 VM size string on Azure Local** — currently `Standard_NC24ads_A100_v4`; Azure Local may use different sizing (HCI-specific names).
- **KMS plugin protocol** — HashiCorp Vault Transit engine ≠ Azure Key Vault KMS plugin's expected wire format. Real deploy needs either:
  - A small pod running the K8s KMS v2 gRPC frontend to Vault Transit, or
  - Replace Vault with an Azure Key Vault reachable over ER, and use the built-in AKV KMS plugin.

None block the demo narrative — they're implementation details that get resolved once the stamp is up and we can iterate.
