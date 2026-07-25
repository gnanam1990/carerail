/**
 * CareRail demo CLI
 * -----------------
 * Runs the two PRD §5 demo scenarios against a deployed ServiceEscrow
 * on Arc Testnet and prints real explorer links for each transaction.
 *
 * Unaudited testnet software — no real patient data, no real funds.
 */
import {
  Contract,
  JsonRpcProvider,
  Wallet,
  keccak256,
  toUtf8Bytes,
  formatUnits,
  parseUnits,
} from "ethers";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const ARC_RPC   = process.env.ARC_TESTNET_RPC ?? "https://rpc.testnet.arc.network";
const EXPLORER  = process.env.EXPLORER_BASE   ?? "https://testnet.arcscan.app";
const ESCROW    = process.env.ESCROW_ADDRESS  ?? "";
const USDC      = process.env.USDC_ADDRESS    ?? "0x3600000000000000000000000000000000000000";
const PK        = process.env.PRIVATE_KEY     ?? "";
const PROV_KEY  = process.env.PROVIDER_KEY    ?? "";

if (!PK || !PROV_KEY || !ESCROW) {
  console.error("PRIVATE_KEY, PROVIDER_KEY, ESCROW_ADDRESS required");
  process.exit(2);
}

const SID_1 = keccak256(toUtf8Bytes("telehealth-consult-001"));
const SID_2 = keccak256(toUtf8Bytes("telehealth-consult-002"));

const ABI = [
  "function lockFunds(bytes32,address,uint96,uint64,uint64)",
  "function submitAttestation(bytes32,bytes32)",
  "function ack(bytes32)",
  "function refundExpired(bytes32)",
  "function getService(bytes32) view returns (tuple(address payer,address provider,uint64 attestationTime,uint64 reviewWindow,uint64 expiry,uint96 amount,uint8 state,bytes32 recordHash))",
  "function services(bytes32) view returns (address payer,address provider,uint64 attestationTime,uint64 reviewWindow,uint64 expiry,uint96 amount,uint8 state,bytes32 recordHash)",
];

const ERC20_ABI = [
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
];

const STATE = ["None", "Locked", "Attested", "Held", "Released", "Refunded"];

async function scenario1() {
  console.log("\n=== Scenario 1: lock -> attest -> ack -> release ===\n");
  const provider = new JsonRpcProvider(ARC_RPC);
  const payer = new Wallet(PK, provider);
  const providerW = new Wallet(PROV_KEY, provider);

  const escrow = new Contract(ESCROW, ABI, payer);
  const escrowProv = new Contract(ESCROW, ABI, providerW);
  const usdc = new Contract(USDC, ERC20_ABI, payer);

  const amount = parseUnits("40", 6);
  const window = 7n * 24n * 60n * 60n; // 7 days
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60);

  const tx1 = await usdc.approve(ESCROW, amount);
  await tx1.wait();
  console.log(`  approve   ${link("tx", tx1.hash)}`);

  const tx2 = await escrow.lockFunds(SID_1, await providerW.getAddress(), amount, window, expiry);
  const r2 = await tx2.wait();
  console.log(`  lockFunds ${link("tx", tx2.hash)}  block ${r2!.blockNumber}`);

  const tx3 = await escrowProv.submitAttestation(SID_1, keccak256(toUtf8Bytes("synthetic-record")));
  await tx3.wait();
  console.log(`  attest    ${link("tx", tx3.hash)}`);

  const tx4 = await escrow.ack(SID_1);
  const r4 = await tx4.wait();
  console.log(`  ack       ${link("tx", tx4.hash)}  block ${r4!.blockNumber}`);

  const svc = await escrow.getService(SID_1);
  console.log(`\n  final state: ${STATE[Number(svc.state)]}, amount paid: ${formatUnits(svc.amount, 6)} USDC`);
  console.log(`  contract:    ${link("address", ESCROW)}`);
}

async function scenario2() {
  console.log("\n=== Scenario 2: lock -> no attestation -> expiry -> auto-refund ===\n");
  const provider = new JsonRpcProvider(ARC_RPC);
  const payer = new Wallet(PK, provider);
  const providerW = new Wallet(PROV_KEY, provider);

  const escrow = new Contract(ESCROW, ABI, payer);
  const usdc = new Contract(USDC, ERC20_ABI, payer);

  const amount = parseUnits("40", 6);
  const window = 7n * 24n * 60n * 60n;
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 60); // very short for demo

  const tx1 = await usdc.approve(ESCROW, amount);
  await tx1.wait();

  const tx2 = await escrow.lockFunds(SID_2, await providerW.getAddress(), amount, window, expiry);
  await tx2.wait();
  console.log(`  lockFunds ${link("tx", tx2.hash)}  (expiry in 60s)`);

  console.log("  waiting 75s for expiry...");
  await new Promise((r) => setTimeout(r, 75_000));

  const tx3 = await escrow.refundExpired(SID_2);
  const r3 = await tx3.wait();
  console.log(`  refund    ${link("tx", tx3.hash)}  block ${r3!.blockNumber}`);

  const svc = await escrow.getService(SID_2);
  console.log(`\n  final state: ${STATE[Number(svc.state)]}, amount refunded: ${formatUnits(svc.amount, 6)} USDC`);
}

function link(kind: "tx" | "address", id: string) {
  return `${EXPLORER}/${kind}/${id}`;
}

async function main() {
  const arg = process.argv[2] ?? "all";
  if (arg === "1" || arg === "all") await scenario1();
  if (arg === "2" || arg === "all") await scenario2();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
