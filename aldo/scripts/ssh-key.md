# SSH Key for ALDO Vault VM Admin

The public key for the `htxadmin` account on `htxaldo-vault` (the sovereign local Vault VM on the Tokyo-WKLD stamp) is baked into `aldo/main.bicepparam`.

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx6XGJhkvQ1P6kx9MixBCJ16YyhJ4NKTAVKCorLcGJB htxadmin@aldo-vault
```

## Private key location

The matching private key was generated in the assistant's session workspace and is **not** committed to this repository. It lives at:

```
~/.copilot/session-state/<session-id>/files/htx-vault-ed25519
```

Retrieve it, place at `~/.ssh/htx-vault-ed25519`, `chmod 600`, and SSH in:

```powershell
ssh -i ~/.ssh/htx-vault-ed25519 htxadmin@<vault-vm-ip>
```

## Rotation

To rotate: generate a new ed25519 keypair, update `vaultAdminSshPublicKey` in `main.bicepparam`, redeploy (idempotent — will update the existing VM's `~/.ssh/authorized_keys`), then destroy the old private key.

## Production

Real Luna HSM deployment does not use SSH keys for admin — HSM ceremony operators authenticate via smart cards + PINs. This SSH key is demo scaffolding only.
