// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { BatchExecutor } from "../src/BatchExecutor.sol";
import { IAccount } from "../src/interfaces/IAccount.sol";
import { PackedUserOperation } from "../src/interfaces/PackedUserOperation.sol";

/// @dev Mock target contract for testing batch calls.
contract MockTarget {
    uint256 public value;
    uint256 public callCount;

    function setValue(uint256 _v) external payable {
        value = _v;
        callCount++;
    }

    function reverting() external pure {
        revert("MockTarget: forced revert");
    }

    receive() external payable {}
}

contract BatchExecutorTest is Test {
    BatchExecutor public executor;
    MockTarget public target;

    // EOA that will delegate to BatchExecutor via EIP-7702
    uint256 internal eoaPrivateKey = 0xA11CE;
    address internal eoaAddress;

    function setUp() public {
        eoaAddress = vm.addr(eoaPrivateKey);

        // Deploy the delegate implementation
        executor = new BatchExecutor();

        // Deploy mock target
        target = new MockTarget();

        // Fund the EOA
        vm.deal(eoaAddress, 10 ether);

        // EIP-7702: set the EOA's code to delegate to executor
        // In Foundry, we simulate this with vm.etch + delegatecall pattern
        // For Prague-compatible testing, use vm.signDelegation + vm.attachDelegation
        _setupDelegation();
    }

    function _setupDelegation() internal {
        // Sign EIP-7702 delegation
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(
            address(executor),
            eoaPrivateKey
        );

        // Attach delegation to the EOA (simulates EIP-7702 SET_CODE_TX)
        vm.attachDelegation(signedDelegation);
    }

    // ─── Single Execution ────────────────────────────────────────────────

    function test_execute_single() public {
        vm.prank(eoaAddress);
        BatchExecutor(payable(eoaAddress)).execute(
            address(target),
            0,
            abi.encodeCall(MockTarget.setValue, (42))
        );

        assertEq(target.value(), 42);
        assertEq(target.callCount(), 1);
    }

    function test_execute_single_with_value() public {
        vm.prank(eoaAddress);
        BatchExecutor(payable(eoaAddress)).execute{ value: 1 ether }(
            address(target),
            1 ether,
            ""
        );

        assertEq(address(target).balance, 1 ether);
    }

    // ─── Batch Execution ─────────────────────────────────────────────────

    function test_executeBatch() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](3);
        calls[0] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (10)));
        calls[1] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (20)));
        calls[2] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (30)));

        vm.prank(eoaAddress);
        BatchExecutor(payable(eoaAddress)).executeBatch(calls);

        // Last call wins
        assertEq(target.value(), 30);
        assertEq(target.callCount(), 3);
    }

    function test_executeBatch_with_value() public {
        MockTarget target2 = new MockTarget();

        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(address(target), 0.5 ether, "");
        calls[1] = BatchExecutor.Call(address(target2), 0.3 ether, "");

        vm.prank(eoaAddress);
        BatchExecutor(payable(eoaAddress)).executeBatch{ value: 0.8 ether }(calls);

        assertEq(address(target).balance, 0.5 ether);
        assertEq(address(target2).balance, 0.3 ether);
    }

    function test_executeBatch_empty() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](0);

        vm.prank(eoaAddress);
        BatchExecutor(payable(eoaAddress)).executeBatch(calls);
        // Should succeed with no-op
    }

    // ─── Revert Handling ─────────────────────────────────────────────────

    function test_execute_revert_propagates() public {
        vm.prank(eoaAddress);
        vm.expectRevert();
        BatchExecutor(payable(eoaAddress)).execute(
            address(target),
            0,
            abi.encodeCall(MockTarget.reverting, ())
        );
    }

    function test_executeBatch_revert_on_failure() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));
        calls[1] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.reverting, ()));

        vm.prank(eoaAddress);
        vm.expectRevert();
        BatchExecutor(payable(eoaAddress)).executeBatch(calls);
    }

    // ─── Access Control ──────────────────────────────────────────────────

    function test_unauthorized_caller_reverts() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(BatchExecutor.Unauthorized.selector);
        BatchExecutor(payable(eoaAddress)).execute(
            address(target),
            0,
            abi.encodeCall(MockTarget.setValue, (999))
        );
    }

    function test_unauthorized_batch_reverts() public {
        address attacker = makeAddr("attacker");
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](1);
        calls[0] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (999)));

        vm.prank(attacker);
        vm.expectRevert(BatchExecutor.Unauthorized.selector);
        BatchExecutor(payable(eoaAddress)).executeBatch(calls);
    }

    function test_entryPoint_can_call() public {
        vm.prank(executor.ENTRY_POINT());
        // EntryPoint should be allowed to call execute on the EOA
        // Note: in real scenario, EOA has delegation. Here we test the modifier only.
        // Since we're calling the implementation directly (not via delegation),
        // this tests the access control modifier accepts ENTRY_POINT.
        BatchExecutor(payable(eoaAddress)).execute(
            address(target),
            0,
            abi.encodeCall(MockTarget.setValue, (777))
        );
        assertEq(target.value(), 777);
    }

    // ─── validateUserOp ──────────────────────────────────────────────────

    function test_validateUserOp_valid_signature() public {
        bytes32 userOpHash = keccak256("test-userop-hash");

        // Sign the userOpHash with the EOA's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        vm.prank(executor.ENTRY_POINT());
        uint256 result = BatchExecutor(payable(eoaAddress)).validateUserOp(
            userOp,
            userOpHash,
            0
        );

        assertEq(result, 0, "Valid signature should return 0");
    }

    function test_validateUserOp_invalid_signature() public {
        bytes32 userOpHash = keccak256("test-userop-hash");

        // Sign with a different key
        uint256 wrongKey = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        vm.prank(executor.ENTRY_POINT());
        uint256 result = BatchExecutor(payable(eoaAddress)).validateUserOp(
            userOp,
            userOpHash,
            0
        );

        assertEq(result, 1, "Invalid signature should return 1");
    }

    function test_validateUserOp_short_signature() public {
        bytes32 userOpHash = keccak256("test-userop-hash");

        bytes memory signature = hex"DEADBEEF"; // Too short

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        vm.prank(executor.ENTRY_POINT());
        uint256 result = BatchExecutor(payable(eoaAddress)).validateUserOp(
            userOp,
            userOpHash,
            0
        );

        assertEq(result, 1, "Short signature should return 1 (invalid)");
    }

    function test_validateUserOp_pays_prefund() public {
        bytes32 userOpHash = keccak256("test-userop-hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        uint256 prefund = 0.01 ether;
        uint256 epBalanceBefore = executor.ENTRY_POINT().balance;

        vm.prank(executor.ENTRY_POINT());
        BatchExecutor(payable(eoaAddress)).validateUserOp(
            userOp,
            userOpHash,
            prefund
        );

        assertEq(
            executor.ENTRY_POINT().balance,
            epBalanceBefore + prefund,
            "EntryPoint should receive prefund"
        );
    }

    // ─── ERC-165 ─────────────────────────────────────────────────────────

    function test_supportsInterface_IAccount() public view {
        // IAccount interfaceId
        bytes4 iAccountId = bytes4(
            keccak256("validateUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)")
        );
        // We check the hardcoded value in the contract instead
        assertTrue(executor.supportsInterface(type(IAccount).interfaceId));
    }

    function test_supportsInterface_ERC165() public view {
        assertTrue(executor.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_random_false() public view {
        assertFalse(executor.supportsInterface(0xdeadbeef));
    }

    // ─── Receive ETH ────────────────────────────────────────────────────

    function test_receive_eth() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = payable(address(executor)).call{ value: 0.5 ether }("");
        assertTrue(ok);
        assertEq(address(executor).balance, 0.5 ether);
    }

    // ─── No Initialize / No Owner ────────────────────────────────────────

    function test_no_initialize_required() public view {
        // The contract should work immediately after delegation — no setup needed.
        // Verify there's no owner storage slot (slot 0 should be 0).
        bytes32 slot0 = vm.load(address(executor), bytes32(0));
        assertEq(slot0, bytes32(0), "No owner should be stored");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _dummyUserOp(bytes memory signature) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: eoaAddress,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });
    }
}
