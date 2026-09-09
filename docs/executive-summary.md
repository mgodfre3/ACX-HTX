# Burst to Azure Without Giving Up the Keys

**Sovereign Hybrid Compute — Executive Summary**
**Date:** September 2026
**Audience:** HTX Leadership
**Prepared by:** Michael Godfrey, Adaptive Cloud Lab

## The problem

The customer needs elastic compute capacity but will not accept two conditions common to public-cloud sovereignty stories:

1. **Their data must not sit in Azure Storage** — not encrypted at rest, not wrapped, not anywhere.
2. **Their application data key must never leave their premises** — Azure Key Vault cannot hold it, cannot be a fallback, cannot be a re-wrap target.

Traditional Azure BYOK / CMK / Confidential VM patterns all assume Azure Key Vault as the key custodian. That assumption is off the table.

## The solution: edge-controlled burst

Compute runs on-premises by default. When more capacity is needed, an Azure Confidential VM is started **as burst capacity only**. It attests to itself. It calls back to the customer's on-premises Vault. The customer's edge decides — independently of Azure — whether the CVM is trustworthy enough to receive a data key. If yes, an encrypted work item is streamed to the CVM over the customer's ExpressRoute-peered private path. The CVM processes it in memory only, re-encrypts the result with a fresh key also released by the edge, and sends the result home. The CVM shuts down. No customer bytes remain in Azure. The key never touched Azure.

## The two keys

This is the point that must survive Q&A. There are two customer-owned keys — reviewers will conflate them if not carefully separated.

| Key | Where | Protects | Released by | Kill-switch effect |
|---|---|---|---|---|
| **Azure Key Vault OS/attestation key** — `acxhtx-cvm-attestation-key` | Azure Key Vault Premium HSM | CVM boot / OS-disk crypto | Azure, gated on platform attestation | Disable: CVM cannot start. No data exposure. |
| **On-prem Vault Transit data key** — `htx-kek` | Customer HashiCorp Vault at 172.22.218.200 | Customer application data payload | The edge, only after independently validating CVM attestation | Disable: running CVM immediately loses ability to decrypt. Data is inert. |

> **"Azure can start the machine. Only the edge can unlock the data."**

## Architecture

```mermaid
sequenceDiagram
    autonumber
    participant Edge as ALDO Edge<br/>(Vault + video store<br/>+ orchestrator)
    participant Azure as Azure Control<br/>Plane
    participant CVM as Burst CVM<br/>(SEV-SNP target;<br/>Trusted Launch stub today)
    participant EdgeApp as Edge Application

    Edge->>Azure: 1. Start CVM (out-of-band from edge orchestrator)
    Azure->>CVM: 2. Boot; platform attestation gated on AKV OS key
    CVM->>Azure: 3. Request signed attestation evidence
    Azure->>CVM: 4. Signed attestation token
    CVM->>Edge: 5. Present attestation to edge-fetch server (172.22.218.200:8444)
    Edge->>Edge: 6. Independently validate evidence and policy
    Edge->>CVM: 7. Release encrypted envelope + wrapped DEK<br/>(ExpressRoute private path)
    CVM->>CVM: 8. Decrypt in memory only, process,<br/>re-encrypt with fresh DEK
    CVM->>EdgeApp: 9. Push re-encrypted result back
    Edge->>Azure: 10. Deallocate CVM. Zero customer data remains.
```

**Steps 1 and 10 are the entire Azure surface area from the customer's perspective.** Steps 2-4 involve Azure but never touch customer data. Steps 5-9 involve customer data and are gated by the edge alone.

## What is deployed in Azure today (RG `ACX-HTX`)

Nothing that stores or protects customer data.

| Resource | Role in the sovereign story |
|---|---|
| Key Vault Premium `acxhtx-kv-aguuve6oq6by6` | Two keys: `htx-kek` (protects the CVM's own OS disk) and `acxhtx-cvm-attestation-key` (gates CVM startup). Neither protects customer application data. |
| VM `acxhtx-vm` (Trusted Launch, D2as_v5, Windows 2022) | Burst compute stand-in. SEV-SNP is the production target; quota is 0 in westus2 today; TL is the guest-attestation stub Adam approved for the demo. |
| Foundry hub + project + ACR | Prior work. Not on the burst-CVM demo path. Not sovereign-critical. |
| **No Storage Account for customer data.** | Deleted 2026-09-09. The Bicep code paths remain, gated behind `deployStorage=false`, so future customer conversations that DO want blob-based flows can re-enable in one line. |

## What runs on-premises (ALDO)

- **HashiCorp Vault** at `172.22.218.200` — the sovereign data-key custodian. Transit key `htx-kek` never leaves this box.
- **Unwrap service** on `:8443` — attestation-gated DEK release primitive. Reject anything without valid attestation.
- **Edge fetch server** on `:8444` — attestation-gated envelope release + result store. Never sees plaintext.
- **Video store** at `/var/lib/edge-fetch/videos/` — encrypted envelopes only, wrapped with `htx-kek`.

Source of truth for both edge services: [`../aldo/edge-fetch/`](../aldo/edge-fetch/).
Source of truth for the CVM consumer: [`../cvm-app/`](../cvm-app/).

## What the demo proves in 6 minutes

Full storyboard: [`demo-storyboard.md`](demo-storyboard.md). Cheat sheet: [`demo-cheat-sheet.md`](demo-cheat-sheet.md). Design of record: [`burst-cvm-architecture.md`](burst-cvm-architecture.md).

| Property | Evidence on stage |
|---|---|
| **The customer's data key is not in Azure.** | Portal: Azure Key Vault Keys blade shows two keys, both explicitly non-data. Left shell: `vault read transit/keys/htx-kek` from the edge. |
| **No customer data is stored in Azure.** | Portal: RG has zero customer-facing Storage accounts. |
| **The edge — not Azure — decides who gets the data key.** | Edge fetch server audit log shows the attestation-gated release decision. Log line explicitly labels `STUB` vs `PROD`. |
| **Data only lives in Azure during a burst.** | CVM disk usage flat during processing. `Get-Volume` on the deallocated CVM fails. Result on edge. |
| **The customer can kill Azure's access without touching Azure.** | Toggle the edge Vault key. Re-run the burst. Attestation passes; unwrap fails; processing halts. |
| **Azure can stop the compute; that is all.** | Toggle the Azure Key Vault OS key. CVM cannot boot. Customer data on the edge is unaffected. |

## Deferred to production

- **Real SEV-SNP hardware** — quota request filed for `standardECasv6Family` in `westus2`. Swap is a parameter change; no consumer or edge code changes.
- **MAA JWT validation in prod attestation mode** — the code path exists and rejects everything as a fail-safe; the specific JWT verification against MAA JWKS is the last piece to wire once SEV-SNP hardware is available.
- **Customer HSM in place of HashiCorp Vault Transit** — same wire protocol, harder cryptographic backing. No code change on the CVM side.

## Prior iterations preserved

An earlier iteration proposed blob-based transport with a customer-managed key protecting Azure Storage. That flow has been retired at the customer's request. Its Bicep is gated (`deployStorage=false`) so it can be brought back for a different customer conversation without redevelopment.

## What leadership should take away

1. **The trust boundary is cryptographic, not geographic.** Even if Azure Storage or ExpressRoute were compromised, the customer's data would be inert without a key release from the edge.
2. **The customer holds the kill switch.** Two toggles: one on their edge (immediate data-key denial), one in Azure (compute denial). Both live on stage.
3. **Azure is elastic capacity, not a custodian.** The commercial appeal is unchanged; the trust posture is inverted.
4. **The Trusted Launch stub is honest** — every log line says `STUB`. The production upgrade to SEV-SNP is a parameter change, not a redesign.
