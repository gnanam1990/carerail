# CareRail attestation service

Off-chain tool for providers to submit attestations to `ServiceEscrow` without ever exposing patient data — only a content hash of the visit/procedure record leaves the provider's machine.

## What this is

- `attest.ts` — the core. Hashes a local record, sanity-checks the on-chain state, then calls `submitAttestation(serviceId, recordHash)` on behalf of the provider's signing key.
- `providers.json` — pre-vetted provider allowlist (v1 simplification; see "Honesty" below).
- `test/attest.test.ts` — node:test unit tests for hashing + allowlist lookup. Uses a mocked chain call; no real provider keys, no real PHI.

## What this is not (v1)

- **Not** a medical-licensing verification system. Per PRD §4, v1 assumes providers are pre-vetted off-chain. Replacing this stub with a real licensing verification integration is a roadmap item.
- **Not** a real arbitration system. Disputes are still routed to the single trusted arbitrator address configured in `ServiceEscrow`.
- **Not** a HIPAA-grade secret manager. Signer keys come from environment variables; production deployments should use a proper KMS.

## Usage

```bash
# 1. install
npm install

# 2. run the unit tests (no chain needed)
npm test

# 3. submit a real attestation
ESCROW_ADDRESS=0x... \
PROVIDER_PRIVATE_KEY=0x... \
ARC_TESTNET_RPC=https://rpc.testnet.arc.network \
tsx services/attest.ts "telehealth-consult-001" ./record.json
```

`record.json` stays on your machine. Only its SHA-256 hash reaches the chain.

## Honesty rules

No fabricated hashes. No synthetic data labeled as real. The demo record shipped in this directory is clearly labeled `synthetic: true` and contains no PHI.
