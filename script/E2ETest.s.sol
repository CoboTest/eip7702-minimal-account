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

/// @title E2E Step 1: Deploy
/// @dev   forge script script/E2ETest.s.sol:E2EDeploy --rpc-url $RPC_URL --broadcast --slow
contract E2EDeploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.broadcast(pk);
        BatchExecutor executor = new BatchExecutor();

        console.log("Deployed:", address(executor));
    }
}

/// @title E2E Step 2: Basic Execution
/// @dev   EXECUTOR=0x... forge script script/E2ETest.s.sol:E2EBasic --rpc-url $RPC_URL --broadcast --slow
contract E2EBasic is Script {
    address constant T1 = 0x1111111111111111111111111111111111111111;
    address constant T2 = 0x2222222222222222222222222222222222222222;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address eoa = vm.addr(pk);
        address executor = vm.envAddress("EXECUTOR");

        console.log("EOA:", eoa);

        // Single execute
        uint256 bal1 = T1.balance;
        vm.signAndAttachDelegation(executor, pk);
        vm.broadcast(pk);
        BatchExecutor(payable(eoa)).execute{ value: 0.00001 ether }(T1, 0.00001 ether, "");
        require(T1.balance - bal1 == 0.00001 ether, "single exec failed");
        console.log("PASS: single execute");

        // Batch execute
        uint256 bal1b = T1.balance;
        uint256 bal2b = T2.balance;
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(T1, 0.00001 ether, "");
        calls[1] = BatchExecutor.Call(T2, 0.00001 ether, "");

        vm.signAndAttachDelegation(executor, pk);
        vm.broadcast(pk);
        BatchExecutor(payable(eoa)).executeBatch{ value: 0.00002 ether }(calls);

        require(T1.balance - bal1b == 0.00001 ether, "batch T1 failed");
        require(T2.balance - bal2b == 0.00001 ether, "batch T2 failed");
        console.log("PASS: batch execute");

        require(eoa.code.length == 23, "delegation not set");
        console.log("PASS: delegation active");
    }
}

/// @title E2E Step 3: ERC-4337 UserOp
/// @dev   EXECUTOR=0x... forge script script/E2ETest.s.sol:E2E4337 --rpc-url $RPC_URL --broadcast --slow
contract E2E4337 is Script {
    IEntryPoint constant EP = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    address constant T1 = 0x1111111111111111111111111111111111111111;
    address constant T2 = 0x2222222222222222222222222222222222222222;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address eoa = vm.addr(pk);
        address executor = vm.envAddress("EXECUTOR");

        // Deposit if needed
        if (EP.balanceOf(eoa) < 0.005 ether) {
            vm.broadcast(pk);
            EP.depositTo{ value: 0.01 ether }(eoa);
            console.log("Deposited 0.01 ETH to EntryPoint");
        }

        _submitUserOp(eoa, pk, executor);
    }

    function _submitUserOp(address eoa, uint256 pk, address executor) internal {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(T1, 0.00001 ether, "");
        calls[1] = BatchExecutor.Call(T2, 0.00001 ether, "");

        uint256 nonce = EP.getNonce(eoa, 0);

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

        bytes32 opHash = EP.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, opHash);
        op.signature = abi.encodePacked(r, s, v);

        uint256 bal1 = T1.balance;
        uint256 bal2 = T2.balance;

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.signAndAttachDelegation(executor, pk);
        vm.broadcast(pk);
        EP.handleOps(ops, payable(eoa));

        require(T1.balance - bal1 == 0.00001 ether, "4337 T1 failed");
        require(T2.balance - bal2 == 0.00001 ether, "4337 T2 failed");
        console.log("PASS: handleOps batch");

        require(EP.getNonce(eoa, 0) == nonce + 1, "nonce not incremented");
        console.log("PASS: nonce incremented");
    }
}
