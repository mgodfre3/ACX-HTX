# Edge Fetch Server

The sovereign side of the burst-CVM flow. Runs on the ALDO Vault VM at `172.22.218.200` alongside the existing unwrap service.

## What it does

- Serves encrypted video envelopes to attested Azure CVMs (`POST /video/{id}`).
- Accepts encrypted result envelopes back from those same CVMs (`POST /processed/{id}`).
- Rejects everything else at the attestation gate.
- Writes an append-only audit log to `/var/lib/edge-fetch/audit.jsonl` for on-stage inspection.

See [`docs/burst-cvm-architecture.md`](../../docs/burst-cvm-architecture.md) for the design rationale and [`docs/demo-storyboard.md`](../../docs/demo-storyboard.md) for how it appears on stage.

## Layout

```
aldo/edge-fetch/
  edge_fetch/
    __init__.py
    server.py         # FastAPI app: routes, storage layout, audit
    attestation.py    # Stub (Trusted Launch IMDS) + prod (SEV-SNP, not-yet) validators
    seed_video.py     # CLI: source video -> encrypted envelope in /var/lib/edge-fetch/videos/
  requirements.txt
  install.sh          # systemd unit + venv + user + storage layout
  README.md           # this file
```

## Deploy

Run on the Vault VM:

```bash
# 1. Clone / pull the repo onto the Vault VM
git clone https://github.com/mgodfre3/ACX-HTX.git /opt/htx-repo
cd /opt/htx-repo

# 2. Edit install.sh envs if needed (ALLOWED_ARM_IDS, ATTESTATION_MODE)
sudo bash aldo/edge-fetch/install.sh
```

The install script is idempotent — re-run it after any config change.

## Seed a demo video

```bash
sudo -u edge-fetch \
  VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN=<producer-token-from-vault-app-tokens.json> \
  /opt/edge-fetch/venv/bin/python -m edge_fetch.seed_video \
    --video-id sample-video-01 \
    --input /home/edge/demo-samples/big-buck-bunny-30s.mp4 \
    --storage-root /var/lib/edge-fetch
```

Producing the source `.mp4`: any short generic clip works. If a canned one isn't handy, `ffmpeg -f lavfi -i testsrc=duration=30:size=1280x720:rate=30 -c:v libx264 sample.mp4` gets you a synthetic test pattern.

## Verify

```bash
curl -sS http://127.0.0.1:8444/healthz | jq
sudo journalctl -u edge-fetch -f
tail -f /var/lib/edge-fetch/audit.jsonl
```

## Attestation modes

- **`ATTESTATION_MODE=stub`** (default, current lab): accepts a well-formed Azure IMDS attested document from a Trusted Launch VM whose `subject_arm_id` matches `EDGE_FETCH_ALLOWED_ARM_IDS`. Every log line for a stub-mode acceptance carries `stub_indicator=STUB(imds,...)` so it's visibly obvious on stage that this is not the production check.
- **`ATTESTATION_MODE=prod`**: requires a SEV-SNP MAA JWT. Not yet implemented — this mode currently rejects everything as a fail-safe. Will be wired when SEV-SNP quota lands.

## Wire protocol

See the module docstring at the top of `edge_fetch/server.py`. Short version:

```
POST /video/{video_id}
  { "attestation": { mode, evidence_b64, expected_arm_id } }
  -> 200 { envelope: {...}, release_id }
  -> 403 { reason }
  -> 404 { reason: "video-not-found" }

POST /processed/{result_id}
  { "attestation": {...}, "envelope": {...} }
  -> 201 { stored_path, audit_id }
  -> 403 { reason }
  -> 400 { reason: "wrapped-dek-not-vault-format" }

GET /healthz
GET /audit/tail?n=20
```

## Security notes

- The server never touches plaintext customer data. It serves encrypted envelopes and stores encrypted envelopes.
- The wrapped DEK returned by `GET /video/{id}` remains a Vault Transit ciphertext (`vault:v1:...`) — actually unwrapping it requires a separate call to the existing unwrap service on `:8443`, which enforces its own attestation-gated policy.
- Disabling the Vault Transit `htx-kek` key from the edge Vault CLI causes any future unwrap call to fail without touching this server. That is the intended kill switch.
