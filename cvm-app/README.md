# CVM Decrypt + Summarize Service (placeholder)

This directory will hold the Windows service that runs **inside the confidential VM** and:

1. Attests the TEE via Microsoft Azure Attestation (MAA).
2. Fetches an encrypted envelope blob from the CMK-protected storage account.
3. Calls Azure Key Vault to **unwrap the DEK** using the KEK (RSA-OAEP-256).
4. Decrypts the payload (AES-256-GCM) **in-memory inside the TEE**.
5. Runs a small ONNX LLM (Phi-3-mini) to summarize.
6. Exposes an HTTP endpoint (`GET /summary?blob=<name>`) returning the summary + attestation quote.

## Planned stack

- .NET 8 minimal API (Windows Server 2022 has native support)
- `Azure.Identity` (uses VM system-assigned MI)
- `Azure.Security.KeyVault.Keys` for unwrap
- `Azure.Storage.Blobs` for envelope fetch
- `Azure.Security.Attestation` for MAA attestation quote
- `Microsoft.ML.OnnxRuntime.DirectML` for Phi-3-mini inference on the CVM

## Deployment

Will be delivered via a `Microsoft.Compute/virtualMachines/extensions@customScriptExtension` module
that pulls the built binaries from the CMK-protected storage account and installs them as a Windows service.

**Status:** placeholder — infra is ready, payload comes next.

## Envelope format (produced by `scripts/seed-blob.ps1`)

```json
{
  "version": "1",
  "createdUtc": "2026-...",
  "kekVaultUri": "https://acxhtx-kv-....vault.azure.net/",
  "kekName": "htx-kek",
  "wrappedDek": "<base64 of RSA-OAEP-256 wrapped DEK>",
  "wrapAlgorithm": "RSA-OAEP-256",
  "dataAlgorithm": "AES-256-GCM",
  "nonce": "<base64 12-byte nonce>",
  "tag": "<base64 16-byte GCM tag>",
  "ciphertext": "<base64 payload>",
  "documentCount": 25
}
```

The service reverses the seed script exactly: unwrap DEK → AesGcm decrypt → parse docs → summarize.
