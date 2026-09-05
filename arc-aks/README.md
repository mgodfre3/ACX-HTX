# Arc-AKS + Foundry Local — Sovereign Model Distribution

Reference manifests for pulling the CMK-encrypted antenna detector model from
sovereign Azure ACR to Arc-AKS clusters running on ALDO stamps.

**Status:** reference architecture. Live deploy waits on the ALDO Tokyo WKLD stamp being ready.

## The distribution path

```
Sovereign ACR (Azure, CMK-encrypted)
    │
    │  1. ACR Connected Registry sync
    │     (Microsoft.ContainerRegistry/connectedRegistries)
    ▼
On-prem Connected Registry mirror (runs on ALDO)
    │
    │  2. Arc-AKS pod pulls image via local mirror
    │     No egress traffic during pull
    ▼
Foundry Local pod (Arc-AKS on ALDO, A100 GPU)
    │
    │  3. Decrypt model at rest with local KEK (Azure Local Key Vault)
    │  4. Serve inference — data & weights never leave the site
    ▼
Local inference API (in-cluster only)
```

## What the manifests cover

| File | Purpose |
|---|---|
| `connected-registry.bicep` | ACR Connected Registry resource pointing at an on-prem sync token (deployed to Azure side) |
| `foundry-local-deployment.yaml` | Kubernetes Deployment for Foundry Local pulling `htx-antenna-detector:v1` |
| `arc-etcd-cmk.md` | How to configure Arc-AKS etcd encryption with the local KEK |
| `README.md` | This file |

## Key-custody chain

| Stage | Encryption at rest | Key |
|---|---|---|
| Training data blob | Azure Storage CMK | Sovereign KV → `htx-kek` |
| Compute disk | SSE-CMK via DES | Sovereign KV → `htx-kek` |
| Model artifact (ACR) | ACR CMK | Sovereign KV → `htx-kek` |
| Connected Registry mirror on ALDO | On-prem CSI + local KV | ALDO KV → local `htx-kek` |
| Arc-AKS etcd | KMS plugin with local KV | ALDO KV → local `htx-kek` |
| Foundry Local model on PV | On-prem CSI encryption | ALDO KV → local `htx-kek` |

**Same conceptual key across the entire lifecycle.** In the demo, the Azure `htx-kek` and the ALDO `htx-kek` are separate objects (they must be — the Azure one lives in Azure Key Vault, the ALDO one in the local vault). In production, a BYOK ceremony imports the customer HSM key into both, so the *logical* key is the same across both sides of the boundary.

## Not yet built (deferred until ALDO)

- Live Connected Registry activation (requires an outbound window from the ALDO stamp)
- Model signing with `notation` / `cosign` (production requirement, not demo blocker)
- Autoscaling policy on the Foundry Local Deployment
- Model version rollout via Flux GitOps
