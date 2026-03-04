// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PackedUserOperation } from "./PackedUserOperation.sol";

/// @title IAccount
/// @notice ERC-4337 v0.7 account interface.
interface IAccount {
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
}
