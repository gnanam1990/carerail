# CareRail

**A verified-service payment rail for cash-pay and out-of-pocket healthcare.**

Patients pre-fund treatment cost in USDC escrow. Providers get paid when a service-delivery attestation lands onchain — and, above an immutable `ackThreshold`, only when the payer acknowledges or an arbitrator so orders. Below the threshold the optimistic-release flow is retained; above it the patient's silence never pays the provider.

Status: early build · Arc testnet · **unaudited — do not use with real funds or real patient data.**

Docs: [`docs/PRD.md`](docs/PRD.md) · Build prompts: [`PROMPT.md`](PROMPT.md) · Testnet addresses: [`docs/addresses.md`](docs/addresses.md)

## Quickstart (dev)

```bash
# 1. Foundry tests (32/32 incl. 512-run conservation fuzz + threshold-gating cases)
forge test

# 2. Off-chain service tests (6/6)
npm install
npm test

# 3. Deploy to Arc testnet (requires a funded key — see docs/addresses.md)
cp .env.example .env
# edit .env: PRIVATE_KEY, PROVIDER_KEY, USDC_ADDRESS, ARBITRATOR
source .env
forge script script/Deploy.s.sol:Deploy --rpc-url $ARC_TESTNET_RPC --broadcast
ESCROW_ADDRESS=0x... forge script script/DemoScenarios.s.sol:DemoScenarios --rpc-url $ARC_TESTNET_RPC --broadcast

# 4. Run the demo CLI (prints real explorer links)
ESCROW_ADDRESS=0x... npm run demo -- 1   # scenario 1
ESCROW_ADDRESS=0x... npm run demo -- 2   # scenario 2
```

## Layout

- `src/` — onchain contracts (ServiceEscrow).
- `test/` — Foundry unit + fuzz tests (invariants).
- `services/` — off-chain attestation service + demo CLI.
- `script/` — deployment + demo-scenario scripts.
- `docs/addresses.md` — testnet addresses + lifecycle proof.

## Honesty rules

- Unaudited testnet software — do not use with real funds or real patient data.
- Provider vetting is **off-chain only** (`services/providers.json` + `services/attest.ts`); the contract has no on-chain allowlist. Real medical-licensing verification is a roadmap item per PRD §4.
- Optimistic release is gated by an immutable `ackThreshold` set at deploy: services above it require payer `ack` or arbitration, and `reviewWindow` has a 3-day floor.
- The demo records are clearly labeled synthetic; no PHI is ever uploaded or hashed from this repo.
