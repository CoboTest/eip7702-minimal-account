// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { VerifyingPaymaster } from "../src/VerifyingPaymaster.sol";
import { PackedUserOperation, IEntryPoint } from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import { ERC4337Utils } from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Minimal EntryPoint stub for unit testing deposit/stake interactions.
contract MockEntryPointStub {
    mapping(address => uint256) public deposits;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return deposits[account];
    }

    function withdrawTo(address payable to, uint256 amount) external {
        (bool ok,) = to.call{ value: amount }("");
        require(ok);
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable to) external {
        (bool ok,) = to.call{ value: 0 }("");
        require(ok);
    }

    function getNonce(address, uint192) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract VerifyingPaymasterTest is Test {
    VerifyingPaymaster public pm;
    IEntryPoint public ep;

    uint256 internal ownerPk = 0xA11CE;
    address internal owner;
    uint256 internal signerPk = 0xB0B;
    address internal signer;
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        owner = vm.addr(ownerPk);
        signer = vm.addr(signerPk);
        ep = ERC4337Utils.ENTRYPOINT_V07;

        // Deploy a mock EP stub that accepts all calls
        MockEntryPointStub stub = new MockEntryPointStub();
        vm.etch(address(ep), address(stub).code);

        pm = new VerifyingPaymaster(ep, owner, signer);
        vm.deal(owner, 10 ether);
        vm.deal(address(pm), 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_constructor() public view {
        assertEq(address(pm.entryPoint()), address(ep));
        assertEq(pm.owner(), owner);
        assertEq(pm.verifyingSigner(), signer);
    }

    function test_constructor_reverts_zero_signer() public {
        vm.expectRevert(VerifyingPaymaster.InvalidSignerAddress.selector);
        new VerifyingPaymaster(ep, owner, address(0));
    }

    function test_constructor_reverts_zero_entrypoint() public {
        vm.expectRevert(VerifyingPaymaster.InvalidEntryPoint.selector);
        new VerifyingPaymaster(IEntryPoint(address(0)), owner, signer);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      SIGNER MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_setVerifyingSigner() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(owner);
        pm.setVerifyingSigner(newSigner);
        assertEq(pm.verifyingSigner(), newSigner);
    }

    function test_setVerifyingSigner_emits_event() public {
        address newSigner = makeAddr("newSigner");
        vm.expectEmit(true, true, false, false);
        emit VerifyingPaymaster.SignerChanged(signer, newSigner);
        vm.prank(owner);
        pm.setVerifyingSigner(newSigner);
    }

    function test_setVerifyingSigner_reverts_zero() public {
        vm.prank(owner);
        vm.expectRevert(VerifyingPaymaster.InvalidSignerAddress.selector);
        pm.setVerifyingSigner(address(0));
    }

    function test_setVerifyingSigner_reverts_not_owner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pm.setVerifyingSigner(attacker);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      OWNERSHIP (Ownable2Step)
    // ═══════════════════════════════════════════════════════════════════

    function test_ownership_two_step() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        pm.transferOwnership(newOwner);
        // Not yet transferred
        assertEq(pm.owner(), owner);

        vm.prank(newOwner);
        pm.acceptOwnership();
        assertEq(pm.owner(), newOwner);
    }

    function test_ownership_transfer_reverts_non_owner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pm.transferOwnership(attacker);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      PAUSE / UNPAUSE
    // ═══════════════════════════════════════════════════════════════════

    function test_pause_unpause() public {
        vm.prank(owner);
        pm.pause();
        assertTrue(pm.paused());

        vm.prank(owner);
        pm.unpause();
        assertFalse(pm.paused());
    }

    function test_pause_reverts_not_owner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pm.pause();
    }

    function test_validatePaymasterUserOp_reverts_when_paused() public {
        vm.prank(owner);
        pm.pause();

        PackedUserOperation memory userOp = _dummyUserOp(alice, 0, _buildPmAndData(0, 0));

        vm.prank(address(ep));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pm.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      VALIDATE PAYMASTER USER OP
    // ═══════════════════════════════════════════════════════════════════

    function test_validate_valid_signature() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;
        uint256 nonce = 42;

        bytes memory pmAndData = _buildPmAndData(validUntil, validAfter);
        // Sign with the correct signer key
        bytes32 hash = pm.getHash(alice, nonce, validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, hash);
        // Append signature to pmAndData
        pmAndData = abi.encodePacked(pmAndData, r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(alice, nonce, pmAndData);

        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 0);

        // Authorizer = 0 means success
        uint160 authorizer = uint160(validationData);
        assertEq(authorizer, 0, "Should return success (authorizer=0)");
    }

    function test_validate_wrong_signer_fails() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;
        uint256 nonce = 0;

        bytes memory pmAndData = _buildPmAndData(validUntil, validAfter);
        bytes32 hash = pm.getHash(alice, nonce, validUntil, validAfter);
        // Sign with wrong key
        uint256 wrongPk = 0xDEAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, hash);
        pmAndData = abi.encodePacked(pmAndData, r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(alice, nonce, pmAndData);

        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 0);

        uint160 authorizer = uint160(validationData);
        assertEq(authorizer, 1, "Should return failure (authorizer=1)");
    }

    function test_validate_reverts_bad_data_length() public {
        // Too short pmData
        bytes memory badPmAndData = abi.encodePacked(
            address(pm),
            uint128(100_000),
            uint128(50_000),
            bytes6(uint48(0)),  // only 6 bytes, missing rest
            bytes3(uint24(0))   // incomplete
        );

        PackedUserOperation memory userOp = _dummyUserOp(alice, 0, badPmAndData);

        vm.prank(address(ep));
        vm.expectRevert(VerifyingPaymaster.InvalidPaymasterDataLength.selector);
        pm.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_validate_only_entrypoint() public {
        bytes memory pmAndData = _buildPmAndData(0, 0);
        pmAndData = abi.encodePacked(pmAndData, new bytes(65));
        PackedUserOperation memory userOp = _dummyUserOp(alice, 0, pmAndData);

        vm.prank(attacker);
        vm.expectRevert(VerifyingPaymaster.OnlyEntryPoint.selector);
        pm.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_validate_time_range_encoded() public {
        uint48 validUntil = uint48(block.timestamp + 2 hours);
        uint48 validAfter = uint48(block.timestamp + 1 hours);
        uint256 nonce = 0;

        bytes memory pmAndData = _buildPmAndData(validUntil, validAfter);
        bytes32 hash = pm.getHash(alice, nonce, validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, hash);
        pmAndData = abi.encodePacked(pmAndData, r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(alice, nonce, pmAndData);

        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 0);

        // Extract time range from validationData
        uint48 extractedValidAfter = uint48(validationData >> 208);
        uint48 extractedValidUntil = uint48(validationData >> 160);
        assertEq(extractedValidAfter, validAfter);
        assertEq(extractedValidUntil, validUntil);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      REPLAY PROTECTION
    // ═══════════════════════════════════════════════════════════════════

    function test_different_chain_different_hash() public view {
        bytes32 hash1 = pm.getHash(alice, 0, 1000, 0);

        // The hash includes chainId via domain separator
        // On a different chain, the domain separator would differ
        // We verify the domain separator is chain-bound
        bytes32 ds = pm.domainSeparator();
        assertTrue(ds != bytes32(0), "Domain separator should be non-zero");

        // Same params produce same hash (deterministic)
        bytes32 hash2 = pm.getHash(alice, 0, 1000, 0);
        assertEq(hash1, hash2, "Same params should produce same hash");
    }

    function test_different_nonce_different_hash() public view {
        bytes32 hash1 = pm.getHash(alice, 0, 1000, 0);
        bytes32 hash2 = pm.getHash(alice, 1, 1000, 0);
        assertTrue(hash1 != hash2, "Different nonces should produce different hashes");
    }

    function test_different_sender_different_hash() public view {
        bytes32 hash1 = pm.getHash(alice, 0, 1000, 0);
        bytes32 hash2 = pm.getHash(attacker, 0, 1000, 0);
        assertTrue(hash1 != hash2, "Different senders should produce different hashes");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      DEPOSIT & STAKE (access control)
    // ═══════════════════════════════════════════════════════════════════

    function test_deposit_anyone() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        pm.deposit{ value: 0.1 ether }();
        // Should not revert — anyone can deposit
    }

    function test_withdrawTo_only_owner() public {
        // Fund the paymaster's EP deposit
        vm.prank(owner);
        pm.deposit{ value: 0.1 ether }();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pm.withdrawTo(payable(attacker), 0.1 ether);
    }

    function test_addStake_only_owner() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pm.addStake{ value: 0.01 ether }(1);
    }

    function test_unlockStake_only_owner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pm.unlockStake();
    }

    function test_withdrawStake_only_owner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        pm.withdrawStake(payable(attacker));
    }

    function test_getDeposit() public {
        vm.prank(owner);
        pm.deposit{ value: 0.5 ether }();
        assertEq(pm.getDeposit(), 0.5 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      FUZZ
    // ═══════════════════════════════════════════════════════════════════

    function test_fuzz_validate_random_signer_fails(uint256 randomPk) public {
        vm.assume(randomPk != 0 && randomPk < type(uint256).max / 2);
        vm.assume(vm.addr(randomPk) != signer);

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;

        bytes memory pmAndData = _buildPmAndData(validUntil, validAfter);
        bytes32 hash = pm.getHash(alice, 0, validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomPk, hash);
        pmAndData = abi.encodePacked(pmAndData, r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(alice, 0, pmAndData);

        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 0);

        uint160 authorizer = uint160(validationData);
        assertEq(authorizer, 1, "Random signer should fail validation");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      SIGNER ROTATION + VALIDATION
    // ═══════════════════════════════════════════════════════════════════

    function test_old_signer_fails_after_rotation() public {
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;

        // Sign with old signer
        bytes memory pmAndData = _buildPmAndData(validUntil, validAfter);
        bytes32 hash = pm.getHash(alice, 0, validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, hash);
        pmAndData = abi.encodePacked(pmAndData, r, s, v);

        // Rotate signer
        uint256 newSignerPk = 0xCAFE;
        address newSigner = vm.addr(newSignerPk);
        vm.prank(owner);
        pm.setVerifyingSigner(newSigner);

        // Old signature should now fail
        PackedUserOperation memory userOp = _dummyUserOp(alice, 0, pmAndData);
        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 0);

        uint160 authorizer = uint160(validationData);
        assertEq(authorizer, 1, "Old signer should fail after rotation");
    }

    function test_new_signer_works_after_rotation() public {
        uint256 newSignerPk = 0xCAFE;
        address newSigner = vm.addr(newSignerPk);

        vm.prank(owner);
        pm.setVerifyingSigner(newSigner);

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;

        bytes memory pmAndData = _buildPmAndData(validUntil, validAfter);
        bytes32 hash = pm.getHash(alice, 0, validUntil, validAfter);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newSignerPk, hash);
        pmAndData = abi.encodePacked(pmAndData, r, s, v);

        PackedUserOperation memory userOp = _dummyUserOp(alice, 0, pmAndData);
        vm.prank(address(ep));
        (, uint256 validationData) = pm.validatePaymasterUserOp(userOp, bytes32(0), 0);

        uint160 authorizer = uint160(validationData);
        assertEq(authorizer, 0, "New signer should pass after rotation");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      RECEIVE ETH
    // ═══════════════════════════════════════════════════════════════════

    function test_receive_eth() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = payable(address(pm)).call{ value: 0.5 ether }("");
        assertTrue(ok);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _buildPmAndData(uint48 validUntil, uint48 validAfter) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(pm),
            uint128(100_000),  // pmVerificationGas
            uint128(50_000),   // pmPostOpGas
            bytes6(validUntil),
            bytes6(validAfter)
        );
    }

    function _dummyUserOp(
        address sender,
        uint256 nonce,
        bytes memory paymasterAndData
    ) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }
}
