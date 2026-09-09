# HTX Sovereign Hybrid — Demo Cheat Sheet

> **Direction change (2026-09-09):** This cheat sheet describes the **prior** blob-based demo flow. The current design of record is the edge-controlled burst-CVM flow in [`burst-cvm-architecture.md`](burst-cvm-architecture.md). This cheat sheet needs to be rewritten around the two-key toggle (edge Vault ⇒ CVM cannot decrypt; Azure Key Vault OS-attestation key ⇒ CVM cannot start) once Adam confirms scope after 2026-09-09 evening customer meeting. **Do not use as-is on stage.**

**Print this. Keep it open in a side monitor. Every command tested against the live stack.**

---

## The one-sentence pitch (memorize)

> HTX keeps its keys, sensitive data, and inference on-prem. Azure adds scale for storage, training, and non-sensitive processing. **One customer key protects everything at rest. Revoke it once — everything locks.**

---

## Before the demo (T-30 min)

### 1. Two shells ready

```powershell
# Shell A: Public Azure Cloud (ACX-HTX)
Connect-AzAccount -Tenant d1623670-9777-4399-aaf6-01d87b84ef1d
Set-AzContext -Subscription 'AdaptiveCloudLab'

# Shell B: ALDO Autonomous plane (Tokyo-WKLD)
# Open a separate PS window
Connect-AzAccount
Set-AzContext -Subscription 'ef23bab2-5bd7-afa3-3013-d5116a941684'
```

### 2. Browser tabs to pre-open

| # | Tab | URL |
|---|---|---|
| 1 | ACX-HTX resource group | `portal.azure.com` → RG `ACX-HTX` |
| 2 | Key Vault `acxhtx-kv-aguuve6oq6by6` → **Keys** blade | showing `htx-kek` |
| 3 | Storage Account `acxhtxstgaguuve6oq6by6` → **Encryption** blade | shows CMK reference |
| 4 | ACR `acxhtxacraguuve6o` → **Encryption** blade | shows CMK reference |
| 5 | GitHub repo | `github.com/mgodfre3/ACX-HTX` — open `docs/executive-summary.md` for the diagram |
| 6 | ALDO portal / RG `ACX-HTX-ALDO` | (only if ALDO stack finished deploying) |

### 3. Sanity checks

```powershell
# Shell A: All 3 vaults happy?
az resource list -g ACX-HTX --resource-type Microsoft.KeyVault/vaults --query "[].name" -o tsv

# VM running?
az vm get-instance-view -g ACX-HTX -n acxhtx-vm --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv

# Contributor group visible?
az ad group show --group ACX_HTX_Contributor --query displayName -o tsv
```

If any of those return blank → **stop and fix before demoing**.

---

## The story arc (5 acts, 12 minutes total)

### Act 1 — "Here's the boundary" (1 min)

Open GitHub `docs/executive-summary.md`. Show the mermaid diagram.

**Say:** "This is one architecture, one boundary. Left side is HTX's data center. Right side is Azure. The line between them is a cryptographic boundary — not a network boundary. It exists because HTX holds the keys, not because the data doesn't move."

### Act 2 — "The customer holds the key" (2 min)

**Show the sovereign vault:**

```powershell
# Shell A - list the KEK
az keyvault key show --vault-name acxhtx-kv-aguuve6oq6by6 --name htx-kek `
  --query "{name:key.kid, kty:key.kty, ops:key.keyOps, hsm:managed}" -o json
```

Point at the output:
- `kty: RSA-HSM` — hardware-backed
- `hsm: true` — Microsoft never sees the private half
- Vault has `enableRbacAuthorization: true`, `enablePurgeProtection: true`, `publicNetworkAccess: Disabled`

**Say:** "This is `htx-kek`. It lives in an HSM inside Azure Key Vault Premium. Microsoft's control plane can't extract it. In production, this KEK is BYOK'd from the customer's Luna HSM — the demo uses AKV Premium as a stand-in."

### Act 3 — "One key protects everything" (3 min)

**Show the three surfaces the KEK protects:**

```powershell
# 1. Storage account CMK
az storage account show -n acxhtxstgaguuve6oq6by6 -g ACX-HTX `
  --query "{keySource:encryption.keySource, keyName:encryption.keyVaultProperties.keyName, publicAccess:publicNetworkAccess}" -o json

# 2. Container registry CMK
az acr show --name acxhtxacraguuve6o `
  --query "{sku:sku.name, keyId:encryption.keyVaultProperties.keyIdentifier, status:encryption.status}" -o json

# 3. VM OS disk CMK (via Disk Encryption Set)
$diskId = az vm show -g ACX-HTX -n acxhtx-vm --query "storageProfile.osDisk.managedDisk.id" -o tsv
az disk show --ids $diskId `
  --query "{type:encryption.type, desId:encryption.diskEncryptionSetId}" -o json
```

**Say:** "Three CMK relationships. All three point at the same `htx-kek`. Storage. Container registry. VM disks. If HTX revokes this key, Microsoft's storage service can no longer wrap the data-encryption keys and every byte becomes unreadable ciphertext. Simultaneously."

### Act 4 — "The customer keeps sensitive processing on-prem" (3 min)

Switch to Shell B / ALDO portal.

**Say:** "On the on-prem side we have HTX's Azure Local Disconnected Operations stamp — Tokyo-WKLD in this demo. A HashiCorp Vault holds the local mirror of `htx-kek`. And a Windows Server 2025 VM with A100 GPU passthrough runs Foundry Local."

Show:
```powershell
# Shell B - ALDO VMs
az resource list -g ACX-HTX-ALDO --resource-type Microsoft.AzureStackHCI/virtualMachineInstances --query "[].{name:name}" -o table
```

**Explain the split:**
- **Local Foundry Local instance** runs Phi-4 mini + our custom HTX antenna detector
- **Model came from Azure Foundry** — trained in the cloud on non-sensitive imagery, published to the CMK-encrypted ACR
- **Pulled to on-prem** via ACR Connected Registry mirror — never in plaintext
- **Sensitive inference stays local** — customer drone footage never leaves the boundary
- **Model cache is BitLocker-encrypted** with a DEK from the local Vault

### Act 5 — "The revoke button" (3 min)

**The money shot.** This is why leadership is in the room.

```powershell
# Show the KEK is enabled and being used
az keyvault key show --vault-name acxhtx-kv-aguuve6oq6by6 --name htx-kek --query "attributes.enabled"
# → true

# Try to read encrypted blob — works today (through trusted-services bypass)
az storage blob list --account-name acxhtxstgaguuve6oq6by6 --container sovereign-cold --auth-mode login --query "[].name" -o tsv
```

**Say:** "Now watch this."

```powershell
# THE REVOKE
az keyvault key set-attributes --vault-name acxhtx-kv-aguuve6oq6by6 --name htx-kek --enabled false

# Wait ~30 seconds for storage to notice the revocation
Start-Sleep 30

# Try to read the same blob
az storage blob list --account-name acxhtxstgaguuve6oq6by6 --container sovereign-cold --auth-mode login
# → Storage returns 403 KeyVaultAuthenticationFailure or similar
```

**Say:** "The blobs are still there. The ciphertext hasn't changed. But Storage can no longer request the wrap operation from Key Vault, so it can no longer decrypt the data-encryption keys, so nobody — including Microsoft — can read the plaintext. The same thing just happened to the VM disks and the ACR images. One command locked everything at rest."

**Then restore it:**

```powershell
az keyvault key set-attributes --vault-name acxhtx-kv-aguuve6oq6by6 --name htx-kek --enabled true
Start-Sleep 30
az storage blob list --account-name acxhtxstgaguuve6oq6by6 --container sovereign-cold --auth-mode login
# → works again
```

**Say:** "And re-enabling brings everything back. This is what 'customer holds the keys' means in Azure. Not a policy statement — a cryptographic property."

---

## Common questions & 15-second answers

| Question | Answer |
|---|---|
| **"Why not Confidential VMs everywhere?"** | SEV-SNP capacity isn't available on this subscription's hardware in any US region today. The CMK + Trusted Launch VM is the closest possible today; SEV-SNP swaps in with a config flag when capacity returns. |
| **"Why not Arc-AKS on the edge?"** | A100 GPUs aren't supported on Arc-AKS (T4/A2 only). Foundry Local on Windows Server 2025 with DDA passthrough gets us the A100 hardware working with the same customer-key story. |
| **"How do we know Microsoft can't read the data?"** | The CMK design: every touch of the DEK requires a wrap-op from Key Vault. Revoke the KEK → wrap fails → DEK stays encrypted → data stays ciphertext. Just showed this live. |
| **"What's the actual key custody?"** | Demo uses AKV Premium HSM (public preview: FIPS 140-2 L3, cert-managed). Production replaces both sides with Luna HSMs — customer holds smart cards, does BYOK ceremony, key material never leaves the HSMs. |
| **"What's the timeline?"** | Demo running now. Pilot with pilot HSMs: months. Full production with dual-Luna + real BYOK ceremony: years — planned and budgeted. This isn't a slideware promise. |
| **"What about training data leakage?"** | Training in Azure Foundry uses the same CMK'd storage. Trained model pushed to CMK'd ACR. The customer key protects every stage — Microsoft's control-plane only ever handles ciphertext. |
| **"Contributor group access?"** | `ACX_HTX_Contributor` Entra group has `Key Vault Crypto User` on both vaults — get/list keys, wrap/unwrap. Cannot delete or purge. |
| **"What if the ExpressRoute drops?"** | Storage + ACR + Key Vault are all reached via private endpoints on `AC-Managment-WUS2` which peers to `AC-HubGW-EUS` and routes over ExpressRoute. If ER drops, the Azure side is unreachable from on-prem — but the on-prem Foundry Local + Vault + BitLocker-encrypted cache keep working, offline. That's disconnected-operations design. |
| **"Can you show the on-prem key custody?"** | Yes — see aldo/scripts/init-vault.sh. Vault Transit engine holds the local `htx-kek` mirror. Same revoke story, on-prem side. |

---

## Fallback if something breaks live

**Something in Azure won't respond?** → Point to `docs/executive-summary.md` + `docs/deployment-status.md` on GitHub. Everything visible in the portal (KV, storage, ACR, VM) has the CMK relationship documented there.

**ALDO side isn't up?** → Say: "The on-prem stack is templated and mid-deploy. Same customer-key story. Ping me and I'll follow up." Then move on.

**Revoke demo doesn't propagate in time?** → Have a screen recording ready:
```powershell
# Record this beforehand as a safety net:
# Start-VMTraceRecording or just use OBS/Xbox Game Bar
```

**Portal is slow?** → CLI everything. It's faster and looks more expert anyway.

---

## Reset script (run after demo)

```powershell
# Re-enable the KEK if you left it disabled
az keyvault key set-attributes --vault-name acxhtx-kv-aguuve6oq6by6 --name htx-kek --enabled true

# Verify everything is happy again
az storage blob list --account-name acxhtxstgaguuve6oq6by6 --container sovereign-cold --auth-mode login --query "[].name" -o tsv
az disk show --ids (az vm show -g ACX-HTX -n acxhtx-vm --query "storageProfile.osDisk.managedDisk.id" -o tsv) --query provisioningState -o tsv
```

---

## Talking points that always land

- **"Cryptographic boundary, not a geographic one."**
- **"Microsoft can't read the data by construction, not by policy."**
- **"One key. Three surfaces. One revoke."**
- **"The path to Luna production is a config flag, not an architecture change."**
- **"This isn't slideware. Everything you just saw is a git commit away."**

---

*Full docs: https://github.com/mgodfre3/ACX-HTX*
*Exec summary (with diagram): `docs/executive-summary.md`*
*This cheat sheet: `docs/demo-cheat-sheet.md`*
