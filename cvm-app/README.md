# CVM Burst Consumer

Runs inside the Azure burst CVM (`acxhtx-vm`). Pulls encrypted work from the ALDO edge, processes it in memory only, sends re-encrypted results back to the edge. **Talks to Azure only for platform attestation evidence** (IMDS today, MAA when SEV-SNP quota lands). Never talks to Azure Storage. Never talks to Azure Key Vault for data-key operations.

Full architecture in [`../docs/burst-cvm-architecture.md`](../docs/burst-cvm-architecture.md). On-stage script in [`../docs/demo-storyboard.md`](../docs/demo-storyboard.md).

## Flow (matches storyboard Acts 3-5)

```
1. attestation.build(mode)
      -> IMDS attested doc wrapped with subject_arm_id + timestamp
         (or SEV-SNP MAA JWT when quota lands)

2. POST http://172.22.218.200:8444/video/{id}
      { attestation: {...} }
      -> { envelope: {kek_ref, wrapped_dek_b64, nonce, tag, ciphertext} }

3. POST http://172.22.218.200:8443/unwrap
      { attestation: {...}, wrapped_dek: "vault:v1:..." }
      -> { dek_b64 }

4. AES-256-GCM decrypt in memory

5. Process (sha256, byte count, frame count if OpenCV present)

6. Fresh DEK; encrypt result; POST /wrap for new wrapped DEK

7. POST http://172.22.218.200:8444/processed/{id}
      { attestation: {...}, envelope: {...} }
      -> { audit_id }

8. Zeroize buffers. Exit.
```

Every step emits a single-line JSON event to stdout so the orchestrator's tail overlay stays readable on stage.

## Deploy

On the CVM, as Administrator:

```powershell
# Clone repo (once)
git clone https://github.com/mgodfre3/ACX-HTX.git C:\HTX\repo

# Install
cd C:\HTX\repo\cvm-app
.\install-consumer.ps1
```

The install script is idempotent — re-run to update.

## Run manually (for smoke testing outside the demo)

```powershell
C:\HTX\burst-consumer\run.cmd --video-id sample-video-01
```

Expected exit code 0, and the edge-fetch server's `audit.jsonl` should show one `release_granted` and one `store_accepted` event for the same `subject_arm_id`.

## Files

- `burst_consumer/attestation.py` — builds evidence (stub IMDS today, SEV-SNP later)
- `burst_consumer/main.py` — the full 8-step driver with structured logging
- `install-consumer.ps1` — Windows install (Python, venv, package copy, env vars, run shim)
- `requirements.txt` — httpx, cryptography, optional opencv

## Assumes about the unwrap service

The unwrap service already running on `:8443` on the ALDO Vault VM is assumed to:

- Accept `POST /unwrap` with body `{ attestation, wrapped_dek }` and return `{ dek_b64 }`.
- Accept `POST /wrap` with body `{ attestation, dek_b64 }` and return `{ wrapped_dek }` (Vault Transit `encrypt` around the incoming DEK).
- Reject requests when its own attestation policy is not satisfied.

If the wrap route doesn't exist yet, it's a two-line addition on the unwrap service that just proxies to Vault's `transit/encrypt/htx-kek` — no security posture change since the attestation-gate is already in place.

## Prior README (blob-based)

The old `README.md` in this directory described a blob-fetch design that has been retired. It has been replaced by this file. See git history for the prior text.
