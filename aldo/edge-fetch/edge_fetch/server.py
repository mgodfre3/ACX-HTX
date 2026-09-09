"""
Edge Fetch Server — the sovereign side of the burst-CVM flow.

Runs on the ALDO Vault VM at 172.22.218.200 alongside the existing unwrap service
(which continues to listen on :8443). This server listens on :8444.

Design goals:
  - Every request that returns customer data (encrypted or not) requires attestation
    evidence signed for the requester.
  - Attestation evidence is validated by this server BEFORE any bytes leave the box.
  - The wrapped DEK is returned alongside the encrypted envelope; unwrap remains a
    separate call to :8443/unwrap so the two custody events are visibly distinct in
    a demo.
  - No plaintext customer data ever touches this server. It stores and serves
    envelopes, not payloads.

Wire protocol: see the module docstring in the git repo. Same layout as the seed
script produces and the burst_consumer expects.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

from . import attestation

# -------------------------- config --------------------------

LISTEN = os.environ.get("EDGE_FETCH_LISTEN", "0.0.0.0:8444")
STORAGE_ROOT = Path(os.environ.get("EDGE_FETCH_STORAGE_ROOT", "/var/lib/edge-fetch"))
UNWRAP_URL = os.environ.get("EDGE_FETCH_UNWRAP_URL", "http://127.0.0.1:8443/unwrap")
ALLOWED_ARM_IDS = [
    s.strip().lower() for s in os.environ.get("EDGE_FETCH_ALLOWED_ARM_IDS", "").split(",") if s.strip()
]
MODE = os.environ.get("EDGE_FETCH_ATTESTATION_MODE", "stub").lower()

# Vault Transit config — this server proxies wrap/unwrap so the burst CVM never
# has to talk to a second endpoint.
VAULT_ADDR = os.environ.get("EDGE_FETCH_VAULT_ADDR", "http://127.0.0.1:8200")
VAULT_TOKEN = os.environ.get("EDGE_FETCH_VAULT_TOKEN", "")
VAULT_TRANSIT_KEY = os.environ.get("EDGE_FETCH_VAULT_TRANSIT_KEY", "htx-kek")

# Fail-closed guard: refuse to accept an empty allow-list unless the operator has
# explicitly opted in. This closes the "silent bypass on unset env var" bug the
# code-review agent flagged 2026-09-09.
ALLOW_EMPTY_ALLOWLIST = os.environ.get("EDGE_FETCH_ALLOW_EMPTY_ALLOWLIST", "").strip() == "1"
if not ALLOWED_ARM_IDS and not ALLOW_EMPTY_ALLOWLIST:
    raise RuntimeError(
        "EDGE_FETCH_ALLOWED_ARM_IDS is empty. "
        "Any attester would be accepted. Set EDGE_FETCH_ALLOW_EMPTY_ALLOWLIST=1 "
        "to explicitly permit this (development only), or provide a comma-separated "
        "list of ARM resource IDs."
    )
if MODE not in {"stub", "prod"}:
    raise RuntimeError(f"EDGE_FETCH_ATTESTATION_MODE must be 'stub' or 'prod', got {MODE!r}")
if not VAULT_TOKEN:
    raise RuntimeError(
        "EDGE_FETCH_VAULT_TOKEN is empty. "
        "The edge-fetch server proxies wrap/unwrap to Vault Transit and needs a token "
        "with encrypt+decrypt on transit/keys/" + VAULT_TRANSIT_KEY + "."
    )

VIDEOS_DIR = STORAGE_ROOT / "videos"
PROCESSED_DIR = STORAGE_ROOT / "processed"
AUDIT_LOG = STORAGE_ROOT / "audit.jsonl"

VIDEOS_DIR.mkdir(parents=True, exist_ok=True)
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("edge-fetch")

# -------------------------- app --------------------------

app = FastAPI(title="Edge Fetch Server", version="1.0.0")


class AttestationPayload(BaseModel):
    mode: str = Field(..., description="'stub-tl-imds' or 'sev-snp'")
    evidence_b64: str
    expected_arm_id: str


class FetchRequest(BaseModel):
    attestation: AttestationPayload


class Envelope(BaseModel):
    version: str = "burst-cvm-1"
    created_utc: str
    kek_ref: str
    wrap_algo: str
    wrapped_dek_b64: str
    data_algo: str
    nonce_b64: str
    tag_b64: str
    ciphertext_b64: str


class StoreRequest(BaseModel):
    attestation: AttestationPayload
    envelope: Envelope


class UnwrapRequest(BaseModel):
    attestation: AttestationPayload
    wrapped_dek: str = Field(..., description="Vault Transit ciphertext, e.g. 'vault:v1:...'")


class WrapRequest(BaseModel):
    attestation: AttestationPayload
    dek_b64: str = Field(..., description="base64 of a 32-byte DEK")


# -------------------------- helpers --------------------------


def _audit(event_type: str, **fields: Any) -> str:
    audit_id = str(uuid.uuid4())
    record = {
        "audit_id": audit_id,
        "ts_utc": datetime.now(timezone.utc).isoformat(),
        "event": event_type,
        **fields,
    }
    with AUDIT_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
    return audit_id


def _validate_attestation(payload: AttestationPayload) -> attestation.ValidationResult:
    return attestation.validate(
        mode_config=MODE,
        payload_mode=payload.mode,
        evidence_b64=payload.evidence_b64,
        expected_arm_id=payload.expected_arm_id,
        allowed_arm_ids=ALLOWED_ARM_IDS,
    )


# -------------------------- routes --------------------------


@app.get("/healthz")
async def healthz() -> dict:
    unwrap_reachable = False
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            r = await client.get(UNWRAP_URL.replace("/unwrap", "/healthz"))
            unwrap_reachable = r.status_code == 200
    except Exception:
        unwrap_reachable = False
    return {
        "status": "ok",
        "version": app.version,
        "attestation_mode": MODE,
        "unwrap_service": "reachable" if unwrap_reachable else "unreachable",
        "storage_root": str(STORAGE_ROOT),
        "allowed_arm_id_count": len(ALLOWED_ARM_IDS),
        "vault_transit_key": VAULT_TRANSIT_KEY,
    }


# -------------------------- vault transit proxy --------------------------


async def _vault_encrypt(dek: bytes) -> str:
    """Call Vault Transit `encrypt` and return the `vault:v1:...` ciphertext."""
    url = f"{VAULT_ADDR.rstrip('/')}/v1/transit/encrypt/{VAULT_TRANSIT_KEY}"
    async with httpx.AsyncClient(timeout=5.0) as client:
        r = await client.post(
            url,
            headers={"X-Vault-Token": VAULT_TOKEN},
            json={"plaintext": base64.b64encode(dek).decode("ascii")},
        )
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"vault-encrypt-failed:{r.status_code}")
    return r.json()["data"]["ciphertext"]


async def _vault_decrypt(wrapped: str) -> bytes:
    """Call Vault Transit `decrypt`. Raises 403 on Vault refusal (kill-switch trip)."""
    url = f"{VAULT_ADDR.rstrip('/')}/v1/transit/decrypt/{VAULT_TRANSIT_KEY}"
    async with httpx.AsyncClient(timeout=5.0) as client:
        r = await client.post(
            url,
            headers={"X-Vault-Token": VAULT_TOKEN},
            json={"ciphertext": wrapped},
        )
    if r.status_code == 403:
        raise HTTPException(status_code=403, detail="vault-decrypt-denied")
    if r.status_code != 200:
        # Vault surfaces 400 when the key version is below min_decryption_version --
        # i.e., Toggle A tripped. Return 403 to the caller so the demo shows the
        # kill-switch on the CVM log directly.
        detail = f"vault-decrypt-failed:{r.status_code}"
        try:
            errors = r.json().get("errors", [])
        except (ValueError, AttributeError):
            errors = []
        if r.status_code == 400 and any(
            isinstance(error, str) and "disallowed by policy (too old)" in error.lower()
            for error in errors
        ):
            raise HTTPException(status_code=403, detail="key-min-version-not-met")
        raise HTTPException(status_code=502, detail=detail)
    return base64.b64decode(r.json()["data"]["plaintext"])


@app.post("/unwrap")
async def unwrap(req: UnwrapRequest, request: Request) -> dict:
    """
    Attestation-gated unwrap. Reverses a Vault Transit ciphertext back to raw DEK
    bytes. Only callers whose attestation validates get the plaintext DEK.
    """
    peer = request.client.host if request.client else "unknown"
    result = _validate_attestation(req.attestation)
    if not result.ok:
        _audit("unwrap_denied", reason=result.reason, arm_id=req.attestation.expected_arm_id, peer=peer)
        raise HTTPException(status_code=403, detail=result.reason)

    dek = await _vault_decrypt(req.wrapped_dek)
    audit_id = _audit(
        "unwrap_granted",
        arm_id=req.attestation.expected_arm_id.lower(),
        stub_indicator=result.stub_indicator,
        peer=peer,
    )
    log.info(
        "UNWRAP arm_id=%s mode=%s stub=%s peer=%s audit=%s",
        req.attestation.expected_arm_id, MODE, result.stub_indicator, peer, audit_id,
    )
    return {"dek_b64": base64.b64encode(dek).decode("ascii"), "audit_id": audit_id}


@app.post("/wrap")
async def wrap(req: WrapRequest, request: Request) -> dict:
    """
    Attestation-gated wrap. Encrypts an incoming DEK under the Vault Transit key
    so the caller (typically the CVM producing a re-encrypted result) can carry
    an opaque ciphertext back to the edge without ever holding the KEK.
    """
    peer = request.client.host if request.client else "unknown"
    result = _validate_attestation(req.attestation)
    if not result.ok:
        _audit("wrap_denied", reason=result.reason, arm_id=req.attestation.expected_arm_id, peer=peer)
        raise HTTPException(status_code=403, detail=result.reason)

    try:
        dek = base64.b64decode(req.dek_b64)
    except Exception:
        raise HTTPException(status_code=400, detail="dek-b64-not-decodable")
    if len(dek) not in (16, 24, 32):
        raise HTTPException(status_code=400, detail="dek-length-not-aes-legal")

    wrapped = await _vault_encrypt(dek)
    audit_id = _audit(
        "wrap_granted",
        arm_id=req.attestation.expected_arm_id.lower(),
        stub_indicator=result.stub_indicator,
        dek_bytes=len(dek),
        peer=peer,
    )
    log.info(
        "WRAP arm_id=%s mode=%s stub=%s dek_bytes=%d peer=%s audit=%s",
        req.attestation.expected_arm_id, MODE, result.stub_indicator, len(dek), peer, audit_id,
    )
    return {"wrapped_dek": wrapped, "audit_id": audit_id}


@app.post("/video/{video_id}")
async def fetch_video(video_id: str, req: FetchRequest, request: Request) -> dict:
    peer = request.client.host if request.client else "unknown"
    envelope_path = VIDEOS_DIR / video_id / "envelope.json"
    if not envelope_path.is_file():
        _audit("release_denied", reason="video-not-found", video_id=video_id, peer=peer)
        raise HTTPException(status_code=404, detail="video-not-found")

    result = _validate_attestation(req.attestation)
    if not result.ok:
        _audit(
            "release_denied",
            reason=result.reason,
            mode_config=MODE,
            payload_mode=req.attestation.mode,
            expected_arm_id=req.attestation.expected_arm_id,
            peer=peer,
        )
        log.warning(
            "video=%s DENIED reason=%s payload_mode=%s expected=%s peer=%s",
            video_id, result.reason, req.attestation.mode,
            req.attestation.expected_arm_id, peer,
        )
        raise HTTPException(status_code=403, detail=result.reason)

    envelope_data = json.loads(envelope_path.read_text(encoding="utf-8"))
    audit_id = _audit(
        "release_granted",
        video_id=video_id,
        mode_config=MODE,
        stub_indicator=result.stub_indicator,
        arm_id=req.attestation.expected_arm_id.lower(),
        envelope_bytes=envelope_path.stat().st_size,
        peer=peer,
    )
    log.info(
        "video=%s RELEASE arm_id=%s mode=%s stub=%s peer=%s audit=%s",
        video_id, req.attestation.expected_arm_id, MODE,
        result.stub_indicator, peer, audit_id,
    )
    return {
        "video_id": video_id,
        "envelope": envelope_data,
        "release_id": audit_id,
    }


@app.post("/processed/{result_id}", status_code=201)
async def store_processed(result_id: str, req: StoreRequest, request: Request) -> dict:
    peer = request.client.host if request.client else "unknown"

    result = _validate_attestation(req.attestation)
    if not result.ok:
        _audit(
            "store_denied",
            reason=result.reason,
            result_id=result_id,
            expected_arm_id=req.attestation.expected_arm_id,
            peer=peer,
        )
        log.warning(
            "processed=%s DENIED reason=%s peer=%s",
            result_id, result.reason, peer,
        )
        raise HTTPException(status_code=403, detail=result.reason)

    if not req.envelope.wrapped_dek_b64.startswith("vault:"):
        _audit(
            "store_denied",
            reason="wrapped-dek-not-vault-format",
            result_id=result_id,
            peer=peer,
        )
        raise HTTPException(status_code=400, detail="wrapped-dek-not-vault-format")

    out_dir = PROCESSED_DIR / result_id
    out_dir.mkdir(parents=True, exist_ok=True)
    envelope_path = out_dir / "envelope.json"
    envelope_path.write_text(req.envelope.model_dump_json(indent=2), encoding="utf-8")

    audit_id = _audit(
        "store_accepted",
        result_id=result_id,
        arm_id=req.attestation.expected_arm_id.lower(),
        envelope_bytes=envelope_path.stat().st_size,
        stored_path=str(envelope_path),
        peer=peer,
    )
    log.info(
        "processed=%s STORE arm_id=%s bytes=%d peer=%s audit=%s",
        result_id, req.attestation.expected_arm_id,
        envelope_path.stat().st_size, peer, audit_id,
    )
    return {
        "result_id": result_id,
        "stored_path": str(envelope_path),
        "audit_id": audit_id,
    }


@app.get("/audit/tail")
async def audit_tail(n: int = 20) -> list[dict]:
    if not AUDIT_LOG.is_file():
        return []
    with AUDIT_LOG.open("r", encoding="utf-8") as fh:
        lines = fh.readlines()
    return [json.loads(line) for line in lines[-max(1, min(n, 500)):]]
