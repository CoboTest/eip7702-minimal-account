// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";
import { Execution } from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

/// @title E2EDirect - Direct Execution Flow (no ERC-4337)
/// @notice Two actors:
///   - Deployer: deploys MinimalAccount, funds Alice, activates delegation (type 4 tx)
///   - Alice:    fresh EOA, calls execute() directly via ERC-7821 (pays own gas)
contract E2EDirect is Script {
    uint256 constant TRANSFER_AMT = 0.00005 ether;
    uint256 constant FUND_AMT = 3 * TRANSFER_AMT; // Exact amount for transfers
    uint256 constant GAS_AMT = 0.0002 ether;       // Gas budget for Alice's 2 txs

    /// @dev ERC-7579 batch mode: callType=0x01, rest zeros
    bytes32 constant BATCH_MODE = bytes32(uint256(0x01) << 248);

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
        // Verify Alice starts fresh
        require(vm.getNonce(alice) == 0, "Alice nonce should be 0");
        console.log("  Alice nonce before: 0");
        _step1_deploy();
        _step2_fund();
        _step3_delegate();
        _step4_executeSingle();
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
        (bool ok,) = alice.call{ value: FUND_AMT + GAS_AMT }("");
        require(ok, "fund failed");
        console.log("  Transfer fund:", FUND_AMT, "wei");
        console.log("  Gas budget:", GAS_AMT, "wei");
        console.log("  PASS: funded");
    }

    function _step3_delegate() internal {
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
        (bool ok,) = alice.call{ value: 0 }("");
        require(ok, "delegation tx failed");

        require(alice.code.length == 23, "delegation not set");
        console.log("  PASS: delegation active");

        vm.setNonce(alice, 1);
    }

    function _step4_executeSingle() internal {
        console.log("");
        console.log("[4] Alice calls execute() - single transfer to Deployer...");

        uint256 balBefore = deployer.balance;

        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(deployer, TRANSFER_AMT, "");

        vm.broadcast(alicePk);
        MinimalAccount(payable(alice)).execute(BATCH_MODE, abi.encode(batch));

        uint256 received = deployer.balance - balBefore;
        require(received == TRANSFER_AMT, "execute transfer failed");
        console.log("  Transferred:", TRANSFER_AMT, "wei to Deployer");
        console.log("  PASS: execute() works");
    }

    function _step5_executeBatch() internal {
        console.log("");
        console.log("[5] Alice calls execute() batch - 2x transfer to Deployer...");

        uint256 balBefore = deployer.balance;

        Execution[] memory batch = new Execution[](2);
        batch[0] = Execution(deployer, TRANSFER_AMT, "");
        batch[1] = Execution(deployer, TRANSFER_AMT, "");

        vm.broadcast(alicePk);
        MinimalAccount(payable(alice)).execute(BATCH_MODE, abi.encode(batch));

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
        console.log("  Alice balance:", alice.balance, "wei (gas remainder)");

        uint256 nonceAfter = vm.getNonce(alice);
        require(nonceAfter == 3, "Alice nonce should be 3");
        console.log("  Alice nonce:", nonceAfter, "(1 auth + 1 execute + 1 batch)");

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
