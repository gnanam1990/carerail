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
# Arc testnet: chain 5042002, RPC https://rpc.testnet.arc.network, explorer https://testnet.arcscan.app, escrow 0xfBCCcCE1650824c6F06945DBa5e95c16a6Afe9D8 (see ../docs/addresses.md)
ESCROW_ADDRESS=0xfBCCcCE1650824c6F06945DBa5e95c16a6Afe9D8 \
PROVIDER_PRIVATE_KEY=0x... \
ARC_TESTNET_RPC=https://rpc.testnet.arc.network \
tsx services/attest.ts "telehealth-consult-001" ./record.json
```

`record.json` stays on your machine. Only its SHA-256 hash reaches the chain.

## Hash conventions (single source of truth)

- `recordHash` — what leaves the provider's machine: **SHA-256 over the
  UTF-8 bytes of the canonical JSON record**, computed by `hashRecord()` in
  `attest.ts`. The demo CLI (`demo.ts`) calls the same function with a
  payload labeled `{ synthetic: true, ... }`, so demo hashes and real hashes
  share one convention.
- `serviceId` — **`keccak256` over the UTF-8 bytes of the human-readable
  id**: `buildServiceId()` off-chain, `makeServiceId()` on-chain. Unchanged.
- Exceptions, both demo-only placeholders that reference nothing:
  - `script/DemoScenarios.s.sol` attests with `keccak256("synthetic-record-1")`.
  - The four lifecycle-proof attestations in `docs/addresses.md` carry
    `keccak256("synthetic-record-A"…​"D")` and predate this convention.
  - Neither is canonical. Anything real must go through `attest.hashRecord`.

## Updating the allowlist

`providers.json` ships with the `0x0000…​0001` placeholder. Point it at the
real provider before any live attestation — `submitAttestation` fails closed
(a signer not on the list is rejected before any chain call, and an empty
list allows nobody):

```bash
# replace the placeholder with the real testnet provider (see ../docs/addresses.md)
jq '.providers["demo-provider-1"].address = "0x81b86555fD882Fd7941d3DE80D85Bb8fcAf5bB8d"' \
  services/providers.json > /tmp/providers.json && mv /tmp/providers.json services/providers.json
npm test   # allowlist tests confirm the new entry matches (case-insensitive)
```

## Honesty rules

No fabricated hashes. No synthetic data labeled as real. The demo record shipped in this directory is clearly labeled `synthetic: true` and contains no PHI.
