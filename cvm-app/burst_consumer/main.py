"""
main.py — the burst-CVM consumer entrypoint.

End-to-end flow (matches Acts 3-5 in docs/demo-storyboard.md):

  1. Build attestation evidence (stub IMDS or SEV-SNP MAA).
  2. POST /video/{id} to the edge fetch server with the evidence -> receive
     encrypted envelope + wrapped DEK.
  3. POST /unwrap to the same edge server with the wrapped DEK to recover the
     raw DEK. The edge decides "yes, this attested CVM may see plaintext."
  4. AES-256-GCM decrypt the payload in memory.
  5. "Process" — count bytes/frames, compute SHA-256, extract 1 thumbnail
     (best-effort; falls back to bytes-in / bytes-out if OpenCV isn't installed).
  6. Generate a fresh DEK; encrypt the result with it; POST /wrap for a fresh
     Vault Transit ciphertext of the new DEK.
  7. POST /processed/{id} to the edge fetch server with the fresh envelope.
  8. Zeroize everything. Exit.

Everything is logged as structured JSON to stdout so the orchestrator can tail
it directly for the on-stage overlay.

Environment variables:
  BURST_CONSUMER_EDGE_FETCH_URL       required, e.g. http://172.22.218.200:8444
                                      The edge-fetch server proxies fetch, wrap,
                                      unwrap, and result storage on a single port.
  BURST_CONSUMER_EDGE_UNWRAP_URL      optional; defaults to EDGE_FETCH_URL. Only
                                      set this if you are still running a
                                      legacy split-server layout with unwrap on
                                      a different port.
  BURST_CONSUMER_ATTESTATION_MODE     "stub-tl-imds" (default) or "sev-snp"

CLI:
  python -m burst_consumer.main --video-id sample-video-01
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import logging
import os
import secrets
import sys
import time
from datetime import datetime, timezone
from typing import Any

import httpx
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import attestation

# -------------------------- config --------------------------

EDGE_FETCH_URL = os.environ.get("BURST_CONSUMER_EDGE_FETCH_URL", "").rstrip("/")
# The edge-fetch server (:8444) proxies both wrap and unwrap now (see
# aldo/edge-fetch/edge_fetch/server.py). The old separate unwrap-service URL is
# kept as a fallback for environments where the split-server layout is still
# deployed, but the primary path is single-URL edge-fetch.
EDGE_UNWRAP_URL = os.environ.get("BURST_CONSUMER_EDGE_UNWRAP_URL", EDGE_FETCH_URL).rstrip("/")
ATTESTATION_MODE = os.environ.get("BURST_CONSUMER_ATTESTATION_MODE", "stub-tl-imds")

# -------------------------- logging --------------------------

log = logging.getLogger("burst-consumer")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "lvl": record.levelname,
            "msg": record.getMessage(),
        }
        if getattr(record, "extra_fields", None):
            payload.update(record.extra_fields)
        return json.dumps(payload)


def _configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.handlers[:] = [handler]


def log_evt(event: str, **fields: Any) -> None:
    rec = logging.LogRecord(
        name="burst-consumer",
        level=logging.INFO,
        pathname=__file__,
        lineno=0,
        msg=event,
        args=(),
        exc_info=None,
    )
    rec.extra_fields = fields
    logging.getLogger().handle(rec)


# -------------------------- edge calls --------------------------


def fetch_envelope(video_id: str, att: attestation.AttestationEnvelope) -> dict[str, Any]:
    url = f"{EDGE_FETCH_URL}/video/{video_id}"
    r = httpx.post(url, json={"attestation": att.as_dict()}, timeout=15.0)
    if r.status_code != 200:
        raise RuntimeError(f"edge fetch failed: {r.status_code} {r.text}")
    return r.json()


def unwrap_dek(wrapped_dek_b64: str, att: attestation.AttestationEnvelope) -> bytes:
    """
    Ask the edge to reverse the Vault Transit ciphertext.

    Wire shape (matches aldo/edge-fetch/edge_fetch/server.py :: /unwrap):
      POST /unwrap
        { "attestation": {...}, "wrapped_dek": "vault:v1:..." }
        -> 200 { "dek_b64": "...", "audit_id": "..." }
        -> 403 { "detail": "key-min-version-not-met" }  (Toggle A tripped)
        -> 403 { "detail": "<attestation-reason>" }
    """
    url = f"{EDGE_UNWRAP_URL}/unwrap"
    body = {"attestation": att.as_dict(), "wrapped_dek": wrapped_dek_b64}
    r = httpx.post(url, json=body, timeout=10.0)
    if r.status_code != 200:
        raise RuntimeError(f"unwrap failed: {r.status_code} {r.text}")
    return base64.b64decode(r.json()["dek_b64"])


def wrap_dek(dek: bytes, att: attestation.AttestationEnvelope) -> str:
    """
    Ask the edge to wrap a fresh DEK for the return leg.

    Wire shape (matches aldo/edge-fetch/edge_fetch/server.py :: /wrap):
      POST /wrap
        { "attestation": {...}, "dek_b64": "<32 bytes b64>" }
        -> 200 { "wrapped_dek": "vault:v1:...", "audit_id": "..." }
        -> 403 { "detail": "<attestation-reason>" }
    """
    url = f"{EDGE_UNWRAP_URL}/wrap"
    body = {"attestation": att.as_dict(), "dek_b64": base64.b64encode(dek).decode("ascii")}
    r = httpx.post(url, json=body, timeout=10.0)
    if r.status_code != 200:
        raise RuntimeError(f"wrap failed: {r.status_code} {r.text}")
    return r.json()["wrapped_dek"]


def submit_result(result_id: str, envelope: dict[str, Any], att: attestation.AttestationEnvelope) -> dict[str, Any]:
    url = f"{EDGE_FETCH_URL}/processed/{result_id}"
    r = httpx.post(
        url,
        json={"attestation": att.as_dict(), "envelope": envelope},
        timeout=30.0,
    )
    if r.status_code != 201:
        raise RuntimeError(f"submit_result failed: {r.status_code} {r.text}")
    return r.json()


# -------------------------- crypto + processing --------------------------


def decrypt_envelope(envelope: dict[str, Any], dek: bytes) -> bytes:
    if envelope.get("data_algo") != "aes-256-gcm":
        raise RuntimeError(f"unsupported data_algo: {envelope.get('data_algo')}")
    nonce = base64.b64decode(envelope["nonce_b64"])
    tag = base64.b64decode(envelope["tag_b64"])
    ct = base64.b64decode(envelope["ciphertext_b64"])
    aesgcm = AESGCM(dek)
    return aesgcm.decrypt(nonce, ct + tag, associated_data=None)


def process(payload: bytes) -> dict[str, Any]:
    """
    Trivially-visible processing so the demo has something to point at.

    Real customer workload plugs in here. Kept deliberately simple to keep the
    demo short and the security story front-and-center.
    """
    sha = hashlib.sha256(payload).hexdigest()

    # Try to count frames if OpenCV is available. Otherwise report byte-level stats.
    frames = None
    try:
        import cv2  # type: ignore  # noqa: PLC0415
        import numpy as np  # type: ignore  # noqa: PLC0415
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=".mp4", delete=True) as fh:
            fh.write(payload)
            fh.flush()
            cap = cv2.VideoCapture(fh.name)
            frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            cap.release()
    except Exception:
        frames = None

    return {
        "sha256": sha,
        "bytes": len(payload),
        "frames_scanned": frames,
        "processed_at_utc": datetime.now(timezone.utc).isoformat(),
    }


def encrypt_result(result_bytes: bytes, dek: bytes) -> dict[str, Any]:
    nonce = secrets.token_bytes(12)
    aesgcm = AESGCM(dek)
    ct_and_tag = aesgcm.encrypt(nonce, result_bytes, associated_data=None)
    ct, tag = ct_and_tag[:-16], ct_and_tag[-16:]
    return {
        "nonce_b64": base64.b64encode(nonce).decode("ascii"),
        "tag_b64": base64.b64encode(tag).decode("ascii"),
        "ciphertext_b64": base64.b64encode(ct).decode("ascii"),
    }


# -------------------------- driver --------------------------


def zeroize(*buffers: bytearray) -> None:
    for buf in buffers:
        for i in range(len(buf)):
            buf[i] = 0


def run(video_id: str, result_id: str | None) -> int:
    _configure_logging()

    if not EDGE_FETCH_URL:
        log_evt("config_error", reason="BURST_CONSUMER_EDGE_FETCH_URL is required")
        return 2

    result_id = result_id or f"{video_id}-{int(time.time())}"
    log_evt("start", video_id=video_id, result_id=result_id, attestation_mode=ATTESTATION_MODE)

    # Phase A — attestation
    t0 = time.perf_counter()
    att = attestation.build(ATTESTATION_MODE)
    log_evt("attestation_built", subject=att.expected_arm_id, mode=att.mode, ms=int((time.perf_counter() - t0) * 1000))

    # Phase B — fetch envelope
    t0 = time.perf_counter()
    fetch_response = fetch_envelope(video_id, att)
    envelope = fetch_response["envelope"]
    log_evt(
        "envelope_fetched",
        video_id=video_id,
        release_id=fetch_response.get("release_id"),
        envelope_bytes=len(json.dumps(envelope)),
        ms=int((time.perf_counter() - t0) * 1000),
    )

    # Phase C — unwrap
    t0 = time.perf_counter()
    dek = bytearray(unwrap_dek(envelope["wrapped_dek_b64"], att))
    log_evt("dek_unwrapped", dek_bytes=len(dek), ms=int((time.perf_counter() - t0) * 1000))

    # Phase D — decrypt
    t0 = time.perf_counter()
    plaintext = bytearray(decrypt_envelope(envelope, bytes(dek)))
    log_evt("payload_decrypted", plaintext_bytes=len(plaintext), ms=int((time.perf_counter() - t0) * 1000))

    # Phase E — process
    t0 = time.perf_counter()
    result = process(bytes(plaintext))
    log_evt("processed", ms=int((time.perf_counter() - t0) * 1000), **result)

    # Phase F — encrypt result with a fresh DEK
    new_dek = bytearray(secrets.token_bytes(32))
    payload_bytes = json.dumps(result).encode("utf-8")
    ct = encrypt_result(payload_bytes, bytes(new_dek))
    log_evt("result_encrypted", ciphertext_bytes=len(ct["ciphertext_b64"]))

    # Phase G — wrap fresh DEK
    t0 = time.perf_counter()
    wrapped_new_dek = wrap_dek(bytes(new_dek), att)
    log_evt("new_dek_wrapped", wrap_ms=int((time.perf_counter() - t0) * 1000))

    # Phase H — submit
    out_envelope = {
        "version": "burst-cvm-1",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "kek_ref": envelope["kek_ref"],
        "wrap_algo": envelope["wrap_algo"],
        "wrapped_dek_b64": wrapped_new_dek,
        "data_algo": "aes-256-gcm",
        **ct,
    }
    t0 = time.perf_counter()
    submit_response = submit_result(result_id, out_envelope, att)
    log_evt(
        "result_submitted",
        result_id=result_id,
        audit_id=submit_response.get("audit_id"),
        stored_path=submit_response.get("stored_path"),
        ms=int((time.perf_counter() - t0) * 1000),
    )

    # Zeroize
    zeroize(dek, plaintext, new_dek)
    log_evt("done", video_id=video_id, result_id=result_id)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Burst consumer for the sovereign hybrid demo.")
    p.add_argument("--video-id", required=True)
    p.add_argument("--result-id", default=None)
    args = p.parse_args()
    try:
        return run(args.video_id, args.result_id)
    except Exception as ex:
        log_evt("fatal", error=str(ex), error_type=type(ex).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
