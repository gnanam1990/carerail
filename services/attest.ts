/**
 * CareRail attestation service
 * ---------------------------
 * Providers use this to submit attestations to ServiceEscrow without ever
 * touching PHI. Only a content hash of the visit/procedure record leaves the
 * provider's machine.
 *
 * v1 simplification: a pre-vetted provider allowlist (services/providers.json)
 * gates which signing keys may submit. Real medical-licensing verification is
 * a roadmap item per PRD §4.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { Contract, JsonRpcProvider, Wallet, keccak256, toUtf8Bytes } from "ethers";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ------------------------------------------------------------------
// Types
// ------------------------------------------------------------------

export interface AttestInput {
  /** Opaque service id chosen by the payer (e.g. "telehealth-consult-001"). */
  serviceId: string;
  /** Local path or raw JSON string of the visit/procedure record. NEVER uploaded. */
  record: string | Record<string, unknown>;
  /** Optional: override the auto-derived recordHash. */
  recordHashOverride?: string;
}

export interface ProviderAllowlist {
  providers: Record<
    string,
    {
      address: string;
      category: string;
      jurisdiction: string;
    }
  >;
}

// ------------------------------------------------------------------
// Service contract ABI (subset, used off-chain only)
// ------------------------------------------------------------------

export const SERVICE_ESCROW_ABI = [
  "function submitAttestation(bytes32 serviceId, bytes32 recordHash) external",
  "function makeServiceId(string calldata raw) external pure returns (bytes32)",
  "function services(bytes32) external view returns (address payer, address provider, uint64 attestationTime, uint64 reviewWindow, uint64 expiry, uint96 amount, uint8 state, bytes32 recordHash)",
  "function getService(bytes32) external view returns (tuple)",
] as const;

// ------------------------------------------------------------------
// Allowlist helpers
// ------------------------------------------------------------------

export function loadAllowlist(path = join(__dirname, "providers.json")): ProviderAllowlist {
  return JSON.parse(readFileSync(path, "utf8")) as ProviderAllowlist;
}

export function isProviderAllowed(
  allowlist: ProviderAllowlist,
  address: string
): boolean {
  const norm = address.toLowerCase();
  return Object.values(allowlist.providers).some(
    (p) => p.address.toLowerCase() === norm
  );
}

// ------------------------------------------------------------------
// Hashing — done locally; the record itself is never sent anywhere.
// ------------------------------------------------------------------

/** Hash a local record. Returns 0x-prefixed 32-byte hex. */
export function hashRecord(record: string | Record<string, unknown>): string {
  const payload = typeof record === "string" ? record : JSON.stringify(record);
  return "0x" + createHash("sha256").update(payload).digest("hex");
}

/** Build a serviceId bytes32 from a human-readable string. */
export function buildServiceId(raw: string): string {
  return keccak256(toUtf8Bytes(raw));
}

// ------------------------------------------------------------------
// Core: submit an attestation on behalf of a provider's key.
// ------------------------------------------------------------------

export interface AttestResult {
  serviceId: string;
  recordHash: string;
  txHash: string;
  blockNumber?: number;
}

export async function submitAttestation(
  input: AttestInput,
  opts: {
    rpcUrl: string;
    escrowAddress: string;
    signer: Wallet;
    allowlist?: ProviderAllowlist;
  }
): Promise<AttestResult> {
  const { rpcUrl, escrowAddress, signer, allowlist } = opts;

  if (allowlist && !isProviderAllowed(allowlist, await signer.getAddress())) {
    throw new Error(
      `signer ${await signer.getAddress()} is not on the provider allowlist`
    );
  }

  const recordHash = input.recordHashOverride ?? hashRecord(input.record);
  const serviceId = buildServiceId(input.serviceId);

  const provider = new JsonRpcProvider(rpcUrl);
  const contract = new Contract(escrowAddress, SERVICE_ESCROW_ABI, signer.connect(provider));

  // Sanity: confirm the on-chain service is in Locked and the signer is the
  // registered provider. Fails closed if either is wrong.
  const onchain = await contract.getService(serviceId);
  const state = Number(onchain.state ?? onchain[6]);
  if (state !== 1 /* Locked */) {
    throw new Error(`service is not Locked onchain (state=${state})`);
  }
  const registeredProvider = String(onchain.provider ?? onchain[1]);
  const signerAddress = await signer.getAddress();
  if (registeredProvider.toLowerCase() !== signerAddress.toLowerCase()) {
    throw new Error(
      `signer ${signerAddress} is not the registered provider (${registeredProvider})`
    );
  }

  const tx = await contract.submitAttestation(serviceId, recordHash);
  const receipt = await tx.wait();

  return {
    serviceId,
    recordHash,
    txHash: receipt.hash,
    blockNumber: receipt.blockNumber,
  };
}

// ------------------------------------------------------------------
// CLI entry — `tsx services/attest.ts` reads env, signs, submits.
// ------------------------------------------------------------------

async function main() {
  const rpc = process.env.ARC_TESTNET_RPC ?? "https://rpc.testnet.arc.network";
  const escrow = process.env.ESCROW_ADDRESS;
  const pk = process.env.PROVIDER_PRIVATE_KEY;
  if (!escrow) throw new Error("ESCROW_ADDRESS not set");
  if (!pk) throw new Error("PROVIDER_PRIVATE_KEY not set");

  const serviceId = process.argv[2];
  if (!serviceId) {
    console.error("usage: tsx services/attest.ts <serviceId> [path/to/record.json]");
    process.exit(2);
  }
  const recordPath = process.argv[3];
  const record = recordPath
    ? JSON.parse(readFileSync(recordPath, "utf8"))
    : { synthetic: true, note: "demo-only synthetic record, no PHI" };

  const allowlist = loadAllowlist();
  const signer = new Wallet(pk);
  const result = await submitAttestation(
    { serviceId, record },
    { rpcUrl: rpc, escrowAddress: escrow, signer, allowlist }
  );

  console.log(JSON.stringify(result, null, 2));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
