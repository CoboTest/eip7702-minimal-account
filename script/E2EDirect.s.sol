// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";

/// @title E2EDirect - Direct Execution Flow (no ERC-4337)
/// @notice Two actors:
///   - Deployer: deploys MinimalAccount, funds Alice
///   - Alice:    fresh EOA, sends one type 4 tx that activates delegation
///              and calls executeBatch (tests both delegation + batch execution)
///
/// @dev Usage:
///   source .env  # DEPLOYER_PRIVATE_KEY, RPC_URL
///   forge script script/E2EDirect.s.sol --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
contract E2EDirect is Script {
    uint256 constant TRANSFER_AMT = 0.00005 ether;

    uint256 deployerPk;
    address deployer;
    uint256 alicePk;
    address alice;
    address executorAddr;

    function run() external {
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);

        // Fresh Alice each run
        alicePk = uint256(keccak256(abi.encodePacked("alice-direct", block.number, block.timestamp)));
        alice = vm.addr(alicePk);

        _header();
        _step1_deploy();
        _step2_fund();
        _step3_delegateAndBatch();
        _step4_verify();
        _footer();
    }

    function _header() internal view {
        console.log("================================================");
        console.log("  Direct Execution E2E");
        console.log("================================================");
        console.log("  Deployer:", deployer);
        console.log("  Alice:   ", alice);
        console.log("================================================");
    }

    function _step1_deploy() internal {
        console.log("");
        console.log("[1] Deployer deploys MinimalAccount...");

        vm.broadcast(deployerPk);
        MinimalAccount impl = new MinimalAccount();
        executorAddr = address(impl);

        require(executorAddr.code.length > 0, "deploy failed");
        console.log("  Contract:", executorAddr);
        console.log("  PASS: deployed");
    }

    function _step2_fund() internal {
        console.log("");
        console.log("[2] Deployer funds Alice...");

        vm.broadcast(deployerPk);
        (bool ok,) = alice.call{ value: 0.01 ether }("");
        require(ok, "fund failed");
        console.log("  Amount: 0.01 ETH");
        console.log("  PASS: funded");
    }

    function _step3_delegateAndBatch() internal {
        console.log("");
        console.log("[3] Alice: delegation + executeBatch (type 4 tx)...");

        uint256 balBefore = deployer.balance;

        // Alice signs EIP-7702 delegation off-chain
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(executorAddr, alicePk);
        vm.attachDelegation(signedDelegation);
        console.log("  Alice signed delegation (off-chain):");
        console.log("    target:", executorAddr);
        console.log("    v:", signedDelegation.v);
        console.log("    r:", vm.toString(signedDelegation.r));
        console.log("    s:", vm.toString(signedDelegation.s));

        // 3 transfers to Deployer via batch
        MinimalAccount.Call[] memory calls = new MinimalAccount.Call[](3);
        calls[0] = MinimalAccount.Call(deployer, TRANSFER_AMT, "");
        calls[1] = MinimalAccount.Call(deployer, TRANSFER_AMT, "");
        calls[2] = MinimalAccount.Call(deployer, TRANSFER_AMT, "");

        // Alice sends type 4 tx: delegation + executeBatch in one shot
        vm.broadcast(alicePk);
        MinimalAccount(payable(alice)).executeBatch(calls);

        // Verify delegation
        require(alice.code.length == 23, "delegation not set");

        // Verify transfers
        uint256 received = deployer.balance - balBefore;
        require(received == 3 * TRANSFER_AMT, "batch transfer failed");
        console.log("  PASS: delegation activated + executeBatch() works");
        console.log("  Transferred: 3x", TRANSFER_AMT, "wei to Deployer");
    }

    function _step4_verify() internal view {
        console.log("");
        console.log("[4] Final verification...");

        require(alice.code.length == 23, "delegation intact");
        console.log("  Delegation: still active");
        console.log("  Alice balance:", alice.balance, "wei");
        console.log("  Total transferred: 3x", TRANSFER_AMT, "wei to Deployer");
        console.log("  PASS: all assertions passed");
    }

    function _footer() internal view {
        console.log("");
        console.log("================================================");
        console.log("  ALL TESTS PASSED");
        console.log("================================================");
        console.log("  Alice:    ", alice);
        console.log("  Alice PK: ", vm.toString(bytes32(alicePk)));
        console.log("  Executor: ", executorAddr);
        console.log("  Deployer: ", deployer);
        console.log("================================================");
    }
}
