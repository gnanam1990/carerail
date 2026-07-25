# CareRail — staged Claude Code build prompts

Read docs/PRD.md fully before Stage 1. Do not add features beyond §2 without flagging them first. Each stage below is a separate, self-contained prompt — paste one at a time, confirm green, then move to the next.

---
## STAGE 1 — Core contract (ServiceEscrow)

Build ServiceEscrow.sol in Foundry. Tests FIRST for every invariant below.

INVARIANTS (encode as tests before implementing):
1. Funds release ONLY to the registered provider for that serviceId, or back to the original payer on refund — never a free-text destination.
2. A service can be acked, disputed, or expire-refunded — never more than one of these per service (state machine, no double-release).
3. Optimistic release after the review window is reachable only if no dispute was raised in that window.
4. Auto-refund is reachable only if no attestation was submitted before expiry.
5. Amounts are 6dp USDC throughout; Arc timestamp comparisons are inclusive (non-decreasing timestamps).

BUILD: `lockFunds(serviceId, provider, amount, expiry)`, `submitAttestation(serviceId, recordHash)` (provider-only), `ack(serviceId)` (payer-only, instant release), `claimOptimistic(serviceId)` (after review window, no dispute), `dispute(serviceId)` (payer-only, within window, moves to Held), `resolveDispute(serviceId, releaseToProvider)` (arbitrator-only stub), `refundExpired(serviceId)`. Full Foundry test suite, fuzz the conservation property (every lock ends in exactly one terminal state, funds never stranded). Commit and report test count + invariants covered.

---
## STAGE 2 — Attestation service (off-chain)

A small TypeScript service (services/) that providers use to submit attestations without ever touching PHI:
- `attest.ts`: given a local record (never uploaded), compute its hash locally, submit `submitAttestation(serviceId, recordHash)` on behalf of the provider's key.
- A basic provider allowlist config (services/providers.json) — v1 assumes providers are pre-vetted; do not build licensing verification.
- Tests for the hashing + submission flow using a mocked chain call. No real patient data in any test fixture — use clearly-labeled synthetic data only.

Report what's built and what's stubbed (arbitration, licensing) versus real.

---
## STAGE 3 — Arc testnet deployment + lifecycle proof

Deploy ServiceEscrow to Arc testnet: RPC https://rpc.testnet.arc.network, chain 5042002. Resolve the USDC address from docs.arc.io's contract-addresses page and verify onchain (symbol()==USDC, decimals()==6) before using it — never assume. Read docs.arc.io/arc/references/evm-differences first (non-decreasing timestamps, zero-address reverts). Deployer key from .env (PRIVATE_KEY), never committed.

Run the two demo scenarios from PRD §5 as real transactions: (1) lock → attest → ack → release, (2) lock → no attestation → expiry → auto-refund. Capture both sets of explorer links into docs/addresses.md. Verify source on testnet.arcscan.app.

---
## STAGE 4 — Demo interface

A minimal CLI or single-page UI (your choice, keep it small) showing: current locked services, their state (Locked/Attested/Released/Disputed/Refunded), and the two demo scenarios triggerable with one command each, printing the real explorer link at the end of each. Label prominently: "Unaudited testnet software — no real patient data, no real funds." README updated with quickstart + demo instructions. Commit and report the final state: test count, deployed addresses, demo screenshots or captured output.
