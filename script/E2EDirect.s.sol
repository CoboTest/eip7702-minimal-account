// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";

/// @title E2EDirect - Direct Execution Flow (no ERC-4337)
/// @notice Two actors:
///   - Deployer: deploys MinimalAccount, funds Alice, activates delegation (type 4 tx)
///   - Alice:    fresh EOA, calls execute() and executeBatch() directly (pays own gas)
///
/// @dev Single-run script. Uses vm.setNonce to account for EIP-7702 auth nonce
///      increment that forge simulation doesn't model.
///
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
        alicePk = vm.randomUint();
        alice = vm.addr(alicePk);

        _header();
        _step1_deploy();
        _step2_fund();
        _step3_delegate();
        _step4_execute();
        _step5_executeBatch();
        _step6_verify();
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

    function _step3_delegate() internal {
        console.log("");
        console.log("[3] Deployer activates Alice's delegation (type 4 tx)...");

        // Alice signs EIP-7702 delegation off-chain
        Vm.SignedDelegation memory sd = vm.signDelegation(executorAddr, alicePk);
        vm.attachDelegation(sd);
        console.log("  Alice signed delegation (off-chain):");
        console.log("    target:", executorAddr);
        console.log("    v:", sd.v);
        console.log("    r:", vm.toString(sd.r));
        console.log("    s:", vm.toString(sd.s));

        // Deployer sends type 4 tx carrying Alice's delegation
        vm.broadcast(deployerPk);
        (bool ok,) = alice.call{ value: 0 }("");
        require(ok, "delegation tx failed");

        require(alice.code.length == 23, "delegation not set");
        console.log("  PASS: delegation active");

        // EIP-7702 auth increments Alice's nonce on-chain (0 -> 1),
        // but forge simulation doesn't model this. Sync manually
        // so forge uses the correct nonce for Alice's subsequent txs.
        vm.setNonce(alice, 1);
    }

    function _step4_execute() internal {
        console.log("");
        console.log("[4] Alice calls execute() - single transfer to Deployer...");

        uint256 balBefore = deployer.balance;

        vm.broadcast(alicePk);
        MinimalAccount(payable(alice)).execute(deployer, TRANSFER_AMT, "");

        uint256 received = deployer.balance - balBefore;
        require(received == TRANSFER_AMT, "execute transfer failed");
        console.log("  Transferred:", TRANSFER_AMT, "wei to Deployer");
        console.log("  PASS: execute() works");
    }

    function _step5_executeBatch() internal {
        console.log("");
        console.log("[5] Alice calls executeBatch() - 2x transfer to Deployer...");

        uint256 balBefore = deployer.balance;

        MinimalAccount.Call[] memory calls = new MinimalAccount.Call[](2);
        calls[0] = MinimalAccount.Call(deployer, TRANSFER_AMT, "");
        calls[1] = MinimalAccount.Call(deployer, TRANSFER_AMT, "");

        vm.broadcast(alicePk);
        MinimalAccount(payable(alice)).executeBatch(calls);

        uint256 received = deployer.balance - balBefore;
        require(received == 2 * TRANSFER_AMT, "batch transfer failed");
        console.log("  Transferred: 2x", TRANSFER_AMT, "wei to Deployer");
        console.log("  PASS: executeBatch() works");
    }

    function _step6_verify() internal view {
        console.log("");
        console.log("[6] Final verification...");

        require(alice.code.length == 23, "delegation lost");
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
