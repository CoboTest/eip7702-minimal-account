// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";

/// @title E2EDirect - Direct Execution Flow (no ERC-4337)
/// @notice Two phases, two actors:
///   - Deployer: deploys MinimalAccount, funds Alice, activates delegation (type 4 tx)
///   - Alice:    calls execute() and executeBatch() directly (pays own gas)
///
/// Phase 1 (Deployer sets up):
///   forge script script/E2EDirect.s.sol --sig "phase1()" --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
///
/// Phase 2 (Alice executes - after delegation is confirmed on-chain):
///   ALICE_PRIVATE_KEY=<from phase1 output> EXECUTOR=<from phase1 output> \
///   forge script script/E2EDirect.s.sol --sig "phase2()" --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
contract E2EDirect is Script {
    uint256 constant TRANSFER_AMT = 0.00005 ether;

    // ─── Phase 1: Deployer sets up ──────────────────────────────────

    function phase1() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        // Fresh Alice each run
        uint256 alicePk = uint256(keccak256(abi.encodePacked("alice-direct", block.number, block.timestamp)));
        address alice = vm.addr(alicePk);

        console.log("================================================");
        console.log("  Direct Execution E2E - Phase 1 (Setup)");
        console.log("================================================");
        console.log("  Deployer:", deployer);
        console.log("  Alice:   ", alice);
        console.log("================================================");

        // [1] Deploy
        console.log("");
        console.log("[1] Deployer deploys MinimalAccount...");
        vm.broadcast(deployerPk);
        MinimalAccount impl = new MinimalAccount();
        address executorAddr = address(impl);
        require(executorAddr.code.length > 0, "deploy failed");
        console.log("  Contract:", executorAddr);
        console.log("  PASS: deployed");

        // [2] Fund Alice
        console.log("");
        console.log("[2] Deployer funds Alice...");
        vm.broadcast(deployerPk);
        (bool ok,) = alice.call{ value: 0.01 ether }("");
        require(ok, "fund failed");
        console.log("  Amount: 0.01 ETH");
        console.log("  PASS: funded");

        // [3] Activate delegation
        console.log("");
        console.log("[3] Deployer activates Alice's delegation (type 4 tx)...");
        Vm.SignedDelegation memory sd = vm.signDelegation(executorAddr, alicePk);
        vm.attachDelegation(sd);
        console.log("  Alice signed delegation (off-chain):");
        console.log("    target:", executorAddr);
        console.log("    v:", sd.v);
        console.log("    r:", vm.toString(sd.r));
        console.log("    s:", vm.toString(sd.s));

        vm.broadcast(deployerPk);
        (ok,) = alice.call{ value: 0 }("");
        require(ok, "delegation tx failed");
        require(alice.code.length == 23, "delegation not set");
        console.log("  PASS: delegation active");

        // Print Phase 2 command
        console.log("");
        console.log("================================================");
        console.log("  Phase 1 COMPLETE - Run Phase 2:");
        console.log("================================================");
        console.log("  ALICE_PRIVATE_KEY=", vm.toString(bytes32(alicePk)));
        console.log("  EXECUTOR=", vm.toString(executorAddr));
        console.log("================================================");
    }

    // ─── Phase 2: Alice executes ────────────────────────────────────

    function phase2() external {
        uint256 alicePk = vm.envUint("ALICE_PRIVATE_KEY");
        address alice = vm.addr(alicePk);
        address executorAddr = vm.envAddress("EXECUTOR");
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        console.log("================================================");
        console.log("  Direct Execution E2E - Phase 2 (Execute)");
        console.log("================================================");
        console.log("  Alice:   ", alice);
        console.log("  Executor:", executorAddr);
        console.log("  Deployer:", deployer);
        console.log("================================================");

        // Verify delegation is set
        require(alice.code.length == 23, "delegation not active - run phase1 first");

        // [4] execute()
        console.log("");
        console.log("[4] Alice calls execute() - single transfer to Deployer...");
        uint256 balBefore = deployer.balance;

        vm.broadcast(alicePk);
        MinimalAccount(payable(alice)).execute(deployer, TRANSFER_AMT, "");

        uint256 received = deployer.balance - balBefore;
        require(received == TRANSFER_AMT, "execute transfer failed");
        console.log("  Transferred:", TRANSFER_AMT, "wei to Deployer");
        console.log("  PASS: execute() works");

        // [5] executeBatch()
        console.log("");
        console.log("[5] Alice calls executeBatch() - 2x transfer to Deployer...");
        balBefore = deployer.balance;

        MinimalAccount.Call[] memory calls = new MinimalAccount.Call[](2);
        calls[0] = MinimalAccount.Call(deployer, TRANSFER_AMT, "");
        calls[1] = MinimalAccount.Call(deployer, TRANSFER_AMT, "");

        vm.broadcast(alicePk);
        MinimalAccount(payable(alice)).executeBatch(calls);

        received = deployer.balance - balBefore;
        require(received == 2 * TRANSFER_AMT, "batch transfer failed");
        console.log("  Transferred: 2x", TRANSFER_AMT, "wei to Deployer");
        console.log("  PASS: executeBatch() works");

        // [6] Verify
        console.log("");
        console.log("[6] Final verification...");
        require(alice.code.length == 23, "delegation lost");
        console.log("  Delegation: still active");
        console.log("  Alice balance:", alice.balance, "wei");
        console.log("  Total transferred: 3x", TRANSFER_AMT, "wei to Deployer");
        console.log("  PASS: all assertions passed");

        console.log("");
        console.log("================================================");
        console.log("  ALL TESTS PASSED");
        console.log("================================================");
    }
}
