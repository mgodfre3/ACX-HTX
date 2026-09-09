# Copilot Handoff — Deploy Sovereign Data Pipeline on ALDO Tokyo-WKLD

**Read this whole file before doing anything. It is the mission brief for a fresh Copilot session on an ALDO-connected workstation.**

---

## Who you are

You are GitHub Copilot working on the ALDO-connected workstation. Your job is to finish the on-prem side of the HTX Sovereign Hybrid demo — bootstrap the Vault, deploy the three sovereign apps (producer / unwrap-service / consumer), verify end-to-end, and update the docs.

Everything you need is already in the repo. Do not redesign anything. Do not switch tools. Do not "improve" the architecture. If something is unclear, ask the operator (Michael) rather than guessing.

## Environment context

- You are on a workstation that has **routed access to the Tokyo-WKLD ALDO Autonomous ARM plane**.
- The public Azure Cloud is **not** reachable for private-endpoint hostnames from this workstation. That is by design.
- The repo is at `C:\ACX-HTX` and tracks `master` on `https://github.com/mgodfre3/ACX-HTX`.
- Two Az contexts exist:
  - Public: subscription `AdaptiveCloudLab` (id `fbaf508b-cb61-4383-9cda-a42bfa0c7bc9`) in tenant `d1623670-9777-4399-aaf6-01d87b84ef1d`.
  - Autonomous: subscription `ACX-airgapped` (id `ef23bab2-5bd7-afa3-3013-d5116a941684`) in tenant `98b8267d-e97f-426e-8b3f-7956511fd63f`.
- Bicep CLI is installed at `%LOCALAPPDATA%\Programs\Bicep CLI\bicep.exe`.

## Ground truth — what is already deployed

**Azure side (public cloud, resource group `ACX-HTX` in West US 2, ExpressRoute-routed via `AC-Managment-WUS2`):**

- `acxhtx-kv-aguuve6oq6by6` — Key Vault Premium (HSM-backed) with key `htx-kek` (RSA-HSM 3072)
- `acxhtxstgaguuve6oq6by6` — Storage Account with CMK from `htx-kek`, public access disabled, container `sovereign-cold`
- `acxhtx-des` — Disk Encryption Set backing the VM
- `acxhtx-vm` — Windows Server 2022 Trusted Launch VM (`Standard_D2as_v5`), OS disk CMK-encrypted, no public IP
- `acxhtxacraguuve6o` — Premium ACR with CMK from `htx-kek`
- `acxhtx-foundry-hub` + `acxhtx-foundry-proj` — Azure AI Foundry hub + project
- Entra group `ACX_HTX_Contributor` (object id `e09d9488-62b2-4ca2-a4a2-232348662665`) with Key Vault Secrets User + Key Vault Crypto User on both vaults

**ALDO side (Autonomous plane, resource group `ACX-HTX-ALDO` in `Autonomous`):**

- `htxaldo-vault` — Ubuntu 24.04 VM, private IP `172.22.218.200`. Arc agent has phoned home. Vault is installed by cloud-init but **not initialized**. SSH pubkey is `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx6XGJhkvQ1P6kx9MixBCJ16YyhJ4NKTAVKCorLcGJB htxadmin@aldo-vault`. The matching private key was generated in the previous Copilot session workspace and is **not** on this workstation — you will need to either copy it over, get it from Michael, or regenerate + redeploy the VM.
- `htxaldo-foundry` — Windows Server 2025 VM with A100 DDA attempt. Last deploy hit `OutOfCapacity` on the A100 across all three nodes. Whether the VM instance actually landed or is stuck in Failed is unknown until you check.
- **No AKS-Arc** on this stamp. Pivoted away because A100 is not supported by Arc-AKS.

**Connected Registry:**

- `aldotokyowkld` created against `acxhtxacraguuve6o` from the Azure side.
- **Not yet installed** on the ALDO stamp.
- Activation settings JSON is in the previous session workspace (path in Michael's earlier note: `files/aldotokyowkld-settings.json`).

## The design intent (do not change)

The customer key story is materialized as three Python apps in `apps/`:

1. **`apps/producer/producer.py`** runs on the ALDO Foundry VM. Generates a fresh AES-256 DEK, encrypts a synthetic drone-telemetry payload, wraps the DEK using `htx-kek` via the on-prem Vault Transit engine, uploads the envelope (ciphertext + wrapped DEK + nonce + tag) to Azure Blob at `sovereign-encrypted/<producer>/<yyyy>/<mm>/<dd>/<uuid>.envelope.json`.
2. **`apps/unwrap-service/unwrap.py`** runs on the ALDO Vault VM as a sidecar to Vault. Flask app exposing `POST /unwrap`. Accepts a Microsoft Azure Attestation JWT and a wrapped DEK. Verifies the JWT against MAA's public JWKS. On success calls Vault Transit unwrap and returns the plaintext DEK.
3. **`apps/consumer/consumer.py`** runs on the Azure VM (`acxhtx-vm`). Fetches the envelope, requests an attestation token from the guest attestation endpoint, POSTs to the on-prem unwrap service, receives the DEK, decrypts payload in memory, processes.

The critical property is that the plaintext DEK exists only briefly in the on-prem Vault box and inside the consumer VM's TEE memory. It never touches Azure storage, control plane, or transit in plaintext form.

Read `apps/README.md` for the full sequence diagram and rationale. Read `docs/executive-summary.md` for the leadership narrative you must not undermine.

## Your task list (in order)

You must complete these in sequence. Do not skip ahead. Update the SQL todos table as you go (there is a `todos` table already; use `status='in_progress'` when you start each item and `status='done'` when finished).

### 1. Sanity check the environment

- `git -C C:\ACX-HTX pull` and verify latest commit matches origin/master
- `Get-AzContext` should show `ACX-airgapped` for the Autonomous plane
- Verify Bicep CLI works: `& "$env:LOCALAPPDATA\Programs\Bicep CLI\bicep.exe" --version`
- Verify network reach to `172.22.218.200:22` from this workstation: `Test-NetConnection -ComputerName 172.22.218.200 -Port 22`. If it fails, escalate to Michael — there is no point continuing.

### 2. Get the Vault VM SSH key sorted

Ask Michael for the private key from the previous session workspace (`~/.copilot/session-state/85358c88-.../files/htx-vault-ed25519`). Place it at `%USERPROFILE%\.ssh\htx-vault-ed25519` and set ACL:

```powershell
icacls "$env:USERPROFILE\.ssh\htx-vault-ed25519" /inheritance:r /grant:r "$($env:USERNAME):(F)"
```

If Michael cannot produce it, regenerate:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\htx-vault-ed25519" -N '""' -C 'htxadmin@aldo-vault'
Get-Content "$env:USERPROFILE\.ssh\htx-vault-ed25519.pub"
```

Then update `C:\ACX-HTX\aldo\main.bicepparam` line `param vaultAdminSshPublicKey = '...'` with the new pubkey, commit, push, and redeploy **only the Vault VM** (delete the Arc machine + VM instance for `htxaldo-vault` first, then run `.\aldo\scripts\deploy.ps1` — it should idempotently recreate).

Test SSH:

```powershell
ssh -i "$env:USERPROFILE\.ssh\htx-vault-ed25519" -o StrictHostKeyChecking=accept-new htxadmin@172.22.218.200 "uname -a"
```

### 3. Bootstrap Vault

Copy the init script over and run it:

```powershell
scp -i "$env:USERPROFILE\.ssh\htx-vault-ed25519" `
    C:\ACX-HTX\aldo\scripts\init-vault.sh `
    htxadmin@172.22.218.200:/tmp/

ssh -i "$env:USERPROFILE\.ssh\htx-vault-ed25519" htxadmin@172.22.218.200 @"
sudo apt-get update
sudo apt-get install -y unzip jq curl python3-venv
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main' | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y vault
sudo mkdir -p /etc/vault.d /opt/vault/data
sudo bash /tmp/init-vault.sh
"@
```

Retrieve `/root/vault-init.json` (root token + unseal key) and hand it to Michael. **Do not commit it to the repo. Do not paste it in chat if the session is shared.**

### 4. Create Vault app-role tokens with least privilege

On the Vault VM, create two policies and issue tokens:

- **Producer policy** (`transit/encrypt/htx-kek` only):
  ```bash
  vault policy write htx-producer - <<EOF
  path "transit/encrypt/htx-kek" { capabilities = ["update"] }
  EOF
  PRODUCER_TOKEN=$(vault token create -policy=htx-producer -period=720h -format=json | jq -r .auth.client_token)
  echo "Producer token: $PRODUCER_TOKEN"
  ```

- **Unwrap-service policy** (`transit/decrypt/htx-kek` only):
  ```bash
  vault policy write htx-unwrap - <<EOF
  path "transit/decrypt/htx-kek" { capabilities = ["update"] }
  EOF
  UNWRAP_TOKEN=$(vault token create -policy=htx-unwrap -period=720h -format=json | jq -r .auth.client_token)
  echo "Unwrap token: $UNWRAP_TOKEN"
  ```

Hand both tokens to Michael for storage in the ACX-HTX Contributor secret store (not in the repo). Note the token TTL is 720h (30 days) — set a calendar reminder to rotate.

### 5. Install the unwrap service on the Vault VM

```powershell
scp -i "$env:USERPROFILE\.ssh\htx-vault-ed25519" -r `
    C:\ACX-HTX\apps `
    htxadmin@172.22.218.200:/tmp/apps

ssh -i "$env:USERPROFILE\.ssh\htx-vault-ed25519" htxadmin@172.22.218.200 @"
sudo mkdir -p /opt/htx-unwrap
sudo cp -r /tmp/apps/unwrap-service/* /opt/htx-unwrap/
sudo cp -r /tmp/apps/shared /opt/htx-unwrap/../apps-shared
sudo python3 -m venv /opt/htx-unwrap/.venv
sudo /opt/htx-unwrap/.venv/bin/pip install -r /opt/htx-unwrap/requirements.txt
"@
```

Create a systemd unit at `/etc/systemd/system/htx-unwrap.service`:

```ini
[Unit]
Description=HTX Sovereign Unwrap Service
After=network-online.target vault.service
Requires=vault.service

[Service]
Type=simple
User=vault
Group=vault
Environment=HTX_VAULT_ADDR=http://127.0.0.1:8200
Environment=HTX_VAULT_TOKEN=REPLACE_WITH_UNWRAP_TOKEN
Environment=HTX_KEK_NAME=htx-kek
Environment=HTX_LISTEN_ADDR=0.0.0.0:8443
Environment=HTX_POLICY_PATH=/opt/htx-unwrap/policy.yaml
Environment=HTX_DEMO_MODE=1
ExecStart=/opt/htx-unwrap/.venv/bin/python /opt/htx-unwrap/unwrap.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Enable + start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now htx-unwrap.service
sudo systemctl status htx-unwrap.service
curl http://127.0.0.1:8443/health
```

Open the firewall for port 8443 from the Azure-side VNet address range only (do not blanket-open).

### 6. Diagnose the Foundry VM

Determine whether `htxaldo-foundry` has an actual VirtualMachineInstance under it, or only the Arc machine parent projection:

```powershell
$foundryVmiPath = '/subscriptions/ef23bab2-5bd7-afa3-3013-d5116a941684/resourceGroups/ACX-HTX-ALDO/providers/Microsoft.HybridCompute/machines/htxaldo-foundry/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default'
try {
    $vmi = Get-AzResource -ResourceId $foundryVmiPath -ApiVersion '2025-02-01-preview' -ExpandProperties
    $vmi.Properties | ConvertTo-Json -Depth 5
} catch {
    Write-Host "Foundry VMI does not exist yet - will need to redeploy: $_"
}
```

If the VMI is missing or in a Failed state, work with Michael to either:
- Free an A100 on one of the Tokyo hosts (see the earlier `Get-VMHostAssignableDevice` output showing two A100s), OR
- Redeploy the Foundry VM with `foundryGpuName = ''` (CPU-only Foundry Local) so the demo can proceed

Do not spend more than one round of diagnosis on the GPU. Producer runs fine CPU-only — the demo does not require GPU inference for the sovereign key story.

### 7. Install the producer on the Foundry VM

Once the Foundry VM is reachable (via Bastion, RDP, or a jumpbox):

```powershell
# on htxaldo-foundry
mkdir C:\HTX\producer -Force
# Copy apps/producer + apps/shared over via RDP clipboard or scp from a Linux jumpbox
python -m venv C:\HTX\producer\.venv
C:\HTX\producer\.venv\Scripts\pip install -r C:\HTX\producer\requirements.txt
```

Set env vars in a Windows service or scheduled task — do not put the Vault token in plaintext env files that live in the repo. Use `sc.exe` or the Task Scheduler XML to inject.

Run once manually to test:

```powershell
$env:HTX_VAULT_ADDR      = 'http://172.22.218.200:8200'
$env:HTX_VAULT_TOKEN     = '<PRODUCER_TOKEN from step 4>'
$env:HTX_KEK_NAME        = 'htx-kek'
$env:HTX_STORAGE_ACCOUNT = 'acxhtxstgaguuve6oq6by6'
$env:HTX_CONTAINER       = 'sovereign-encrypted'
$env:HTX_PRODUCER_ID     = 'htxaldo-foundry'
az login  # need creds that can write to the storage account
C:\HTX\producer\.venv\Scripts\python C:\HTX\producer\producer.py
```

The container `sovereign-encrypted` may not exist yet — create it via portal or `az storage container create -n sovereign-encrypted --account-name acxhtxstgaguuve6oq6by6 --auth-mode login`.

Verify a blob lands. Note the blob path — you will need it for step 8.

### 8. Install the consumer on `acxhtx-vm`

Access `acxhtx-vm` (Azure side, RG `ACX-HTX`). There is no public IP — use serial console, Bastion in a peered VNet, or run `Invoke-AzVMRunCommand` to drop the app.

```powershell
mkdir C:\HTX\consumer -Force
# Get apps/consumer + apps/shared onto the VM
python -m venv C:\HTX\consumer\.venv
C:\HTX\consumer\.venv\Scripts\pip install -r C:\HTX\consumer\requirements.txt

$env:HTX_STORAGE_ACCOUNT   = 'acxhtxstgaguuve6oq6by6'
$env:HTX_CONTAINER         = 'sovereign-encrypted'
$env:HTX_BLOB_NAME         = '<blob path from step 7>'
$env:HTX_UNWRAP_URL        = 'http://172.22.218.200:8443/unwrap'
$env:HTX_UNWRAP_VERIFY_TLS = '0'  # demo only

C:\HTX\consumer\.venv\Scripts\python C:\HTX\consumer\consumer.py
```

Expected output: fetches envelope, gets attestation token from IMDS, POSTs to unwrap service, receives DEK, decrypts, logs the drone-telemetry payload.

If the consumer's IMDS attested-document returns a shape that the unwrap service does not accept, that is expected on Trusted Launch — the JWT is not a real MAA token. Set `HTX_DEMO_MODE=1` on the unwrap service so it logs the mismatch and continues. **Never set demo mode in production.** Log this discrepancy in `apps/README.md` under a "Known Limitations" section.

### 9. Verify the money shot end-to-end

- Run producer to upload one envelope
- Run consumer against that blob
- Show the plaintext payload landing in the consumer log
- On the Vault VM, tail `journalctl -u htx-unwrap.service` and show the attestation request being logged
- Toggle the KEK enabled state (`az keyvault key set-attributes ... --enabled false` from the Azure side) and re-run the consumer — expect the on-prem unwrap step to succeed at Vault level (Vault holds its own local KEK independently). This is the point where the demo diverges from the Azure-only revoke story: **the on-prem key is truly independent**. Add a note to the cheat sheet explaining this: Azure revoke locks Azure storage, but the on-prem side keeps working because it holds its own KEK. That is the sovereignty story.

### 10. Document what changed

Update these files with what you actually observed:

- `docs/deployment-status.md` — add an "On-prem side" section with the Vault VM IP, unwrap service endpoint, producer/consumer install locations
- `apps/README.md` — Known Limitations section for the Trusted Launch attestation shape
- `docs/demo-cheat-sheet.md` — add an Act 6 for the end-to-end pipeline demo (fetching a blob, attestation gate, decryption in TEE)
- Commit with a clear message. Push to master.

### 11. Handoff back to Michael

At the end of the session:

- Update the todos table: set `aldo-cluster-recover`, `vault-vm-access`, `kms-integration-approach` to `done` if you completed each item; otherwise `blocked` with the reason in the description
- Print a short summary of what was deployed, what tokens were minted (identifiers only, not values), what did not work, and what Michael needs to do manually
- Do not call `task_complete` if any of the three key milestones (Vault initialized, unwrap service running, consumer decrypted a payload) failed

## Rules of engagement

- **Ask Michael before destroying anything.** If the failed Foundry VM has a working Arc machine, do not delete it without checking — there may be state you need.
- **Do not commit secrets.** Ever. Not in commit messages, not in code, not in docs. The Vault root token and app-role tokens go to Michael and to a secret store — not to git.
- **Prefer minimal changes.** If a script needs one line changed, change one line. Do not "refactor while you're in there."
- **When in doubt, stop and ask.** Michael is available. Assuming is more expensive than asking.
- **Do not switch tools.** The stack is Bicep + Python + Az PowerShell + `az` CLI + SSH. Do not introduce Terraform, Docker, Kubernetes, or "just this one shell script in bash on Windows."
- **Update the SQL todos table religiously.** It is how the next session picks up where you leave off.
- **Bias toward completing acts 1-8. Acts 9-10 (demo + docs) can defer.** A running pipeline is worth more than a beautifully documented one.

## Files you will edit

- `aldo/main.bicepparam` (only if regenerating the SSH key)
- `apps/README.md` (Known Limitations section)
- `docs/deployment-status.md` (On-prem side section)
- `docs/demo-cheat-sheet.md` (Act 6)
- `todos` SQL table

## Files you must NOT touch

- Anything in `infra/` — the Azure-side stack is deployed and stable
- `docs/executive-summary.md` — this is the leadership narrative; do not weaken it
- `docs/1130-brief.md` — historical artifact from Michael's leadership meeting
- The `README.md` at the repo root

---

**When you finish, print:**

1. Vault VM SSH status (working / needs Michael)
2. Vault init status (initialized / not / who has the root token)
3. Unwrap service status (running / not, health endpoint response)
4. Producer install status (running / not, last blob uploaded)
5. Consumer install status (running / not, last decrypt result)
6. What you updated in docs
7. Any blockers requiring Michael's manual intervention

Then hand back to Michael. Do not close out on your own if anything critical is unfinished.
