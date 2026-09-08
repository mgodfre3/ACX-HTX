# Foundry Local Bootstrap for the Sovereign VM

Run these commands on the Windows Server 2025 Foundry VM (`htxaldo-foundry`) after it boots. Copy this file via RDP or paste into an admin PowerShell session.

## 1. Install prerequisites

```powershell
# NVIDIA driver + CUDA runtime for the A100 passed through via DDA
# Download the current data-center driver from https://www.nvidia.com/Download/index.aspx
# (search: Data Center / A100 / Windows Server 2025 / CUDA 12.x)
# Silent install:
Start-Process -FilePath "C:\path\to\nvidia-driver.exe" -ArgumentList "-s","-noreboot" -Wait

# Verify GPU is visible
nvidia-smi
```

## 2. Install Foundry Local

```powershell
winget install -e --id Microsoft.FoundryLocal
```

## 3. Verify install

```powershell
foundry --version
foundry service status
```

## 4. Pull the general-purpose model (Phi-4 mini)

```powershell
# Runs the model - downloads on first use, ~4.5 GB
foundry model run phi-4-mini
```

Foundry will:
- Detect the A100 via CUDA
- Download the ONNX GenAI variant to the local model cache (default `%LOCALAPPDATA%\Microsoft\Foundry\models`)
- Start an inference endpoint on `http://127.0.0.1:5273`

Test:

```powershell
curl http://127.0.0.1:5273/v1/models
```

## 5. Pull the sovereign HTX antenna detector from the ACR mirror (post-Connected-Registry install)

The antenna model was published from Azure Foundry to `acxhtxacraguuve6o.azurecr.io/models/htx-antenna-detector:v1` as an OCI artifact (CMK-encrypted). Once the on-prem ACR Connected Registry mirror is installed on the ALDO stamp (see `arc-aks/connected-registry.bicep` and `az acr connected-registry install`), pull with ORAS:

```powershell
# Install ORAS
winget install -e --id ORAS.Project

# Login to the local mirror (uses the mirror's sync token)
oras login <mirror-hostname>:5000 -u <sync-token-name> -p <sync-token-password>

# Pull the model artifact
mkdir C:\Foundry\models\htx-antenna-detector
oras pull <mirror-hostname>:5000/models/htx-antenna-detector:v1 -o C:\Foundry\models\htx-antenna-detector

# Register with Foundry Local as a BYO ONNX model
foundry model register `
  --name htx-antenna-detector `
  --path C:\Foundry\models\htx-antenna-detector\htx-antenna-detector.onnx `
  --runtime onnxruntime-gpu `
  --type predictive
```

## 6. Sovereign key custody

Encrypt the Foundry model cache with a customer key from the local Vault:

```powershell
# Attach a data disk from the ALDO cluster (do this via arc-appliance or the Azure Local UI)
# Then encrypt it with a Vault-generated key:

# Retrieve DEK from the local Vault
$dek = (Invoke-RestMethod -Uri "http://<vault-vm-ip>:8200/v1/transit/datakey/plaintext/htx-kek" `
  -Headers @{ "X-Vault-Token" = $env:VAULT_TOKEN } -Method Post).data.plaintext

# BitLocker the data disk with the DEK
manage-bde -on D: -RecoveryPassword $dek -UsedSpaceOnly

# Move Foundry model cache to encrypted disk
$env:FOUNDRY_MODEL_CACHE_DIR = 'D:\FoundryModels'
[Environment]::SetEnvironmentVariable('FOUNDRY_MODEL_CACHE_DIR', 'D:\FoundryModels', 'Machine')
Restart-Service FoundryLocalService
```

In production this uses the Luna HSM directly; the local Vault is the demo stand-in.

## 7. End-to-end demo

- Point a lightweight web UI (see MWC26 demo `video-dashboard/`) at `http://<foundry-vm-ip>:5273`
- Feed drone imagery through the antenna detector endpoint
- Show that revoking `htx-kek` in the local Vault immediately locks the model cache disk

## What you gain vs Arc-AKS

- **A100 works** (Arc-AKS caps at T4/A2)
- Simpler operational model — one VM, no cluster to manage
- Foundry Local runs natively on Windows Server 2025 — no K8s overhead
- Same customer-key custody story: model weights CMK-encrypted at rest, Vault held on-prem

## What you lose

- No K8s GitOps rollout of model versions (would need Foundry CLI + a small pull-script on a timer)
- No cluster-level RBAC for multi-tenant model access
- ACR Connected Registry mirror still installed to serve OCI pulls (typically runs on a small K8s cluster; can also run standalone via docker/containerd on the same Windows VM if you want to avoid any K8s)
