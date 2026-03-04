// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { MinimalAccount } from "../src/MinimalAccount.sol";
import { PackedUserOperation } from "../src/interfaces/PackedUserOperation.sol";

interface IEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
}

/// @title E2E4337 — Full ERC-4337 Sponsored Gasless Flow
/// @notice Four actors:
///   - Deployer: deploys MinimalAccount (fresh each run)
///   - Sponsor:  deposits to EntryPoint for Alice (gas sponsorship) and
///              funds Alice with ETH for transfers. In production this role
///              is typically a Paymaster contract; here we use a plain EOA.
///   - Bundler:  submits handleOps tx to EntryPoint (pays tx gas, recouped
///              from UserOp prefund)
///   - Alice:    fresh EOA with 0 ETH, signs delegation + UserOp off-chain
///
/// @dev Usage:
///   source .env
///   forge script script/E2E4337.s.sol --rpc-url $RPC_URL --broadcast --slow --gas-estimate-multiplier 500
contract E2E4337 is Script {
    IEntryPoint constant EP = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    uint256 constant FUND_AMT = 0.0001 ether; // Alice's total funds for transfers

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

        // Fresh Alice each run — deterministic within a single broadcast
        alicePk = uint256(keccak256(abi.encodePacked("alice-e2e", block.number, block.timestamp)));
        alice = vm.addr(alicePk);

        _header();
        _step1_deploy();
        _step2_verifyAlice();
        _step3_deposit();
        _step4_fund();

        PackedUserOperation memory op = _step5_signUserOp();

        _step6_handleOps(op);
        _step7_verify();
        _footer();
    }

    function _header() internal view {
        console.log("================================================");
        console.log("  ERC-4337 Sponsored Gasless E2E");
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
        console.log("[2] Verify Alice starts with 0 ETH...");
        require(alice.balance == 0, "Alice should have 0 balance");
        require(alice.code.length == 0, "Alice should have no code");
        console.log("  PASS: balance = 0, no code");
    }

    function _step3_deposit() internal {
        console.log("");
        console.log("[3] Sponsor deposits to EntryPoint for Alice...");

        vm.broadcast(sponsorPk);
        EP.depositTo{ value: 0.01 ether }(alice);

        console.log("  PASS: deposited 0.01 ETH to EP for Alice");
    }

    function _step4_fund() internal {
        console.log("");
        console.log("[4] Sponsor funds Alice for transfer values...");

        vm.broadcast(sponsorPk);
        (bool ok,) = alice.call{ value: FUND_AMT }("");
        require(ok, "fund failed");

        console.log("  Amount:", FUND_AMT, "wei");
        console.log("  PASS: funded");
    }

    /// @dev Compute userOpHash locally (same as EntryPoint.getUserOpHash)
    ///      to avoid simulation vs on-chain divergence.
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

        // Transfer all funded ETH back to Deployer (Alice ends with 0)
        // Split into 2 calls to test batch: half + half
        uint256 half = FUND_AMT / 2;
        MinimalAccount.Call[] memory calls = new MinimalAccount.Call[](2);
        calls[0] = MinimalAccount.Call(deployer, half, "");
        calls[1] = MinimalAccount.Call(deployer, half, "");

        op = PackedUserOperation({
            sender: alice,
            nonce: 0,  // Fresh Alice, always 0
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, opHash);
        op.signature = abi.encodePacked(r, s, v);

        console.log("  Action: executeBatch -> 2x transfer to Deployer");
        console.log("  Transfer total:", FUND_AMT, "wei");
        console.log("  UserOp hash:", vm.toString(opHash));
        console.log("  PASS: signed (no tx, pure off-chain)");
    }

    function _step6_handleOps(PackedUserOperation memory op) internal {
        console.log("");
        console.log("[6] Bundler submits handleOps + delegation (type 4 tx)...");

        // Alice signs delegation (off-chain, nonce=0 for fresh account)
        vm.attachDelegation(vm.signDelegation(executorAddr, alicePk));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        // Bundler sends type 4 tx: sets delegation + executes handleOps
        vm.broadcast(bundlerPk);
        EP.handleOps(ops, payable(bundler));

        console.log("  Delegation: Alice ->", executorAddr);
        console.log("  PASS: handleOps executed on-chain");
    }

    function _step7_verify() internal view {
        console.log("");
        console.log("[7] Verify on-chain results...");

        // Delegation active
        require(alice.code.length == 23, "delegation not set");
        console.log("  Delegation: active (code.length = 23)");

        // EP nonce incremented
        uint256 epNonce = EP.getNonce(alice, 0);
        require(epNonce == 1, "EP nonce should be 1");
        console.log("  EP nonce:", epNonce);

        // Alice balance should be 0 (all transferred to Deployer)
        require(alice.balance == 0, "Alice balance should be 0");
        console.log("  Alice balance: 0 wei (all transferred)");

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
        console.log("  Sponsor:  ", sponsor);
        console.log("  Bundler:  ", bundler);
        console.log("================================================");
    }
}
