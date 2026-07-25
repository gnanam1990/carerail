// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ServiceEscrow} from "../src/ServiceEscrow.sol";

/// @notice Deploys ServiceEscrow to Arc Testnet.
///
/// Env vars (read from .env when running via `forge script --env`):
///   PRIVATE_KEY     — deployer (must hold USDC for the demo scenarios later)
///   USDC_ADDRESS    — verified ERC-20 USDC on Arc Testnet
///   ARBITRATOR      — address that may resolve disputes in v1
///
/// Usage:
///   source .env
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $ARC_TESTNET_RPC \
///     --broadcast \
///     --verify --etherscan-api-key verify
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address arbitrator = vm.envOr("ARBITRATOR", vm.addr(pk)); // default = deployer

        vm.startBroadcast(pk);
        ServiceEscrow escrow = new ServiceEscrow(IERC20(usdc), arbitrator);
        vm.stopBroadcast();

        console2.log("ServiceEscrow deployed at:", address(escrow));
        console2.log("USDC:", usdc);
        console2.log("Arbitrator:", arbitrator);
        console2.log("Deployer:", vm.addr(pk));
    }
}
