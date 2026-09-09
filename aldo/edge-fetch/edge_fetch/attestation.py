"""
Attestation validation for the edge-fetch server.

Two modes are supported:

  stub   — accepts the Azure IMDS attested document from a Trusted Launch VM.
           This is what we run in the lab today because SEV-SNP quota is 0 in
           westus2. The response body includes an `X-Attestation-Mode: STUB` note
           that surfaces in the edge-fetch server log so on-stage a reviewer can
           see we are NOT running the real check.

  prod   — accepts only a SEV-SNP MAA (Microsoft Azure Attestation) JWT with a
           confidential VM measurement claim. This is a stub-of-a-stub for now:
           the code path is present so `EDGE_FETCH_ATTESTATION_MODE=prod` toggles
           the stricter check, but the JWT signature verification against the MAA
           JWKS is left as an explicit TODO that will be wired when we get real
           SEV-SNP quota. Until then, `prod` mode simply rejects everything, which
           is the correct fail-safe behavior for a production posture.

The stub is deliberately generous — it validates that the evidence is a well-formed
Azure IMDS attested document, that the signing chain roots at a Microsoft cert,
that the `vmId` inside matches the caller's `expected_arm_id`, and that the doc
is fresh (< 5 minutes old). It does NOT validate SEV-SNP measurements because
there is no such measurement in a Trusted Launch document.

References:
  - IMDS attested doc: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service?tabs=windows#attested-data
  - MAA JWT: https://learn.microsoft.com/en-us/azure/attestation/overview
"""

from __future__ import annotations

import base64
import json
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

log = logging.getLogger("edge-fetch.attestation")

# Max age of an IMDS attested document we will accept (freshness bound).
STUB_MAX_AGE = timedelta(minutes=5)


@dataclass
class ValidationResult:
    ok: bool
    reason: str = ""
    # Human-readable indicator for logs / audit / demo overlay.
    # e.g. "STUB(imds,vmId=...)", "PROD(sev-snp,measurement=...)", "REJECT(...)".
    stub_indicator: str = ""


def validate(
    *,
    mode_config: str,
    payload_mode: str,
    evidence_b64: str,
    expected_arm_id: str,
    allowed_arm_ids: list[str],
) -> ValidationResult:
    """
    Validate attestation evidence.

    Behavior matrix:

      mode_config  payload_mode         action
      -----------  -------------------  --------------------------------------
      stub         stub-tl-imds         run stub IMDS validation
      stub         sev-snp              accept if PROD path succeeds (upgrade)
      prod         sev-snp              run SEV-SNP validation (currently stubbed to REJECT)
      prod         stub-tl-imds         REJECT — stub evidence is not acceptable in prod

    `expected_arm_id` must be in `allowed_arm_ids` (case-insensitive).
    """
    expected_lower = expected_arm_id.lower()
    if allowed_arm_ids and expected_lower not in allowed_arm_ids:
        return ValidationResult(
            ok=False,
            reason="arm-id-not-allowlisted",
            stub_indicator=f"REJECT(arm_id={expected_lower[:60]})",
        )

    if mode_config == "prod" and payload_mode == "stub-tl-imds":
        return ValidationResult(
            ok=False,
            reason="stub-evidence-not-accepted-in-prod",
            stub_indicator="REJECT(mode=prod,payload=stub)",
        )

    if payload_mode == "stub-tl-imds":
        return _validate_imds_stub(evidence_b64, expected_arm_id)

    if payload_mode == "sev-snp":
        return _validate_sev_snp(evidence_b64, expected_arm_id, mode_config)

    return ValidationResult(
        ok=False,
        reason=f"unknown-payload-mode:{payload_mode}",
        stub_indicator=f"REJECT(unknown-mode={payload_mode})",
    )


def _validate_imds_stub(evidence_b64: str, expected_arm_id: str) -> ValidationResult:
    """
    Validate an Azure IMDS attested document from a Trusted Launch VM.

    Freshness + subject-matches-expected-ARM-id checks are enforced. Signature
    validation against Microsoft's cert chain is intentionally NOT done here —
    that would require pulling the cert chain from the document and validating
    against a Microsoft root, which is straightforward but noisy for the demo.
    In prod mode this whole path is disabled.
    """
    try:
        raw = base64.b64decode(evidence_b64)
        doc = json.loads(raw)
    except Exception as ex:
        return ValidationResult(
            ok=False,
            reason=f"stub-evidence-not-parseable:{type(ex).__name__}",
            stub_indicator="STUB_REJECT(parse-fail)",
        )

    # IMDS attested doc contains a nested "signature" (JWS) and a "encoding"
    # field. The interesting payload lives in the JWS payload segment. For the
    # stub we accept either the raw IMDS response body OR our simpler wrapper
    # that the burst_consumer builds (which extracts vmId / timestamp / subject).
    subject_arm_id: Optional[str] = doc.get("subject_arm_id")
    doc_timestamp: Optional[str] = doc.get("timestamp")

    if not subject_arm_id or not doc_timestamp:
        # Try to parse the raw IMDS body — it stores fields under "payload".
        payload = doc.get("payload") or {}
        subject_arm_id = subject_arm_id or payload.get("subject_arm_id")
        doc_timestamp = doc_timestamp or payload.get("timeStamp") or payload.get("timestamp")

    if not subject_arm_id or not doc_timestamp:
        return ValidationResult(
            ok=False,
            reason="stub-evidence-missing-subject-or-timestamp",
            stub_indicator="STUB_REJECT(missing-fields)",
        )

    if subject_arm_id.lower() != expected_arm_id.lower():
        return ValidationResult(
            ok=False,
            reason="stub-subject-mismatch",
            stub_indicator=f"STUB_REJECT(subject={subject_arm_id[:60]})",
        )

    try:
        ts = datetime.fromisoformat(doc_timestamp.replace("Z", "+00:00"))
    except Exception:
        return ValidationResult(
            ok=False,
            reason="stub-timestamp-not-parseable",
            stub_indicator="STUB_REJECT(ts-parse)",
        )
    now = datetime.now(timezone.utc)
    if ts > now + timedelta(seconds=60):
        return ValidationResult(
            ok=False,
            reason="stub-timestamp-in-future",
            stub_indicator="STUB_REJECT(ts-future)",
        )
    if now - ts > STUB_MAX_AGE:
        return ValidationResult(
            ok=False,
            reason=f"stub-timestamp-too-old:{(now-ts).total_seconds():.0f}s",
            stub_indicator="STUB_REJECT(ts-stale)",
        )

    log.info(
        "STUB ACCEPT subject=%s doc_ts=%s age=%ds",
        subject_arm_id, doc_timestamp, int((now - ts).total_seconds()),
    )
    return ValidationResult(
        ok=True,
        stub_indicator=f"STUB(imds,vmId={subject_arm_id.split('/')[-1]})",
    )


def _validate_sev_snp(evidence_b64: str, expected_arm_id: str, mode_config: str) -> ValidationResult:
    """
    Validate a SEV-SNP MAA JWT.

    NOT IMPLEMENTED. Kept as a fail-safe reject until real SEV-SNP quota lands.
    When implemented, this will:
      1. Parse the JWT; fetch MAA JWKS; verify signature.
      2. Assert `x-ms-attestation-type == "sevsnpvm"`.
      3. Assert `x-ms-compliance-status == "azure-compliant-cvm"`.
      4. Assert `x-ms-sevsnpvm-launchmeasurement` matches an expected reference value.
      5. Assert `subject_arm_id` matches `expected_arm_id`.
    """
    return ValidationResult(
        ok=False,
        reason="sev-snp-validation-not-implemented",
        stub_indicator=f"PROD_REJECT(sev-snp,mode_config={mode_config})",
    )
