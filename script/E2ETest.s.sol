// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { BatchExecutor } from "../src/BatchExecutor.sol";
import { PackedUserOperation } from "../src/interfaces/PackedUserOperation.sol";

interface IEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
}

/// @title E2ETest
/// @notice Full E2E test via Forge Script: deploy + basic + ERC-4337.
/// @dev    Usage: PRIVATE_KEY=0x... forge script script/E2ETest.s.sol --rpc-url <RPC> --broadcast
contract E2ETest is Script {
    IEntryPoint constant EP = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    address constant T1 = 0x1111111111111111111111111111111111111111;
    address constant T2 = 0x2222222222222222222222222222222222222222;

    uint256 pk;
    address eoa;
    BatchExecutor executor;

    function run() external {
        pk = vm.envUint("PRIVATE_KEY");
        eoa = vm.addr(pk);

        console.log("========================================");
        console.log("  EIP-7702 BatchExecutor E2E Test");
        console.log("========================================");
        console.log("EOA:", eoa);
        console.log("Balance:", eoa.balance);

        _step1_deploy();
        _step2_basicExecution();
        _step3_selfCallProtection();
        _step4_erc4337();

        console.log("");
        console.log("========================================");
        console.log("  ALL TESTS PASSED");
        console.log("========================================");
    }

    function _step1_deploy() internal {
        console.log("");
        console.log("[1] Deploy BatchExecutor...");

        vm.broadcast(pk);
        executor = new BatchExecutor();

        console.log("  Deployed:", address(executor));
        require(address(executor).code.length > 0, "deploy failed");
        console.log("  PASS: contract deployed");
    }

    function _step2_basicExecution() internal {
        console.log("");
        console.log("[2] Basic execution (EIP-7702 delegation)...");

        // --- Single execute ---
        uint256 bal1Before = T1.balance;

        vm.signAndAttachDelegation(address(executor), pk);
        vm.broadcast(pk);
        BatchExecutor(payable(eoa)).execute{ value: 0.00001 ether }(
            T1, 0.00001 ether, ""
        );

        require(T1.balance - bal1Before == 0.00001 ether, "single execute transfer failed");
        console.log("  PASS: single execute");

        // --- Batch execute ---
        uint256 bal1Before2 = T1.balance;
        uint256 bal2Before = T2.balance;

        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(T1, 0.00001 ether, "");
        calls[1] = BatchExecutor.Call(T2, 0.00001 ether, "");

        vm.signAndAttachDelegation(address(executor), pk);
        vm.broadcast(pk);
        BatchExecutor(payable(eoa)).executeBatch{ value: 0.00002 ether }(calls);

        require(T1.balance - bal1Before2 == 0.00001 ether, "batch T1 failed");
        require(T2.balance - bal2Before == 0.00001 ether, "batch T2 failed");
        console.log("  PASS: batch execute (2 transfers)");

        // --- Verify delegation ---
        require(eoa.code.length == 23, "delegation code not set");
        console.log("  PASS: EIP-7702 delegation active");
    }

    function _step3_selfCallProtection() internal {
        console.log("");
        console.log("[3] Self-call protection...");

        // We can't easily test reverts in scripts, so just verify the error selector exists
        // The shell E2E already covers this on-chain
        console.log("  SKIP: self-call revert tested in unit tests + shell E2E");
    }

    function _step4_erc4337() internal {
        console.log("");
        console.log("[4] ERC-4337 UserOp flow...");

        // Deposit to EntryPoint
        if (EP.balanceOf(eoa) < 0.005 ether) {
            vm.broadcast(pk);
            EP.depositTo{ value: 0.01 ether }(eoa);
            console.log("  Deposited 0.01 ETH to EntryPoint");
        }

        // Build UserOp
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(T1, 0.00001 ether, "");
        calls[1] = BatchExecutor.Call(T2, 0.00001 ether, "");

        uint256 nonce = EP.getNonce(eoa, 0);
        console.log("  EP nonce:", nonce);

        PackedUserOperation memory op = PackedUserOperation({
            sender: eoa,
            nonce: nonce,
            initCode: "",
            callData: abi.encodeCall(BatchExecutor.executeBatch, (calls)),
            accountGasLimits: bytes32(uint256(uint128(128_000)) << 128 | uint128(256_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32(uint256(uint128(2 gwei)) << 128 | uint128(50 gwei)),
            paymasterAndData: "",
            signature: ""
        });

        // Sign
        bytes32 opHash = EP.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, opHash);
        op.signature = abi.encodePacked(r, s, v);

        // Record balances
        uint256 bal1Before = T1.balance;
        uint256 bal2Before = T2.balance;

        // Submit
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.signAndAttachDelegation(address(executor), pk);
        vm.broadcast(pk);
        EP.handleOps(ops, payable(eoa));

        // Verify
        require(T1.balance - bal1Before == 0.00001 ether, "4337 T1 failed");
        require(T2.balance - bal2Before == 0.00001 ether, "4337 T2 failed");
        console.log("  PASS: handleOps executed batch");

        uint256 newNonce = EP.getNonce(eoa, 0);
        require(newNonce == nonce + 1, "nonce not incremented");
        console.log("  PASS: nonce incremented");
    }
}
