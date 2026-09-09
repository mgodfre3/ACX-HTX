"""
seed_video.py — build a burst-CVM envelope from a source video file.

Usage:
  python -m edge_fetch.seed_video \
    --video-id sample-video-01 \
    --input /path/to/source.mp4 \
    --storage-root /var/lib/edge-fetch \
    --vault-addr http://127.0.0.1:8200 \
    --vault-token <root_or_seed_token> \
    --kek-name htx-kek

What it does (all on the edge, never touches Azure):
  1. Read the source file into memory.
  2. Generate a random 32-byte DEK.
  3. AES-256-GCM encrypt the payload with the DEK (12-byte random nonce).
  4. Call Vault Transit `encrypt` on the `htx-kek` transit key to wrap the DEK.
     (Vault Transit is symmetric-encrypt-friendly for arbitrary bytes and returns
     an opaque `vault:v1:<ciphertext>` reference. This is the format the
     unwrap service already knows how to reverse.)
  5. Write an envelope.json at
     {storage_root}/videos/{video_id}/envelope.json
     matching the schema declared in edge_fetch.server.Envelope.

The DEK, plaintext, and the source file bytes are zeroized from local variables
before exit. The source file on disk is left in place — this is a seed utility,
not a shredder.
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

log = logging.getLogger("seed-video")
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")


def _wrap_dek_with_vault(vault_addr: str, vault_token: str, kek_name: str, dek: bytes) -> str:
    """Call Vault Transit `encrypt` and return the `vault:v1:...` ciphertext."""
    url = f"{vault_addr.rstrip('/')}/v1/transit/encrypt/{kek_name}"
    headers = {"X-Vault-Token": vault_token}
    body = {"plaintext": base64.b64encode(dek).decode("ascii")}
    r = httpx.post(url, headers=headers, json=body, timeout=10.0)
    r.raise_for_status()
    return r.json()["data"]["ciphertext"]


def main() -> int:
    p = argparse.ArgumentParser(description="Seed a burst-CVM video envelope.")
    p.add_argument("--video-id", required=True, help="Logical ID under storage-root/videos/")
    p.add_argument("--input", required=True, type=Path, help="Path to source video (any bytes)")
    p.add_argument("--storage-root", type=Path, default=Path("/var/lib/edge-fetch"))
    p.add_argument("--vault-addr", default=os.environ.get("VAULT_ADDR", "http://127.0.0.1:8200"))
    p.add_argument("--vault-token", default=os.environ.get("VAULT_TOKEN"))
    p.add_argument("--kek-name", default="htx-kek")
    args = p.parse_args()

    if not args.vault_token:
        log.error("VAULT_TOKEN not provided (--vault-token or env)")
        return 2
    if not args.input.is_file():
        log.error("input file not found: %s", args.input)
        return 2

    plaintext = args.input.read_bytes()
    log.info("read %d bytes from %s", len(plaintext), args.input)

    dek = secrets.token_bytes(32)
    nonce = secrets.token_bytes(12)
    aesgcm = AESGCM(dek)
    ciphertext_and_tag = aesgcm.encrypt(nonce, plaintext, associated_data=None)
    # AESGCM in cryptography returns ciphertext||tag concatenated.
    ciphertext, tag = ciphertext_and_tag[:-16], ciphertext_and_tag[-16:]

    wrapped_dek = _wrap_dek_with_vault(
        args.vault_addr, args.vault_token, args.kek_name, dek,
    )
    log.info("wrapped DEK via Vault Transit key %r", args.kek_name)

    envelope = {
        "version": "burst-cvm-1",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "kek_ref": f"transit/keys/{args.kek_name}",
        "wrap_algo": "vault-transit-aes256gcm96",
        "wrapped_dek_b64": wrapped_dek,   # Vault ciphertext is already string-encoded ("vault:v1:...")
        "data_algo": "aes-256-gcm",
        "nonce_b64": base64.b64encode(nonce).decode("ascii"),
        "tag_b64": base64.b64encode(tag).decode("ascii"),
        "ciphertext_b64": base64.b64encode(ciphertext).decode("ascii"),
    }

    out_dir = args.storage_root / "videos" / args.video_id
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "envelope.json"
    out_path.write_text(json.dumps(envelope, indent=2), encoding="utf-8")
    log.info("wrote envelope to %s (%d bytes)", out_path, out_path.stat().st_size)

    # Zeroize local secrets (best effort — Python doesn't give a strong guarantee).
    dek = b"\x00" * 32
    nonce = b"\x00" * 12
    plaintext = b""
    ciphertext = b""

    print(json.dumps({
        "video_id": args.video_id,
        "envelope_path": str(out_path),
        "source_bytes": len(envelope["ciphertext_b64"]),
        "kek_ref": envelope["kek_ref"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
