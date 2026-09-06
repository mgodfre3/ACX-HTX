#!/usr/bin/env bash
# Bootstrap HashiCorp Vault on the sovereign VM.
# Run this once, from the Vault VM, after cloud-init has installed Vault.

set -euo pipefail

VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
export VAULT_ADDR

cat > /etc/vault.d/vault.hcl <<EOF
ui = true
disable_mlock = false
api_addr = "http://0.0.0.0:8200"
cluster_addr = "http://0.0.0.0:8201"
storage "file" { path = "/opt/vault/data" }
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"  # DEMO ONLY - production must use TLS with CA-signed cert
}
EOF

systemctl restart vault
sleep 5

echo "[1/5] Initializing Vault..."
if vault status | grep -q 'Initialized.*true'; then
    echo "    Already initialized."
else
    vault operator init -key-shares=1 -key-threshold=1 -format=json > /root/vault-init.json
    chmod 600 /root/vault-init.json
    echo "    Init keys written to /root/vault-init.json (production would split via Shamir)."
fi

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/vault-init.json)

echo "[2/5] Unsealing..."
vault operator unseal "$UNSEAL_KEY" >/dev/null

export VAULT_TOKEN="$ROOT_TOKEN"

echo "[3/5] Enabling Transit engine..."
vault secrets enable -path=transit transit 2>/dev/null || echo "    Already enabled."

echo "[4/5] Creating sovereign KEK 'htx-kek'..."
vault write -f transit/keys/htx-kek type=rsa-3072
echo "    KEK created. Production: BYOK from customer HSM."

echo "[5/5] Enabling audit log..."
mkdir -p /var/log/vault
vault audit enable file file_path=/var/log/vault/audit.log 2>/dev/null || echo "    Already enabled."

echo ""
echo "======================================================================"
echo "  Sovereign local Vault initialized."
echo "  Address: $VAULT_ADDR"
echo "  KEK:     transit/keys/htx-kek"
echo "======================================================================"
