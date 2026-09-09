#!/usr/bin/env bash
# install.sh — deploy edge-fetch alongside the existing unwrap service.
#
# Run on the ALDO Vault VM at 172.22.218.200 as a user with sudo.
# Idempotent: safe to re-run to pick up config changes.
#
# Prereqs: python3 >= 3.10, systemd, the existing unwrap service already running on :8443.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/edge-fetch}"
STORAGE_ROOT="${STORAGE_ROOT:-/var/lib/edge-fetch}"
SERVICE_USER="${SERVICE_USER:-edge-fetch}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:8444}"

# Allowed ARM ID(s) of Azure VMs permitted to attest. Edit this before first run.
ALLOWED_ARM_IDS="${ALLOWED_ARM_IDS:-/subscriptions/fbaf508b-cb61-4383-9cda-a42bfa0c7bc9/resourceGroups/ACX-HTX/providers/Microsoft.Compute/virtualMachines/acxhtx-vm}"

# stub  — accepts Trusted Launch IMDS docs (current lab)
# prod  — requires SEV-SNP (rejects everything until SEV-SNP validation is wired)
ATTESTATION_MODE="${ATTESTATION_MODE:-stub}"

# Vault token used by edge-fetch to proxy Transit encrypt/decrypt for /wrap and /unwrap.
# Must have policy allowing encrypt+decrypt on transit/keys/htx-kek.
# The producer token from vault-app-tokens.json is a fine choice; the unwrap
# token is another. NEVER pass the Vault root token here.
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN is required — provide a Vault token with transit encrypt+decrypt on htx-kek}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TRANSIT_KEY="${VAULT_TRANSIT_KEY:-htx-kek}"

echo "== install root      : $INSTALL_ROOT"
echo "== storage root      : $STORAGE_ROOT"
echo "== service user      : $SERVICE_USER"
echo "== listen            : $LISTEN_ADDR"
echo "== attestation mode  : $ATTESTATION_MODE"
echo "== allowed ARM IDs   : $ALLOWED_ARM_IDS"
echo "== vault addr        : $VAULT_ADDR"
echo "== vault transit key : $VAULT_TRANSIT_KEY"

# --- system user + storage ---

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  sudo useradd --system --home "$STORAGE_ROOT" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
sudo mkdir -p "$STORAGE_ROOT/videos" "$STORAGE_ROOT/processed"
sudo touch "$STORAGE_ROOT/audit.jsonl"
sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$STORAGE_ROOT"

# --- python venv + package ---

sudo mkdir -p "$INSTALL_ROOT"
sudo chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_ROOT"
sudo -u "$SERVICE_USER" python3 -m venv "$INSTALL_ROOT/venv"
sudo -u "$SERVICE_USER" "$INSTALL_ROOT/venv/bin/pip" install --upgrade pip
sudo -u "$SERVICE_USER" "$INSTALL_ROOT/venv/bin/pip" install -r "$REPO_ROOT/aldo/edge-fetch/requirements.txt"
sudo cp -r "$REPO_ROOT/aldo/edge-fetch/edge_fetch" "$INSTALL_ROOT/"
sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_ROOT/edge_fetch"

# --- systemd unit ---

LISTEN_HOST="${LISTEN_ADDR%:*}"
LISTEN_PORT="${LISTEN_ADDR##*:}"

sudo tee /etc/systemd/system/edge-fetch.service >/dev/null <<UNIT
[Unit]
Description=Edge Fetch Server (sovereign burst-CVM endpoint)
After=network-online.target vault.service
Wants=network-online.target

[Service]
Type=exec
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$INSTALL_ROOT
Environment=EDGE_FETCH_LISTEN=$LISTEN_ADDR
Environment=EDGE_FETCH_STORAGE_ROOT=$STORAGE_ROOT
Environment=EDGE_FETCH_ALLOWED_ARM_IDS=$ALLOWED_ARM_IDS
Environment=EDGE_FETCH_ATTESTATION_MODE=$ATTESTATION_MODE
Environment=EDGE_FETCH_UNWRAP_URL=http://127.0.0.1:8443/unwrap
Environment=EDGE_FETCH_VAULT_ADDR=$VAULT_ADDR
Environment=EDGE_FETCH_VAULT_TOKEN=$VAULT_TOKEN
Environment=EDGE_FETCH_VAULT_TRANSIT_KEY=$VAULT_TRANSIT_KEY
ExecStart=$INSTALL_ROOT/venv/bin/uvicorn edge_fetch.server:app --host $LISTEN_HOST --port $LISTEN_PORT --log-level info
Restart=on-failure
RestartSec=5s
# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$STORAGE_ROOT

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now edge-fetch.service

echo
echo "-- edge-fetch service status --"
sudo systemctl --no-pager status edge-fetch.service | head -20
echo
echo "-- healthz probe --"
sleep 2
curl -sS "http://127.0.0.1:$LISTEN_PORT/healthz" | python3 -m json.tool || true

cat <<EOF

Next steps:
  1. Seed a sample video envelope:
       sudo -u $SERVICE_USER VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<producer-token> \\
         $INSTALL_ROOT/venv/bin/python -m edge_fetch.seed_video \\
         --video-id sample-video-01 --input /path/to/sample.mp4 \\
         --storage-root $STORAGE_ROOT

  2. Confirm allow-list on the CVM side matches ALLOWED_ARM_IDS above.

  3. Tail logs during the demo:
       journalctl -u edge-fetch -f
EOF
