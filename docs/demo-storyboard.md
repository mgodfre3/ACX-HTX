# Demo Storyboard — Burst to Azure Without Giving Up the Keys

**Audience:** HTX leadership (via Adam).
**Duration:** ~6 minutes end-to-end, plus 2-3 minutes of Q&A buffer.
**Design of record:** [`burst-cvm-architecture.md`](burst-cvm-architecture.md).
**Companion pages:** the on-stage command matrix is in [`demo-cheat-sheet.md`](demo-cheat-sheet.md); the executive summary that opens the deck is in [`executive-summary.md`](executive-summary.md).

## The one-sentence pitch

> Azure can start the machine. Only the edge can unlock the data.

## Setup on the machine

Two terminal windows and one browser, side by side on a single monitor.

| Window | Content |
|---|---|
| **Left shell** | SSH into ALDO Vault VM at `172.22.218.200`. Prompt: `edge $`. Runs the edge-fetch server logs (`journalctl -u edge-fetch -f`) in split-tmux top pane, and interactive Vault + curl commands in the bottom pane. |
| **Right shell** | Local PowerShell logged in as the operator with `Az` + `az` CLI. Runs `demo-burst.ps1`, kill-switch scripts, and `az vm show` commands. |
| **Browser** | Azure portal, three tabs pre-opened: (1) RG `ACX-HTX` overview; (2) Key Vault `acxhtx-kv-aguuve6oq6by6` → Keys blade; (3) VM `acxhtx-vm` → Overview. |

Pre-warm the CVM by starting and stopping it once so first-boot delays don't show up on stage.

---

## Act 1 — What's at the edge, and what isn't in Azure (90 s)

**Objective:** Establish the two-key model before anything moves.

| Step | Action | On-stage line |
|---|---|---|
| 1 | Left shell: `ls /var/lib/edge-fetch/videos/`. Shows one directory `sample-video-01/` containing `envelope.json`. | *"This is the customer's data. It's encrypted. It lives here, on their edge."* |
| 2 | Left shell: `cat /var/lib/edge-fetch/videos/sample-video-01/envelope.json \| jq '.kek_ref, .wrap_algo'`. Shows `"transit/keys/htx-kek"` and `"vault-transit-aes256gcm96"` (Vault Transit is symmetric — that's the expected label). | *"The key that can unlock it lives in a Vault instance right next to it. This key has never been in Azure. It never will be."* |
| 3 | Left shell: `vault read transit/keys/htx-kek \| head -20`. Confirms the key exists locally. | *"Same customer, same data center, same physical enclosure."* |
| 4 | Browser tab 1 (RG `ACX-HTX`): scroll. | *"Now let's look at what's in Azure."* |
| 5 | Point at resource list: Key Vault, a VM, the Foundry hub. **No storage account visible.** (Foundry-internal `acxhtxfdystgaguuve6o` may show — call it out: *"That storage belongs to Azure AI Foundry's workspace. It contains no customer data. Zero customer bytes are stored in Azure."*) | *"There is nothing here that says 'customer data'."* |
| 6 | Browser tab 2 (Key Vault → Keys): show the two keys. Click into `acxhtx-cvm-attestation-key`, show tag `Purpose: cvm-os-attestation`, key ops `wrapKey, unwrapKey` only. | *"This is Azure's key. It gates whether the CVM can boot. It cannot decrypt customer data. Different key, different vault instance, different purpose."* |
| 7 | Click into `htx-kek` in the same portal blade. Show the **Tags panel** first — three explicit tags: `Purpose=osdisk-and-acr-cmk`, `Not-Used-For=customer-application-data`, `Customer-Data-Key-Location=on-prem Vault Transit (172.22.218.200)`. Then show the key ops. | *"This key shares a name with the on-prem data key by historical accident — you'll notice we've tagged it explicitly to prevent that confusion. Its actual job is encrypting the CVM's own OS disk and the container registry. The tag `Customer-Data-Key-Location` points reviewers at the on-prem Vault we just looked at. Azure does not have a copy."* |

---

## Act 2 — The customer bursts. A CVM materializes (60 s)

**Objective:** Trigger the burst from the edge, show Azure responding but not receiving data.

| Step | Action | On-stage line |
|---|---|---|
| 1 | Right shell: `.\scripts\demo-burst.ps1 -Video sample-video-01 -Verbose`. | *"The customer's on-prem orchestrator is deciding to consume Azure burst compute. Azure is not initiating this."* |
| 2 | Watch orchestrator output: `[edge]` waits for CVM ready; `[azure]` shows `az vm start` returning; poll loop reports `PowerState: VM running` after ~30-45 s. | (Silent while it runs. Let the audience read the log.) |
| 3 | Browser tab 3 (`acxhtx-vm` overview): refresh; show state → Running. | *"The machine is up. Nothing has moved yet."* |
| 4 | Right shell: `az vm show -g ACX-HTX -n acxhtx-vm --query "identity" -o json`. Shows the system-assigned MI and empty user-assigned. | *"This VM has zero permissions on any storage account. We deleted that surface area yesterday."* |

---

## Act 3 — The CVM proves who it is. The edge decides whether to talk to it (90 s)

**Objective:** Show that data movement is gated by the edge, not by Azure.

| Step | Action | On-stage line |
|---|---|---|
| 1 | The orchestrator has already triggered the burst-consumer on the CVM via a scheduled task. Left shell top pane (edge-fetch server log) shows the incoming request. | *"The CVM inside Azure just asked the edge for the video."* |
| 2 | Log line: `POST /video/sample-video-01 attestation_mode=STUB source_arm_id=/subscriptions/.../acxhtx-vm decision=ALLOW`. | *"The edge validated the attestation evidence. In production this is a real SEV-SNP measurement. Today, per your OK, we are running the stub mode — that log line clearly says STUB."* |
| 3 | Next log line: `RELEASE wrapped_dek=<24 chars> envelope_bytes=<size> to=<CVM ARM ID>`. | *"The edge released a wrapped data key and the encrypted video envelope. This is the only moment when encrypted customer data crosses onto Azure infrastructure."* |
| 4 | On the CVM side (visible via a small telemetry endpoint or a tail of the burst-consumer log the orchestrator prints back): `unwrap_ok=true decrypt_ok=true bytes_in_memory=<size>`. | *"The CVM asked the edge to unwrap the data key. The edge did. The video is now plaintext, in CVM memory only. Nothing on disk in Azure."* |

---

## Act 4 — Processing happens in CVM memory. Nothing lands in Azure (60 s)

**Objective:** Show computation happening with no persistent Azure state.

| Step | Action | On-stage line |
|---|---|---|
| 1 | Burst-consumer log: `frames_scanned=<n> stream_sha256=<hex[:12]>… thumbnail_generated=1`. | *"The CVM is running the customer's workload against the plaintext video. We're doing a trivial frame count and hash to keep the demo short — in production this is where their real processing happens."* |
| 2 | Browser tab 3 (`acxhtx-vm`): show OS disk usage graph — flat. Show metrics — no Storage endpoint hit count. | *"Zero writes to any storage account. Zero writes to the OS disk beyond the OS's own logging."* |
| 3 | Burst-consumer log: `reencrypt_ok=true new_wrapped_dek=<hash[:8]>… payload_bytes=<size>`. | *"The result gets wrapped with a brand-new data key, also wrapped by the edge Vault. Same custody story on the return path."* |

---

## Act 5 — Result goes home. CVM goes away (45 s)

**Objective:** Show data returning to the edge and Azure being emptied.

| Step | Action | On-stage line |
|---|---|---|
| 1 | Left shell: edge-fetch log shows `POST /processed/sample-video-01 attestation_ok=true bytes=<size> stored=/var/lib/edge-fetch/processed/…`. | *"Result is home."* |
| 2 | Left shell: `ls -la /var/lib/edge-fetch/processed/`. Shows the returned envelope. | *"On the edge. Encrypted. Wrapped with a data key that never left the edge."* |
| 3 | Right shell: orchestrator prints `[azure] deallocating CVM…` and confirms `PowerState: VM deallocated`. Browser tab 3: refresh, state → Stopped (deallocated). | *"Azure compute was in the loop for approximately 90 seconds. The bill just stopped."* |
| 4 | Right shell: `az vm run-command invoke -g ACX-HTX -n acxhtx-vm --command-id RunPowerShellScript --scripts "Get-Volume"` (attempt) — fails with `VM must be running`. | *"There is no live customer data in Azure right now. There is no live compute in Azure right now."* |

---

## Act 6 — The two kill switches (90 s)

**Objective:** The proof-of-sovereignty moment. Two toggles, two provable properties.

### Toggle A — Edge disables the data key. Azure keeps running. Data becomes unreadable.

| Step | Action | On-stage line |
|---|---|---|
| 1 | Left shell: `.\demo-toggle-vault.ps1 -Disable`. Banner prints `!!! EDGE VAULT: htx-kek DISABLED (min_decryption_version bumped) !!!`. | *"The customer is now denying Azure the ability to decrypt anything, from the edge. No Azure API was called."* |
| 2 | Right shell: `.\scripts\demo-burst.ps1 -Video sample-video-02`. CVM starts. Attestation passes. Envelope fetch succeeds. **Unwrap call to edge Vault returns 403.** | *"The CVM is running. The CVM is attested. The CVM just cannot decrypt anything. The video is inert bytes."* |
| 3 | Burst-consumer log: `unwrap_call_failed status=403 reason=key-min-version-not-met`. Orchestrator aborts, deallocates CVM. | *"That's the sovereignty story. Not a promise from Microsoft. A property of the wiring."* |
| 4 | Left shell: `.\demo-toggle-vault.ps1 -Enable`. Banner prints `--- EDGE VAULT: htx-kek RESTORED ---`. | (Reset for next audience.) |

### Toggle B — Azure disables the OS attestation key. CVM cannot start.

| Step | Action | On-stage line |
|---|---|---|
| 1 | Right shell: `.\demo-toggle-azurekek.ps1 -Disable`. Banner: `!!! AZURE KEY VAULT: acxhtx-cvm-attestation-key DISABLED !!!`. | *"Now Microsoft is denying startup. Different toggle. Different outcome."* |
| 2 | Right shell: `.\scripts\demo-burst.ps1 -Video sample-video-01`. **Orchestrator preflights `az keyvault key encrypt` against the disabled key, gets a 403, and aborts before even calling `az vm start`.** Banner: `AZURE KV OS ATTESTATION GATE: DENIED`. On stage: this is exactly what a real SEV-SNP Confidential DES would do at boot time — same failure, one code level earlier. | *"Azure can stop the compute. That's the extent of Azure's power in this design."* |
| 3 | Right shell: `.\demo-toggle-azurekek.ps1 -Enable`. Banner: `--- AZURE KEY VAULT: acxhtx-cvm-attestation-key RESTORED ---`. | (Reset.) |

---

## Anchors for Q&A

Expect these questions. Have the answer ready.

| Question | Answer anchor |
|---|---|
| *"Isn't this just a normal Azure VM with encrypted volumes?"* | No — the OS disk uses the Azure KEK, but customer data is protected by the on-prem Vault Transit key which Azure has no route to. Prove it: show `acxhtx-cvm-attestation-key` scope vs the edge Vault key. |
| *"Where does data actually live in Azure?"* | Only in CVM RAM during a burst. Never on disk. Show OS disk usage flat during Act 4. |
| *"What if the CVM is compromised?"* | The edge validates attestation before releasing the key. A compromised CVM fails attestation and gets nothing. Show the STUB banner and explain what SEV-SNP measurement replaces it in production. |
| *"Why not use Azure Key Vault for the data key too?"* | Because then Microsoft could be compelled to release it. Customer requirement is that only the customer can release the key. |
| *"How is this different from CVMs at other cloud providers?"* | The novelty is not the CVM — it's the edge-gated release. Any CSP could host the compute; only the customer can host the release policy. |
| *"Can you demo real SEV-SNP?"* | Not today — quota in westus2 is 0. Request is filed. TL stub demonstrates the same wiring; SEV-SNP swap is a param change. |

---

## Failure modes to rehearse

- **Edge-fetch server crash mid-demo:** `sudo systemctl restart edge-fetch`, then re-run. Loss of demo time ~15 s. Practiced recovery.
- **CVM stuck starting:** `az vm redeploy -g ACX-HTX -n acxhtx-vm`. Loss ~3 min — abort demo, reschedule.
- **Vault sealed unexpectedly:** unseal from `vault-init.json` (protected). Loss ~30 s. Have the unseal key value in a paper envelope next to the laptop.
- **ExpressRoute path down:** left shell will see connection refused. Loss = show-stopping. Confirm connectivity 10 minutes before demo start.
