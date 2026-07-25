# CareRail

**A verified-service payment rail for cash-pay and out-of-pocket healthcare.**

Patients pre-fund treatment cost in USDC escrow. Providers get paid only when a service-delivery attestation lands onchain — not on trust, not on a 30-45 day insurance cycle.

Status: early build · Arc testnet · **unaudited — do not use with real funds or real patient data.**

Docs: [`docs/PRD.md`](docs/PRD.md) · Build prompts: [`PROMPT.md`](PROMPT.md)

## Quickstart (dev)

```bash
forge install
forge test -vv
```

## Layout

- `src/` — onchain contracts (ServiceEscrow).
- `test/` — Foundry unit + fuzz tests (invariants).
- `services/` — off-chain attestation service (Stage 2).
- `script/` — deployment scripts (Stage 3).
- `docs/addresses.md` — testnet addresses + explorer links (Stage 3).
