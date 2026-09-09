# Burst CVM Architecture — Edge-Controlled Confidential Data Flow

**Status:** Design of record — supersedes the prior "encrypted-blob-in-Azure" flow described in `docs/executive-summary.md` and `docs/demo-cheat-sheet.md`.
**Source:** Meeting with Adam (2026-09-09) — see meeting notes checked into the workspace history.
**Owner:** Michael Godfrey.

---

## What we are showing

The customer does not want data stored in Azure. They will accept **Azure as temporary burst compute only**, provided that:

1. The application data key **never leaves the on-premises Vault**.
2. Data lives in Azure only for the lifetime of a single Confidential VM run.
3. Azure Key Vault plays no role in protecting customer data — its role is limited to attestation-gating the CVM's OS startup.
4. No customer data is written to Azure Storage — ever.

This is a **burst-capacity story**: customer sovereign compute stays on the edge; when they need more, they consume attested CVM cycles in Azure temporarily, without giving Azure custody of their data or their key.

## Non-goals (explicitly out of scope for this demo)

- Long-term data storage in Azure (no `sovereign-cold`, no `sovereign-encrypted` blob-based data flow).
- Any application-layer BYOK ceremony against Azure Key Vault for the customer data key.
- Showing what the application actually computes. The demo is about **data movement and protection**, not what the workload does. Use a **generic video feed** as the example payload — no drone framing, no operational use case exposed.

## Two customer-controlled keys, two different jobs

This is the point that has to survive Q&A. Every reviewer will conflate the two if you let them.

| Key | Where it lives | What it protects | Who releases it | Kill-switch effect |
|---|---|---|---|---|
| **OS / attestation key** | Azure Key Vault (`acxhtx-kv-aguuve6oq6by6/htx-kek` today; may become a separate "dummy" key for absolute clarity) | The CVM's own boot / OS-disk crypto — never customer data | Azure, gated on CVM platform attestation | CVM cannot start. Application never runs. No data exposure. |
| **Application data key** | On-premises HashiCorp Vault Transit engine (`172.22.218.200`, key `htx-kek`) | The customer's video-feed payload | **The edge**, only after independently validating CVM attestation evidence | Application inside the running CVM immediately loses ability to decrypt the fetched payload. |

The demo's core narrative sentence:

> "Azure can start the machine. Only the edge can unlock the data."

## End-to-end flow

```mermaid
sequenceDiagram
    autonumber
    participant Edge as ALDO Edge<br/>(Vault + video store + orchestrator)
    participant Azure as Azure Control Plane<br/>(MAA / AKV)
    participant CVM as Burst CVM<br/>(Trusted Launch stand-in;<br/>real target: SEV-SNP)
    participant EdgeApp as Edge Application<br/>(consumer of processed result)

    Edge->>Azure: 1. Start CVM (out-of-band trigger from edge orchestrator)
    Azure->>CVM: 2. Boot; platform attestation gated on AKV OS key
    CVM->>Azure: 3. Request signed attestation evidence (MAA / guest attestation)
    Azure->>CVM: 4. Signed attestation token
    CVM->>Edge: 5. Present signed attestation to edge Vault<br/>(unwrap service at 172.22.218.200:8443)
    Edge->>Edge: 6. Edge independently validates evidence and policy
    Edge->>CVM: 7. Release short-lived DEK + encrypted video payload<br/>(over ExpressRoute-peered private path)
    CVM->>CVM: 8. Decrypt in memory, process, re-encrypt with a new DEK<br/>(also released and unwrappable only by the edge)
    CVM->>EdgeApp: 9. Push re-encrypted result back to edge
    Edge->>Azure: 10. Destroy CVM. All key material and plaintext gone.
```

**Steps 1 and 10 are the entire Azure surface area from the customer's perspective.** Steps 2–4 involve Azure but never touch customer data. Steps 5–9 involve customer data and are gated by the edge alone.

## What the CVM has to prove to the edge

The edge Vault will only release the data key if the presented evidence proves the requester is:

1. Running on real Microsoft-attested confidential hardware (SEV-SNP measurement matches expected reference values), AND
2. Booted from the expected OS image (measurement of boot chain), AND
3. Identified by an Azure resource ID / managed identity the edge has pre-authorized, AND
4. Within a valid time window (evidence nonce freshness).

In the current lab, item 1 is stubbed: **the running Azure VM is a Trusted Launch VM, not SEV-SNP**, because SEV-SNP quota is 0 in westus2 (see `docs/deployment-status.md`). The unwrap service at `172.22.218.200:8443` runs in "demo mode" that accepts the Trusted Launch IMDS document; **the same code path in production mode rejects anything that isn't a real SEV-SNP measurement**. Adam explicitly OK'd showing the flow with a guest-attestation stub, provided we make clear on-stage that "this is where the real SEV-SNP validation would run."

## What in the existing lab we KEEP

| Component | Role in the new demo |
|---|---|
| On-prem Vault + Transit `htx-kek` | **Central.** Data-key custody. No change. |
| Unwrap service `172.22.218.200:8443` | **Central.** This is the edge attestation-gated release primitive. |
| ExpressRoute peering `AC-Managment-WUS2 ↔ AC-HubGW-EUS` | **Central.** The private path from CVM back to edge Vault. No customer data on public internet. |
| Azure Key Vault `acxhtx-kv-aguuve6oq6by6` + `htx-kek` | **Repurposed.** Reframed as OS/attestation-gating key, not data-protection key. May be replaced by a distinct "dummy" key for narrative clarity — see Open Question 1 below. |
| Trusted Launch VM `acxhtx-vm` | **The CVM stand-in.** Consumer service on it needs to be rewritten (see "Code changes required" below). |
| Peered VNet + private DNS | **Central.** Same as before. |

## What we DROP from the customer narrative

These stay deployed for now (Adam: "keep the cloud option available") but are **not shown in the demo** and are not part of the sovereignty pitch:

| Component | Why it's dropped |
|---|---|
| Storage account `acxhtxstgaguuve6oq6by6` and containers `sovereign-cold` / `sovereign-encrypted` | Customer refuses to store data in Azure Blob. Blob-based flow is off the table. |
| `acxhtx-mi-storage` + `acxhtx-producer-mi` UAMIs (blob-scoped) | The producer→blob→consumer flow is not the demo anymore. Identities remain deployed and harmless. |
| ACR `acxhtxacraguuve6o` CMK narrative | The "three encryption relationships, one key" pitch depended on storage + disk + ACR all pointing at the AKV KEK. New pitch is different. |
| Foundry hub / project | Not part of the burst-CVM story. Keep as prior work. |
| MWC / drone / HTX-DRONE-16 framing | Adam: present as a generic video feed. |

## Code changes required (deferred until Adam's post-meeting update)

Do NOT execute these yet — Adam is meeting the customer this evening and may adjust scope again. Listed here so the shape is captured.

1. **Producer (`C:\HTX\producer` on ALDO)** — stop uploading to Azure Blob. Instead, keep encrypted payloads in an edge-local store (filesystem, local MinIO, whatever's convenient) and expose them via a small edge fetch endpoint on ALDO. Callers must present valid attestation to fetch.
2. **Consumer (`C:\HTX\consumer` on `acxhtx-vm`)** — stop reading from Azure Blob. New flow:
   - Obtain platform attestation evidence (MAA / guest attestation for real SEV-SNP; IMDS document for the current Trusted Launch stub).
   - Call the edge fetch endpoint with the evidence to receive the encrypted payload AND the wrapped DEK.
   - Call the edge unwrap service to unwrap the DEK.
   - Decrypt, process, re-encrypt with a new DEK (also wrapped by the edge Vault).
   - Push the re-encrypted result back to a separate edge endpoint.
   - Zeroize keys and exit. The CVM should be shut down after each run.
3. **Edge orchestrator** — a small script/service on ALDO that: starts the Azure CVM on demand, waits for completion signal, tears it down. This is where the "burst" narrative lives operationally.
4. **Attestation stub location** — the unwrap service's demo-mode branch is the correct home for the stub. Add a highly visible log line and a `X-Attestation-Mode: stub` response header so on-stage it is obvious this is not production.

## Open questions to resolve before code work starts

1. **Separate "dummy" AKV key, or reuse `htx-kek`?** Adam suggested a distinct key strictly for OS attestation, so it's obvious the AKV key never touches data. Cleaner narrative but one more resource to manage. Recommend: create a new key `acxhtx-cvm-attestation-key` for demos, leave `htx-kek` in place for the prior CMK pattern (which may still get used in a different customer conversation).
2. **Real SEV-SNP or persistent stub?** Quota is not landing on its own; we submitted a case (see `docs/deployment-status.md`). If the customer wants to see the burst demo before quota lands, we go with the stub and are explicit about it on-stage. Adam approved this.
3. **Storage account fate.** Leave deployed but hidden, or delete to prevent the customer inferring we planned to use it? Recommend: leave deployed, do not show, and explicitly retire the storage narrative in the executive summary rewrite.
4. **Where does the edge fetch endpoint live?** Standing up a second service on `172.22.218.200` is easy, but if we want to show a proper "edge fabric" we might put it on a different ALDO node. Not blocking; just a scenography choice.

## Next actions (blocked until Adam's post-meeting update)

- [ ] Rewrite `docs/executive-summary.md` around the burst flow and update the mermaid diagram to match the sequence in this document.
- [ ] Rewrite `docs/demo-cheat-sheet.md` around the two-key toggle demo (edge Vault disable ⇒ CVM cannot decrypt; AKV OS key disable ⇒ CVM cannot start).
- [ ] Retire drone terminology in `docs/1130-brief.md`, `aldo/README.md`, `aldo/scripts/bootstrap-foundry-vm.md`, `arc-aks/foundry-local/model.yaml`, `training/*` — swap for "video-feed" / "video processing."
- [ ] Implement the producer/consumer/orchestrator changes listed above under "Code changes required."
- [ ] Decide on Open Questions 1–4 with Adam.
