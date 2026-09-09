"""
Consumer - runs on the Azure Confidential VM (or Trusted Launch stand-in).

Flow:
    1. Fetch an envelope from Azure Blob Storage (ciphertext + wrapped_dek)
    2. Ask the guest attestation library for a fresh MAA token
    3. POST token + wrapped_dek to the on-prem unwrap service
    4. Receive plaintext DEK over the response (mTLS in production)
    5. Decrypt payload in TEE memory
    6. Zero the DEK
    7. Do downstream processing
"""
from __future__ import annotations

import base64
import json
import logging
import os
import sys
from pathlib import Path

import requests
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "shared"))
from envelope import Envelope, b64d, zero_bytes  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="[consumer] %(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("consumer")


def fetch_envelope(storage_account: str, container: str, blob_name: str) -> Envelope:
    credential = DefaultAzureCredential()
    svc = BlobServiceClient(
        account_url=f"https://{storage_account}.blob.core.windows.net",
        credential=credential,
    )
    blob = svc.get_blob_client(container=container, blob=blob_name)
    body = blob.download_blob().readall().decode("utf-8")
    return Envelope.from_json(body)


def get_maa_token() -> str:
    """Request an MAA token from the guest attestation service.

    On a real Confidential VM this uses the guest attestation client library
    (Azure.Security.Attestation SDK) which reads from the vTPM. On the
    Trusted Launch stand-in the Guest Attestation extension exposes the
    token via a local endpoint. Env var override for demo scenarios.
    """
    demo_token = os.environ.get("HTX_DEMO_TOKEN")
    if demo_token:
        log.warning("[demo] using HTX_DEMO_TOKEN instead of live attestation")
        return demo_token

    # IMDS attested-document endpoint (returns a signed statement over VM identity).
    # This is NOT a full MAA token but has the same trust chain and is enough for
    # the demo. Real prod path: Azure.Security.Attestation SDK -> MAA endpoint.
    r = requests.get(
        "http://169.254.169.254/metadata/attested/document?api-version=2020-09-01",
        headers={"Metadata": "true"},
        timeout=10,
    )
    r.raise_for_status()
    return r.json().get("signature") or json.dumps(r.json())


def request_unwrap(unwrap_url: str, maa_token: str, wrapped_dek: str, verify_tls: bool = True) -> bytes:
    r = requests.post(
        unwrap_url,
        json={"maa_token": maa_token, "wrapped_dek": wrapped_dek},
        timeout=30,
        verify=verify_tls,
    )
    if r.status_code == 403:
        raise SystemExit(f"[consumer] unwrap rejected by attestation gate: {r.json()}")
    r.raise_for_status()
    body = r.json()
    return base64.b64decode(body["dek"])


def decrypt_envelope(env: Envelope, dek: bytes) -> bytes:
    aead = AESGCM(dek)
    ciphertext = b64d(env.ciphertext) + b64d(env.tag)  # reassemble AES-GCM format
    return aead.decrypt(b64d(env.nonce), ciphertext, associated_data=None)


def process_plaintext(payload_json: bytes) -> None:
    """Whatever the sensitive workload does after decryption."""
    obj = json.loads(payload_json)
    log.info(
        "decrypted: producer=%s callsign=%s pos=(%s,%s)",
        obj.get("producer_id"),
        obj.get("callsign"),
        obj.get("position", {}).get("lat"),
        obj.get("position", {}).get("lon"),
    )
    log.info(
        "cellular: rsrp=%s dbm sinr=%s db dl=%s Mbps",
        obj.get("cellular", {}).get("rsrp_dbm"),
        obj.get("cellular", {}).get("sinr_db"),
        obj.get("cellular", {}).get("dl_mbps"),
    )


def main() -> None:
    storage_account = os.environ["HTX_STORAGE_ACCOUNT"]
    container = os.environ.get("HTX_CONTAINER", "sovereign-encrypted")
    blob_name = os.environ["HTX_BLOB_NAME"]
    unwrap_url = os.environ["HTX_UNWRAP_URL"]
    verify_tls = os.environ.get("HTX_UNWRAP_VERIFY_TLS", "1") == "1"

    log.info("fetching envelope: %s/%s", container, blob_name)
    env = fetch_envelope(storage_account, container, blob_name)
    log.info(
        "envelope loaded: version=%d kek=%s producer=%s ct_bytes=%d",
        env.version, env.kek_name, env.producer_id, len(b64d(env.ciphertext)),
    )

    log.info("obtaining MAA attestation token")
    maa_token = get_maa_token()
    log.info("attestation token obtained (%d chars)", len(maa_token))

    log.info("requesting unwrap from %s", unwrap_url)
    dek_bytes = request_unwrap(unwrap_url, maa_token, env.wrapped_dek, verify_tls=verify_tls)

    dek = bytearray(dek_bytes)
    try:
        plaintext = decrypt_envelope(env, bytes(dek))
        log.info("decrypted %d bytes of plaintext inside TEE memory", len(plaintext))
        process_plaintext(plaintext)
    finally:
        zero_bytes(dek)
        del dek

    log.info("done. Wrapped DEK stays at rest in blob; plaintext DEK never touched disk.")


if __name__ == "__main__":
    main()
