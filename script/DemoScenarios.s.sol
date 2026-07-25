// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ServiceEscrow} from "../src/ServiceEscrow.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Runs the two demo scenarios from PRD §5 against a deployed
///         ServiceEscrow on Arc Testnet, as real transactions.
///
/// Scenario 1: lock → attest → ack → release
/// Scenario 2: lock → no attestation → expiry → auto-refund
///
/// Env vars:
///   PRIVATE_KEY       — payer key (Scenario 1 & 2)
///   PROVIDER_KEY      — provider key (Scenario 1)
///   ESCROW_ADDRESS    — ServiceEscrow deployment
///   USDC_ADDRESS      — USDC ERC-20 address
///   EXPLORER_BASE     — e.g. https://testnet.arcscan.app
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
        ServiceEscrow(escrow).submitAttestation(SID_1, keccak256("synthetic-record-1"));
        vm.stopBroadcast();

        console2.log("Provider attested SID_1");

        vm.startBroadcast(payerPk);
        ServiceEscrow(escrow).ack(SID_1);
        vm.stopBroadcast();

        console2.log("Payer acked SID_1 -> funds released to provider");

        // ---- Scenario 2: lock → no attestation → expiry → auto-refund ----
        console2.log("\n=== Scenario 2: lock -> no attestation -> expiry -> auto-refund ===");

        vm.startBroadcast(payerPk);
        ServiceEscrow(escrow).lockFunds(SID_2, provider, amount, window, expiry2);
        vm.stopBroadcast();

        console2.log("Locked", amount / 1e6, "USDC for SID_2");

        // Fast-forward past expiry.
        vm.warp(expiry2 + 1);

        ServiceEscrow(escrow).refundExpired(SID_2);

        console2.log("SID_2 expired -> auto-refunded to payer");
    }

    function _link(string memory base, string memory kind, string memory tail) internal pure returns (string memory) {
        return string(abi.encodePacked(base, "/", kind, "/", tail));
    }
}
