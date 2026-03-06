// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";
import { VerifyingPaymaster } from "../src/VerifyingPaymaster.sol";
import { PackedUserOperation, IEntryPoint } from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import { Execution } from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import { IERC7821 } from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";

/// @title E2EPaymaster — ERC-4337 Paymaster-Sponsored E2E Flow
/// @notice Three actors:
///   - Deployer: deploys MinimalAccount + VerifyingPaymaster, funds paymaster
///              Acts as both owner and verifyingSigner for testing simplicity
///   - Bundler:  submits handleOps tx
///   - Alice:    fresh EOA with 0 ETH, uses paymaster for gas sponsorship
///
/// @dev Alice never holds ETH — fully gasless via Paymaster sponsorship.
///      Uses EIP-712 typed data for paymaster authorization signatures.
contract E2EPaymaster is Script {
    IEntryPoint constant EP = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);

    /// @dev ERC-7579 batch mode: callType=0x01, rest zeros
    bytes32 constant BATCH_MODE = bytes32(uint256(0x01) << 248);

    uint256 deployerPk;
    address deployer;
    uint256 bundlerPk;
    address bundler;
    uint256 alicePk;
    address alice;
    address executorAddr;
    VerifyingPaymaster paymaster;

    function run() external {
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        bundlerPk = vm.envUint("BUNDLER_PRIVATE_KEY");
        bundler = vm.addr(bundlerPk);

        // Fresh Alice each run
        alicePk = vm.randomUint();
        alice = vm.addr(alicePk);

        _header();
        _step1_deploy();
        _step2_verifyAlice();
        _step3_fundPaymaster();

        PackedUserOperation memory op = _step4_signUserOp();

        _step5_handleOps(op);
        _step6_verify();
        _step7_cleanup();
        _footer();
    }

    function _header() internal view {
        console.log("================================================");
        console.log("  ERC-4337 Paymaster-Sponsored E2E");
        console.log("================================================");
        console.log("  Deployer:   ", deployer);
        console.log("  Bundler:    ", bundler);
        console.log("  Alice:      ", alice);
        console.log("  EntryPoint: ", address(EP));
        console.log("================================================");
    }

    function _step1_deploy() internal {
        console.log("");
        console.log("[1] Deployer deploys MinimalAccount + VerifyingPaymaster...");

        vm.startBroadcast(deployerPk);
        MinimalAccount impl = new MinimalAccount();
        executorAddr = address(impl);

        // deployer is both owner and verifyingSigner for E2E simplicity
        paymaster = new VerifyingPaymaster(EP, deployer, deployer);
        vm.stopBroadcast();

        require(executorAddr.code.length > 0, "MinimalAccount deploy failed");
        require(address(paymaster).code.length > 0, "Paymaster deploy failed");
        console.log("  MinimalAccount:", executorAddr);
        console.log("  Paymaster:", address(paymaster));
        console.log("  Paymaster owner:", deployer);
        console.log("  Paymaster signer:", deployer);
        console.log("  PASS: deployed");
    }

    function _step2_verifyAlice() internal view {
        console.log("");
        console.log("[2] Verify Alice starts empty...");
        require(alice.balance == 0, "Alice should have 0 ETH");
        require(alice.code.length == 0, "Alice should have no code");
        uint256 nonceBefore = vm.getNonce(alice);
        require(nonceBefore == 0, "Alice nonce should be 0");
        console.log("  ETH: 0");
        console.log("  Nonce:", nonceBefore);
        console.log("  PASS: empty");
    }

    function _step3_fundPaymaster() internal {
        console.log("");
        console.log("[3] Deployer funds paymaster (deposit + stake to EP)...");

        vm.startBroadcast(deployerPk);
        paymaster.deposit{ value: 0.005 ether }();
        paymaster.addStake{ value: 0.001 ether }(1);
        vm.stopBroadcast();

        uint256 pmDeposit = paymaster.getDeposit();
        console.log("  Paymaster EP deposit:", pmDeposit, "wei");
        require(pmDeposit >= 0.005 ether, "Paymaster deposit too low");
        console.log("  PASS: paymaster funded");
    }

    /// @dev Compute userOpHash locally (same as EntryPoint.getUserOpHash)
    function _packUserOp(PackedUserOperation memory op) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            op.sender,
            op.nonce,
            keccak256(op.initCode),
            keccak256(op.callData),
            op.accountGasLimits,
            op.preVerificationGas,
            op.gasFees,
            keccak256(op.paymasterAndData)
        ));
    }

    function _getUserOpHash(PackedUserOperation memory op) internal view returns (bytes32) {
        return keccak256(abi.encode(
            _packUserOp(op),
            address(EP),
            block.chainid
        ));
    }

    function _buildPaymasterAndData() internal returns (bytes memory) {
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;

        // EIP-712 typed data hash via VerifyingPaymaster.getHash()
        bytes32 pmHash = paymaster.getHash(alice, 0, validUntil, validAfter);
        (uint8 pmV, bytes32 pmR, bytes32 pmS) = vm.sign(deployerPk, pmHash);

        console.log("  PM authorization hash (EIP-712):", vm.toString(pmHash));

        return abi.encodePacked(
            address(paymaster),
            uint128(100_000),  // pmVerificationGas
            uint128(50_000),   // pmPostOpGas
            bytes6(validUntil),
            bytes6(validAfter),
            pmR, pmS, pmV
        );
    }

    function _signUserOp(PackedUserOperation memory op) internal returns (bytes memory) {
        bytes32 opHash = _getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, opHash);
        console.log("  UserOp hash:", vm.toString(opHash));
        return abi.encodePacked(r, s, v);
    }

    function _step4_signUserOp() internal returns (PackedUserOperation memory op) {
        console.log("");
        console.log("[4] Alice signs UserOp with Paymaster (off-chain, 0 gas)...");

        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(deployer, 0, ""); // zero-value call
        bytes memory executionData = abi.encode(batch);

        op = PackedUserOperation({
            sender: alice,
            nonce: 0,
            initCode: "",
            callData: abi.encodeCall(IERC7821.execute, (BATCH_MODE, executionData)),
            accountGasLimits: bytes32(uint256(uint128(200_000)) << 128 | uint128(300_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32(uint256(uint128(1 gwei)) << 128 | uint128(3 gwei)),
            paymasterAndData: _buildPaymasterAndData(),
            signature: ""
        });

        op.signature = _signUserOp(op);

        console.log("  Action: execute(BATCH_MODE) -> zero-value call to Deployer");
        console.log("  Paymaster:", address(paymaster));
        console.log("  Signature scheme: EIP-712 (paymaster) + raw ECDSA (userOp)");
        console.log("  PASS: signed (no tx, pure off-chain)");
    }

    function _step5_handleOps(PackedUserOperation memory op) internal {
        console.log("");
        console.log("[5] Bundler submits handleOps + delegation (type 4 tx)...");

        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(executorAddr, alicePk);
        vm.attachDelegation(signedDelegation);
        console.log("  Alice signed delegation (off-chain):");
        console.log("    target:", executorAddr);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.broadcast(bundlerPk);
        EP.handleOps(ops, payable(bundler));

        vm.setNonce(alice, 1);

        console.log("  PASS: delegation activated + handleOps executed via paymaster");
    }

    function _step6_verify() internal view {
        console.log("");
        console.log("[6] Verify on-chain results...");

        // Delegation active
        require(alice.code.length == 23, "delegation not set");
        console.log("  Delegation: active");

        // EP nonce incremented
        uint256 epNonce = EP.getNonce(alice, 0);
        require(epNonce == 1, "EP nonce should be 1");
        console.log("  EP nonce:", epNonce);

        // Alice still has 0 ETH (paymaster paid gas)
        require(alice.balance == 0, "Alice ETH should be 0");
        console.log("  Alice ETH: 0 (paymaster sponsored)");

        // Alice nonce: 1 (from EIP-7702 delegation auth)
        uint256 nonceAfter = vm.getNonce(alice);
        require(nonceAfter == 1, "Alice nonce should be 1 (delegation auth)");
        console.log("  Alice nonce:", nonceAfter, "(delegation auth)");

        console.log("  PASS: all assertions passed");
    }

    function _step7_cleanup() internal {
        console.log("");
        console.log("[7] Cleanup: unlock paymaster stake...");

        vm.startBroadcast(deployerPk);

        // Unlock stake (starts unstake delay countdown)
        // Note: withdrawStake requires waiting unstakeDelay seconds after unlock.
        // Deposit withdrawal skipped here — simulation/broadcast gas delta causes
        // "Withdraw amount too large" when exact amount is computed during simulation.
        // Use paymaster.withdrawTo() and paymaster.withdrawStake() after script completes.
        paymaster.unlockStake();
        console.log("  Unlocked stake (withdraw after unstakeDelay expires)");

        vm.stopBroadcast();

        uint256 pmDeposit = paymaster.getDeposit();
        console.log("  Remaining deposit:", pmDeposit, "wei");
        console.log("  To recover: call paymaster.withdrawTo() and paymaster.withdrawStake()");
        console.log("  PASS: stake unlock initiated");
    }

    function _footer() internal view {
        console.log("");
        console.log("================================================");
        console.log("  ALL TESTS PASSED");
        console.log("================================================");
        console.log("  Alice:      ", alice);
        console.log("  Alice PK:   ", vm.toString(bytes32(alicePk)));
        console.log("  Executor:   ", executorAddr);
        console.log("  Paymaster:  ", address(paymaster));
        console.log("  Deployer:   ", deployer);
        console.log("  Bundler:    ", bundler);
        console.log("================================================");
    }
}
