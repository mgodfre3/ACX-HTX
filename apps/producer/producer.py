"""
Producer - runs on the ALDO Windows Server 2025 VM.

Gathers a synthetic drone-telemetry payload, encrypts it with a fresh
AES-256 DEK, wraps the DEK using htx-kek in the on-prem Vault Transit
engine, and uploads the envelope to Azure Blob Storage.

The DEK's plaintext lifetime is bounded by the try/finally below - after
encryption and wrap, it is zeroed and dereferenced.
"""
from __future__ import annotations

import json
import os
import random
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import hvac
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "shared"))
from envelope import Envelope, b64e, zero_bytes  # noqa: E402


def gather_payload(producer_id: str) -> bytes:
    """Synthesize a drone-telemetry-shaped payload. Replace with real ingest."""
    payload = {
        "producer_id": producer_id,
        "callsign": f"HTX-DRONE-{random.randint(1, 20):02d}",
        "utc": datetime.now(timezone.utc).isoformat(),
        "position": {
            "lat": round(35.6762 + random.uniform(-0.02, 0.02), 6),
            "lon": round(139.6503 + random.uniform(-0.02, 0.02), 6),
            "alt_m": round(random.uniform(80, 250), 1),
        },
        "cellular": {
            "rsrp_dbm": random.randint(-110, -70),
            "sinr_db": round(random.uniform(-3, 20), 1),
            "dl_mbps": round(random.uniform(5, 400), 1),
            "ul_mbps": round(random.uniform(1, 80), 1),
        },
        "sensor_classification": "SENSITIVE",
    }
    return json.dumps(payload, sort_keys=True).encode("utf-8")


def wrap_dek_with_vault(vault: hvac.Client, kek_name: str, dek: bytes) -> str:
    """Ask Vault Transit to wrap the DEK. Returns 'vault:v1:<base64>'."""
    resp = vault.secrets.transit.encrypt_data(
        name=kek_name,
        plaintext=b64e(dek),
    )
    return resp["data"]["ciphertext"]


def upload_envelope(account_url: str, container: str, blob_name: str, envelope_json: str) -> None:
    credential = DefaultAzureCredential()
    svc = BlobServiceClient(account_url=account_url, credential=credential)
    blob = svc.get_blob_client(container=container, blob=blob_name)
    blob.upload_blob(envelope_json.encode("utf-8"), overwrite=True)


def main() -> None:
    vault_addr = os.environ["HTX_VAULT_ADDR"]
    vault_token = os.environ["HTX_VAULT_TOKEN"]
    kek_name = os.environ.get("HTX_KEK_NAME", "htx-kek")
    storage_account = os.environ["HTX_STORAGE_ACCOUNT"]
    container = os.environ.get("HTX_CONTAINER", "sovereign-encrypted")
    producer_id = os.environ.get("HTX_PRODUCER_ID", "htxaldo-foundry")

    print(f"[producer] vault={vault_addr} kek={kek_name} sa={storage_account}")

    payload = gather_payload(producer_id)
    print(f"[producer] gathered payload: {len(payload)} bytes")

    dek = bytearray(AESGCM.generate_key(bit_length=256))
    try:
        aead = AESGCM(bytes(dek))
        nonce = bytearray(os.urandom(12))
        ct_with_tag = aead.encrypt(bytes(nonce), payload, associated_data=None)
        tag = ct_with_tag[-16:]
        ct_only = ct_with_tag[:-16]

        vault = hvac.Client(url=vault_addr, token=vault_token)
        if not vault.is_authenticated():
            raise SystemExit("[producer] Vault authentication failed")

        wrapped_dek = wrap_dek_with_vault(vault, kek_name, bytes(dek))
    finally:
        zero_bytes(dek)
        del dek

    env = Envelope(
        kek_name=kek_name,
        wrapped_dek=wrapped_dek,
        nonce=b64e(bytes(nonce)),
        tag=b64e(tag),
        ciphertext=b64e(ct_only),
        producer_id=producer_id,
        content_type="application/json+drone-telemetry",
    )

    now = datetime.now(timezone.utc)
    blob_name = f"{producer_id}/{now:%Y/%m/%d}/{uuid.uuid4()}.envelope.json"
    account_url = f"https://{storage_account}.blob.core.windows.net"

    upload_envelope(account_url, container, blob_name, env.to_json())
    print(f"[producer] uploaded {blob_name}")
    print(f"[producer] wrapped_dek starts with: {wrapped_dek[:32]}...")
    print("[producer] Plaintext DEK never left this VM. Wrapped DEK is inside the blob.")


if __name__ == "__main__":
    main()
