"""
Shared envelope format and helpers used by producer + consumer.
"""
from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone


ENVELOPE_VERSION = 1


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def b64d(s: str) -> bytes:
    return base64.b64decode(s.encode("ascii"))


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Envelope:
    kek_name: str
    wrapped_dek: str        # "vault:v1:<base64>"
    nonce: str              # base64
    tag: str                # base64
    ciphertext: str         # base64
    producer_id: str
    content_type: str
    version: int = ENVELOPE_VERSION
    created_utc: str = field(default_factory=utcnow_iso)

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)

    @classmethod
    def from_json(cls, s: str) -> "Envelope":
        d = json.loads(s)
        if d.get("version") != ENVELOPE_VERSION:
            raise ValueError(f"unsupported envelope version {d.get('version')}")
        return cls(**d)


def zero_bytes(b: bytearray) -> None:
    """Best-effort zeroing of a bytearray. Python doesn't guarantee this
    but it removes the reference and reduces the window."""
    for i in range(len(b)):
        b[i] = 0
