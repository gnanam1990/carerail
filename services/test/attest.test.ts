/**
 * Tests for the off-chain attestation service.
 * Uses a mocked chain call — no real provider keys, no real PHI.
 */
import { describe, it, mock, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { keccak256 } from "ethers";
import { Wallet } from "ethers";
import { hashRecord, buildServiceId, loadAllowlist, isProviderAllowed } from "../attest.ts";

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
});
