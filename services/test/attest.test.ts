/**
 * Tests for the off-chain attestation service.
 * Hashing + allowlist tests are pure. submitAttestation chain calls are
 * mocked via the `deps.createContract` injection — no RPC, no real
 * provider keys, no real PHI.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { keccak256 } from "ethers";
import {
  hashRecord,
  buildServiceId,
  loadAllowlist,
  isProviderAllowed,
  submitAttestation,
} from "../attest.ts";
import type { ProviderAllowlist } from "../attest.ts";

describe("hashRecord", () => {
  it("produces a 0x-prefixed 32-byte hex hash", () => {
    const h = hashRecord("hello");
    assert.match(h, /^0x[0-9a-f]{64}$/);
  });
  it("is deterministic", () => {
    assert.equal(hashRecord("x"), hashRecord("x"));
  });
  it("differs for different inputs", () => {
    assert.notEqual(hashRecord("a"), hashRecord("b"));
  });
  it("stringifies objects before hashing", () => {
    const a = hashRecord({ a: 1, b: 2 });
    const b = hashRecord({ a: 1, b: 2 });
    assert.equal(a, b);
  });
});

describe("buildServiceId", () => {
  it("matches keccak256 over the utf-8 bytes (matches on-chain makeServiceId)", () => {
    const sid = buildServiceId("telehealth-consult-001");
    assert.match(sid, /^0x[0-9a-f]{64}$/);
    const expected = keccak256(new TextEncoder().encode("telehealth-consult-001"));
    assert.equal(sid, expected);
  });
});

describe("allowlist", () => {
  it("rejects unknown provider addresses (case-insensitive)", () => {
    const wl = loadAllowlist();
    assert.equal(isProviderAllowed(wl, "0x0000000000000000000000000000000000000001"), true);
    assert.equal(isProviderAllowed(wl, "0x0000000000000000000000000000000000000002"), false);
  });
  it("fails closed: empty allowlist allows nobody", () => {
    const empty: ProviderAllowlist = { providers: {} };
    assert.equal(
      isProviderAllowed(empty, "0x0000000000000000000000000000000000000001"),
      false
    );
    assert.equal(
      isProviderAllowed(empty, "0x81b86555fD882Fd7941d3DE80D85Bb8fcAf5bB8d"),
      false
    );
  });
  it("fails closed: mixed-case allowlist entry still matches case-insensitively", () => {
    const mixed = "0x81b86555fD882Fd7941d3DE80D85Bb8fcAf5bB8d";
    const wl: ProviderAllowlist = {
      providers: {
        "real-provider": {
          address: mixed,
          category: "telehealth",
          jurisdiction: "US-CA",
        },
      },
    };
    assert.equal(isProviderAllowed(wl, mixed.toLowerCase()), true);
    assert.equal(isProviderAllowed(wl, mixed.toUpperCase()), true);
    assert.equal(
      isProviderAllowed(wl, "0x0000000000000000000000000000000000000001"),
      false
    );
  });
});

describe("submitAttestation (mocked chain)", () => {
  const PROVIDER = "0x1111111111111111111111111111111111111111";
  const OTHER = "0x2222222222222222222222222222222222222222";
  const allowlist: ProviderAllowlist = {
    providers: {
      "test-provider": {
        address: PROVIDER,
        category: "telehealth",
        jurisdiction: "US-CA",
      },
    },
  };
  const mockSigner = (addr: string) => ({
    getAddress: async () => addr,
  });
  const mockContract = (service: any, opts?: { onSubmit?: () => void }) => ({
    getService: async (_sid: string) => service,
    submitAttestation: async (_sid: string, _hash: string) => {
      opts?.onSubmit?.();
      return { wait: async () => ({ hash: "0xmocktx", blockNumber: 1 }) };
    },
  });
  const baseOpts = {
    rpcUrl: "http://127.0.0.1:1",
    escrowAddress: "0x3333333333333333333333333333333333333333",
  };

  it("submits when Locked and signer is the registered provider", async () => {
    let submitted = false;
    const res = await submitAttestation(
      { serviceId: "telehealth-consult-001", record: { synthetic: true } },
      {
        ...baseOpts,
        signer: mockSigner(PROVIDER),
        allowlist,
        deps: {
          createContract: () =>
            mockContract(
              { state: 1, provider: PROVIDER },
              { onSubmit: () => (submitted = true) }
            ),
        },
      }
    );
    assert.equal(submitted, true);
    assert.match(res.recordHash, /^0x[0-9a-f]{64}$/);
    assert.equal(res.txHash, "0xmocktx");
  });

  it("rejects when the on-chain service is not Locked (fail closed)", async () => {
    let submitted = false;
    await assert.rejects(
      () =>
        submitAttestation(
          { serviceId: "telehealth-consult-001", record: { synthetic: true } },
          {
            ...baseOpts,
            signer: mockSigner(PROVIDER),
            allowlist,
            deps: {
              createContract: () =>
                mockContract(
                  { state: 2 /* Attested */, provider: PROVIDER },
                  { onSubmit: () => (submitted = true) }
                ),
            },
          }
        ),
      /not Locked/
    );
    assert.equal(submitted, false);
  });

  it("rejects when the signer is not the registered provider", async () => {
    let submitted = false;
    await assert.rejects(
      () =>
        submitAttestation(
          { serviceId: "telehealth-consult-001", record: { synthetic: true } },
          {
            ...baseOpts,
            signer: mockSigner(OTHER),
            // No allowlist here: this test isolates the on-chain provider check.
            deps: {
              createContract: () =>
                mockContract(
                  { state: 1, provider: PROVIDER },
                  { onSubmit: () => (submitted = true) }
                ),
            },
          }
        ),
      /not the registered provider/
    );
    assert.equal(submitted, false);
  });

  it("rejects when the signer is not on the allowlist — before any chain call", async () => {
    let chainTouched = false;
    await assert.rejects(
      () =>
        submitAttestation(
          { serviceId: "telehealth-consult-001", record: { synthetic: true } },
          {
            ...baseOpts,
            signer: mockSigner(OTHER),
            allowlist,
            deps: {
              createContract: () => {
                chainTouched = true;
                return mockContract({ state: 1, provider: OTHER });
              },
            },
          }
        ),
      /not on the provider allowlist/
    );
    assert.equal(chainTouched, false);
  });
});
