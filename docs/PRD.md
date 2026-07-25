# CareRail — PRD v1.0

**A verified-service payment rail for healthcare. Built on Arc.**

## 1. Problem
Global out-of-pocket health spending exceeds $1T/year — cash-pay care, medical tourism, diaspora-funded treatment — with zero payment protection: patients pay upfront and hope. Separately, insurance claims commonly take 30-45 days to settle, tying up provider cash flow for weeks over a payment that is contractually already owed.

## 2. Solution (MVP scope)
**ServiceEscrow (contract).** A payer (patient, insurer, or employer plan) locks a USDC amount against a specific `serviceId` and `provider`. The provider delivers care, then submits a **service-attestation** (a signed claim referencing a content hash of the visit/procedure record — never the patient record itself, only its hash). Release rules:
- Payer acknowledges (`ack`) → instant release.
- No ack within a review window → **optimistic release** (mirrors the "not disputed = accepted" pattern).
- Payer disputes within the window → funds held pending a designated arbitrator resolution (a stub in v1 — a single trusted arbitrator address; real arbitration is a roadmap item).
- No attestation submitted before an `expiry` → **auto-refund** to payer.

**Attestation service (off-chain).** Providers submit attestations through a simple signed-message flow. No PHI (protected health information) ever touches the chain — only content hashes and structured non-identifying metadata (service category, amount, timestamp).

## 3. Why Arc specifically
USDC-native gas makes per-claim micro-settlement economically viable — a $40 telehealth consult can settle onchain without gas eating a meaningful share of the payment. Sub-second finality turns what is a 30-45 day reimbursement cycle in traditional insurance into same-day settlement. Arc Explorer gives both payer and provider an independently verifiable settlement record, useful for the employer/insurer side's own audit needs.

## 4. Non-goals (v1)
No real PHI onchain, ever · no real medical-licensing verification (assume a pre-vetted provider allowlist) · no insurance-claims-adjudication logic (rules engine) · no real arbitration court · no token.

## 5. Demo moment
Patient locks 40.00 USDC for "telehealth-consult-001" with Provider X. Provider delivers, submits an attestation hash. Patient acks → instant release, both sides see the same tx on Arc Explorer. Second scenario: Provider never submits before expiry → auto-refund, patient never loses the money for a service never delivered.

## 6. Honesty rules
Unaudited testnet label everywhere · never store or reference real patient data · real transactions only, no fabricated hashes.
