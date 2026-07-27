# CareRail — PRD v1.0

**A verified-service payment rail for healthcare. Built on Arc.**

## 1. Problem
Global out-of-pocket health spending exceeds $1T/year — cash-pay care, medical tourism, diaspora-funded treatment — with zero payment protection: patients pay upfront and hope. Separately, insurance claims commonly take 30-45 days to settle, tying up provider cash flow for weeks over a payment that is contractually already owed.

## 2. Solution (MVP scope)
**ServiceEscrow (contract).** A payer (patient, insurer, or employer plan) locks a USDC amount against a specific `serviceId` and `provider`. The provider delivers care, then submits a **service-attestation** (a signed claim referencing a content hash of the visit/procedure record — never the patient record itself, only its hash). Release rules (threshold-gated optimistic release — v2):
- The contract is constructed with an immutable `ackThreshold` (USDC micro-units).
- Payer acknowledges (`ack`) → instant release, any amount.
- For services with `amount <= ackThreshold`: no ack within the review window → **optimistic release** callable by anyone (the "not disputed = accepted" pattern is retained for low-value claims).
- For services with `amount > ackThreshold`: **no optimistic release.** The provider's self-attestation alone cannot release a high-value escrow. Release requires payer `ack`, or arbitrator resolution after a payer `dispute`. If the payer neither acks nor disputes, funds stay locked until `expiry`, after which `refundExpired` returns them to the payer — patient silence never pays the provider above the threshold.
- Payer disputes within the window → funds held pending a designated arbitrator resolution (a stub in v1 — a single trusted arbitrator address; real arbitration is a roadmap item).

**Risk allocation is asymmetric by design above the threshold.** Above `ackThreshold` the contract protects the **patient** and does **not** protect the provider. On patient silence the patient is refunded in full — they keep both the care already delivered and the funds; there is no "skin in the game" for the patient in the silent case, and the provider has **no on-chain recourse** because `dispute` is payer-only. A provider who delivered care to a silent (or non-acking) payer cannot, in this version, force the escrow to release or to enter arbitration. Providers must understand this and either (a) require `ack` before delivering high-value care, or (b) rely on off-chain remedies.
- **Future item — provider-initiated escalation:** allow the provider, after the review window on an above-threshold service, to move `Attested → Held` (escalate to the arbitrator) so a delivered-but-unacked claim can be adjudicated rather than refunded on expiry. This is intentionally **not** in v2; it is a larger change (it adds a second path into `Held` and shifts load onto the v1 stub arbitrator) and is recorded here as a named roadmap item, not silently assumed.
- No attestation submitted before an `expiry` → **auto-refund** to payer.
- `reviewWindow` has a floor (`MIN_REVIEW_WINDOW`, 3 days) so a provider dictating terms cannot shrink the patient's defence to nothing.

**Threshold-split vector (known, accepted).** `ackThreshold` is checked per `serviceId`. A single 500 USDC obligation split into ten 50 USDC services sits entirely at-or-below the threshold and is fully optimistically releasable — i.e. the protection above the threshold can be defeated by fragmentation. Mitigation: `lockFunds` is **payer-initiated** (the payer chooses `serviceId` and `amount` and signs the `transferFrom`), so a provider **cannot split unilaterally** — the provider has no function that creates or subdivides a lock. Residual risk: a payer who does not understand the threshold being talked/coerced by a provider into splitting one high-value service into many sub-threshold locks. This is a social-engineering residual, not a contract bug. A per-provider rolling-window aggregate (sum of locked amounts per provider over a recent window) would close it structurally, but that is a larger change than this fix warrants and is **not** implemented in v2; it is recorded as a future item only.

**Attestation service (off-chain).** Providers submit attestations through a simple signed-message flow. No PHI (protected health information) ever touches the chain — only content hashes and structured non-identifying metadata (service category, amount, timestamp).

**Provider vetting is off-chain only.** The contract has no on-chain allowlist: the v1 `providers.json` allowlist is enforced by the off-chain attestation service (`services/attest.ts`), not by `ServiceEscrow`. The contract's control is `msg.sender == provider` — the provider address the payer chose at `lockFunds`. A decorative on-chain allowlist that no release path reads was removed; it is worse than no mapping because it implies a guarantee the contract does not provide.

## 3. Why Arc specifically
USDC-native gas makes per-claim micro-settlement economically viable — a $40 telehealth consult can settle onchain without gas eating a meaningful share of the payment. Sub-second finality turns what is a 30-45 day reimbursement cycle in traditional insurance into same-day settlement. Arc Explorer gives both payer and provider an independently verifiable settlement record, useful for the employer/insurer side's own audit needs.

## 4. Non-goals (v1)
No real PHI onchain, ever · no real medical-licensing verification (provider allowlist is off-chain only; the contract does not vet providers) · no insurance-claims-adjudication logic (rules engine) · no real arbitration court · no token.

## 5. Demo moment
Patient locks 40.00 USDC for "telehealth-consult-001" with Provider X. Provider delivers, submits an attestation hash. Patient acks → instant release, both sides see the same tx on Arc Explorer. Second scenario: Provider never submits before expiry → auto-refund, patient never loses the money for a service never delivered.

## 6. Honesty rules
Unaudited testnet label everywhere · never store or reference real patient data · real transactions only, no fabricated hashes.
