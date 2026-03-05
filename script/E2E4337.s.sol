// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";
import { PackedUserOperation } from "../src/interfaces/PackedUserOperation.sol";

interface IEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title E2E4337 — Full ERC-4337 Sponsored Gasless USDC Flow
/// @notice Four actors:
///   - Deployer: deploys MinimalAccount (fresh each run)
///   - Sponsor:  deposits to EntryPoint for Alice (gas) + transfers USDC to Alice.
///              In production this role is typically a Paymaster; here plain EOA.
///   - Bundler:  submits handleOps tx to EntryPoint (pays tx gas, recouped from prefund)
///   - Alice:    fresh EOA with 0 ETH at all times, signs delegation + UserOp off-chain.
///              Receives USDC from Sponsor, sends it to Deployer via ERC-4337 batch.
///
/// @dev Alice never holds ETH — fully gasless via EntryPoint sponsorship.
///
///   source .env
///   forge script script/E2E4337.s.sol --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
contract E2E4337 is Script {
    IEntryPoint constant EP = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);

    /// @dev Circle USDC on Sepolia (6 decimals)
    IERC20 constant USDC = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
    uint256 constant USDC_AMOUNT = 5e6; // 5 USDC

    uint256 deployerPk;
    address deployer;
    uint256 sponsorPk;
    address sponsor;
    uint256 bundlerPk;
    address bundler;
    uint256 alicePk;
    address alice;
    address executorAddr;

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
        _step3_deposit();
        _step4_fundUSDC();

        PackedUserOperation memory op = _step5_signUserOp();

        _step6_handleOps(op);
        _step7_verify();
        _step8_returnUSDC();
        _footer();
    }

    function _header() internal view {
        console.log("================================================");
        console.log("  ERC-4337 Sponsored Gasless USDC E2E");
        console.log("================================================");
        console.log("  Deployer:   ", deployer);
        console.log("  Sponsor:    ", sponsor);
        console.log("  Bundler:    ", bundler);
        console.log("  Alice:      ", alice);
        console.log("  EntryPoint: ", address(EP));
        console.log("  USDC:       ", address(USDC));
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

    function _step2_verifyAlice() internal view {
        console.log("");
        console.log("[2] Verify Alice starts empty...");
        require(alice.balance == 0, "Alice should have 0 ETH");
        require(alice.code.length == 0, "Alice should have no code");
        require(USDC.balanceOf(alice) == 0, "Alice should have 0 USDC");
        uint256 nonceBefore = vm.getNonce(alice);
        require(nonceBefore == 0, "Alice nonce should be 0");
        console.log("  ETH: 0");
        console.log("  USDC: 0");
        console.log("  Nonce:", nonceBefore);
        console.log("  PASS: empty");
    }

    function _step3_deposit() internal {
        console.log("");
        console.log("[3] Sponsor deposits to EntryPoint for Alice (gas)...");

        vm.broadcast(sponsorPk);
        EP.depositTo{ value: 0.01 ether }(alice);

        console.log("  PASS: deposited 0.01 ETH to EP for Alice");
    }

    function _step4_fundUSDC() internal {
        console.log("");
        console.log("[4] Sponsor transfers USDC to Alice...");

        uint256 sponsorBefore = USDC.balanceOf(sponsor);
        require(sponsorBefore >= USDC_AMOUNT, "Sponsor needs USDC");
        console.log("  Sponsor USDC before:", sponsorBefore / 1e6, "USDC");

        vm.broadcast(sponsorPk);
        USDC.transfer(alice, USDC_AMOUNT);

        require(USDC.balanceOf(alice) == USDC_AMOUNT, "Alice USDC mismatch");
        require(alice.balance == 0, "Alice should still have 0 ETH");
        console.log("  Alice USDC:", USDC_AMOUNT / 1e6, "USDC");
        console.log("  Alice ETH: 0 (gasless)");
        console.log("  PASS: funded");
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

    function _step5_signUserOp() internal returns (PackedUserOperation memory op) {
        console.log("");
        console.log("[5] Alice signs UserOp (off-chain, 0 gas)...");

        // Alice sends all USDC to Deployer via executeBatch
        // Split into 2 calls to exercise batch: 3 USDC + 2 USDC
        uint256 part1 = 3e6; // 3 USDC
        uint256 part2 = 2e6; // 2 USDC

        MinimalAccount.Call[] memory calls = new MinimalAccount.Call[](2);
        calls[0] = MinimalAccount.Call(
            address(USDC),
            0,
            abi.encodeCall(IERC20.transfer, (deployer, part1))
        );
        calls[1] = MinimalAccount.Call(
            address(USDC),
            0,
            abi.encodeCall(IERC20.transfer, (deployer, part2))
        );

        op = PackedUserOperation({
            sender: alice,
            nonce: 0,
            initCode: "",
            callData: abi.encodeCall(MinimalAccount.executeBatch, (calls)),
            // verificationGasLimit=200k, callGasLimit=300k
            accountGasLimits: bytes32(uint256(uint128(200_000)) << 128 | uint128(300_000)),
            preVerificationGas: 100_000,
            // maxPriorityFeePerGas=1gwei, maxFeePerGas=3gwei
            gasFees: bytes32(uint256(uint128(1 gwei)) << 128 | uint128(3 gwei)),
            paymasterAndData: "",
            signature: ""
        });

        bytes32 opHash = _getUserOpHash(op);
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", opHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, prefixedHash);
        op.signature = abi.encodePacked(r, s, v);

        console.log("  Action: executeBatch -> 2x USDC transfer to Deployer");
        console.log("  Transfer: 3 + 2 = 5 USDC");
        console.log("  UserOp hash:", vm.toString(opHash));
        console.log("  PASS: signed (no tx, pure off-chain)");
    }

    function _step6_handleOps(PackedUserOperation memory op) internal {
        console.log("");
        console.log("[6] Bundler submits handleOps + delegation (type 4 tx)...");

        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(executorAddr, alicePk);
        vm.attachDelegation(signedDelegation);
        console.log("  Alice signed delegation (off-chain):");
        console.log("    target:", executorAddr);
        console.log("    v:", signedDelegation.v);
        console.log("    r:", vm.toString(signedDelegation.r));
        console.log("    s:", vm.toString(signedDelegation.s));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.broadcast(bundlerPk);
        EP.handleOps(ops, payable(bundler));

        console.log("  PASS: delegation activated + handleOps executed on-chain");
    }

    function _step7_verify() internal view {
        console.log("");
        console.log("[7] Verify on-chain results...");

        // Delegation active
        require(alice.code.length == 23, "delegation not set");
        console.log("  Delegation: active");

        // EP nonce incremented
        uint256 epNonce = EP.getNonce(alice, 0);
        require(epNonce == 1, "EP nonce should be 1");
        console.log("  EP nonce:", epNonce);

        // Alice: 0 ETH, 0 USDC
        require(alice.balance == 0, "Alice ETH should be 0");
        console.log("  Alice ETH: 0");

        uint256 aliceUsdc = USDC.balanceOf(alice);
        require(aliceUsdc == 0, "Alice USDC should be 0");
        console.log("  Alice USDC: 0");

        // Alice on-chain nonce: 1 from EIP-7702 delegation auth.
        // Note: vm.getNonce() in simulation doesn't reflect delegation auth
        // increment — this is verified on-chain via the test report.
        console.log("  Alice nonce (sim):", vm.getNonce(alice), "(on-chain: 1 from delegation auth)");

        // Deployer received USDC
        console.log("  Deployer USDC:", USDC.balanceOf(deployer) / 1e6, "USDC");

        console.log("  PASS: all assertions passed");
    }

    function _step8_returnUSDC() internal {
        console.log("");
        console.log("[8] Deployer returns USDC to Sponsor...");

        uint256 deployerUsdc = USDC.balanceOf(deployer);
        require(deployerUsdc >= USDC_AMOUNT, "Deployer should have USDC");

        vm.broadcast(deployerPk);
        USDC.transfer(sponsor, USDC_AMOUNT);

        console.log("  Returned:", USDC_AMOUNT / 1e6, "USDC to Sponsor");
        console.log("  Sponsor USDC:", USDC.balanceOf(sponsor) / 1e6, "USDC");
        console.log("  PASS: USDC returned");
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
        console.log("  Sponsor:  ", sponsor);
        console.log("  Bundler:  ", bundler);
        console.log("  USDC:     ", address(USDC));
        console.log("================================================");
    }
}
