# Vault Token Runbook

**Always mint scoped Vault tokens with `-orphan`. Always.**

If you skip that flag, the token becomes a **child** of whichever token created it (usually root). When root is rotated, the cascade revokes every child of the old root, and every service holding one of those tokens breaks silently.

## The rule

```bash
# CORRECT -- orphan periodic token, survives root rotation
vault token create \
  -orphan \
  -policy=<policy-name> \
  -period=720h \
  -display-name=<service-name> \
  -format=json

# WRONG -- child token, revoked on next root rotation
vault token create \
  -policy=<policy-name> \
  -period=720h \
  -display-name=<service-name>
```

That single `-orphan` flag is the whole difference. The token still enforces its policy the same way, still renews the same way, still shows in `vault list auth/token/accessors` the same way. Only the parent-child relationship changes -- and that's exactly what causes the cascade problem.

## Why this matters

`vault operator generate-root` produces a new root. `vault token revoke` on the old root then walks the token tree and revokes every descendant. Any scoped service token that was created as a plain (non-orphan) child of that root goes with it. In practice:

- The service that holds the token stops working immediately.
- The failure looks like `permission denied` on whatever the service was authorized to do.
- Nothing about the service configuration, the policy, or the token file changed. Only the token itself was silently invalidated by an unrelated administrative action.

Orphan tokens have no parent, so nothing revokes them when root rotates.

## Provisioned tokens on the ALDO Vault VM

All four scoped tokens are now orphan periodic (as of 2026-09-14 root rotation). Accessors are safe to reference; the values live only on the edge.

| Token | Accessor | Policy | Installed at | File format | Mode | Owner |
|---|---|---|---|---|---|---|
| `htx-edge-fetch` | `KT8F0qJQibJBk2Vbx2ZBZSq5` | transit encrypt+decrypt on htx-kek | `/etc/edge-fetch/env` | `EDGE_FETCH_VAULT_TOKEN=<value>` (systemd EnvironmentFile) | `0600` | `edge:edge` |
| `htx-toggle` | `J7wqli7KjXvPaMvbq76rQ9aU` | transit rotate/config/read on htx-kek | `/etc/vault/htx-toggle-token` | raw token, no newline | `0440` | `root:edge` |
| `htx-producer` | `rSryuRBCahcgkWeKWyNcZhrB` | seed_video / producer path (transit encrypt on htx-kek) | Foundry producer VM `HTX_VAULT_TOKEN` Machine env var (172.22.218.201) | env-var value | n/a | Machine-scope |
| `htx-unwrap` | `Wr8wQUca34TyV2HELAhLl756` | transit decrypt on htx-kek | legacy unwrap service config on :8443 | raw token | `0400` | `root:root` |

**When re-minting a token, follow the row above for that specific token.** The file location, format, mode, and owner MUST match; the ceremony below covers the raw-token pattern (used by `htx-toggle` and `htx-unwrap`), but `htx-edge-fetch` uses the KEY=VALUE env-file pattern -- see the alternative install step in the ceremony section for that shape.

## When to re-mint

Re-mint a scoped token when:

1. **Root has been rotated** -- verify with `vault token lookup -accessor <accessor>`. If the token is still valid, you're fine. If it returns "bad token," the previous root rotation cascaded to it and it needs re-minting as orphan.
2. **A token file is compromised** -- if someone gets to the file, revoke the accessor and mint a new orphan.
3. **Approaching TTL** -- periodic tokens with a 720h period should be renewed by their consumers automatically; if not, mint a new one.

## Ceremony: mint a new orphan periodic token

Run on the Vault VM as root (`sudo -i`):

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(jq -r .root_token /root/vault-init.json)

# Choose your parameters
POLICY=htx-toggle              # policy name that must already exist
DISPLAY=htx-toggle-token       # human-readable label
PERIOD=720h                    # 30-day renewal window

# Create it (note the -orphan flag)
vault token create \
  -orphan \
  -policy="$POLICY" \
  -period="$PERIOD" \
  -display-name="$DISPLAY" \
  -format=json > /tmp/mint.json

# Extract the accessor (safe to log) and token (must not be logged)
NEW_ACCESSOR=$(jq -r .auth.accessor /tmp/mint.json)
NEW_TOKEN=$(jq -r .auth.client_token /tmp/mint.json)

echo "new accessor: $NEW_ACCESSOR"
echo "token ends in: ${NEW_TOKEN: -6}"    # never print the full value
```

Now install the token. The install step differs by consumer -- pick the row that matches the token you're re-minting from the "Provisioned tokens" table above.

### Install pattern A: raw token file (`htx-toggle`, `htx-unwrap`)

```bash
# Adjust for the specific token being re-minted (from the "Provisioned tokens" table)
TARGET=/etc/vault/htx-toggle-token   # e.g., /etc/vault/htx-toggle-token or the htx-unwrap path
OWNER=root:edge                       # e.g., root:edge (htx-toggle) or root:root (htx-unwrap)
MODE=0440                              # e.g., 0440 (htx-toggle) or 0400 (htx-unwrap)
READER=edge                            # the user that actually reads the token: 'edge' for
                                       # htx-toggle (needed for demo-toggle-vault.ps1's ssh call);
                                       # 'root' for htx-unwrap (read by the unwrap service, which
                                       # runs as root).

echo -n "$NEW_TOKEN" | sudo tee "$TARGET" > /dev/null
sudo chmod "$MODE" "$TARGET"
sudo chown "$OWNER" "$TARGET"

# Verify: the intended reader can read it, and the token itself is valid
sudo -u "$READER" cat "$TARGET" | wc -c    # non-zero
sudo -u "$READER" sh -c "export VAULT_ADDR=http://127.0.0.1:8200; \
  export VAULT_TOKEN=\$(cat $TARGET); \
  vault token lookup | grep -E 'policies|renewable|orphan'"
# Expect: policies contains the intended policy, renewable=true, orphan=true
```

### Install pattern B: systemd EnvironmentFile (`htx-edge-fetch`)

```bash
TARGET=/etc/edge-fetch/env
# Rewrite ONLY the EDGE_FETCH_VAULT_TOKEN line; preserve the rest.
sudo sed -i "s|^EDGE_FETCH_VAULT_TOKEN=.*|EDGE_FETCH_VAULT_TOKEN=$NEW_TOKEN|" "$TARGET"
sudo chmod 0600 "$TARGET"
sudo chown edge:edge "$TARGET"

# Restart the service so it picks up the new value
sudo systemctl restart edge-fetch

# Verify: service is healthy
curl -sS http://127.0.0.1:8444/healthz | jq -r '.status'
# Expect: ok
```

### Install pattern C: env-var on a remote Windows VM (`htx-producer`)

```bash
# This one lives on the Foundry producer VM at 172.22.218.201 as a Machine
# scope env var. From the Vault VM you cannot set it directly; hand off the
# new token to the ALDO Copilot agent on the Foundry VM and have that session
# run (PowerShell, elevated):
#
#   [Environment]::SetEnvironmentVariable(
#     'HTX_VAULT_TOKEN',
#     '<new token value>',
#     'Machine')
#
# Then restart any scheduled producer task or the producer process so it
# rereads the Machine env var.
```

### Cleanup (all patterns)

```bash
shred -u /tmp/mint.json
```

## Ceremony: rotate the Vault root token

The 2026-09-14 root rotation exposed the child-token cascade problem. If you rotate root again, follow this order:

1. **Pre-flight (mandatory).** Enumerate every scoped token on the Vault instance and check each one for `orphan=true`. Use **discovery**, not memory — a hardcoded list of "known" accessors is what led to the 2026-09-14 incident, and if a future service is provisioned without being added to that list, the same failure will repeat.
   ```bash
   sudo -i
   export VAULT_ADDR=http://127.0.0.1:8200
   export VAULT_TOKEN=$(jq -r .root_token /root/vault-init.json)

   # List every accessor in the token store, look up each, print the fields
   # that matter for rotation safety.
   vault list -format=json auth/token/accessors \
     | jq -r '.[]' \
     | while read -r A; do
         vault token lookup -accessor "$A" -format=json 2>/dev/null \
           | jq -r '[.data.display_name, .data.accessor, (.data.orphan|tostring), (.data.policies|join(","))] | @tsv' \
           2>/dev/null
       done \
     | column -t -s $'\t'
   ```
   Skim the output. **Any row where the third column (`orphan`) is `false` and the fourth column is not `root` must be re-minted as orphan BEFORE you touch the root ceremony.** If you skip this step and the rotation cascades to a child token, the affected service breaks and you have to re-mint under time pressure. (Root's own token entry will show `orphan=false` -- that's expected and is what gets rotated; it's the non-root children that matter.)

2. **Ceremony.** `vault operator generate-root -init`, provide unseal key(s), decode the encoded token, capture the accessor.

3. **Revoke old root by accessor** (not by value -- less risk of a copy-paste leak like the 2026-09-14 incident): `vault token revoke -accessor <old-accessor>`.

4. **Update `/root/vault-init.json`** with the new root token value. Keep it `root:root`, mode `0600`.

5. **Verify all scoped tokens still respond.** Re-run the inventory command above. Each accessor should still return valid metadata. If any return "bad token," the token was child-linked to the old root and needs immediate re-minting.

6. **Verify service smoke tests:**
   ```bash
   # edge-fetch
   curl -sS http://127.0.0.1:8444/healthz | jq -r '.status'   # ok
   # legacy unwrap
   curl -sS http://127.0.0.1:8443/health                       # HTTP 200
   # transit read via toggle token
   sudo -u edge sh -c 'export VAULT_ADDR=http://127.0.0.1:8200; \
     export VAULT_TOKEN=$(cat /etc/vault/htx-toggle-token); \
     vault read -field=latest_version transit/keys/htx-kek'    # returns a number
   ```

7. **Shred any temp files** (`/tmp/generate-root-*.json`, `/tmp/new-root-token`, etc.). No sensitive material should linger in `/tmp`.

## Historical incident: 2026-09-14

- **Trigger:** operator laptop captured the Vault root token in a paste screenshot. Rotation was initiated to revoke the exposed token.
- **Discovery:** three scoped tokens (`htx-toggle`, `htx-producer`, `htx-unwrap`) had been minted without `-orphan`. They were children of the old root, and revoking root cascaded to them.
- **Impact:** the toggle script, the Foundry producer, and the legacy unwrap service lost their credentials simultaneously.
- **Remediation:** each affected token was re-minted as orphan periodic. Token files at existing paths were replaced in place. Services picked up the new values without configuration changes.
- **`htx-edge-fetch` was already orphan** (it was minted correctly on 2026-09-09) and survived the rotation untouched.
- **Documented lesson:** always mint with `-orphan`. This runbook is the durable form of that lesson.
