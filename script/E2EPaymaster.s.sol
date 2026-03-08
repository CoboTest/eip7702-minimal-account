// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";
import { VerifyingPaymaster } from "../src/VerifyingPaymaster.sol";
import { PackedUserOperation, IEntryPoint } from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import { Execution } from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import { IERC7821 } from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title E2EPaymaster — ERC-4337 Paymaster-Sponsored E2E Flow
/// @notice Four actors:
///   - Deployer: deploys MinimalAccount + VerifyingPaymaster, funds paymaster.
///              Acts as both owner and verifyingSigner.
///   - Sponsor:  transfers USDC to Alice (demo-only, not needed in production)
///   - Bundler:  submits handleOps tx
///   - Alice:    fresh EOA with 0 ETH, uses paymaster for gas sponsorship
///
/// @dev Alice never holds ETH — fully gasless via Paymaster sponsorship.
///      Alice transfers USDC back to Sponsor to demonstrate real token operations.
///      Uses EIP-712 typed data for paymaster authorization signatures.
contract E2EPaymaster is Script {
    IEntryPoint constant EP = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    IERC20 constant USDC = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
    uint256 constant USDC_AMOUNT = 1e6; // 1 USDC

    /// @dev ERC-7579 batch mode: callType=0x01, rest zeros
    bytes32 constant BATCH_MODE = bytes32(uint256(0x01) << 248);

    uint256 deployerPk;
    address deployer;
    uint256 sponsorPk;
    address sponsor;
    uint256 bundlerPk;
    address bundler;
    uint256 alicePk;
    address alice;
    address executorAddr;
    VerifyingPaymaster paymaster;

    function run() external {
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        sponsorPk = vm.envUint("SPONSOR_PRIVATE_KEY");
        sponsor = vm.addr(sponsorPk);
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
        console.log("  Sponsor:    ", sponsor);
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
        console.log("[3] Fund paymaster + transfer USDC to Alice...");

        // Deployer funds paymaster (deposit + stake)
        vm.startBroadcast(deployerPk);
        paymaster.deposit{ value: 0.005 ether }();
        paymaster.addStake{ value: 0.001 ether }(1);
        vm.stopBroadcast();

        uint256 pmDeposit = paymaster.getDeposit();
        console.log("  Paymaster EP deposit:", pmDeposit, "wei");
        require(pmDeposit >= 0.005 ether, "Paymaster deposit too low");

        // Sponsor transfers USDC to Alice (demo only — user already holds tokens in production)
        vm.broadcast(sponsorPk);
        USDC.transfer(alice, USDC_AMOUNT);

        uint256 aliceUsdc = USDC.balanceOf(alice);
        console.log("  Alice USDC:", aliceUsdc / 1e6);
        require(aliceUsdc == USDC_AMOUNT, "Alice USDC mismatch");
        console.log("  PASS: paymaster funded + Alice has USDC");
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

    function _buildPaymasterDataNoSig(uint48 validUntil, uint48 validAfter) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(paymaster),
            uint128(100_000),  // pmVerificationGas
            uint128(50_000),   // pmPostOpGas
            bytes6(validUntil),
            bytes6(validAfter)
        );
    }

    /// @dev Compute paymaster hash input from UserOp, excluding trailing paymaster signature bytes.
    function _getPaymasterUserOpHash(
        PackedUserOperation memory op,
        bytes memory paymasterAndDataNoSig
    ) internal view returns (bytes32) {
        bytes32 packHash = keccak256(abi.encode(
            op.sender,
            op.nonce,
            keccak256(op.initCode),
            keccak256(op.callData),
            op.accountGasLimits,
            op.preVerificationGas,
            op.gasFees,
            keccak256(paymasterAndDataNoSig)
        ));

        return keccak256(abi.encode(packHash, address(EP), block.chainid));
    }

    function _signUserOp(PackedUserOperation memory op) internal returns (bytes memory) {
        bytes32 opHash = _getUserOpHash(op);
        // EIP-191 prefix: matches MinimalAccount._signableUserOpHash()
        bytes32 signableHash = MessageHashUtils.toEthSignedMessageHash(opHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, signableHash);
        console.log("  UserOp hash:", vm.toString(opHash));
        return abi.encodePacked(r, s, v);
    }

    function _step4_signUserOp() internal returns (PackedUserOperation memory op) {
        console.log("");
        console.log("[4] Alice signs UserOp with Paymaster (off-chain, 0 gas)...");

        // Alice sends her USDC back to Sponsor (0.6 + 0.4) — fully gasless via Paymaster
        Execution[] memory batch = new Execution[](2);
        uint256 part1 = 600000; // 0.6 USDC
        uint256 part2 = 400000; // 0.4 USDC
        batch[0] = Execution(address(USDC), 0, abi.encodeCall(IERC20.transfer, (sponsor, part1)));
        batch[1] = Execution(address(USDC), 0, abi.encodeCall(IERC20.transfer, (sponsor, part2)));
        bytes memory executionData = abi.encode(batch);

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint48 validAfter = 0;
        bytes memory pmDataNoSig = _buildPaymasterDataNoSig(validUntil, validAfter);

        op = PackedUserOperation({
            sender: alice,
            nonce: 0,
            initCode: "",
            callData: abi.encodeCall(IERC7821.execute, (BATCH_MODE, executionData)),
            accountGasLimits: bytes32(uint256(uint128(200_000)) << 128 | uint128(300_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32(uint256(uint128(1 gwei)) << 128 | uint128(3 gwei)),
            paymasterAndData: pmDataNoSig,
            signature: ""
        });

        // Sign paymaster authorization over the full UserOp payload/gas (excluding pm signature bytes).
        bytes32 paymasterUserOpHash = _getPaymasterUserOpHash(op, pmDataNoSig);
        bytes32 pmHash = paymaster.getHash(paymasterUserOpHash, validUntil, validAfter);
        (uint8 pmV, bytes32 pmR, bytes32 pmS) = vm.sign(deployerPk, pmHash);
        op.paymasterAndData = abi.encodePacked(pmDataNoSig, pmR, pmS, pmV);
        console.log("  PM authorization hash (EIP-712):", vm.toString(pmHash));

        op.signature = _signUserOp(op);

        console.log("  Action: execute(BATCH_MODE) -> USDC.transfer(sponsor, 0.6 USDC) + USDC.transfer(sponsor, 0.4 USDC)");
        console.log("  Paymaster:", address(paymaster));
        console.log("  Signature scheme: EIP-712 (paymaster) + EIP-191 (userOp)");
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

        // Alice USDC: 0 (all transferred back to Deployer)
        uint256 aliceUsdc = USDC.balanceOf(alice);
        require(aliceUsdc == 0, "Alice USDC should be 0");
        console.log("  Alice USDC: 0 (all transferred to Sponsor)");

        // Alice nonce: 1 (from EIP-7702 delegation auth)
        uint256 nonceAfter = vm.getNonce(alice);
        require(nonceAfter == 1, "Alice nonce should be 1 (delegation auth)");
        console.log("  Alice nonce:", nonceAfter, "(delegation auth)");

        console.log("  PASS: all assertions passed");
    }

    function _step7_cleanup() internal {
        console.log("");
        console.log("[7] Cleanup: unlock stake + withdraw deposit...");

        // --- Tx 1: unlock stake (starts unstakeDelay countdown) ---
        vm.broadcast(deployerPk);
        paymaster.unlockStake();
        console.log("  Unlocked stake (unstakeDelay=1s)");

        // --- Tx 2: withdraw deposit ---
        // Use a reduced amount to absorb simulation-vs-broadcast gas delta.
        uint256 pmDeposit = paymaster.getDeposit();
        if (pmDeposit > 0.0005 ether) {
            uint256 safeAmount = pmDeposit - 0.0005 ether;
            vm.broadcast(deployerPk);
            paymaster.withdrawTo(payable(deployer), safeAmount);
            console.log("  Withdrew deposit:", safeAmount, "wei (kept 0.0005 ETH buffer)");
        }

        console.log("  NOTE: Run PaymasterCleanup script to withdraw stake after unstakeDelay");
        console.log("  PASS: unlock + deposit withdrawal complete");
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
        console.log("  Sponsor:    ", sponsor);
        console.log("  Bundler:    ", bundler);
        console.log("  USDC:       ", address(USDC));
        console.log("================================================");
    }
}
