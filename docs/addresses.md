# CareRail — testnet addresses & lifecycle proof

> **Unaudited testnet software.** No real patient data, no real funds. Synthetic record
> hashes only.

## Arc Testnet (chain 5042002)

| Resource | Value |
|---|---|
| RPC | `https://rpc.testnet.arc.network` |
| Explorer | `https://testnet.arcscan.app` |
| USDC (ERC-20) | `0x3600000000000000000000000000000000000000` |
| USDC decimals | 6 |

Note: USDC is the gas token on Arc, and every transfer appears twice in the logs — an
18-decimal native log and a 6-decimal ERC-20 log. Same movement, two representations.

## ServiceEscrow deployment

| Field | Value |
|---|---|
| Address | `0xfBCCcCE1650824c6F06945DBa5e95c16a6Afe9D8` |
| Deploy tx | `0xb95f4804c4ab2d52108fba7d0ab0a63ad3490e6c6b94442e886a96b2cf4f850e` |
| Block | 53,883,879 |
| Gas | 1,189,184 (0.024972864 USDC) |
| Chain | 5042002 (Arc testnet) |
| `usdc` | `0x3600000000000000000000000000000000000000` |
| `arbitrator` | `0x0555AcEe3854Be831D304D54b7dd17fd018cfb17` |
| `ackThreshold` | 1,000,000 micro-USDC = 1.00 USDC (immutable) |
| `MIN_REVIEW_WINDOW` | 259,200 s = 3 days (constant) |

Roles are held by distinct addresses. The arbitrator is not the deployer — this is
visible on chain in step 12 below, where `resolveDispute` is signed by
`0x0555AcEe…`, not by the payer.

| Role | Address |
|---|---|
| Payer / deployer | `0x99B723eD097721036C08dd9DEe307286Df3A792D` |
| Provider | `0x81b86555fD882Fd7941d3DE80D85Bb8fcAf5bB8d` |
| Arbitrator | `0x0555AcEe3854Be831D304D54b7dd17fd018cfb17` |

> An earlier record in this file referenced an Anvil-fork deployment
> (`0xf488…da07`, fork block 53,596,833) and the Anvil default account
> `0xf39Fd6…b92266` as arbitrator. That was never on a real network and is
> superseded by the deployment above.

---

## The finding this deployment closes

Before this version, a provider could be paid without any patient participation at all:
`submitAttestation` accepts a record hash the provider supplies about themselves, and
`claimOptimistic` had no caller restriction — so after the review window the provider
simply called it and paid themselves. The patient's only defence was an affirmative duty
to dispute in time.

The fix is a threshold, not the removal of optimistic release. Above `ackThreshold`,
optimistic release is blocked outright: payment requires payer acknowledgment or an
arbitrator order, and patient silence past expiry refunds the patient. At or below the
threshold, the fast optimistic path is deliberately retained for low-value claims.

---

## Lifecycle proof — real Arc testnet transactions

Four services, one contract, one deployment. Threshold 1.00 USDC.

| Service | Amount | Relative to threshold |
|---|---|---|
| A `care-rail-A-001` | 2.00 USDC | above |
| B `care-rail-B-001` | 1.40 USDC | above |
| C `care-rail-C-001` | 1.20 USDC | above |
| D `care-rail-D-001` | 0.20 USDC | below |

### Setup

| # | Action | Tx | Block |
|---|---|---|---|
| 1 | Gas funding → provider (0.50 USDC) | `0xa8052047bbad479d05c223d9108d8d859fa39543888733aa18fadf3d26e14269` | 53,888,886 |
| 2 | Gas funding → arbitrator (0.30 USDC) | `0xb1493637d485a56b749e0d1f78b4ca2e24a97ae5baffaac8f232711faf49b7c7` | 53,888,901 |
| 3 | USDC approve (payer → escrow, 5.00) | `0xea952382c85796d6fdad4fc7c6781c1adcb8cc0fcc9d69c660207f299a661190` | 53,888,922 |

### A and D — locked and attested

| # | Action | Tx | Block |
|---|---|---|---|
| 4 | A — `lockFunds` 2,000,000, window 7 d | `0xab8b7b301e2bdceb23d7839baa4eb879d336c2145b1c723e13c4ef91df3b9c3c` | 53,888,981 |
| 5 | A — `submitAttestation` (provider) | `0xe3273c54172a501a0287cb29904f50f8617f3da00d3d48b3948eb1c4d579abc9` | 53,888,991 |
| 6 | D — `lockFunds` 200,000, window 7 d | `0xca28b26f6ab37077987aa4b08226de26f0ba910c93bedd45178f45dd02a510f8` | 53,889,011 |
| 7 | D — `submitAttestation` (provider) | `0x3d9f199856742b3894a07ab4e75237792b468de9a571f9e45754515ea5fc3066` | 53,889,025 |

### 8 — The proof

Both services are attested. Both are in the identical state. `claimOptimistic` is called
on each, from the same caller, in the same minute. Only the amount differs.

```
cast call 0xfBCCcCE1650824c6F06945DBa5e95c16a6Afe9D8 "claimOptimistic(bytes32)" \
  0xeadf800cddfa354de2b114099bf0a4e7366cc3232f8a1e5cb5097e09b9f8636f \
  --rpc-url https://rpc.testnet.arc.network --from 0x99B723eD097721036C08dd9DEe307286Df3A792D

→ execution reverted, data: "0x57984991"    OptimisticReleaseBlocked()
```

```
cast call 0xfBCCcCE1650824c6F06945DBa5e95c16a6Afe9D8 "claimOptimistic(bytes32)" \
  0xddfd8f85b634ca6703e46b9e35dc27e7b17e3df13cbe60245830303ace12dab4 \
  --rpc-url https://rpc.testnet.arc.network --from 0x99B723eD097721036C08dd9DEe307286Df3A792D

→ execution reverted, data: "0x8e3e8125"    WindowNotElapsed()
```

| Service | Amount | Selector | Error |
|---|---|---|---|
| A | 2.00 USDC | `0x57984991` | `OptimisticReleaseBlocked()` |
| D | 0.20 USDC | `0x8e3e8125` | `WindowNotElapsed()` |

Two different reverts prove the gate is the **threshold**, not the window. Service A is
not merely waiting — the optimistic path is closed to it permanently. Service D's path is
open and only time-gated.

Both selectors are `bytes4(keccak256(...))` of the error signatures and can be recomputed
independently. Both calls are `eth_call` simulations against live chain state: they
consume no gas, produce no transaction, and can be re-run by anyone at any time against
the deployed contract.

State after step 8 — no release occurred:

```
getService(A).state == 2 (Attested)      escrow USDC balance unchanged
```

### B — payer acknowledgment releases

| # | Action | Tx | Block |
|---|---|---|---|
| 9 | B — `lockFunds` 1,400,000 | `0x8ab945fb114c532ed72bd8e43912df7541b764707f80f1cfd6bed4e63438ccfb` | 53,889,198 |
| 10 | B — `submitAttestation` (provider) | `0xec55c860265aafee7619fdaf0022c9e9df211e79208b1cbe006f19330767dda4` | 53,889,205 |
| 11 | B — `ack` (payer) → **Released**, 1.40 USDC to provider | `0x22bbd242accab56193cce44a41bfa47aba0190a36d07d48d11da06f48c5ec343` | 53,889,215 |

### C — dispute, then arbitration

| # | Action | Tx | Block |
|---|---|---|---|
| 12 | C — `lockFunds` 1,200,000 | `0x02c36fa07f0ff1e43f3dbea0353e84a6bb641f5854eba7f1b6fbb9a28ad1f286` | 53,889,230 |
| 13 | C — `submitAttestation` (provider) | `0xc105e2ca06bb79c0968118bcd4ccfda52f21b9816a9122f6309656f89305931e` | 53,889,243 |
| 14 | C — `dispute` (payer) → **Held** | `0x8813ab327dff055d9eaecef19480091ddab6a4f17b8bae72e00648a992b44fd5` | 53,889,263 |
| 15 | C — `resolveDispute(true)` **signed by the arbitrator** → **Released**, 1.20 USDC to provider | `0xdcc6eac2b46fb634c36aa6bbb028bf1488bbc874ea8f55b355d0432f0296f690` | 53,889,287 |

Transaction 15 has `from: 0x0555AcEe3854Be831D304D54b7dd17fd018cfb17` — the arbitrator,
a different address from the payer who funded every other step.

### Final balances, read from chain

| Account | Balance | Reconciliation |
|---|---|---|
| Escrow | 2,200,000 | A 2,000,000 + D 200,000, both still locked |
| Provider | 3,095,228 | 500,000 gas float + B 1,400,000 + C 1,200,000 − 4,772 gas |

Above the threshold, the provider received payment exactly twice: once because the payer
acknowledged, once because an arbitrator ordered it. Never on their own attestation
alone.

Reproduce any state read with:

```
cast call 0xfBCCcCE1650824c6F06945DBa5e95c16a6Afe9D8 \
  "getService(bytes32)(address,address,uint64,uint64,uint64,uint96,uint8,bytes32)" \
  <serviceId> --rpc-url https://rpc.testnet.arc.network
```

State values: `0` None · `1` Locked · `2` Attested · `3` Held · `4` Released · `5` Refunded

---

## What this proof does NOT show

**Release does not mean care was delivered.** The contract has no concept of care. It
cannot have one — whether a patient received treatment is knowable only to the patient
and the provider. What the threshold does is decide who must speak before money moves.
Above 1.00 USDC, the provider's word alone is not enough.

**The below-threshold optimistic release is not demonstrated on chain.** It requires
`block.timestamp > attestationTime + reviewWindow`, and the window is floored at three
days, so it cannot complete on the day of deployment. Service D is locked and attested
and left open precisely for this reason. The path is covered by
`test_belowThreshold_optimisticReleaseAllowed`, `test_atThreshold_optimisticReleaseAllowed`
and the 512-run conservation fuzz. Its live proof here is negative: the `WindowNotElapsed`
revert in step 8 shows the path is open and merely early.

**The refund path is not demonstrated.** `refundExpired` requires reaching expiry
(2026-08-30). Services A and D hold 2.20 USDC that becomes recoverable then.

**Above the threshold, the contract protects the patient and does not protect the
provider.** If a patient receives care and then goes silent, expiry refunds them in full —
they keep both the care and the money. `dispute` is payer-only, so the provider has no
on-chain recourse. This is a deliberate risk allocation, not an oversight. Providers must
require acknowledgment before delivering high-value care, or rely on off-chain remedies.
Provider-initiated escalation is a named future item and is not built.

**The threshold is per service, and splitting defeats it.** A 5.00 USDC obligation
divided into six 0.90 USDC services is entirely below threshold and fully optimistically
releasable. `lockFunds` is payer-initiated, so a provider cannot split unilaterally — but
a payer who does not understand the threshold can be talked into it. The structural fix is
a per-provider rolling-window aggregate. It is not implemented, and this is recorded as
accepted risk rather than remediated.

**Provider vetting is off-chain.** The on-chain allowlist was removed in this version
because it gated nothing — no release path consulted it. A control that looks live but
isn't is worse than none. Real licensing verification is a non-goal for v1; the contract's
only provider control is `msg.sender == s.provider`, the address the payer chose.

**Record hashes are synthetic.** The four attestations carry
`keccak256("synthetic-record-A"…"D")`. They reference nothing. A real deployment would
hash an actual visit record — but note that the provider would still generate that hash,
so this changes what is referenced, not who is trusted.

---

## Summary

| | |
|---|---|
| Foundry tests | 32 / 32 (incl. 512-run conservation fuzz) |
| Off-chain tests | 6 / 6 |
| Real testnet deploy | `0xfBCCcCE1650824c6F06945DBa5e95c16a6Afe9D8`, block 53,883,879 |
| Lifecycle proof | 15 transactions + 2 verifiable reverts |
| Total committed | 4.80 USDC (2.60 released, 2.20 still locked) |
