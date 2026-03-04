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

/// @title E2E Sponsored Transaction Test
/// @notice Two-actor scenario: EOA delegates + signs, Bundler pays all gas.
///         Single `forge script` invocation — no shell wrapper needed.
///
/// @dev Usage:
///   source .env
///   forge script script/E2ESponsored.s.sol --rpc-url $RPC_URL --broadcast --slow
///
/// Env vars:
///   PRIVATE_KEY         — EOA that delegates (signs auth + UserOp)
///   BUNDLER_PRIVATE_KEY — Bundler that deploys, deposits, and calls handleOps
contract E2ESponsored is Script {
    IEntryPoint constant EP = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    address constant T1 = 0x1111111111111111111111111111111111111111;
    address constant T2 = 0x2222222222222222222222222222222222222222;

    uint256 eoaPk;
    uint256 bundlerPk;
    address eoa;
    address bundler;
    address executorAddr;

    function run() external {
        eoaPk = vm.envUint("PRIVATE_KEY");
        bundlerPk = vm.envUint("BUNDLER_PRIVATE_KEY");
        eoa = vm.addr(eoaPk);
        bundler = vm.addr(bundlerPk);

        // Use existing deployment or deploy new
        executorAddr = vm.envOr("EXECUTOR", address(0));

        console.log("================================================");
        console.log("  EIP-7702 Sponsored Transaction E2E");
        console.log("================================================");
        console.log("  EOA (delegator):", eoa);
        console.log("  Bundler (payer):", bundler);
        console.log("================================================");

        if (executorAddr == address(0)) {
            _step1_deploy();
        } else {
            console.log("");
            console.log("[1] Using existing BatchExecutor:", executorAddr);
        }
        _step2_deposit();
        _step3_sponsoredUserOp();

        console.log("");
        console.log("================================================");
        console.log("  ALL TESTS PASSED");
        console.log("================================================");
    }

    /// @dev Bundler deploys the implementation contract
    function _step1_deploy() internal {
        console.log("");
        console.log("[1] Bundler deploys BatchExecutor...");

        vm.broadcast(bundlerPk);
        BatchExecutor impl = new BatchExecutor();
        executorAddr = address(impl);

        require(executorAddr.code.length > 0, "deploy failed");
        console.log("  PASS: deployed at", executorAddr);
    }

    /// @dev Bundler deposits ETH to EntryPoint for EOA (sponsorship)
    ///      and funds EOA with ETH for transfer values
    function _step2_deposit() internal {
        console.log("");
        console.log("[2] Bundler sponsors EOA...");

        // Deposit to EntryPoint (pays for gas via 4337)
        vm.broadcast(bundlerPk);
        EP.depositTo{ value: 0.01 ether }(eoa);
        console.log("  Deposited 0.01 ETH to EntryPoint for EOA");

        // Fund EOA with ETH for the actual transfers
        vm.broadcast(bundlerPk);
        (bool ok,) = eoa.call{ value: 0.0001 ether }("");
        require(ok, "fund eoa failed");
        console.log("  Funded EOA with 0.0001 ETH for transfers");

        console.log("  PASS: sponsorship setup complete");
    }

    /// @dev Full sponsored flow:
    ///      - EOA signs delegation + UserOp (off-chain, 0 gas)
    ///      - Bundler attaches delegation and submits handleOps (pays gas)
    function _step3_sponsoredUserOp() internal {
        console.log("");
        console.log("[3] Sponsored ERC-4337 UserOp...");

        // Build batch: EOA wants to transfer to T1 + T2
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
            accountGasLimits: bytes32(uint256(uint128(200_000)) << 128 | uint128(300_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32(uint256(uint128(2 gwei)) << 128 | uint128(50 gwei)),
            paymasterAndData: "",
            signature: ""
        });

        // EOA signs the UserOp hash (off-chain, no tx)
        bytes32 opHash = EP.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPk, opHash);
        op.signature = abi.encodePacked(r, s, v);

        // Record pre-state
        uint256 bal1Before = T1.balance;
        uint256 bal2Before = T2.balance;
        uint256 bundlerBalBefore = bundler.balance;

        // EOA signs delegation (off-chain), Bundler attaches and submits
        vm.attachDelegation(vm.signDelegation(executorAddr, eoaPk));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.broadcast(bundlerPk);
        EP.handleOps(ops, payable(bundler));

        // Verify transfers
        require(T1.balance - bal1Before == 0.00001 ether, "T1 transfer failed");
        require(T2.balance - bal2Before == 0.00001 ether, "T2 transfer failed");
        console.log("  PASS: batch transfers executed");

        // Verify nonce
        require(EP.getNonce(eoa, 0) == nonce + 1, "nonce not incremented");
        console.log("  PASS: nonce incremented");

        // Verify delegation
        require(eoa.code.length == 23, "delegation not active");
        console.log("  PASS: delegation active");

        console.log("");
        console.log("  Flow summary:");
        console.log("    EOA: signed delegation + UserOp (0 tx, 0 gas)");
        console.log("    Bundler: deploy + deposit + fund + handleOps (paid all gas)");
    }
}
