// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";
import { Account as OZAccount } from "@openzeppelin/contracts/account/Account.sol";
import { PackedUserOperation } from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import { Execution } from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

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

/// @dev Malicious contract that re-enters execute on receive.
contract ReentrantTarget {
    address public victim;
    bool public attacked;

    constructor(address _victim) {
        victim = _victim;
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            Execution[] memory batch = new Execution[](1);
            batch[0] = Execution(address(this), 0, "");
            bytes memory executionData = abi.encode(batch);
            bytes32 mode = bytes32(uint256(0x01) << 248); // CALLTYPE_BATCH
            MinimalAccount(payable(victim)).execute(mode, executionData);
        }
    }
}

contract MinimalAccountTest is Test {
    MinimalAccount public impl;
    MockTarget public target;

    // ERC-7579 batch mode: callType=0x01, execType=0x00, rest zeros
    bytes32 constant BATCH_MODE = bytes32(uint256(0x01) << 248);

    // EOA that will delegate to MinimalAccount via EIP-7702
    uint256 internal eoaPrivateKey = 0xA11CE;
    address internal eoaAddress;

    function setUp() public {
        eoaAddress = vm.addr(eoaPrivateKey);
        impl = new MinimalAccount();
        target = new MockTarget();
        vm.deal(eoaAddress, 10 ether);
        _setupDelegation();
    }

    function _setupDelegation() internal {
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(
            address(impl),
            eoaPrivateKey
        );
        vm.attachDelegation(signedDelegation);
    }

    // Helper: encode a batch of Execution[] for ERC7821
    function _encodeBatch(Execution[] memory batch) internal pure returns (bytes memory) {
        return abi.encode(batch);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      SINGLE EXECUTION (via batch mode)
    // ═══════════════════════════════════════════════════════════════════

    function test_execute_single() public {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (42)));

        vm.prank(eoaAddress);
        MinimalAccount(payable(eoaAddress)).execute(BATCH_MODE, _encodeBatch(batch));

        assertEq(target.value(), 42);
        assertEq(target.callCount(), 1);
    }

    function test_execute_single_with_value() public {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(address(target), 1 ether, "");

        vm.prank(eoaAddress);
        MinimalAccount(payable(eoaAddress)).execute{ value: 1 ether }(BATCH_MODE, _encodeBatch(batch));

        assertEq(address(target).balance, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      BATCH EXECUTION
    // ═══════════════════════════════════════════════════════════════════

    function test_executeBatch() public {
        Execution[] memory batch = new Execution[](3);
        batch[0] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (10)));
        batch[1] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (20)));
        batch[2] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (30)));

        vm.prank(eoaAddress);
        MinimalAccount(payable(eoaAddress)).execute(BATCH_MODE, _encodeBatch(batch));

        assertEq(target.value(), 30);
        assertEq(target.callCount(), 3);
    }

    function test_executeBatch_with_value() public {
        MockTarget target2 = new MockTarget();

        Execution[] memory batch = new Execution[](2);
        batch[0] = Execution(address(target), 0.5 ether, "");
        batch[1] = Execution(address(target2), 0.3 ether, "");

        vm.prank(eoaAddress);
        MinimalAccount(payable(eoaAddress)).execute{ value: 0.8 ether }(BATCH_MODE, _encodeBatch(batch));

        assertEq(address(target).balance, 0.5 ether);
        assertEq(address(target2).balance, 0.3 ether);
    }

    function test_executeBatch_empty() public {
        Execution[] memory batch = new Execution[](0);

        vm.prank(eoaAddress);
        MinimalAccount(payable(eoaAddress)).execute(BATCH_MODE, _encodeBatch(batch));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      REVERT HANDLING
    // ═══════════════════════════════════════════════════════════════════

    function test_execute_revert_propagates() public {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(address(target), 0, abi.encodeCall(MockTarget.reverting, ()));

        vm.prank(eoaAddress);
        vm.expectRevert();
        MinimalAccount(payable(eoaAddress)).execute(BATCH_MODE, _encodeBatch(batch));
    }

    function test_executeBatch_revert_on_failure() public {
        Execution[] memory batch = new Execution[](2);
        batch[0] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));
        batch[1] = Execution(address(target), 0, abi.encodeCall(MockTarget.reverting, ()));

        vm.prank(eoaAddress);
        vm.expectRevert();
        MinimalAccount(payable(eoaAddress)).execute(BATCH_MODE, _encodeBatch(batch));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

    function test_unauthorized_caller_reverts() public {
        address attacker = makeAddr("attacker");

        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (999)));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, attacker));
        MinimalAccount(payable(eoaAddress)).execute(BATCH_MODE, _encodeBatch(batch));
    }

    function test_entryPoint_can_call_execute() public {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (777)));

        vm.prank(address(impl.entryPoint()));
        MinimalAccount(payable(eoaAddress)).execute(BATCH_MODE, _encodeBatch(batch));
        assertEq(target.value(), 777);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    validateUserOp
    // ═══════════════════════════════════════════════════════════════════

    function test_validateUserOp_valid_signature() public {
        bytes32 userOpHash = keccak256("test-userop-hash");

        // OZ SignerEIP7702 uses raw signature (no personal_sign prefix)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        vm.prank(address(impl.entryPoint()));
        uint256 result = MinimalAccount(payable(eoaAddress)).validateUserOp(
            userOp, userOpHash, 0
        );

        assertEq(result, 0, "Valid signature should return 0");
    }

    function test_validateUserOp_invalid_signature() public {
        bytes32 userOpHash = keccak256("test-userop-hash");

        uint256 wrongKey = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        vm.prank(address(impl.entryPoint()));
        uint256 result = MinimalAccount(payable(eoaAddress)).validateUserOp(
            userOp, userOpHash, 0
        );

        assertEq(result, 1, "Invalid signature should return 1");
    }

    function test_validateUserOp_short_signature() public {
        bytes32 userOpHash = keccak256("test-userop-hash");
        bytes memory signature = hex"DEADBEEF";

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        vm.prank(address(impl.entryPoint()));
        uint256 result = MinimalAccount(payable(eoaAddress)).validateUserOp(
            userOp, userOpHash, 0
        );

        assertEq(result, 1, "Short signature should return 1 (invalid)");
    }

    function test_validateUserOp_pays_prefund() public {
        bytes32 userOpHash = keccak256("test-userop-hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        uint256 prefund = 0.01 ether;
        address ep = address(impl.entryPoint());
        uint256 epBalanceBefore = ep.balance;

        vm.prank(ep);
        MinimalAccount(payable(eoaAddress)).validateUserOp(
            userOp, userOpHash, prefund
        );

        assertEq(ep.balance, epBalanceBefore + prefund, "EntryPoint should receive prefund");
    }

    function test_validateUserOp_pays_prefund_even_on_invalid_sig() public {
        bytes32 userOpHash = keccak256("test-userop-hash");

        // Sign with wrong key
        uint256 wrongKey = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(signature);

        uint256 prefund = 0.01 ether;
        address ep = address(impl.entryPoint());
        uint256 epBalanceBefore = ep.balance;

        // OZ Account always pays prefund, even when sig is invalid
        vm.prank(ep);
        uint256 result = MinimalAccount(payable(eoaAddress)).validateUserOp(
            userOp, userOpHash, prefund
        );

        assertEq(result, 1, "Invalid signature should return 1");
        assertEq(ep.balance, epBalanceBefore + prefund, "Prefund should be paid even on invalid sig");
    }

    function test_validateUserOp_onlyEntryPoint() public {
        bytes32 userOpHash = keccak256("test-userop-hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        PackedUserOperation memory userOp = _dummyUserOp(signature);

        // EOA itself should NOT be able to call validateUserOp
        vm.prank(eoaAddress);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, eoaAddress));
        MinimalAccount(payable(eoaAddress)).validateUserOp(userOp, userOpHash, 0);

        // Random address should NOT be able to call validateUserOp
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, random));
        MinimalAccount(payable(eoaAddress)).validateUserOp(userOp, userOpHash, 0);
    }

    function test_validateUserOp_all_zero_signature() public {
        bytes32 userOpHash = keccak256("test-zero-sig");
        bytes memory signature = new bytes(65);
        PackedUserOperation memory userOp = _dummyUserOp(signature);

        vm.prank(address(impl.entryPoint()));
        uint256 result = MinimalAccount(payable(eoaAddress)).validateUserOp(
            userOp, userOpHash, 0
        );
        assertEq(result, 1, "All-zero signature should return SIG_VALIDATION_FAILED");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      ERC-165
    // ═══════════════════════════════════════════════════════════════════

    function test_supportsInterface_ERC165() public view {
        assertTrue(impl.supportsInterface(0x01ffc9a7));
    }

    function test_supportsInterface_random_false() public view {
        assertFalse(impl.supportsInterface(0xdeadbeef));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      RECEIVE ETH
    // ═══════════════════════════════════════════════════════════════════

    function test_receive_eth() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = payable(address(impl)).call{ value: 0.5 ether }("");
        assertTrue(ok);
        assertEq(address(impl).balance, 0.5 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    NO INITIALIZE / NO OWNER
    // ═══════════════════════════════════════════════════════════════════

    function test_no_initialize_required() public view {
        bytes32 slot0 = vm.load(address(impl), bytes32(0));
        assertEq(slot0, bytes32(0), "No owner should be stored");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      REENTRANCY
    // ═══════════════════════════════════════════════════════════════════

    function test_executeBatch_reentrant_target_reverts() public {
        ReentrantTarget reentrant = new ReentrantTarget(eoaAddress);

        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(address(reentrant), 0.1 ether, "");

        // Re-entrant call from ReentrantTarget → AccountUnauthorized
        vm.prank(eoaAddress);
        vm.expectRevert();
        MinimalAccount(payable(eoaAddress)).execute{ value: 0.1 ether }(BATCH_MODE, _encodeBatch(batch));
    }

    // ═══════════════════════════════════════════════════════════════════
    //              ADDITIONAL EDGE CASES
    // ═══════════════════════════════════════════════════════════════════

    function test_validateUserOp_zero_prefund_zero_balance_no_revert() public {
        // Drain EOA
        uint256 bal = eoaAddress.balance;
        vm.prank(eoaAddress);
        (bool ok,) = payable(address(0xdead)).call{ value: bal }("");
        assertTrue(ok);
        assertEq(eoaAddress.balance, 0);

        bytes32 userOpHash = keccak256("test-zero-prefund");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        PackedUserOperation memory userOp = _dummyUserOp(signature);

        // missingAccountFunds == 0, balance == 0 → should NOT revert
        vm.prank(address(impl.entryPoint()));
        uint256 result = MinimalAccount(payable(eoaAddress)).validateUserOp(
            userOp, userOpHash, 0
        );
        assertEq(result, 0, "Valid sig + zero prefund should succeed");
    }

    function test_executeBatch_insufficient_value_reverts() public {
        Execution[] memory batch = new Execution[](2);
        batch[0] = Execution(address(target), 1 ether, "");
        batch[1] = Execution(address(target), 1 ether, "");

        vm.deal(eoaAddress, 0.5 ether);
        _setupDelegation();

        vm.prank(eoaAddress);
        vm.expectRevert();
        MinimalAccount(payable(eoaAddress)).execute{ value: 0.5 ether }(BATCH_MODE, _encodeBatch(batch));
    }

    function test_supportsExecutionMode() public view {
        assertTrue(MinimalAccount(payable(eoaAddress)).supportsExecutionMode(BATCH_MODE));
        // Random mode should not be supported
        assertFalse(MinimalAccount(payable(eoaAddress)).supportsExecutionMode(bytes32(0)));
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
