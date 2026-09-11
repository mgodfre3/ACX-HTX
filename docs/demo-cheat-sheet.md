# Demo Cheat Sheet — Burst to Azure Without Giving Up the Keys

Print this. Keep the laptop's font size big enough that the audience-facing monitor is readable.

**Full script:** [`demo-storyboard.md`](demo-storyboard.md). This is the command-only summary.
**Design of record:** [`burst-cvm-architecture.md`](burst-cvm-architecture.md).

## The one-sentence pitch

> Azure can start the machine. Only the edge can unlock the data.

## Presenter mode — recommended default

One command drives the whole demo. ENTER-gated between acts. You focus on the customer conversation; the script prints each act's on-stage line, waits for you to tap ENTER, then runs the underlying commands.

```powershell
# Full six-act run
.\scripts\demo-presenter.ps1

# Highlights only (Acts 1-5, no kill switches)
.\scripts\demo-presenter.ps1 -SkipToggles

# Timed dry run — no ENTER gates (1-second pauses instead). Use once before demo day.
.\scripts\demo-presenter.ps1 -Rehearse
```

Controls while running:
- **ENTER** — advance to the next act (or run the current act's commands)
- **S** — skip the current act (only meaningful for kill-switch acts)
- **Q** or **Ctrl-C** — quit cleanly (deallocates the CVM if we started it)

The presenter calls `demo-burst.ps1`, `demo-toggle-vault.ps1`, and `demo-toggle-azurekek.ps1` internally — those still exist and can be run standalone if you need to work off-script.

## Pre-demo checklist (T-30 min)

- [ ] VPN + tenant: `az account show --query tenantId -o tsv` returns `d1623670-9777-4399-aaf6-01d87b84ef1d`.
- [ ] Edge reachable: `ping 172.22.218.200` from the operator laptop.
- [ ] Edge services up:
      `ssh edge@172.22.218.200 'systemctl is-active vault edge-fetch'` → two `active`s.
- [ ] `curl -sS http://172.22.218.200:8444/healthz | jq` returns `status=ok`, `unwrap_service=reachable`.
- [ ] CVM stopped-deallocated and pre-warmed once (start-stop cycle to shake out first-boot slowness).
- [ ] Sample video seeded: `ssh edge@172.22.218.200 'ls /var/lib/edge-fetch/videos/'` shows at least `sample-video-01/`.
- [ ] Portal tabs open: RG `ACX-HTX`; KV → Keys blade; VM `acxhtx-vm` overview.
- [ ] `HTX_VAULT_INIT_PATH` env var set (or `~/.htx/vault-init.json` in place) — the Vault toggle needs the root token.
- [ ] Ran `demo-presenter.ps1 -Rehearse` at least once end-to-end.

## Manual mode — for off-script Q&A

If you need to drop out of the presenter and run individual commands, this is the raw command matrix aligned to the storyboard acts.

## Act 1 — What's here, what isn't (90 s)

```bash
# LEFT
ls /var/lib/edge-fetch/videos/                                 # -> sample-video-01/
cat /var/lib/edge-fetch/videos/sample-video-01/envelope.json | jq '.kek_ref, .wrap_algo'
vault read transit/keys/htx-kek | head -20                     # key is on-prem
```

```powershell
# RIGHT
az resource list -g ACX-HTX --query "[?type=='Microsoft.Storage/storageAccounts'].name" -o table
# -> only acxhtxfdystgaguuve6o (Foundry-internal). Say: "Zero customer bytes in Azure."
az keyvault key list --vault-name acxhtx-kv-aguuve6oq6by6 --query "[].{name:name,tags:tags}" -o table
# -> htx-kek + acxhtx-cvm-attestation-key (Purpose=cvm-os-attestation)
```

## Act 2 — Burst (60 s)

```powershell
# RIGHT
.\scripts\demo-burst.ps1 -Video sample-video-01 -Verbose
# Watch: az vm start -> polling -> VM running
```

## Act 3 — Attestation gate (90 s, mostly reading logs)

Left shell top pane (edge-fetch log) auto-tails. Look for:

```
release_granted video_id=sample-video-01 stub_indicator=STUB(imds,vmId=acxhtx-vm) arm_id=/subscriptions/.../acxhtx-vm
```

Then the orchestrator prints the CVM's structured events:

```
{"event":"attestation_built","subject":"/subscriptions/.../acxhtx-vm","mode":"stub-tl-imds"}
{"event":"envelope_fetched","envelope_bytes":...,"release_id":"..."}
{"event":"dek_unwrapped","dek_bytes":32}
{"event":"payload_decrypted","plaintext_bytes":...}
```

## Act 4 — Processing in CVM memory (60 s)

Orchestrator continues printing:

```
{"event":"processed","sha256":"...","bytes":...,"frames_scanned":...}
{"event":"result_encrypted","ciphertext_bytes":...}
{"event":"new_dek_wrapped"}
```

While it runs, click the portal `acxhtx-vm` → **Metrics → OS disk read bytes** — flat.

## Act 5 — Result home; CVM gone (45 s)

```
{"event":"result_submitted","result_id":"sample-video-01-<ts>","audit_id":"...","stored_path":"/var/lib/edge-fetch/processed/sample-video-01-.../envelope.json"}
{"event":"done"}
```

Left shell (edge audit) shows `store_accepted` matching the `audit_id`.

```bash
# LEFT
ls -la /var/lib/edge-fetch/processed/                         # -> the new result
```

Orchestrator auto-deallocates. Portal `acxhtx-vm` state → **Stopped (deallocated)** within ~30 s.

Optional theatrical move:

```powershell
az vm run-command invoke -g ACX-HTX -n acxhtx-vm --command-id RunPowerShellScript --scripts "Get-Volume"
# -> fails: "VM must be running". Say: "There is no live compute in Azure right now."
```

## Act 6a — Kill switch A: edge disables the data key (45 s)

```powershell
# RIGHT
.\scripts\demo-toggle-vault.ps1 -Disable
# -> red banner: EDGE VAULT: htx-kek DISABLED (min_decryption_version bumped)
.\scripts\demo-burst.ps1 -Video sample-video-01
# -> orchestrator prints attestation_built + envelope_fetched OK
# -> then: {"event":"fatal","error":"unwrap failed: 403 ..."}
```

Reset:

```powershell
.\scripts\demo-toggle-vault.ps1 -Enable
```

## Act 6b — Kill switch B: Azure disables the OS key (45 s)

```powershell
# RIGHT
.\scripts\demo-toggle-azurekek.ps1 -Disable
# -> red banner: AZURE KEY VAULT: acxhtx-cvm-attestation-key DISABLED
.\scripts\demo-burst.ps1 -Video sample-video-01
# -> CVM boot fails (or attestation preflight fails; either way, no burst)
```

Reset:

```powershell
.\scripts\demo-toggle-azurekek.ps1 -Enable
```

## Panic recovery

| Symptom | Command |
|---|---|
| edge-fetch dead | `ssh edge@172.22.218.200 'sudo systemctl restart edge-fetch'` |
| Vault sealed | `ssh edge@172.22.218.200 'vault operator unseal $(jq -r .unseal_keys_b64[0] ~/vault-init.json)'` |
| CVM stuck starting | `az vm redeploy -g ACX-HTX -n acxhtx-vm` (loses 2-3 min; abort demo) |
| Orchestrator hangs | Ctrl-C. `az vm deallocate -g ACX-HTX -n acxhtx-vm --no-wait`. `.\scripts\demo-burst.ps1 -Status`. Start over. |
| Toggle A stuck on | `.\scripts\demo-toggle-vault.ps1 -Enable`. If key was deleted with `-Delete`, re-seed videos. |
| Toggle B stuck on | `.\scripts\demo-toggle-azurekek.ps1 -Enable`. |

## Q&A anchors

Full list in [`demo-storyboard.md`](demo-storyboard.md#anchors-for-qa). The three most-likely:

- *"Isn't this just a normal Azure VM with encrypted disks?"* → OS disk uses Azure KEK. **Customer data key is on-prem Vault, not Azure Key Vault.** Different key, different vault, different purpose. Show both.
- *"Where does data live in Azure?"* → CVM RAM during a burst. Nowhere else. Portal metrics blade proves it.
- *"Can you show real SEV-SNP?"* → Not today. Quota is 0 in westus2. Stub is labeled STUB in every log line. Swap is a parameter change.
