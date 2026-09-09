"""
Sovereign Unwrap Service - runs on the ALDO Vault VM (sidecar to Vault).

Purpose:
    Only release customer DEK material to an Azure workload that can PROVE,
    via a signed Microsoft Azure Attestation (MAA) token, that it is a
    Confidential VM (or Trusted Launch, in demo mode) satisfying the policy.

Endpoint:
    POST /unwrap
        body: { "maa_token": "<JWT>", "wrapped_dek": "vault:v1:<base64>" }
        200:  { "dek": "<base64>", "policy_matched": "...", "kek_name": "..." }
        403:  { "error": "attestation_rejected", "reasons": [...] }
        400:  { "error": "bad_request", "detail": "..." }
"""
from __future__ import annotations

import base64
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import hvac
import jwt
import yaml
from flask import Flask, jsonify, request
from jwt import PyJWKClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "shared"))

logging.basicConfig(
    level=logging.INFO,
    format="[unwrap] %(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("unwrap-service")


@dataclass
class Policy:
    trusted_issuers: list[str] = field(default_factory=list)
    allowed_tee_types: list[str] = field(default_factory=list)
    require_compliance_status: Optional[str] = None
    allowed_vm_ids: list[str] = field(default_factory=list)
    max_token_age_seconds: int = 300


def load_policy(path: Path) -> Policy:
    with path.open() as f:
        d = yaml.safe_load(f) or {}
    return Policy(**d)


class AttestationError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


_jwks_cache: dict[str, PyJWKClient] = {}


def _jwks_client(issuer: str) -> PyJWKClient:
    if issuer not in _jwks_cache:
        # MAA publishes JWKS at <issuer>/certs
        _jwks_cache[issuer] = PyJWKClient(f"{issuer.rstrip('/')}/certs")
    return _jwks_cache[issuer]


def verify_maa_token(token: str, policy: Policy, demo_mode: bool) -> dict[str, Any]:
    # First, peek at the issuer without verifying, to pick the right JWKS
    unverified = jwt.decode(token, options={"verify_signature": False})
    iss = unverified.get("iss")
    if iss not in policy.trusted_issuers:
        raise AttestationError(f"issuer_not_trusted: {iss}")

    try:
        signing_key = _jwks_client(iss).get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            issuer=iss,
            options={"verify_aud": False},
        )
    except Exception as e:
        raise AttestationError(f"signature_invalid: {e}")

    now = int(time.time())
    iat = int(claims.get("iat", 0))
    if now - iat > policy.max_token_age_seconds:
        raise AttestationError(f"token_stale: age={now - iat}s")

    tee_type = claims.get("x-ms-attestation-type", "unknown")
    if tee_type not in policy.allowed_tee_types:
        if demo_mode:
            log.warning("[demo-mode] tee_type '%s' not allowed but allowing", tee_type)
        else:
            raise AttestationError(f"tee_type_not_allowed: {tee_type}")

    comp = claims.get("x-ms-compliance-status")
    if policy.require_compliance_status and comp != policy.require_compliance_status:
        if demo_mode:
            log.warning("[demo-mode] compliance '%s' != required '%s' but allowing", comp, policy.require_compliance_status)
        else:
            raise AttestationError(f"compliance_status_mismatch: {comp}")

    vm_id = claims.get("x-ms-runtime", {}).get("vm-id") or claims.get("x-ms-azurevm-vmid")
    if policy.allowed_vm_ids and vm_id not in policy.allowed_vm_ids:
        if demo_mode:
            log.warning("[demo-mode] vm_id '%s' not in allow-list but allowing", vm_id)
        else:
            raise AttestationError(f"vm_id_not_allowed: {vm_id}")

    return claims


def unwrap_dek(vault: hvac.Client, kek_name: str, wrapped_dek: str) -> bytes:
    resp = vault.secrets.transit.decrypt_data(name=kek_name, ciphertext=wrapped_dek)
    dek_b64 = resp["data"]["plaintext"]
    return base64.b64decode(dek_b64)


app = Flask(__name__)
policy: Policy
vault: hvac.Client
demo_mode: bool


@app.route("/health", methods=["GET"])
def health() -> Any:
    return jsonify({
        "status": "ok",
        "vault_addr": os.environ.get("HTX_VAULT_ADDR"),
        "demo_mode": demo_mode,
        "kek_name": os.environ.get("HTX_KEK_NAME"),
    })


@app.route("/unwrap", methods=["POST"])
def unwrap() -> Any:
    body = request.get_json(silent=True) or {}
    maa_token = body.get("maa_token")
    wrapped_dek = body.get("wrapped_dek")

    if not maa_token or not wrapped_dek:
        return jsonify({"error": "bad_request", "detail": "maa_token and wrapped_dek are required"}), 400

    try:
        claims = verify_maa_token(maa_token, policy, demo_mode)
    except AttestationError as e:
        log.warning("attestation rejected: %s", e.reason)
        return jsonify({"error": "attestation_rejected", "reasons": [e.reason]}), 403

    log.info(
        "attestation OK: tee=%s vm=%s iss=%s",
        claims.get("x-ms-attestation-type"),
        claims.get("x-ms-runtime", {}).get("vm-id") or claims.get("x-ms-azurevm-vmid"),
        claims.get("iss"),
    )

    try:
        dek = unwrap_dek(vault, os.environ.get("HTX_KEK_NAME", "htx-kek"), wrapped_dek)
    except Exception as e:
        log.exception("vault unwrap failed")
        return jsonify({"error": "vault_error", "detail": str(e)}), 500

    return jsonify({
        "dek": base64.b64encode(dek).decode("ascii"),
        "kek_name": os.environ.get("HTX_KEK_NAME", "htx-kek"),
        "policy_matched": "ok",
        "tee_type": claims.get("x-ms-attestation-type"),
        "demo_mode": demo_mode,
    }), 200


def main() -> None:
    global policy, vault, demo_mode
    policy_path = Path(os.environ.get("HTX_POLICY_PATH", "policy.yaml"))
    policy = load_policy(policy_path)
    demo_mode = os.environ.get("HTX_DEMO_MODE") == "1"

    vault = hvac.Client(url=os.environ["HTX_VAULT_ADDR"], token=os.environ["HTX_VAULT_TOKEN"])
    if not vault.is_authenticated():
        raise SystemExit("[unwrap] Vault authentication failed at startup")

    listen = os.environ.get("HTX_LISTEN_ADDR", "0.0.0.0:8443")
    host, port = listen.rsplit(":", 1)

    log.info(
        "policy loaded: issuers=%d tees=%s demo=%s",
        len(policy.trusted_issuers), policy.allowed_tee_types, demo_mode,
    )
    log.info("listening on %s", listen)
    app.run(host=host, port=int(port), debug=False)


if __name__ == "__main__":
    main()
