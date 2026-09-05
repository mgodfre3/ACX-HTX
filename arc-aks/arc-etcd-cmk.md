# Arc-AKS etcd Encryption with the Local KEK

Arc-AKS on Azure Local supports Kubernetes envelope encryption of etcd secrets
and configmaps using a **KMS plugin** that unwraps DEKs via a customer-controlled
key. On an ALDO stamp, that key lives in the on-prem Azure Key Vault (the
sovereign side of the story — the Azure `htx-kek` we deployed in `ACX-HTX` has
a mirror on the ALDO stamp).

## What this covers

- **What's encrypted:** every secret and configmap written to Arc-AKS etcd, at rest
- **What's not:** in-memory secrets after being decrypted for a pod, and non-secret resources like Deployments (Kubernetes only supports envelope encryption for `secrets` and `configmaps`)
- **Key custody:** the KEK never leaves the on-prem KV — the KMS plugin proxies wrap/unwrap requests

## The Kubernetes side (EncryptionConfiguration)

Arc-AKS reads this file from a well-known path on the control plane. Provisioned
via the AKS-Arc `az aksarc` CLI or via the Kubernetes API config for self-managed
clusters:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - kms:
          apiVersion: v2
          name: aldo-htx-kek
          endpoint: unix:///var/run/kmsplugin/socket.sock
          cachesize: 1000
          timeout: 3s
      - identity: {}
```

## The KMS plugin (on-prem sidecar)

A small gRPC service running on each control-plane node that:

1. Authenticates to the local Azure Key Vault via workload identity (managed identity federation from Arc)
2. Implements the KMS v2 `Encrypt`/`Decrypt`/`Status` interface
3. Uses the local `htx-kek` (RSA-HSM 3072) to wrap/unwrap AES-256 DEKs
4. Caches unwrapped DEKs for the configured TTL

Microsoft-supported implementation: **Azure Key Vault KMS Plugin for AKS-Arc** — installed via `az aksarc update --enable-azure-keyvault-kms --azure-keyvault-kms-key-id <local-kek-uri>` once the ALDO stamp is up.

## Verification

Once running:

```bash
# From the Arc-AKS cluster
kubectl create secret generic test-secret --from-literal=key=value
# Then check etcd directly on the control plane
etcdctl get /registry/secrets/default/test-secret --print-value-only | head -c 8
# Expect: bytes starting with "k8s:enc:kms:v2:aldo-htx-kek:" (envelope prefix)
# NOT the plaintext "value"
```

## Same story as our Azure side

The Azure `acxhtx-vm` proves the pattern with SSE-CMK on managed disks. The
Arc-AKS etcd encryption proves the same pattern for the Kubernetes control
plane on the sovereign side. Combined: **no data at rest anywhere in the
lifecycle is readable without customer key custody.**
