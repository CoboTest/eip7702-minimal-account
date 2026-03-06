// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PackedUserOperation, IEntryPoint, IPaymaster } from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title MockVerifyingPaymaster
/// @notice A minimal verifying paymaster for E2E testing.
///         The paymaster owner signs a hash of (userOp.sender, userOp.nonce, validUntil, validAfter)
///         and the paymaster verifies that signature in validatePaymasterUserOp.
contract MockVerifyingPaymaster is IPaymaster {
    IEntryPoint public immutable entryPoint;
    address public immutable owner;

    error OnlyEntryPoint();

    modifier onlyEP() {
        if (msg.sender != address(entryPoint)) revert OnlyEntryPoint();
        _;
    }

    constructor(IEntryPoint _ep, address _owner) {
        entryPoint = _ep;
        owner = _owner;
    }

    /// @dev paymasterAndData layout:
    ///   [0:20]   paymaster address (standard, not part of paymasterData)
    ///   [20:36]  paymasterVerificationGasLimit (uint128, packed by EP)
    ///   [36:52]  paymasterPostOpGasLimit (uint128, packed by EP)
    ///   [52:58]  validUntil (uint48)
    ///   [58:64]  validAfter (uint48)
    ///   [64:129] signature (65 bytes: r,s,v)
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /* userOpHash */,
        uint256 /* maxCost */
    ) external onlyEP returns (bytes memory context, uint256 validationData) {
        // Decode paymasterData (after the 52-byte header)
        bytes calldata pmData = userOp.paymasterAndData[52:];
        require(pmData.length == 77, "bad pmData length"); // 6+6+65 = 77

        uint48 validUntil = uint48(bytes6(pmData[0:6]));
        uint48 validAfter = uint48(bytes6(pmData[6:12]));
        bytes calldata signature = pmData[12:77];

        // Verify owner signed (sender, nonce, validUntil, validAfter)
        bytes32 hash = keccak256(abi.encode(userOp.sender, userOp.nonce, validUntil, validAfter));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        address recovered = ECDSA.recover(ethHash, signature);

        if (recovered != owner) {
            // Return SIG_VALIDATION_FAILED (aggregator = address(1))
            validationData = _packValidation(false, validAfter, validUntil);
        } else {
            validationData = _packValidation(true, validAfter, validUntil);
        }

        context = "";
    }

    function postOp(
        PostOpMode,
        bytes calldata,
        uint256,
        uint256
    ) external onlyEP {}

    /// @dev Deposit ETH to EntryPoint for this paymaster
    function deposit() external payable {
        entryPoint.depositTo{ value: msg.value }(address(this));
    }

    /// @dev Stake to the EntryPoint
    function addStake(uint32 unstakeDelaySec) external payable {
        entryPoint.addStake{ value: msg.value }(unstakeDelaySec);
    }

    function _packValidation(bool success, uint48 validAfter, uint48 validUntil)
        internal pure returns (uint256)
    {
        // ERC-4337 validationData packing:
        // [0:6] validAfter, [6:12] validUntil, [12:32] aggregator/authorizer
        // aggregator = 0 for success, 1 for failure
        uint160 authorizer = success ? 0 : 1;
        return uint256(validAfter) << 208 | uint256(validUntil) << 160 | authorizer;
    }

    receive() external payable {}
}
