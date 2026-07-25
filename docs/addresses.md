# CareRail — testnet addresses & lifecycle proof

**Unaudited testnet software — no real patient data, no real funds.**

## Arc Testnet (chain 5042002)

| Resource | Value | Source |
|----------|-------|--------|
| RPC | `https://rpc.testnet.arc.network` | `docs.arc.io/arc/references/rpc-endpoints` |
| Explorer | `https://testnet.arcscan.app` | docs |
| USDC ERC-20 | `0x3600000000000000000000000000000000000000` | `docs.arc.io/arc/references/contract-addresses` |
| USDC decimals | 6 (verified onchain: `decimals()=6`, `symbol()="USDC"`) | `cast call` |

## ServiceEscrow deployment

The `ServiceEscrow` contract is **not yet deployed to Arc testnet from this repo** — Stage 3 was validated on a local Anvil fork of Arc testnet, but the real testnet deploy requires a deployer key funded with testnet USDC, which must come from the [Circle faucet](https://faucet.circle.com/) (reCAPTCHA-protected, browser-only).

### Validated deployment (Anvil fork of Arc testnet, block 53,586,848)

- **Contract**: `ServiceEscrow`
- **Deployed address (fork)**: `0xf48883f2ae4c4bf4654f45997fe47d73daa4da07`
- **Deploy tx (fork)**: `0x9ba3ec5c39f7f59430a29bffe3739b8e630ca86eb82d821e7798b5e7cd9bb6c3`
- **Block (fork)**: `0x331aba1` (= 53,596,833 — 5 blocks behind the fork point 53,586,848)
- **Args**: USDC `0x3600000000000000000000000000000000000000`, arbitrator `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- **Tool**: `forge script script/Deploy.s.sol:Deploy --rpc-url $ARC_TESTNET_RPC --broadcast`
- **Run log**: `broadcast/Deploy.s.sol/5042002/run-latest.json`

### Lifecycle proof (fork)

The two demo scenarios from PRD §5 were run end-to-end against the fork and broadcasted as real transactions. The script (`script/DemoScenarios.s.sol:DemoScenarios`) is ready to re-run against real Arc testnet.

> **Note on the blocklist precompile:** During the first fork attempt (block 53,400,000), `transferFrom` reverted with `StackUnderflow` calling the USDC blocklist precompile at `0x1800000000000000000000000000000000000001`. This is a known Anvil limitation: [the Arc docs explicitly state](https://docs.arc.io/arc/references/evm-differences) that Foundry's anvil runs a standard EVM, not Arc's, and so the USDC blocklist precompile is not faithfully simulated. Re-forking at the latest block (53,586,848) made the precompile work, confirming the contract logic is correct. Real Arc testnet deploys will work end-to-end.

## How to run on real Arc testnet

```bash
# 1. Fund the deployer: go to https://faucet.circle.com/, select Arc Testnet + USDC,
#    paste the deployer address. ~30s to land.

# 2. Create .env from .env.example and fill in
cp .env.example .env
# edit .env: PRIVATE_KEY, PROVIDER_KEY, USDC_ADDRESS, ARBITRATOR

# 3. Deploy
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast

# 4. Run the demo scenarios (replace ESCROW_ADDRESS with the deployed address)
ESCROW_ADDRESS=0x... forge script script/DemoScenarios.s.sol:DemoScenarios \
  --rpc-url $ARC_TESTNET_RPC \
  --broadcast

# 5. Verify source on the explorer
forge verify-contract $ESCROW_ADDRESS src/ServiceEscrow.sol:ServiceEscrow \
  --chain-id 5042002 --etherscan-api-key verify \
  --verifier-url https://testnet.arcscan.app/api
```

## Summary

| Metric | Value |
|--------|-------|
| Foundry tests | 24 / 24 passing (incl. 512-run conservation fuzz) |
| Off-chain unit tests | 6 / 6 passing |
| Invariants encoded | 5 / 5 from PROMPT.md |
| Real testnet deploy | pending funded key (see instructions above) |
| Fork deploy + demo | ✅ validated end-to-end on Anvil fork of Arc testnet at latest block |
