"""
attestation.py — build attestation evidence for the burst CVM.

Two modes are supported, matched to the edge-fetch server's validator:

  stub-tl-imds   The Trusted Launch stand-in for SEV-SNP. Wraps the Azure IMDS
                 attested-data document into the envelope the edge expects. This
                 is what runs in the lab today.

  sev-snp        Real SEV-SNP MAA JWT. Placeholder — will be implemented when
                 SEV-SNP quota lands. Until then this raises NotImplementedError.

The edge validates whichever mode the CVM claims; it will reject a stub-mode
evidence when it is configured in prod mode. That mismatch is the correct
production behavior — never accept stub evidence for a real workload.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import httpx

log = logging.getLogger("burst-consumer.attest")

# IMDS attested-data endpoint. Only reachable from inside the Azure VM.
IMDS_ATTESTED_URL = "http://169.254.169.254/metadata/attested/document?api-version=2020-09-01"
# IMDS instance metadata — used to look up our own ARM ID.
IMDS_INSTANCE_URL = "http://169.254.169.254/metadata/instance?api-version=2021-02-01"


@dataclass
class AttestationEnvelope:
    mode: str
    evidence_b64: str
    expected_arm_id: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "evidence_b64": self.evidence_b64,
            "expected_arm_id": self.expected_arm_id,
        }


def _own_arm_id() -> str:
    """Query IMDS for our own ARM resource ID."""
    r = httpx.get(IMDS_INSTANCE_URL, headers={"Metadata": "true"}, timeout=5.0)
    r.raise_for_status()
    body = r.json()
    compute = body["compute"]
    sub = compute["subscriptionId"]
    rg = compute["resourceGroupName"]
    name = compute["name"]
    return f"/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{name}"


def _imds_attested_doc() -> dict[str, Any]:
    """Fetch the raw IMDS attested-data document."""
    r = httpx.get(IMDS_ATTESTED_URL, headers={"Metadata": "true"}, timeout=5.0)
    r.raise_for_status()
    return r.json()


def build(mode: str) -> AttestationEnvelope:
    """
    Build the attestation envelope to POST to the edge.

    For `stub-tl-imds`, we wrap the IMDS document with our subject ARM ID and
    timestamp fields the edge validator expects. This is a stand-in for real
    SEV-SNP measurement bytes and is clearly labeled as such in every log line.
    """
    arm_id = _own_arm_id()

    if mode == "stub-tl-imds":
        imds = _imds_attested_doc()
        wrapper = {
            "subject_arm_id": arm_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "imds_document": imds,
        }
        evidence_b64 = base64.b64encode(json.dumps(wrapper).encode("utf-8")).decode("ascii")
        log.info("attestation STUB(imds) built for subject=%s", arm_id)
        return AttestationEnvelope(
            mode="stub-tl-imds",
            evidence_b64=evidence_b64,
            expected_arm_id=arm_id,
        )

    if mode == "sev-snp":
        raise NotImplementedError(
            "SEV-SNP attestation not implemented — waiting on real SEV-SNP quota. "
            "Set BURST_CONSUMER_ATTESTATION_MODE=stub-tl-imds to run the stub."
        )

    raise ValueError(f"unknown attestation mode: {mode}")
