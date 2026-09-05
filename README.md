# Sovereign Hybrid Demo — Azure Buildout

The Azure public-cloud side of the "Master the Environment, Extend the Scale" sovereign hybrid architecture, plus the model-training + distribution pipeline that feeds Arc-AKS clusters on Azure Local Disconnected Operations (ALDO) stamps.

**Live deployment status:** see [`docs/deployment-status.md`](docs/deployment-status.md).  
**Executive summary + diagrams:** see [`docs/executive-summary.md`](docs/executive-summary.md).  
**Model training pipeline:** see [`training/README.md`](training/README.md).  
**Arc-AKS distribution:** see [`arc-aks/README.md`](arc-aks/README.md).

## What this deploys

Everything into a single resource group **`ACX-HTX`** in **West US 2**, tagged `Project=HTX` and `Created By=Michael Godfrey`. **No public IPs.** All workloads attach to the existing VNet **`AC-Managment-WUS2`** (RG `AdaptiveCloud-Management`), subnet `Default`. Key Vault and Storage use **private endpoints** and have public network access **disabled**.

| # | Resource | Purpose |
|---|---|---|
| 1 | Azure Key Vault Premium (HSM-backed, private endpoint) | Holds the KEK. Stand-in for the future Luna HSM. |
| 2 | Storage Account with CMK (private endpoint) | Encrypted "cold slice" blobs. CMK points at AKV KEK. |
| 3 | Confidential VM (DCadsv5, Win 2022, SEV-SNP) — private IP only | Attests, decrypts in TEE, runs small-LLM summary. Access via existing Azure Bastion. |
| 4 | Azure AI Foundry hub + project | Represents commercial-GPU less-sensitive processing. |

## Prereqs

- Azure CLI 2.60+ with Bicep
- Subscription with Owner or Contributor + User Access Administrator
- **Network Contributor** (or Subnet Join) on `AC-Managment-WUS2/Default` in RG `AdaptiveCloud-Management`
- DCadsv5 quota in West US 2 (confirmed 0/100 vCPUs used)
- Access to Azure Bastion in the existing VNet (or peered connectivity) for CVM RDP
- Private DNS zones for `privatelink.vaultcore.azure.net` and `privatelink.blob.core.windows.net` linked to the VNet — required for name resolution of the private endpoints. The AC-Management environment includes a DNS resolver, so this is likely already handled centrally; verify before deploy.

## Deploy

```powershell
# One-time: log in and pick subscription
az login --tenant <tenant-id>
az account set --subscription <sub-id>

# Preview
az deployment sub what-if `
  --location westus2 `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam

# Deploy
az deployment sub create `
  --location westus2 `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam `
  --name acx-htx-$(Get-Date -Format yyyyMMdd-HHmm)
```

## Cleanup

```powershell
az group delete --name ACX-HTX --yes --no-wait
# Purge soft-deleted Key Vault + Managed HSM keys
az keyvault purge --name <kv-name> --location westus2
```

## Layout

```
infra/
  main.bicep              # subscription-scoped: RG + all modules + tags
  main.bicepparam         # parameter values
  modules/
    keyvault.bicep        # AKV Premium + HSM KEK
    identity.bicep        # User-assigned MI + role assignments
    storage.bicep         # Storage Account + CMK
    cvm.bicep             # DCadsv5 Windows 2022 SEV-SNP
    foundry.bicep         # AI Foundry hub + project
cvm-app/                  # CVM decrypt+summarize service (phase 1: placeholder)
scripts/
  seed-blob.ps1           # Generate synthetic encrypted cold-slice
  deploy.ps1              # Convenience wrapper
```

## Slide mapping

Every resource corresponds to a numbered concept on the "Master the Environment, Extend the Scale" slide. See `docs/slide-mapping.md` (built later).

## Phase 2 (deferred)

- Azure Local Disconnected Operations side (Foundry Local + Phi-4 Mini on A100)
- On-prem key vault generating KEK, real BYOK ceremony into AKV
- Local encrypt+export CLI producing the blob envelopes this stack consumes
