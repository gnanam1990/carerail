// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ServiceEscrow} from "../src/ServiceEscrow.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice LIVE script — runs demo scenario 1 (lock → attest → ack → release)
///         as real transactions on Arc Testnet, plus the lock leg of scenario 2.
///
///         This contract is the ONLY thing that may be run with `--broadcast`.
///         It contains NO time-travel cheatcodes (`vm.warp`) and NO local-only
///         calls: every state-changing call sits inside a broadcast block.
///
/// Scenario 1: lock → attest → ack → release (fully executed here)
/// Scenario 2: lock here; expiry + refund happen later, either by waiting for
///         real expiry and calling `refundExpired`, or via the TS demo
///         (`services/demo.ts` scenario 2: 60s expiry + sleep, no cheatcodes).
///         See DemoScenariosFork below for the fork-only time-travel variant.
///
/// Env vars:
///   PRIVATE_KEY       — payer key (Scenario 1 & 2)
///   PROVIDER_KEY      — provider key (Scenario 1)
///   ESCROW_ADDRESS    — ServiceEscrow deployment
///   USDC_ADDRESS      — USDC ERC-20 address
///   EXPLORER_BASE     — e.g. https://testnet.arcscan.app
///
/// Usage (live):
///   forge script script/DemoScenarios.s.sol:DemoScenarios \
///     --rpc-url $ARC_TESTNET_RPC --broadcast
contract DemoScenarios is Script {
    bytes32 constant SID_1 = keccak256("telehealth-consult-001");
    bytes32 constant SID_2 = keccak256("telehealth-consult-002");

    function run() external {
        uint256 payerPk    = vm.envUint("PRIVATE_KEY");
        uint256 providerPk = vm.envUint("PROVIDER_KEY");
        address escrow     = vm.envAddress("ESCROW_ADDRESS");
        address usdc       = vm.envAddress("USDC_ADDRESS");
        string memory base  = vm.envOr("EXPLORER_BASE", string("https://testnet.arcscan.app"));

        address payer    = vm.addr(payerPk);
        address provider = vm.addr(providerPk);

        uint96 amount = 40_000_000; // 40.00 USDC
        uint64 window = 7 days;
        uint64 expiry1 = uint64(block.timestamp + 30 days);
        uint64 expiry2 = uint64(block.timestamp + 60 days);

        // ---- Scenario 1: lock → attest → ack → release ----
        console2.log("\n=== Scenario 1: lock -> attest -> ack -> release ===");

        vm.startBroadcast(payerPk);
        IERC20(usdc).approve(escrow, type(uint256).max);
        ServiceEscrow(escrow).lockFunds(SID_1, provider, amount, window, expiry1);
        vm.stopBroadcast();

        console2.log("Locked", amount / 1e6, "USDC for SID_1 ->", _link(base, "tx", "?"));

        vm.startBroadcast(providerPk);
        // NOTE: synthetic placeholder hash. Canonical off-chain convention is
        // sha256(JSON) via services/attest.ts hashRecord; this keccak value
        // references nothing and is demo-only (see services/README.md).
        ServiceEscrow(escrow).submitAttestation(SID_1, keccak256("synthetic-record-1"));
        vm.stopBroadcast();

        console2.log("Provider attested SID_1");

        vm.startBroadcast(payerPk);
        ServiceEscrow(escrow).ack(SID_1);
        vm.stopBroadcast();

        console2.log("Payer acked SID_1 -> funds released to provider");

        // ---- Scenario 2: lock leg only (live) ----
        console2.log("\n=== Scenario 2: lock -> (wait for real expiry) -> refundExpired ===");

        vm.startBroadcast(payerPk);
        ServiceEscrow(escrow).lockFunds(SID_2, provider, amount, window, expiry2);
        vm.stopBroadcast();

        console2.log("Locked", amount / 1e6, "USDC for SID_2");
        console2.log("Payer:", payer);
        console2.log("Refund opens after expiry; then anyone may call refundExpired(SID_2).");
        console2.log("For the short-expiry variant without waiting, run the TS demo:");
        console2.log("  ESCROW_ADDRESS=<escrow> npm run demo -- 2   (60s expiry + sleep)");
    }

    function _link(string memory base, string memory kind, string memory tail) internal pure returns (string memory) {
        return string(abi.encodePacked(base, "/", kind, "/", tail));
    }
}

/// @notice FORK/TEST-ONLY script — replays both scenarios with time travel.
///         NEVER run with `--broadcast`: `vm.warp` has no effect on a live
///         network and the refund leg would silently execute against stale
///         local state instead of chain state.
///
/// Usage (local fork, no --broadcast):
///   forge script script/DemoScenarios.s.sol:DemoScenariosFork \
///     --rpc-url $ARC_TESTNET_RPC
///   anvil                                    # or a local fork endpoint
///   forge script script/DemoScenarios.s.sol:DemoScenariosFork \
///     --rpc-url http://127.0.0.1:8545 --broadcast
contract DemoScenariosFork is Script {
    bytes32 constant SID_1 = keccak256("telehealth-consult-001");
    bytes32 constant SID_2 = keccak256("telehealth-consult-002");

    function run() external {
        uint256 payerPk    = vm.envUint("PRIVATE_KEY");
        uint256 providerPk = vm.envUint("PROVIDER_KEY");
        address escrow     = vm.envAddress("ESCROW_ADDRESS");
        address usdc       = vm.envAddress("USDC_ADDRESS");

        address provider = vm.addr(providerPk);

        uint96 amount = 40_000_000; // 40.00 USDC
        uint64 window = 7 days;
        uint64 expiry1 = uint64(block.timestamp + 30 days);
        uint64 expiry2 = uint64(block.timestamp + 60 days);

        // ---- Scenario 1: lock → attest → ack → release ----
        console2.log("\n=== [fork] Scenario 1: lock -> attest -> ack -> release ===");

        vm.startBroadcast(payerPk);
        IERC20(usdc).approve(escrow, type(uint256).max);
        ServiceEscrow(escrow).lockFunds(SID_1, provider, amount, window, expiry1);
        vm.stopBroadcast();

        vm.startBroadcast(providerPk);
        ServiceEscrow(escrow).submitAttestation(SID_1, keccak256("synthetic-record-1"));
        vm.stopBroadcast();

        vm.startBroadcast(payerPk);
        ServiceEscrow(escrow).ack(SID_1);
        vm.stopBroadcast();

        console2.log("[fork] SID_1 released to provider");

        // ---- Scenario 2: lock → warp past expiry → refund ----
        console2.log("\n=== [fork] Scenario 2: lock -> warp -> refundExpired ===");

        vm.startBroadcast(payerPk);
        ServiceEscrow(escrow).lockFunds(SID_2, provider, amount, window, expiry2);
        vm.stopBroadcast();

        // Fork-only time travel. Forbidden in the live DemoScenarios path.
        vm.warp(expiry2 + 1);

        vm.startBroadcast(payerPk);
        ServiceEscrow(escrow).refundExpired(SID_2);
        vm.stopBroadcast();

        console2.log("[fork] SID_2 expired -> refunded to payer");
    }
}
