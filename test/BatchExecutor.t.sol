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
        _setupDelegation();
    }

    function _setupDelegation() internal {
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(
            address(executor),
            eoaPrivateKey
        );
        vm.attachDelegation(signedDelegation);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      SINGLE EXECUTION
    // ═══════════════════════════════════════════════════════════════════

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

    function test_execute_emits_Executed_event() public {
        vm.prank(eoaAddress);
        vm.expectEmit(true, false, false, false);
        emit BatchExecutor.Executed(address(target), 0, "");
        BatchExecutor(payable(eoaAddress)).execute(
            address(target),
            0,
            abi.encodeCall(MockTarget.setValue, (42))
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      BATCH EXECUTION
    // ═══════════════════════════════════════════════════════════════════

    function test_executeBatch() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](3);
        calls[0] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (10)));
        calls[1] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (20)));
        calls[2] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (30)));

        vm.prank(eoaAddress);
        BatchExecutor(payable(eoaAddress)).executeBatch(calls);

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
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      REVERT HANDLING
    // ═══════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════
    //                      ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

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

    function test_entryPoint_can_call_execute() public {
        vm.prank(executor.ENTRY_POINT());
        BatchExecutor(payable(eoaAddress)).execute(
            address(target),
            0,
            abi.encodeCall(MockTarget.setValue, (777))
        );
        assertEq(target.value(), 777);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      SELF-CALL PREVENTION
    // ═══════════════════════════════════════════════════════════════════

    function test_execute_selfCall_reverts() public {
        vm.prank(eoaAddress);
        vm.expectRevert(BatchExecutor.SelfCallNotAllowed.selector);
        BatchExecutor(payable(eoaAddress)).execute(
            eoaAddress,  // self-call
            0,
            abi.encodeCall(MockTarget.setValue, (42))
        );
    }

    function test_executeBatch_selfCall_reverts() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(address(target), 0, abi.encodeCall(MockTarget.setValue, (10)));
        calls[1] = BatchExecutor.Call(eoaAddress, 0, "");  // self-call in batch

        vm.prank(eoaAddress);
        vm.expectRevert(BatchExecutor.SelfCallNotAllowed.selector);
        BatchExecutor(payable(eoaAddress)).executeBatch(calls);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    validateUserOp
    // ═══════════════════════════════════════════════════════════════════

    function test_validateUserOp_valid_signature() public {
        bytes32 userOpHash = keccak256("test-userop-hash");

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

        bytes memory signature = hex"DEADBEEF";

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

    function test_validateUserOp_onlyEntryPoint() public {
        bytes32 userOpHash = keccak256("test-userop-hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        PackedUserOperation memory userOp = _dummyUserOp(signature);

        // EOA itself should NOT be able to call validateUserOp
        vm.prank(eoaAddress);
        vm.expectRevert(BatchExecutor.OnlyEntryPoint.selector);
        BatchExecutor(payable(eoaAddress)).validateUserOp(userOp, userOpHash, 0);

        // Random address should NOT be able to call validateUserOp
        vm.prank(makeAddr("random"));
        vm.expectRevert(BatchExecutor.OnlyEntryPoint.selector);
        BatchExecutor(payable(eoaAddress)).validateUserOp(userOp, userOpHash, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      ERC-165
    // ═══════════════════════════════════════════════════════════════════

    function test_supportsInterface_IAccount() public view {
        assertTrue(executor.supportsInterface(type(IAccount).interfaceId));
    }

    function test_supportsInterface_ERC165() public view {
        assertTrue(executor.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_random_false() public view {
        assertFalse(executor.supportsInterface(0xdeadbeef));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      RECEIVE ETH
    // ═══════════════════════════════════════════════════════════════════

    function test_receive_eth() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = payable(address(executor)).call{ value: 0.5 ether }("");
        assertTrue(ok);
        assertEq(address(executor).balance, 0.5 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    NO INITIALIZE / NO OWNER
    // ═══════════════════════════════════════════════════════════════════

    function test_no_initialize_required() public view {
        bytes32 slot0 = vm.load(address(executor), bytes32(0));
        assertEq(slot0, bytes32(0), "No owner should be stored");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      HELPERS
    // ═══════════════════════════════════════════════════════════════════

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
